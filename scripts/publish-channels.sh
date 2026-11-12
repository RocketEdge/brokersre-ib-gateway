#!/usr/bin/env bash
# Turn the `channels` input of publish.yml into the JSON list its build matrix runs over.
#
# Purpose: the input is free text from whoever dispatches the workflow (a person, or rebuild.yml),
# and the jobs it selects can push to the registry and mint the signing identity. The value
# must therefore never be pasted into a script. publish.yml hands it over in an environment
# variable and passes that, quoted, as this script's one argument; only the two channel names
# can come out.
#
# Contract:
#   publish-channels.sh "<list>"
#   list     channel names separated by spaces: `stable`, `latest`, or both, in any order,
#            repeated or not. Nothing else: no other character than lower-case letters and
#            spaces is accepted, so a line break, a tab, a glob or a command substitution is
#            refused as a whole.
#   stdout   one line, GITHUB_OUTPUT-ready: channels=["stable","latest"] (each name once,
#            stable first)
#   exit     0 on a list, 2 on bad input (message on stderr only: stdout is appended to
#            GITHUB_OUTPUT)
#
# An empty list is refused instead of meaning "both": publish.yml supplies the default itself
# (`inputs.channels || 'stable latest'`), so an empty value here is a mistake, and guessing
# would publish channels nobody asked for.
# No side effects; reads nothing but its argument. Needs bash only (no jq: the two names are
# fixed, so the JSON is written directly).
set -euo pipefail
# The list is never expanded as a file-name pattern, whatever the directory holds.
set -f

usage() {
  echo "usage: publish-channels.sh \"<stable|latest> [<stable|latest>]\"" >&2
  exit 2
}

refuse() {
  echo "publish-channels: $1" >&2
  exit 2
}

[ $# -eq 1 ] || usage
list="$1"

[[ "${list}" =~ ^[a-z\ ]*$ ]] || refuse "the channel list may hold only the names stable and latest, separated by spaces"

stable=0
latest=0
count=0
for name in ${list}; do
  case "${name}" in
    stable) stable=1 ;;
    latest) latest=1 ;;
    *) refuse "unknown channel '${name}' (expected stable or latest)" ;;
  esac
  count=$((count + 1))
done
[ "${count}" -gt 0 ] || refuse "the channel list is empty"

json=""
if [ "${stable}" -eq 1 ]; then json='"stable"'; fi
if [ "${latest}" -eq 1 ]; then json="${json:+${json},}\"latest\""; fi
printf 'channels=[%s]\n' "${json}"
