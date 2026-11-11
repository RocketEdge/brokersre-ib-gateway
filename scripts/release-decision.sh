#!/usr/bin/env bash
# Decide what detect-releases.yml does with what IBKR serves on one channel.
#
# Purpose: one testable place for the release policy (docs/upgrade-policy.md), instead of
# expressions spread over workflow steps.
#
# Contract:
#   release-decision.sh <channel> <pinned_version> <pinned_x64> <pinned_arm> \
#                       <ibkr_version> <ibkr_x64> <ibkr_arm>
#   channel        stable | latest
#   *_version      IBKR build label, e.g. 10.50.1g (non-empty)
#   *_x64, *_arm   SHA-256 of the installers, 64 hex digits, compared case-insensitively
#   stdout         two lines, GITHUB_OUTPUT-ready:
#                    action=none|new-version|reupload
#                    automerge=true|false
#   exit           0 on a decision, 2 on bad input (message on stderr only: stdout is appended
#                  to GITHUB_OUTPUT, where a stray line would break the runner's parser)
#
# Policy:
#   * new-version: IBKR's version differs from the pin -> pull request. It auto-merges only when
#     all of these hold, otherwise a human merges it:
#       - the channel is stable (the channel ci.yml builds and container-tests);
#       - the new version sorts higher than the pin (`sort -V`), so a cached or rolled-back
#         manifest never downgrades the image by itself;
#       - both installers' bytes changed, so a new label over the old download (a stale cache)
#         never ships as a "new" build.
#   * reupload: same version, different bytes (IBKR replaced 10.51.1e on 2026-11-05 without a
#     new label) -> a human decides; never auto-merged.
#   * none: same version, same bytes.
# No side effects; reads nothing but its arguments.
set -euo pipefail

usage() {
  echo "usage: release-decision.sh <stable|latest> <pinned_version> <pinned_x64> <pinned_arm> <ibkr_version> <ibkr_x64> <ibkr_arm>" >&2
  exit 2
}

refuse() {
  echo "release-decision: $1" >&2
  exit 2
}

[ $# -eq 7 ] || usage
channel="$1"
pinned_version="$2"
pinned_x64="${3,,}"
pinned_arm="${4,,}"
ibkr_version="$5"
ibkr_x64="${6,,}"
ibkr_arm="${7,,}"

case "${channel}" in
  stable | latest) ;;
  *) refuse "unknown channel '${channel}' (expected stable or latest)" ;;
esac
[ -n "${pinned_version}" ] || refuse "empty pinned version"
[ -n "${ibkr_version}" ] || refuse "empty IBKR version (manifest not parsed?)"
for hash in "${pinned_x64}" "${pinned_arm}" "${ibkr_x64}" "${ibkr_arm}"; do
  [[ "${hash}" =~ ^[0-9a-f]{64}$ ]] || refuse "'${hash}' is not a SHA-256 (64 hex digits)"
done

if [ "${ibkr_version}" != "${pinned_version}" ]; then
  action=new-version
elif [ "${ibkr_x64}" != "${pinned_x64}" ] || [ "${ibkr_arm}" != "${pinned_arm}" ]; then
  action=reupload
else
  action=none
fi

automerge=false
if [ "${action}" = new-version ] && [ "${channel}" = stable ]; then
  newest="$(printf '%s\n%s\n' "${pinned_version}" "${ibkr_version}" | sort -V | tail -n 1)"
  if [ "${newest}" = "${ibkr_version}" ] \
    && [ "${ibkr_x64}" != "${pinned_x64}" ] && [ "${ibkr_arm}" != "${pinned_arm}" ]; then
    automerge=true
  fi
fi

printf 'action=%s\nautomerge=%s\n' "${action}" "${automerge}"
