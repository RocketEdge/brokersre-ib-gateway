#!/usr/bin/env bats
# Unit tests for scripts/rebuild-issue.sh: the one tracking issue per channel that rebuild.yml
# keeps while the published image has a fixable CRITICAL/HIGH finding in OS packages.
# `gh` is replaced by a stub on PATH; nothing reaches GitHub.
#   tests/.bats-core/bin/bats tests/bats/ci
#
# The contract under test: a finding opens an issue only when the channel has no open one,
# otherwise the open issue is rewritten (never a second issue, never a comment per day); a clean
# scan closes the open issue with the evidence; without an open issue a clean scan does nothing.

bats_require_minimum_version 1.5.0 # `run --separate-stderr`

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/rebuild-issue.sh"
  WORK="$(mktemp -d)"
  STUB_BIN="${WORK}/bin"
  CALLS="${WORK}/gh.calls"
  mkdir -p "${STUB_BIN}"
  : > "${CALLS}"
  # gh stub: every call is appended to ${CALLS} as `gh <arguments>`.
  #   issue list     prints ${WORK}/open-issue when it exists (the number of the open issue)
  #   issue create   prints an issue URL; fails when ${WORK}/fail-create exists
  #   label create   fails when ${WORK}/label-exists exists (gh refuses an existing label)
  cat > "${STUB_BIN}/gh" <<EOF
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >> "${CALLS}"
case "\$1 \$2" in
  "issue list") if [ -f "${WORK}/open-issue" ]; then cat "${WORK}/open-issue"; fi ;;
  "issue create")
    if [ -f "${WORK}/fail-create" ]; then echo "HTTP 403" >&2; exit 1; fi
    echo "https://github.com/example/repo/issues/7"
    ;;
  "label create") if [ -f "${WORK}/label-exists" ]; then echo "already exists" >&2; exit 1; fi ;;
esac
exit 0
EOF
  chmod +x "${STUB_BIN}/gh"
  export PATH="${STUB_BIN}:${PATH}"
  export GH_TOKEN="test-token-not-a-secret"
  export GITHUB_REPOSITORY="example/repo"
  REF="ghcr.io/rocketedge/brokersre-ib-gateway@sha256:$(printf 'a%.0s' {1..64})"
}

teardown() {
  rm -rf "${WORK}"
}

@test "a finding and no open issue for the channel: one issue is opened, naming the CVEs and the image" {
  run "$SCRIPT" stable rebuild CVE-2026-109518,CVE-2026-33845 "$REF"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^gh issue create' "${CALLS}")" -eq 1 ]
  grep -q '^gh issue create -R example/repo --title Fixable OS vulnerabilities in the published stable image --label os-vulnerability --label channel:stable --body ' "${CALLS}"
  grep -q 'CVE-2026-109518' "${CALLS}"
  grep -q 'CVE-2026-33845' "${CALLS}"
  grep -q "${REF}" "${CALLS}"
  ! grep -q '^gh issue edit' "${CALLS}"
  ! grep -q '^gh issue close' "${CALLS}"
}

@test "a finding while the channel's issue is open: that issue is rewritten, never a second one" {
  echo 42 > "${WORK}/open-issue"
  run "$SCRIPT" stable rebuild CVE-2026-109518 "$REF"
  [ "$status" -eq 0 ]
  grep -q '^gh issue edit 42 -R example/repo --body ' "${CALLS}"
  grep -q 'CVE-2026-109518' "${CALLS}"
  ! grep -q '^gh issue create' "${CALLS}"
  ! grep -q '^gh issue comment' "${CALLS}"
}

@test "a clean scan while the issue is open: closed with the image that scanned clean" {
  echo 42 > "${WORK}/open-issue"
  run "$SCRIPT" latest none "" "$REF"
  [ "$status" -eq 0 ]
  grep -q '^gh issue close 42 -R example/repo --reason completed --comment ' "${CALLS}"
  grep -q "${REF}" "${CALLS}"
  ! grep -q '^gh issue create' "${CALLS}"
  ! grep -q '^gh issue edit' "${CALLS}"
}

@test "a clean scan and no open issue: nothing is written" {
  run "$SCRIPT" stable none "" "$REF"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "${CALLS}")" -eq 1 ]
  grep -q '^gh issue list' "${CALLS}"
}

@test "the open issue is looked up per channel and among open issues only" {
  run "$SCRIPT" latest none "" "$REF"
  [ "$status" -eq 0 ]
  grep -q '^gh issue list -R example/repo --state open --label os-vulnerability --label channel:latest --json number --jq ' "${CALLS}"
}

@test "the labels are created before the first issue, and an existing label is not an error" {
  touch "${WORK}/label-exists"
  run "$SCRIPT" stable rebuild CVE-2026-109518 "$REF"
  [ "$status" -eq 0 ]
  grep -q '^gh label create os-vulnerability -R example/repo' "${CALLS}"
  grep -q '^gh label create channel:stable -R example/repo' "${CALLS}"
  # No --force: an existing label keeps its colour and description.
  ! grep -q -- '--force' "${CALLS}"
  label_line="$(grep -n '^gh label create os-vulnerability' "${CALLS}" | cut -d: -f1)"
  create_line="$(grep -n '^gh issue create' "${CALLS}" | cut -d: -f1)"
  [ "${label_line}" -lt "${create_line}" ]
}

@test "the run that scanned is linked when RUN_URL is set" {
  RUN_URL="https://github.com/example/repo/actions/runs/1" run "$SCRIPT" stable rebuild CVE-2026-109518 "$REF"
  [ "$status" -eq 0 ]
  grep -q 'https://github.com/example/repo/actions/runs/1' "${CALLS}"
}

@test "GitHub refusing the new issue fails the script, so the workflow run turns red" {
  touch "${WORK}/fail-create"
  run "$SCRIPT" stable rebuild CVE-2026-109518 "$REF"
  [ "$status" -eq 1 ]
  grep -q '^gh issue create' "${CALLS}"
  [[ "$output" != *"opened"* ]]
}

@test "an issue number that is not a number is refused before anything is written" {
  echo "42 --title injected" > "${WORK}/open-issue"
  run "$SCRIPT" stable rebuild CVE-2026-109518 "$REF"
  [ "$status" -eq 2 ]
  ! grep -q -e '^gh issue edit' -e '^gh issue create' -e '^gh issue close' "${CALLS}"
}

@test "bad arguments are refused before gh is called" {
  run "$SCRIPT" beta rebuild CVE-2026-109518 "$REF"
  [ "$status" -eq 2 ]
  run "$SCRIPT" stable maybe CVE-2026-109518 "$REF"
  [ "$status" -eq 2 ]
  run "$SCRIPT" stable rebuild "" "$REF"
  [ "$status" -eq 2 ]
  run "$SCRIPT" stable none CVE-2026-109518 "$REF"
  [ "$status" -eq 2 ]
  run "$SCRIPT" stable rebuild 'CVE-1 `id`' "$REF"
  [ "$status" -eq 2 ]
  run "$SCRIPT" stable rebuild $'CVE-1\nCVE-2' "$REF"
  [ "$status" -eq 2 ]
  run "$SCRIPT" stable rebuild CVE-2026-109518 "ghcr.io/rocketedge/brokersre-ib-gateway:stable"
  [ "$status" -eq 2 ]
  run "$SCRIPT" stable rebuild CVE-2026-109518
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage"* ]]
  [ ! -s "${CALLS}" ]
}

@test "a missing token or repository is refused before gh is called" {
  GH_TOKEN="" run "$SCRIPT" stable rebuild CVE-2026-109518 "$REF"
  [ "$status" -eq 2 ]
  [[ "$output" == *"GH_TOKEN"* ]]
  GITHUB_REPOSITORY="" run "$SCRIPT" stable rebuild CVE-2026-109518 "$REF"
  [ "$status" -eq 2 ]
  [ ! -s "${CALLS}" ]
}
