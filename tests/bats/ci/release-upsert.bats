#!/usr/bin/env bats
# Unit tests for scripts/release-upsert.sh: create or update a GitHub release so that it ends up
# with the given assets and notes, retrying when GitHub answers with an error.
# Runs wherever bash 5 exists:
#   tests/.bats-core/bin/bats tests/bats/ci
#
# The contract under test: publish.yml moves the channel's tags first and writes the release
# second. On 2026-11-13 GitHub answered HTTP 502 to the replacement of one release asset; the
# job stopped, and for 25 minutes the tags pointed at a new image while the release described
# the previous one. Every step of the release update is repeatable, so the script repeats the
# whole update until the release is right or the attempts are used up, and it checks the result
# instead of trusting exit codes.
#
# `gh` is a stand-in on PATH. Its state is four files (does the release exist, is it a draft,
# its asset names, its notes); a file `fail.<name>` holding a number makes that call fail that
# many times with the text GitHub sent. The stand-in follows what gh 2.81.0 does, as an
# independent review measured it against a local API: `gh release view` finds a draft,
# answers "release not found" with exit 1 only when there is none, and `gh release create`
# with assets makes a draft, uploads and publishes, so a creation that dies halfway and
# cannot clean up leaves a DRAFT behind.

bats_require_minimum_version 1.5.0 # `run --separate-stderr`

setup() {
  REPO="${BATS_TEST_DIRNAME}/../../.."
  SCRIPT="${REPO}/scripts/release-upsert.sh"
  WORK="$(mktemp -d)"
  STATE="${WORK}/state"
  CALLS="${WORK}/calls"
  mkdir -p "${WORK}/bin" "${STATE}" "${WORK}/assets"
  : >"${CALLS}"
  : >"${STATE}/assets"
  printf 'digest file\n' >"${WORK}/assets/digests-stable.json"
  printf 'sbom one\n' >"${WORK}/assets/sbom-stable-linux-amd64.cdx.json"
  printf 'sbom two\n' >"${WORK}/assets/sbom-stable-linux-arm64.cdx.json"
  printf 'Pin this exact build: image@sha256:abc123\n\nSecond paragraph.\n' >"${WORK}/notes.md"
  cat >"${WORK}/bin/gh" <<'STANDIN'
#!/usr/bin/env bash
# Stand-in for the GitHub CLI: only the `release` subcommands the script under test may use.
set -u
state="${GH_STANDIN_STATE:?}"
printf '%s\n' "$*" >>"${GH_STANDIN_CALLS:?}"
[ "${1:-}" = "release" ] || { echo "stand-in gh: only 'release' is known, got: $*" >&2; exit 64; }
sub="${2:-}"
tag="${3:-}"
shift 3 || true
# fail_if_told <name>: fail with GitHub's text while the counter file holds a positive number.
fail_if_told() {
  local counter="${state}/fail.$1" left
  [ -f "${counter}" ] || return 0
  left="$(cat "${counter}")"
  if [ "${left}" -gt 0 ]; then
    echo "$((left - 1))" >"${counter}"
    echo "HTTP 502: Server Error (https://api.github.com/repos/o/r/releases/assets/741261409)" >&2
    exit 1
  fi
}
case "${sub}" in
  view)
    fail_if_told view
    # One counter per kind of question, so a test can fail exactly the read-back it means.
    case "$*" in
      *"--json assets"*) fail_if_told view-assets ;;
      *"--json body"*) fail_if_told view-body ;;
      *"--json isDraft"*) fail_if_told view-draft ;;
      *)
        fail_if_told view-exists
        if [ -f "${state}/not-found-elsewhere" ]; then
          # An error that merely contains "Not Found": the API, not the release, is missing.
          rm -f "${state}/not-found-elsewhere"
          echo "HTTP 404: Not Found (https://api.github.com/graphql)" >&2
          exit 1
        fi
        ;;
    esac
    if [ ! -f "${state}/exists" ]; then
      echo "release not found" >&2
      exit 1
    fi
    case "$*" in
      *"--json assets"*) cat "${state}/assets" ;;
      *"--json body"*) cat "${state}/body" 2>/dev/null ;;
      *"--json isDraft"*) if [ -f "${state}/draft" ]; then echo true; else echo false; fi ;;
      *) echo "title: ${tag}" ;;
    esac
    ;;
  create)
    if [ -f "${state}/fail.create-halfway" ] && [ "$(cat "${state}/fail.create-halfway")" -gt 0 ]; then
      # gh made the draft, an upload failed, and the clean-up failed too: a draft stays.
      echo 0 >"${state}/fail.create-halfway"
      : >"${state}/exists"
      : >"${state}/draft"
      echo "HTTP 502: Server Error (https://uploads.github.com/repos/o/r/releases/1/assets)" >&2
      exit 1
    fi
    fail_if_told create
    if [ -f "${state}/exists" ]; then
      echo "HTTP 422: Validation Failed (already_exists)" >&2
      exit 1
    fi
    : >"${state}/exists"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --notes-file) cp "$2" "${state}/body"; shift 2 ;;
        --target | --title) shift 2 ;;
        --*) shift ;;
        *) basename "$1" >>"${state}/assets"; shift ;;
      esac
    done
    ;;
  upload)
    fail_if_told upload
    [ -f "${state}/exists" ] || { echo "release not found" >&2; exit 1; }
    for arg in "$@"; do
      case "${arg}" in
        --*) ;;
        *)
          name="$(basename "${arg}")"
          if [ -f "${state}/drop.${name}" ]; then continue; fi # GitHub lost it without an error
          grep -qxF -- "${name}" "${state}/assets" || echo "${name}" >>"${state}/assets"
          ;;
      esac
    done
    ;;
  delete-asset)
    fail_if_told delete-asset
    name="${1:-}"
    if ! grep -qxF -- "${name}" "${state}/assets"; then
      echo "asset ${name} not found in release ${tag}" >&2
      exit 1
    fi
    if [ -f "${state}/keep.${name}" ]; then exit 0; fi # GitHub said yes and kept the asset
    grep -vxF -- "${name}" "${state}/assets" >"${state}/assets.new" || true
    mv "${state}/assets.new" "${state}/assets"
    ;;
  edit)
    fail_if_told edit
    [ -f "${state}/exists" ] || { echo "release not found" >&2; exit 1; }
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --notes-file)
          if [ -f "${state}/stale-notes" ]; then shift 2; continue; fi # accepted, not applied
          cp "$2" "${state}/body"
          shift 2
          ;;
        --draft=false)
          if [ ! -f "${state}/stale-draft" ]; then rm -f "${state}/draft"; fi
          shift
          ;;
        *) shift ;;
      esac
    done
    ;;
  *)
    echo "stand-in gh: unknown subcommand ${sub}" >&2
    exit 64
    ;;
esac
STANDIN
  chmod +x "${WORK}/bin/gh"
  export PATH="${WORK}/bin:${PATH}"
  export GH_STANDIN_STATE="${STATE}" GH_STANDIN_CALLS="${CALLS}"
  # No test may sleep: the pauses between attempts are zero here.
  export RELEASE_RETRY_DELAYS="0 0 0 0"
  ASSETS=("${WORK}/assets/digests-stable.json" "${WORK}/assets/sbom-stable-linux-amd64.cdx.json" "${WORK}/assets/sbom-stable-linux-arm64.cdx.json")
}

teardown() {
  rm -rf "${WORK}"
}

# upsert [extra arguments...]: the call publish.yml makes, with the fixture's assets.
upsert() {
  run "$SCRIPT" --tag v1-stable --target 0123abc --title v1-stable --notes-file "${WORK}/notes.md" \
    --expect-in-notes "sha256:abc123" "$@" "${ASSETS[@]}"
}

# calls <subcommand>: how often the stand-in was asked for `gh release <subcommand>`.
calls() { grep -c "^release $1 " "${CALLS}" || true; }

# an existing release with the assets of an earlier publish, one of them of the old kind.
existing_release() {
  : >"${STATE}/exists"
  printf '%s\n' digests-stable.json sbom-stable.cdx.json >"${STATE}/assets"
  printf 'Pin this exact build: image@sha256:old\n' >"${STATE}/body"
}

@test "no release yet: it is created once with the assets, the target, the title and the notes" {
  upsert
  [ "$status" -eq 0 ]
  [ "$(calls create)" -eq 1 ]
  [ "$(calls upload)" -eq 0 ]
  grep -q -- '--target 0123abc' "${CALLS}"
  grep -q -- '--title v1-stable' "${CALLS}"
  [ "$(sort "${STATE}/assets" | tr '\n' ' ')" == "digests-stable.json sbom-stable-linux-amd64.cdx.json sbom-stable-linux-arm64.cdx.json " ]
  grep -q 'sha256:abc123' "${STATE}/body"
}

@test "a release that exists gets its assets replaced and its notes rewritten, and is not created again" {
  existing_release
  upsert
  [ "$status" -eq 0 ]
  [ "$(calls create)" -eq 0 ]
  [ "$(calls upload)" -eq 1 ]
  grep -q -- '--clobber' "${CALLS}"
  grep -q 'sha256:abc123' "${STATE}/body"
  ! grep -q 'sha256:old' "${STATE}/body" || false
}

@test "an asset of the old kind is removed from an existing release, and its absence is no error" {
  existing_release
  upsert --remove-asset sbom-stable.cdx.json
  [ "$status" -eq 0 ]
  ! grep -qx 'sbom-stable.cdx.json' "${STATE}/assets" || false
  # A second publish finds nothing to remove and still succeeds.
  upsert --remove-asset sbom-stable.cdx.json
  [ "$status" -eq 0 ]
}

@test "the 502 of 2026-11-13: the upload fails once, the update is repeated and the release ends up right" {
  existing_release
  echo 1 >"${STATE}/fail.upload"
  upsert
  [ "$status" -eq 0 ]
  [ "$(calls upload)" -eq 2 ]
  grep -q 'sha256:abc123' "${STATE}/body"
  [[ "$output" == *"attempt 1"* ]]
  [[ "$output" == *"HTTP 502"* ]]
}

@test "a failure while the notes are rewritten repeats the whole update, assets included" {
  existing_release
  echo 1 >"${STATE}/fail.edit"
  upsert
  [ "$status" -eq 0 ]
  [ "$(calls upload)" -eq 2 ]
  [ "$(calls edit)" -eq 2 ]
  grep -q 'sha256:abc123' "${STATE}/body"
}

@test "a creation that failed halfway left a draft: it is finished as an update and published" {
  echo 1 >"${STATE}/fail.create-halfway"
  upsert
  [ "$status" -eq 0 ]
  [ "$(calls create)" -eq 1 ]
  [ "$(calls upload)" -eq 1 ]
  [ "$(wc -l <"${STATE}/assets")" -eq 3 ]
  grep -q 'sha256:abc123' "${STATE}/body"
  [ ! -f "${STATE}/draft" ]
}

@test "a draft left by an earlier run is published by the update" {
  existing_release
  : >"${STATE}/draft"
  upsert
  [ "$status" -eq 0 ]
  [ ! -f "${STATE}/draft" ]
  grep -q -- '--draft=false' "${CALLS}"
}

@test "a release that is still a draft after the update is a failure, whatever the exit codes said" {
  existing_release
  : >"${STATE}/draft"
  : >"${STATE}/stale-draft"
  RELEASE_ATTEMPTS=2 upsert
  [ "$status" -eq 1 ]
  [[ "$output" == *"draft"* ]]
}

@test "an error while asking whether the release exists is not read as 'no release'" {
  existing_release
  echo 1 >"${STATE}/fail.view-exists"
  upsert
  [ "$status" -eq 0 ]
  [ "$(calls create)" -eq 0 ]
  [[ "$output" == *"asking whether the release exists: HTTP 502"* ]]
}

@test "an error that merely contains 'Not Found' is not read as 'no release' either" {
  existing_release
  : >"${STATE}/not-found-elsewhere"
  upsert
  [ "$status" -eq 0 ]
  [ "$(calls create)" -eq 0 ]
}

@test "a failed listing in the read-back fails the attempt and the log says why" {
  existing_release
  echo 1 >"${STATE}/fail.view-assets"
  upsert
  [ "$status" -eq 0 ]
  [ "$(calls upload)" -eq 2 ]
  [[ "$output" == *"attempt 1 of 5 failed: listing the assets: HTTP 502"* ]]
}

@test "a failed read of the notes in the read-back fails the attempt and the log says why" {
  existing_release
  echo 1 >"${STATE}/fail.view-body"
  upsert
  [ "$status" -eq 0 ]
  [ "$(calls upload)" -eq 2 ]
  [[ "$output" == *"attempt 1 of 5 failed: reading the notes back: HTTP 502"* ]]
}

@test "a failed read of the draft state in the read-back fails the attempt" {
  existing_release
  echo 1 >"${STATE}/fail.view-draft"
  upsert
  [ "$status" -eq 0 ]
  [ "$(calls upload)" -eq 2 ]
}

@test "a failed removal of the old asset is repeated, not ignored" {
  existing_release
  echo 1 >"${STATE}/fail.delete-asset"
  upsert --remove-asset sbom-stable.cdx.json
  [ "$status" -eq 0 ]
  [ "$(calls delete-asset)" -eq 2 ]
  ! grep -qx 'sbom-stable.cdx.json' "${STATE}/assets" || false
}

@test "an old asset that GitHub says it removed and still lists is a failure" {
  existing_release
  : >"${STATE}/keep.sbom-stable.cdx.json"
  RELEASE_ATTEMPTS=2 upsert --remove-asset sbom-stable.cdx.json
  [ "$status" -eq 1 ]
  [[ "$output" == *"still lists the asset sbom-stable.cdx.json"* ]]
}

@test "when every attempt fails it stops after the configured number, fails, and says what GitHub said" {
  existing_release
  echo 99 >"${STATE}/fail.upload"
  RELEASE_ATTEMPTS=3 upsert
  [ "$status" -eq 1 ]
  [ "$(calls upload)" -eq 3 ]
  [[ "$output" == *"3 attempts"* ]]
  [[ "$output" == *"HTTP 502"* ]]
}

@test "the default is five attempts" {
  existing_release
  echo 99 >"${STATE}/fail.upload"
  upsert
  [ "$status" -eq 1 ]
  [ "$(calls upload)" -eq 5 ]
}

@test "an asset that GitHub accepted but does not list is a failure, not a success" {
  existing_release
  : >"${STATE}/drop.sbom-stable-linux-arm64.cdx.json"
  RELEASE_ATTEMPTS=2 upsert
  [ "$status" -eq 1 ]
  [[ "$output" == *"sbom-stable-linux-arm64.cdx.json"* ]]
}

@test "notes that do not carry the expected text afterwards are a failure" {
  existing_release
  : >"${STATE}/stale-notes"
  RELEASE_ATTEMPTS=2 upsert
  [ "$status" -eq 1 ]
  [[ "$output" == *"notes"* ]]
}

@test "a pause is taken between attempts and none after the last one" {
  existing_release
  echo 99 >"${STATE}/fail.upload"
  cat >"${WORK}/bin/sleep" <<'SLEEP'
#!/usr/bin/env bash
printf 'sleep %s\n' "$*" >>"${GH_STANDIN_CALLS}"
SLEEP
  chmod +x "${WORK}/bin/sleep"
  RELEASE_ATTEMPTS=3 RELEASE_RETRY_DELAYS="7 11" upsert
  [ "$status" -eq 1 ]
  [ "$(grep -c '^sleep ' "${CALLS}")" -eq 2 ]
  grep -qx 'sleep 7' "${CALLS}"
  grep -qx 'sleep 11' "${CALLS}"
}

@test "with more attempts than pauses the last pause is used again" {
  existing_release
  echo 99 >"${STATE}/fail.upload"
  cat >"${WORK}/bin/sleep" <<'SLEEP'
#!/usr/bin/env bash
printf 'sleep %s\n' "$*" >>"${GH_STANDIN_CALLS}"
SLEEP
  chmod +x "${WORK}/bin/sleep"
  RELEASE_ATTEMPTS=4 RELEASE_RETRY_DELAYS="7 11" upsert
  [ "$status" -eq 1 ]
  [ "$(grep '^sleep ' "${CALLS}" | tr '\n' ' ')" == "sleep 7 sleep 11 sleep 11 " ]
}

@test "usage errors exit 2 before GitHub is asked anything" {
  run "$SCRIPT" --target x --title t --notes-file "${WORK}/notes.md" "${ASSETS[@]}"
  [ "$status" -eq 2 ]
  run "$SCRIPT" --tag v1 --target x --title t --notes-file "${WORK}/missing.md" "${ASSETS[@]}"
  [ "$status" -eq 2 ]
  run "$SCRIPT" --tag v1 --target x --title t --notes-file "${WORK}/notes.md"
  [ "$status" -eq 2 ]
  run "$SCRIPT" --tag v1 --target x --title t --notes-file "${WORK}/notes.md" "${WORK}/assets/absent.json"
  [ "$status" -eq 2 ]
  RELEASE_ATTEMPTS=0 run "$SCRIPT" --tag v1 --target x --title t --notes-file "${WORK}/notes.md" "${ASSETS[@]}"
  [ "$status" -eq 2 ]
  RELEASE_RETRY_DELAYS="5 soon" run "$SCRIPT" --tag v1 --target x --title t --notes-file "${WORK}/notes.md" "${ASSETS[@]}"
  [ "$status" -eq 2 ]
  # An option the script does not know is an error, never an asset path.
  run "$SCRIPT" --tag v1 --target x --title t --notes-file "${WORK}/notes.md" --clobber "${ASSETS[@]}"
  [ "$status" -eq 2 ]
  # An empty expectation would switch the check of the notes off without a word.
  run "$SCRIPT" --tag v1 --target x --title t --notes-file "${WORK}/notes.md" --expect-in-notes "" "${ASSETS[@]}"
  [ "$status" -eq 2 ]
  [ ! -s "${CALLS}" ]
}

@test "publish.yml writes the release through this script and with no release command of its own" {
  workflow="${REPO}/.github/workflows/publish.yml"
  grep -q 'scripts/release-upsert.sh' "${workflow}"
  ! grep -E 'gh release (upload|create|edit|delete-asset)' "${workflow}" || false
}
