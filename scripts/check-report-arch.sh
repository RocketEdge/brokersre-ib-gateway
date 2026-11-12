#!/usr/bin/env bash
# Check that a Trivy report describes the platform the scan was asked to read.
#
# Purpose: publish.yml and rebuild.yml scan linux/amd64 and linux/arm64 of one image index from
# a linux/amd64 runner. The platform is chosen through an environment variable of the scanner
# action (TRIVY_PLATFORM). If that pass-through ever stopped working (the action renames it,
# a refactoring drops it), Trivy would silently read the runner's platform both times, both
# scans would pass and the arm64 image would again be published unscanned. This check makes
# that failure loud: the report itself says which platform it read.
#
# Contract:
#   check-report-arch.sh <trivy-report.json> <linux/amd64|linux/arm64>
#   report     a Trivy JSON report (SchemaVersion 2) of a container image
#   platform   the platform that was asked for
#   stdout     one line naming the report and the platform it covers
#   exit       0  the report covers that platform
#              1  it covers another platform (both are named)
#              2  bad input: unknown platform, or a report that is missing, not a Trivy image
#                 report or does not name its platform (message on stderr only). A report that
#                 cannot be read is never passed.
# No side effects; reads only the report. Needs jq.
set -euo pipefail

usage() {
  echo "usage: check-report-arch.sh <trivy-report.json> <linux/amd64|linux/arm64>" >&2
  exit 2
}

refuse() {
  echo "check-report-arch: $1" >&2
  exit 2
}

[ $# -eq 2 ] || usage
report="$1"
wanted="$2"
case "${wanted}" in
  linux/amd64 | linux/arm64) ;;
  *) refuse "unknown platform '${wanted}' (expected linux/amd64 or linux/arm64)" ;;
esac
command -v jq >/dev/null 2>&1 || refuse "jq is required"
if [ ! -f "${report}" ] || [ ! -r "${report}" ]; then refuse "report '${report}' is not a readable file"; fi
[ -s "${report}" ] || refuse "report '${report}' is empty"

# jq program (slurp mode): prints <os>/<architecture>, or fails with the reason. No anchors in
# the token check: a negated class also catches a line break.
platform_program='
  def word: type == "string" and . != "" and (test("[^a-z0-9]") | not);
  if length != 1 then error("expected exactly one JSON document")
  else .[0]
  | if type != "object" then error("not a JSON object")
    elif .SchemaVersion != 2 then error("not a Trivy report (SchemaVersion 2 expected)")
    elif .ArtifactType != "container_image" then error("not a container image report")
    elif (.Metadata.ImageConfig.os | word | not) or (.Metadata.ImageConfig.architecture | word | not)
      then error("the report does not name the platform it scanned (Metadata.ImageConfig.os and .architecture)")
    else "\(.Metadata.ImageConfig.os)/\(.Metadata.ImageConfig.architecture)"
    end
  end'

if ! found="$(jq -s -r "${platform_program}" "${report}" 2>/dev/null)"; then
  reason="$(jq -s -r "${platform_program}" "${report}" 2>&1 >/dev/null | tail -n 1 || true)"
  refuse "report '${report}' is not usable: ${reason}"
fi

if [ "${found}" != "${wanted}" ]; then
  echo "check-report-arch: ${report} covers ${found}, but ${wanted} was asked for: that platform was not scanned"
  exit 1
fi
echo "check-report-arch: ${report} covers ${found}"
