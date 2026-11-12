#!/usr/bin/env bash
# Check the OpenVEX document for IBKR's bundled jars against what Trivy reports for the image.
#
# Purpose: IB Gateway ships third-party jars with known CVEs that this image cannot patch
# (docs/limitations.md L08). security/vex/ibgateway-vendor-jars.openvex.json states this
# project's position on each of them. A statement list written once goes out of date in both
# directions: a new CVE is published for a bundled jar, or IBKR ships a newer jar and a CVE
# disappears. This script names both kinds of drift, so the document cannot quietly claim
# more, or less, than the scanner sees.
#
# Contract:
#   check-vex.sh <openvex.json> [<trivy-report.json> ...]
#   openvex.json   the OpenVEX document (spec v0.2.0)
#   report         Trivy JSON reports (SchemaVersion 2) of the image that cover its jars and
#                  are NOT filtered: `trivy image --pkg-types library --list-all-pkgs
#                  --format json`, without --severity and without --ignore-unfixed (a filtered
#                  report would make statements look stale). Give the reports of every channel
#                  and platform that was scanned; the comparison uses their union.
#   stdout         one line per drift item, notes, and a summary line
#   exit           0  no report given and the document is valid, or document and reports agree
#                  1  drift: a jar finding without a statement (MISSING) or a statement without
#                     a jar finding in any report (STALE)
#                  2  bad input: unreadable or invalid document, unreadable report, or a report
#                     that did not scan the jars (messages on stderr only)
#
# What "agree" means: a finding is the pair (vulnerability id, package URL of the jar) from a
# Trivy result of class `lang-pkgs` and type `jar`. A statement covers a finding when one of
# its products names that package URL as a subcomponent and the finding's id equals the
# statement's vulnerability name or one of its aliases. The version is part of the package
# URL, so a CVE that persists in a newer jar needs a new statement: a new version deserves a
# new look. Findings in other language packages (for example a Go binary of the base image)
# are printed as notes; they are outside this document.
#
# Rules checked on the document (OpenVEX v0.2.0 plus this repository's policy):
#   * @context is https://openvex.dev/ns/v0.2.0; @id, author, timestamp, version and a
#     non-empty statements list are present;
#   * status is not_affected, affected or under_investigation. `fixed` is refused: this image
#     never modifies IBKR's application, so it can never have fixed a vendor jar;
#   * not_affected needs a justification label of the specification AND an impact_statement;
#     affected needs an action_statement; under_investigation needs status_notes saying what
#     is unknown;
#   * every product is the image as a package URL without version or digest
#     (pkg:oci/<name>?repository_url=...), so the statement keeps matching after the next
#     build, and names at least one pkg:maven subcomponent with a version, so it never covers
#     the whole image;
#   * no two statements cover the same (vulnerability name, jar).
# No side effects; reads only the files named in its arguments. Needs jq.
set -euo pipefail

usage() {
  echo "usage: check-vex.sh <openvex.json> [<trivy-report.json> ...]" >&2
  exit 2
}

refuse() {
  echo "check-vex: $1" >&2
  exit 2
}

# run_jq PROGRAM FILE WHAT: print the program's output for FILE (slurp mode), or refuse with
# jq's reason. Runs jq a second time only to fetch that reason, so stdout never carries it.
run_jq() {
  local program="$1" file="$2" what="$3" out reason
  if [ ! -f "${file}" ] || [ ! -r "${file}" ]; then refuse "${what} '${file}' is not a readable file"; fi
  [ -s "${file}" ] || refuse "${what} '${file}' is empty"
  if ! out="$(jq -s -r "${program}" "${file}" 2>/dev/null)"; then
    reason="$(jq -s -r "${program}" "${file}" 2>&1 >/dev/null | tail -n 1 || true)"
    refuse "${what} '${file}' is not usable: ${reason}"
  fi
  printf '%s\n' "${out}"
}

[ $# -ge 1 ] || usage
vex="$1"
shift
command -v jq >/dev/null 2>&1 || refuse "jq is required"

# jq helper shared by the programs below: true for a non-empty string without white space.
# No anchors: `^` and `$` match per line in jq's regular expressions, a negated or POSIX class
# does not let a line break through.
token_def='def token: type == "string" and . != "" and (test("[[:space:]]") | not);'

# Prints `S <name> <jar purl>` per covered pair and `A <alias> <name> <jar purl>` per alias;
# fails with the reason when the document breaks a rule from the header.
# shellcheck disable=SC2016  # $name, $jar and the like are jq variables, not shell ones
vex_program="${token_def}"'
  def text: type == "string" and . != "";
  if length != 1 then error("expected exactly one JSON document")
  else .[0]
  | if type != "object" then error("not a JSON object")
    elif ."@context" != "https://openvex.dev/ns/v0.2.0" then error("@context must be https://openvex.dev/ns/v0.2.0")
    elif (."@id" | text | not) then error("@id is required")
    elif (.author | text | not) then error("author is required")
    elif (.timestamp | text | not) then error("timestamp is required")
    elif (.version | type) != "number" or .version < 1 then error("version must be a number of at least 1")
    elif (.statements | type) != "array" or (.statements | length) == 0 then error("statements must be a non-empty list")
    else
      .statements[]
      | (.vulnerability.name) as $name
      | if ($name | token | not) then error("a statement has no vulnerability.name (a single token)")
        elif .status == "fixed" then error($name + ": status fixed is not allowed (this image never patches a vendor jar)")
        elif (.status | IN("not_affected", "affected", "under_investigation") | not) then error($name + ": status must be not_affected, affected or under_investigation")
        elif .status == "not_affected"
             and ((.justification | IN("component_not_present", "vulnerable_code_not_present", "vulnerable_code_not_in_execute_path", "vulnerable_code_cannot_be_controlled_by_adversary", "inline_mitigations_already_exist") | not)
                  or (.impact_statement | text | not))
          then error($name + ": not_affected needs a justification label of the specification and an impact_statement")
        elif .status == "affected" and (.action_statement | text | not) then error($name + ": affected needs an action_statement")
        elif .status == "under_investigation" and (.status_notes | text | not) then error($name + ": under_investigation needs status_notes that say what is unknown")
        elif (.products | type) != "array" or (.products | length) == 0 then error($name + ": products is required")
        elif ([.vulnerability.aliases // [] | .[] | token] | all | not) then error($name + ": an alias is not a single token")
        else
          (.vulnerability.aliases // []) as $aliases
          | .products[]
          | (."@id") as $product
          | if ($product | token | not) or ($product | startswith("pkg:oci/") | not) or ($product | contains("?repository_url=") | not)
              then error($name + ": the product must be the image as a package URL (pkg:oci/<name>?repository_url=...)")
            elif ($product | contains("@")) then error($name + ": the product must not carry a version or digest (it would stop matching with the next build)")
            elif (.subcomponents | type) != "array" or (.subcomponents | length) == 0
              then error($name + ": every product needs subcomponents (the package URL of the jar); without them the statement covers the whole image")
            else
              .subcomponents[]
              | (."@id") as $jar
              | if ($jar | token | not) or ($jar | startswith("pkg:maven/") | not) or ($jar | contains("@") | not)
                  then error($name + ": a subcomponent must be a pkg:maven package URL with a version")
                else "S \($name) \($jar)", ($aliases[] | "A \(.) \($name) \($jar)")
                end
            end
        end
    end
  end'

# Prints `F <id> <jar purl>` per jar finding and `N <id> <purl or package> <target>` per finding
# in another language package; fails when the report is not a Trivy image report that covers jars.
# shellcheck disable=SC2016  # $id, $pkg and the like are jq variables, not shell ones
report_program="${token_def}"'
  if length != 1 then error("expected exactly one JSON document")
  else .[0]
  | if type != "object" then error("not a JSON object")
    elif .SchemaVersion != 2 then error("not a Trivy report (SchemaVersion 2 expected)")
    elif .ArtifactType != "container_image" then error("not a container image report")
    elif (.Results | type) != "array" then error("no Results list")
    elif ([.Results[] | select(.Class == "lang-pkgs" and .Type == "jar")] | length) == 0
      then error("no jar result: the scan did not cover the jars (run trivy with --pkg-types library --list-all-pkgs, without --severity and --ignore-unfixed)")
    else
      .Results[] | select(.Class == "lang-pkgs")
      | .Type as $type | (.Target // "") as $target
      | (.Vulnerabilities // [])[]
      | (.VulnerabilityID) as $id | (.PkgIdentifier.PURL // .PkgName) as $pkg
      | if ($id | token | not) or ($pkg | token | not) then error("a finding has no plain id or package")
        elif $type == "jar" then "F \($id) \($pkg)"
        else "N \($id) \($pkg) \($target | gsub("[[:space:]]"; "_"))"
        end
    end
  end'

# A refusal inside $(...) ends only the subshell; `set -e` then ends the script with its status.
vex_lines="$(run_jq "${vex_program}" "${vex}" document)"
declare -A statements=() aliases=() matched=()
while read -r kind first second third; do
  case "${kind}" in
    S)
      if [ -n "${statements["${first} ${second}"]:-}" ]; then
        refuse "document '${vex}' has more than one statement for ${first} ${second}"
      fi
      statements["${first} ${second}"]=1
      ;;
    A) aliases["${first} ${third}"]="${second} ${third}" ;;
    *) ;;
  esac
done <<<"${vex_lines}"

if [ $# -eq 0 ]; then
  echo "check-vex: valid: ${#statements[@]} statements in ${vex} (no report given, nothing compared)"
  exit 0
fi

findings=""
notes=""
for report in "$@"; do
  lines="$(run_jq "${report_program}" "${report}" report)"
  findings+="$(grep '^F ' <<<"${lines}" || true)"$'\n'
  notes+="$(grep '^N ' <<<"${lines}" || true)"$'\n'
done

missing=()
finding_count=0
while read -r _ id jar; do
  [ -n "${id}" ] || continue
  finding_count=$((finding_count + 1))
  key="${id} ${jar}"
  if [ -z "${statements["${key}"]:-}" ] && [ -n "${aliases["${key}"]:-}" ]; then key="${aliases["${key}"]}"; fi
  if [ -n "${statements["${key}"]:-}" ]; then
    matched["${key}"]=1
  else
    missing+=("${id} ${jar}")
  fi
done < <(printf '%s' "${findings}" | LC_ALL=C sort -u)

stale=()
while IFS= read -r key; do
  [ -n "${key}" ] || continue
  if [ -z "${matched["${key}"]:-}" ]; then stale+=("${key}"); fi
done < <(printf '%s\n' "${!statements[@]}" | LC_ALL=C sort)

while read -r _ id pkg target; do
  [ -n "${id}" ] || continue
  echo "check-vex: note: not a jar, outside this document: ${id} ${pkg} (${target})"
done < <(printf '%s' "${notes}" | LC_ALL=C sort -u)

for item in "${missing[@]}"; do
  echo "check-vex: MISSING (Trivy reports it, the document has no statement): ${item}"
done
for item in "${stale[@]}"; do
  echo "check-vex: STALE (the document has a statement, no scanned image reports it): ${item}"
done

if [ "${#missing[@]}" -gt 0 ] || [ "${#stale[@]}" -gt 0 ]; then
  echo "check-vex: drift: ${#missing[@]} missing, ${#stale[@]} stale (${#statements[@]} statements, ${finding_count} jar findings, $# report(s))"
  exit 1
fi
echo "check-vex: in sync: ${#statements[@]} statements cover ${finding_count} jar findings in $# report(s)"
