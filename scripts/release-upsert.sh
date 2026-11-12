#!/usr/bin/env bash
# Create or update a GitHub release so that it ends up with the given assets and notes, and
# repeat the whole update when GitHub answers with an error.
#
# Usage:
#   scripts/release-upsert.sh --tag <tag> --target <commit> --title <title> --notes-file <file>
#                             [--expect-in-notes <text>] [--remove-asset <name>]... <asset file>...
#
#   --tag              the release's tag; the release API creates the tag at --target when the
#                      release is new (GITHUB_TOKEN may not push a ref whose commit holds
#                      workflow files, so the tag is never pushed with git)
#   --target           commit a NEW release's tag points at; ignored for an existing release
#   --title            title of a new release
#   --notes-file       file holding the release notes (Markdown)
#   --expect-in-notes  text the notes of the finished release must contain (the digest):
#                      proof that the notes on GitHub are the new ones
#   --remove-asset     name of an asset that must not remain on the release (an asset of an
#                      older naming scheme); absent is fine; may be given several times
#   <asset file>...    files to attach; an asset of the same name is replaced
#
# Environment:
#   RELEASE_ATTEMPTS      whole attempts before giving up (default 5, at least 1)
#   RELEASE_RETRY_DELAYS  seconds to pause after attempt 1, 2, ... (default "5 15 45 90"; the
#                         last value is reused; 0 means no pause)
#   GH_TOKEN and GH_REPO, or a checkout: as the `gh` CLI expects them
#
# Why this exists: publish.yml moves the channel's tags to the new digest and writes the
# release afterwards. On 2026-11-13 GitHub answered HTTP 502 to the replacement of one asset,
# the step stopped, and the tags pointed at a new image while the release described the
# previous one until a person re-ran the job. Nothing here can make "tags, then release" one
# atomic step; what it does is make the second half survive a short outage.
#
# How: every part of the update can be repeated without harm, so one attempt is
#   1. ask whether the release exists (an error is an error, never "it does not exist");
#   2. exists: upload the assets with --clobber, delete the assets to remove that are listed,
#      rewrite the notes; does not exist: create it with assets, target, title and notes;
#   3. read the release back: every asset must be listed, no asset to remove may be listed,
#      and the notes must contain the expected text.
# A failure anywhere fails the attempt, and the next attempt starts again at 1, which is what
# turns a creation that died halfway into an update. The result is judged by step 3, not by
# exit codes: an asset GitHub accepted and does not list is a failure.
#
# Exit status: 0 the release is as asked; 1 it is not, after all attempts; 2 usage error
# (nothing was sent to GitHub).
# Side effects: creates or changes one release; pauses between attempts. Prints one line per
# failed attempt with GitHub's own message (it carries no secret: the token is never printed).
set -uo pipefail

usage() {
  sed -n '5,7p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

tag="" target="" title="" notes_file="" expect=""
remove=()
assets=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag | --target | --title | --notes-file | --expect-in-notes | --remove-asset)
      if [ "$#" -lt 2 ]; then
        echo "release-upsert.sh: $1 needs a value" >&2
        usage
      fi
      case "$1" in
        --tag) tag="$2" ;;
        --target) target="$2" ;;
        --title) title="$2" ;;
        --notes-file) notes_file="$2" ;;
        --expect-in-notes) expect="$2" ;;
        --remove-asset) remove+=("$2") ;;
      esac
      shift 2
      ;;
    --*)
      echo "release-upsert.sh: unknown option '$1'" >&2
      usage
      ;;
    *)
      assets+=("$1")
      shift
      ;;
  esac
done

attempts="${RELEASE_ATTEMPTS:-5}"
read -r -a delays <<<"${RELEASE_RETRY_DELAYS:-5 15 45 90}"
if [ -z "${tag}" ] || [ -z "${target}" ] || [ -z "${title}" ] || [ -z "${notes_file}" ]; then
  echo "release-upsert.sh: --tag, --target, --title and --notes-file are required" >&2
  usage
fi
if [ ! -r "${notes_file}" ]; then
  echo "release-upsert.sh: cannot read the notes file ${notes_file}" >&2
  exit 2
fi
if [ "${#assets[@]}" -eq 0 ]; then
  echo "release-upsert.sh: at least one asset file is required" >&2
  usage
fi
for asset in "${assets[@]}"; do
  if [ ! -r "${asset}" ] || [ ! -f "${asset}" ]; then
    echo "release-upsert.sh: cannot read the asset file ${asset}" >&2
    exit 2
  fi
done
if ! [[ "${attempts}" =~ ^[1-9][0-9]*$ ]]; then
  echo "release-upsert.sh: RELEASE_ATTEMPTS must be a whole number of at least 1" >&2
  exit 2
fi
for delay in "${delays[@]}"; do
  if ! [[ "${delay}" =~ ^[0-9]+$ ]]; then
    echo "release-upsert.sh: RELEASE_RETRY_DELAYS takes whole seconds separated by blanks" >&2
    exit 2
  fi
done

errors="$(mktemp)"
trap 'rm -f "${errors}"' EXIT
problem="" # why the current attempt failed; printed by the caller of attempt

# github <what it is for> <gh arguments...>: run gh; on failure set `problem` to the purpose
# and GitHub's own message, and return 1. Standard output passes through.
github() {
  local purpose="$1"
  shift
  if gh "$@" 2>"${errors}"; then return 0; fi
  problem="${purpose}: $(tr '\n' ' ' <"${errors}" | cut -c1-300)"
  return 1
}

# release_exists: 0 the release exists; 1 GitHub says there is none; 2 the question failed
# (then `problem` is set). "No answer" must never be read as "no release": the next step
# would try to create a release that is already there.
release_exists() {
  if gh release view "${tag}" >/dev/null 2>"${errors}"; then return 0; fi
  if grep -i 'release not found' "${errors}" >/dev/null; then return 1; fi
  problem="asking whether the release exists: $(tr '\n' ' ' <"${errors}" | cut -c1-300)"
  return 2
}

# listed_assets: print the names of the release's assets, one per line.
listed_assets() {
  github "listing the assets" release view "${tag}" --json assets --jq '.assets[].name'
}

# attempt: one whole create-or-update followed by the read-back. Returns 0 when the release
# is as asked; otherwise 1 with `problem` set.
attempt() {
  local state listing name notes
  release_exists
  state=$?
  case "${state}" in
    0)
      github "replacing the assets" release upload "${tag}" "${assets[@]}" --clobber >/dev/null || return 1
      if [ "${#remove[@]}" -gt 0 ]; then
        listing="$(listed_assets)" || return 1
        for name in "${remove[@]}"; do
          if grep -x -F -- "${name}" <<<"${listing}" >/dev/null; then
            github "removing the asset ${name}" release delete-asset "${tag}" "${name}" --yes >/dev/null || return 1
          fi
        done
      fi
      github "rewriting the notes" release edit "${tag}" --notes-file "${notes_file}" >/dev/null || return 1
      ;;
    1)
      github "creating the release" release create "${tag}" "${assets[@]}" --target "${target}" \
        --title "${title}" --notes-file "${notes_file}" >/dev/null || return 1
      ;;
    *) return 1 ;;
  esac
  # Read back: the release must be what was asked for, whatever the exit codes said.
  listing="$(listed_assets)" || return 1
  for asset in "${assets[@]}"; do
    name="$(basename "${asset}")"
    if ! grep -x -F -- "${name}" <<<"${listing}" >/dev/null; then
      problem="the release does not list the asset ${name} after the update"
      return 1
    fi
  done
  for name in "${remove[@]}"; do
    if grep -x -F -- "${name}" <<<"${listing}" >/dev/null; then
      problem="the release still lists the asset ${name}, which was to be removed"
      return 1
    fi
  done
  if [ -n "${expect}" ]; then
    notes="$(github "reading the notes back" release view "${tag}" --json body --jq '.body')" || return 1
    if ! grep -F -- "${expect}" <<<"${notes}" >/dev/null; then
      problem="the notes of the release do not contain the expected text after the update"
      return 1
    fi
  fi
  return 0
}

number=1
while true; do
  problem=""
  if attempt; then
    echo "release-upsert.sh: release ${tag} holds ${#assets[@]} asset(s) and the new notes (attempt ${number} of ${attempts})"
    exit 0
  fi
  echo "release-upsert.sh: attempt ${number} of ${attempts} failed: ${problem}"
  if [ "${number}" -ge "${attempts}" ]; then break; fi
  # The pause after attempt n is the n-th value; the last value is reused.
  index=$((number - 1))
  if [ "${index}" -ge "${#delays[@]}" ]; then index=$((${#delays[@]} - 1)); fi
  if [ "${index}" -ge 0 ] && [ "${delays[index]}" -gt 0 ]; then sleep "${delays[index]}"; fi
  number=$((number + 1))
done
echo "release-upsert.sh: release ${tag} could not be written in ${attempts} attempts; last problem: ${problem}"
exit 1
