#!/usr/bin/env bash
# Keep the README's version table in step with versions.json, the only place versions live.
#
# Usage: scripts/readme-versions.sh [--check] [README.md] [versions.json]
#
# Purpose: the table under "Images and tags" was edited by hand and went stale whenever a
# workflow moved a channel. The table now sits between two marker comments,
#   <!-- versions:start -->  ...  <!-- versions:end -->
# and this script regenerates everything between them.
#
# Contract:
#   - default mode rewrites the block in place (atomically, via a temp file next to the
#     README) and leaves every other line untouched; running it twice changes nothing;
#   - --check writes nothing and exits 1 with the command to run when the block is stale
#     (the CI lint job runs this);
#   - exit 2 when a marker is missing or jq is absent: a README without markers must fail
#     loudly, never be skipped.
# The detect-* workflows run it after they bump versions.json, so their pull requests carry the
# matching README.
set -euo pipefail

check=0
if [ "${1:-}" = "--check" ]; then
  check=1
  shift
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
readme="${1:-${root}/README.md}"
versions="${2:-${root}/versions.json}"
start_marker='<!-- versions:start -->'
end_marker='<!-- versions:end -->'

command -v jq >/dev/null || {
  echo "readme-versions.sh: jq is required" >&2
  exit 2
}
if ! grep -q -F -x -- "${start_marker}" "${readme}" || ! grep -q -F -x -- "${end_marker}" "${readme}"; then
  echo "readme-versions.sh: ${readme} must contain the lines '${start_marker}' and '${end_marker}'" >&2
  exit 2
fi

# table: print the generated Markdown table for both channels.
table() {
  local ibc_version ibc_tag ibc_repo channel version minor
  ibc_version="$(jq -r '.ibc.version' "${versions}")"
  ibc_tag="$(jq -r '.ibc.release_tag' "${versions}")"
  ibc_repo="$(jq -r '.ibc.repo' "${versions}")"
  printf '%s\n' '| IBKR channel | IB Gateway | IBC | Tags |' '|---|---|---|---|'
  for channel in stable latest; do
    version="$(jq -r --arg ch "${channel}" '.channels[$ch].version' "${versions}")"
    minor="$(printf '%s' "${version}" | cut -d. -f1,2)"
    printf '| %s | %s | %s (%s `%s`) | `%s`, `%s`, `%s` |\n' \
      "${channel}" "${version}" "${ibc_version}" "${ibc_repo}" "${ibc_tag}" "${channel}" "${minor}" "${version}"
  done
}

# render: print the README with the block between the markers replaced by the table.
render() {
  local line inside=0
  while IFS= read -r line || [ -n "${line}" ]; do
    if [ "${line}" = "${start_marker}" ]; then
      printf '%s\n' "${line}"
      table
      inside=1
    elif [ "${line}" = "${end_marker}" ]; then
      printf '%s\n' "${line}"
      inside=0
    elif [ "${inside}" -eq 0 ]; then
      printf '%s\n' "${line}"
    fi
  done <"${readme}"
}

tmp="$(mktemp "${TMPDIR:-/tmp}/readme-versions.XXXXXX")"
trap 'rm -f "${tmp}"' EXIT
render >"${tmp}"

if cmp -s "${tmp}" "${readme}"; then
  exit 0
fi
if [ "${check}" -eq 1 ]; then
  echo "README version table is out of date with versions.json; run: scripts/readme-versions.sh" >&2
  exit 1
fi
cat "${tmp}" >"${readme}"
