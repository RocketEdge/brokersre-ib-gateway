#!/usr/bin/env bash
# Decide whether the published image of one channel needs an OS-patch rebuild.
#
# Purpose: one testable place for the rebuild policy (docs/upgrade-policy.md, SECURITY.md).
# rebuild.yml scans the published digest of a channel every day and hands the Trivy reports to
# this script; the workflow only acts on the two lines printed here.
#
# Contract:
#   rebuild-decision.sh <channel> <trivy-report.json> [<trivy-report.json> ...]
#   channel        stable | latest (the channel the reports belong to; named in every refusal)
#   report         a Trivy JSON report (SchemaVersion 2) of a container image that covers OS
#                  packages; give one per platform of the same image (linux/amd64, linux/arm64)
#   stdout         two lines, GITHUB_OUTPUT-ready:
#                    action=none|rebuild
#                    cves=<vulnerability ids, each once, sorted (C locale), comma separated>
#   exit           0 on a decision, 2 on bad input (message on stderr only: stdout is appended
#                  to GITHUB_OUTPUT, where a stray line would break the runner's parser)
#
# Policy:
#   * rebuild: at least one report has a finding in OS packages (Trivy result class `os-pkgs`)
#     with severity CRITICAL or HIGH and a fixed version. That is the predicate of the Trivy
#     gate in ci.yml and publish.yml (--pkg-types os --severity CRITICAL,HIGH --ignore-unfixed),
#     applied here again so that a report written without those flags gives the same answer
#     (tests/bats/ci/rebuild-decision.bats compares both on a real image).
#   * none: no such finding. Findings without a fixed version are left out because a rebuild
#     would produce the same packages; findings in language packages (IBKR's bundled jars,
#     docs/limitations.md L08) are left out because an OS rebuild cannot change them.
#   * refused (exit 2), never `none`: a report that is missing, empty, not JSON, not a Trivy
#     image report, or without any OS-package result. An unreadable scan is not a clean scan.
#     A vulnerability id that is not a plain token is refused too: the ids are written to
#     GITHUB_OUTPUT and into an issue, and a line break in one would forge an output line.
# No side effects; reads nothing but its arguments. Needs jq.
set -euo pipefail

usage() {
  echo "usage: rebuild-decision.sh <stable|latest> <trivy-report.json> [<trivy-report.json> ...]" >&2
  exit 2
}

refuse() {
  echo "rebuild-decision: $1" >&2
  exit 2
}

[ $# -ge 2 ] || usage
channel="$1"
shift
case "${channel}" in
  stable | latest) ;;
  *) refuse "unknown channel '${channel}' (expected stable or latest)" ;;
esac
command -v jq >/dev/null 2>&1 || refuse "jq is required"

# jq program (slurp mode): prints one id per fixable CRITICAL/HIGH finding in OS packages, and
# fails with the reason when the input is not exactly one Trivy image report that covers OS
# packages. The id check has no anchors on purpose: a negated class also catches a line break,
# which `^...$` would let through (they match per line).
fixable_os_ids='
  if length != 1 then error("expected exactly one JSON document")
  else .[0]
  | if type != "object" then error("not a JSON object")
    elif .SchemaVersion != 2 then error("not a Trivy report (SchemaVersion 2 expected)")
    elif .ArtifactType != "container_image" then error("not a container image report")
    elif (.Results | type) != "array" then error("no Results array")
    elif ([.Results[] | select(.Class == "os-pkgs")] | length) == 0
      then error("no OS package result (class os-pkgs): the scan did not cover OS packages")
    else
      .Results[] | select(.Class == "os-pkgs") | (.Vulnerabilities // [])[]
      | select((.Severity == "CRITICAL" or .Severity == "HIGH") and ((.FixedVersion // "") != ""))
      | .VulnerabilityID
      | if type != "string" or . == "" or test("[^A-Za-z0-9._:-]")
          then error("unexpected vulnerability id (not a plain token)")
        else . end
    end
  end'

ids=""
for report in "$@"; do
  if [ ! -f "${report}" ] || [ ! -r "${report}" ]; then
    refuse "${channel}: report '${report}' is not a readable file"
  fi
  [ -s "${report}" ] || refuse "${channel}: report '${report}' is empty"
  if ! found="$(jq -s -r "${fixable_os_ids}" "${report}" 2>/dev/null)"; then
    # Second run only to fetch jq's reason; the first one keeps stdout free of error text.
    reason="$(jq -s -r "${fixable_os_ids}" "${report}" 2>&1 >/dev/null | tail -n 1 || true)"
    refuse "${channel}: report '${report}' is not usable: ${reason}"
  fi
  ids+="${found}"$'\n'
done

cves="$(printf '%s' "${ids}" | LC_ALL=C sort -u | sed '/^$/d' | paste -sd, -)"

if [ -n "${cves}" ]; then action=rebuild; else action=none; fi
printf 'action=%s\ncves=%s\n' "${action}" "${cves}"
