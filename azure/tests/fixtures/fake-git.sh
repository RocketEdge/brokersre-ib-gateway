#!/usr/bin/env bash
# Test double for git, installed as /usr/local/bin/git by apply-config.test.sh. A "remote"
# is the directory FAKE_PACKS, with one sub-directory per commit id holding that commit's
# files; FAKE_GIT_STATE remembers what was fetched and which commit is checked out.
#
#   git -C DIR init --quiet                          succeeds
#   git -C DIR cat-file -e COMMIT^{commit}           true when COMMIT was fetched before
#   git -C DIR fetch --quiet --depth 1 URL COMMIT    fails (128) for an unknown commit
#   git -C DIR archive COMMIT PATH...                a tar stream of the commit's PATHs
#   git -C DIR checkout --quiet --detach COMMIT      copies the commit's files into DIR
#   git -C DIR rev-parse HEAD                        the checked-out commit, or failure
set -euo pipefail

state="${FAKE_GIT_STATE:?}"
packs="${FAKE_PACKS:?}"
mkdir -p "${state}"

[[ "${1:-}" == -C ]] || exit 129
directory="$2"
shift 2
command="$1"
shift

case "${command}" in
  init) mkdir -p "${directory}" ;;
  cat-file)
    commit="${2%%^*}"
    [[ -e "${state}/fetched-${commit}" ]]
    ;;
  fetch)
    commit="${*: -1}"
    if [[ ! -d "${packs}/${commit}" ]]; then
      echo "fatal: remote error: upload-pack: not our ref ${commit}" >&2
      exit 128
    fi
    : >"${state}/fetched-${commit}"
    ;;
  archive)
    commit="$1"
    shift
    tar --create --directory "${packs}/${commit}" "$@"
    ;;
  checkout)
    commit="${*: -1}"
    [[ -e "${state}/fetched-${commit}" ]] || exit 128
    rm -rf "${directory:?}/compose" "${directory:?}/azure"
    cp -r "${packs}/${commit}/." "${directory}/"
    printf '%s\n' "${commit}" >"${state}/head"
    ;;
  rev-parse)
    [[ -e "${state}/head" ]] || exit 128
    cat "${state}/head"
    ;;
  *) exit 129 ;;
esac
