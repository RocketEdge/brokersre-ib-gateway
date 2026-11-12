#!/usr/bin/env bats
# Unit tests for scripts/rebuild-issue.sh: the one tracking issue per channel that rebuild.yml
# keeps while the published image has a fixable CRITICAL/HIGH finding in OS packages, and the
# decision whether today's run requests a rebuild.
# `gh` and `date` are replaced by stubs on PATH; nothing reaches GitHub.
#   tests/.bats-core/bin/bats tests/bats/ci
#
# The contract under test:
#   * a finding opens an issue only when the channel has no open one (never a second issue);
#   * while the published image stays the same, each new day adds exactly one comment, so a
#     person is notified that yesterday's rebuild did not publish;
#   * a rebuild is requested on the first REBUILD_MAX_ATTEMPTS days (default 3) of the same
#     image, then no more, until the image changes or the issue is closed;
#   * a second run on the same day changes nothing and requests nothing;
#   * a clean scan closes the issue; a lookup that fails writes nothing.

bats_require_minimum_version 1.5.0 # `run --separate-stderr`

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/rebuild-issue.sh"
  WORK="$(mktemp -d)"
  STUB_BIN="${WORK}/bin"
  CALLS="${WORK}/gh.calls"
  mkdir -p "${STUB_BIN}"
  : > "${CALLS}"
  echo "2026-11-13" > "${WORK}/today"
  # gh stub: every call is appended to ${CALLS} as `gh <arguments>` (a text argument that spans
  # lines is recorded as it is). The value after --body is also written to ${WORK}/last-body
  # (issue create, issue edit) or ${WORK}/last-comment (issue comment, issue close --comment).
  #   issue list      prints ${WORK}/open-issue when it exists (the number of the open issue);
  #                   fails when ${WORK}/fail-list exists
  #   issue view      prints ${WORK}/open-issue-body; fails when ${WORK}/fail-view exists
  #   issue create    prints an issue URL; fails when ${WORK}/fail-create exists
  #   issue comment   fails when ${WORK}/fail-comment exists
  #   label create    fails when ${WORK}/label-exists exists (gh refuses an existing label)
  cat > "${STUB_BIN}/gh" <<EOF
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >> "${CALLS}"
verb="\$1 \$2"
text=""
comment=""
args=("\$@")
for ((i = 0; i < \${#args[@]}; i++)); do
  case "\${args[i]}" in
    --body) text="\${args[i + 1]}" ;;
    --comment) comment="\${args[i + 1]}" ;;
  esac
done
case "\${verb}" in
  "issue list")
    if [ -f "${WORK}/fail-list" ]; then echo "HTTP 502" >&2; exit 1; fi
    if [ -f "${WORK}/open-issue" ]; then cat "${WORK}/open-issue"; fi
    ;;
  "issue view")
    if [ -f "${WORK}/fail-view" ]; then echo "HTTP 502" >&2; exit 1; fi
    if [ -f "${WORK}/open-issue-body" ]; then cat "${WORK}/open-issue-body"; fi
    ;;
  "issue create")
    if [ -f "${WORK}/fail-create" ]; then echo "HTTP 403" >&2; exit 1; fi
    printf '%s' "\${text}" > "${WORK}/last-body"
    echo "https://github.com/example/repo/issues/7"
    ;;
  "issue edit") printf '%s' "\${text}" > "${WORK}/last-body" ;;
  "issue comment")
    if [ -f "${WORK}/fail-comment" ]; then echo "HTTP 403" >&2; exit 1; fi
    printf '%s' "\${text}" > "${WORK}/last-comment"
    ;;
  "issue close") printf '%s' "\${comment}" > "${WORK}/last-comment" ;;
  "label create") if [ -f "${WORK}/label-exists" ]; then echo "already exists" >&2; exit 1; fi ;;
esac
exit 0
EOF
  # date stub: the day is the content of ${WORK}/today, the time is always 05:30 UTC.
  cat > "${STUB_BIN}/date" <<EOF
#!/usr/bin/env bash
echo "\$(cat "${WORK}/today") 05:30 UTC"
EOF
  chmod +x "${STUB_BIN}/gh" "${STUB_BIN}/date"
  export PATH="${STUB_BIN}:${PATH}"
  export GH_TOKEN="test-token-not-a-secret"
  export GITHUB_REPOSITORY="example/repo"
  unset RUN_URL REBUILD_MAX_ATTEMPTS
  DIGEST="sha256:$(printf 'a%.0s' {1..64})"
  OTHER_DIGEST="sha256:$(printf 'b%.0s' {1..64})"
  REF="ghcr.io/rocketedge/brokersre-ib-gateway@${DIGEST}"
}

teardown() {
  rm -rf "${WORK}"
}

# open_issue NUMBER DIGEST DAYS LAST: the channel has an open issue whose text carries that state.
open_issue() {
  echo "$1" > "${WORK}/open-issue"
  printf 'Some earlier text.\n\n<!-- rebuild-state digest=%s days=%s last=%s -->\n' "$2" "$3" "$4" > "${WORK}/open-issue-body"
}

# count PATTERN: how many recorded gh calls start with PATTERN.
count() {
  grep -c "^$1" "${CALLS}" || true
}

@test "day 1, no open issue: one issue is opened, a rebuild is requested" {
  run --separate-stderr "$SCRIPT" stable rebuild CVE-2026-109518,CVE-2026-33845 "$REF"
  [ "$status" -eq 0 ]
  [ "$output" = $'request=true\nstable=rebuild' ]
  [ "$(count 'gh issue create')" -eq 1 ]
  grep -q '^gh issue create -R example/repo --title Fixable OS vulnerabilities in the published stable image --label os-vulnerability --label channel:stable --body ' "${CALLS}"
  [ "$(count 'gh issue edit')" -eq 0 ]
  [ "$(count 'gh issue comment')" -eq 0 ]
  [ "$(count 'gh issue close')" -eq 0 ]
}

@test "the issue text has this exact shape (Markdown list, ids as code, state on the last line)" {
  RUN_URL="https://github.com/example/repo/actions/runs/1" run "$SCRIPT" stable rebuild CVE-2026-109518,CVE-2026-33845 "$REF"
  [ "$status" -eq 0 ]
  expected="$(printf '%s\n' \
    'The daily scan found CRITICAL or HIGH vulnerabilities in the OS packages of the published `stable` image for which a fixed package exists.' \
    '' \
    "- Image scanned: \`${REF}\`" \
    '- Vulnerability ids: `CVE-2026-109518`, `CVE-2026-33845`' \
    '- Last scan: 2026-11-13 05:30 UTC ([workflow run](https://github.com/example/repo/actions/runs/1))' \
    '- Days with this image and a finding: 1 (a rebuild is requested on each of the first 3)' \
    '' \
    'What happens next: on each of the first 3 days the daily scan requests an OS-patch rebuild of this channel (`publish.yml` with `rebuild=true`). If a rebuilt image passes the scan it is published with a `-rYYYYMMDD` tag and a release, and the next daily scan closes this issue. While the published image stays the same, the scan adds one comment a day here; after 3 days it stops requesting rebuilds and a person decides what to do. Images are pinned by digest, so nothing a consumer runs changes until they move their pin (docs/upgrade-policy.md).' \
    '' \
    'This text is rewritten in place by `scripts/rebuild-issue.sh`; there is one open issue per channel. Do not edit the last line: it is the state the next scan reads.' \
    "<!-- rebuild-state digest=${DIGEST} days=1 last=2026-11-13 -->")"
  [ "$(cat "${WORK}/last-body")" = "${expected}" ]
}

@test "a second run on the same day: no comment, no second issue, no second request" {
  open_issue 42 "$DIGEST" 1 2026-11-13
  run --separate-stderr "$SCRIPT" stable rebuild CVE-2026-109518 "$REF"
  [ "$status" -eq 0 ]
  [ "$output" = $'request=false\nstable=none' ]
  [ "$(count 'gh issue create')" -eq 0 ]
  [ "$(count 'gh issue comment')" -eq 0 ]
  grep -q "<!-- rebuild-state digest=${DIGEST} days=1 last=2026-11-13 -->" "${WORK}/last-body"
}

@test "day 2, same image: yesterday's rebuild did not publish; one comment, and rebuild 2 of 3 is requested" {
  open_issue 42 "$DIGEST" 1 2026-11-12
  run --separate-stderr "$SCRIPT" stable rebuild CVE-2026-109518 "$REF"
  [ "$status" -eq 0 ]
  [ "$output" = $'request=true\nstable=rebuild' ]
  [ "$(count 'gh issue create')" -eq 0 ]
  [ "$(count 'gh issue comment 42')" -eq 1 ]
  grep -q "<!-- rebuild-state digest=${DIGEST} days=2 last=2026-11-13 -->" "${WORK}/last-body"
  grep -q 'Days with this image and a finding: 2 ' "${WORK}/last-body"
  comment="$(cat "${WORK}/last-comment")"
  [[ "$comment" == "Day 2:"* ]]
  [[ "$comment" == *"the rebuild requested on 2026-11-12 did not publish"* ]]
  [[ "$comment" == *"Requesting rebuild 2 of 3 now"* ]]
  [[ "$comment" == *'`CVE-2026-109518`'* ]]
  [[ "$comment" == *"${REF}"* ]]
}

@test "the state is written before the comment, so a failed run can never comment twice a day" {
  open_issue 42 "$DIGEST" 1 2026-11-12
  run "$SCRIPT" stable rebuild CVE-2026-109518 "$REF"
  [ "$status" -eq 0 ]
  edit_line="$(grep -n '^gh issue edit 42' "${CALLS}" | head -1 | cut -d: -f1)"
  comment_line="$(grep -n '^gh issue comment 42' "${CALLS}" | head -1 | cut -d: -f1)"
  [ "${edit_line}" -lt "${comment_line}" ]
}

@test "day 3, same image: the last automatic request (3 of 3)" {
  open_issue 42 "$DIGEST" 2 2026-11-12
  run --separate-stderr "$SCRIPT" stable rebuild CVE-2026-109518 "$REF"
  [ "$status" -eq 0 ]
  [ "$output" = $'request=true\nstable=rebuild' ]
  [[ "$(cat "${WORK}/last-comment")" == *"Requesting rebuild 3 of 3 now"* ]]
  grep -q "days=3 last=2026-11-13" "${WORK}/last-body"
}

@test "day 4, same image: no further request, and the comment says a person must decide" {
  open_issue 42 "$DIGEST" 3 2026-11-12
  run --separate-stderr "$SCRIPT" stable rebuild CVE-2026-109518 "$REF"
  [ "$status" -eq 0 ]
  [ "$output" = $'request=false\nstable=none' ]
  [ "$(count 'gh issue comment 42')" -eq 1 ]
  comment="$(cat "${WORK}/last-comment")"
  [[ "$comment" == "Day 4:"* ]]
  [[ "$comment" == *"3 rebuild requests did not publish"* ]]
  [[ "$comment" == *"No further rebuild is requested automatically"* ]]
  [[ "$comment" == *"channels=stable"* ]]
  grep -q "days=4 last=2026-11-13" "${WORK}/last-body"
}

@test "day 5 and later: still one comment a day, still no request" {
  open_issue 42 "$DIGEST" 4 2026-11-12
  run --separate-stderr "$SCRIPT" latest rebuild CVE-2026-109518 "$REF"
  [ "$status" -eq 0 ]
  [ "$output" = $'request=false\nlatest=none' ]
  [ "$(count 'gh issue comment 42')" -eq 1 ]
  [[ "$(cat "${WORK}/last-comment")" == "Day 5:"* ]]
}

@test "the published image changed but still has a finding: the count starts again, no comment" {
  open_issue 42 "$OTHER_DIGEST" 4 2026-11-12
  run --separate-stderr "$SCRIPT" stable rebuild CVE-2026-109518 "$REF"
  [ "$status" -eq 0 ]
  [ "$output" = $'request=true\nstable=rebuild' ]
  [ "$(count 'gh issue comment')" -eq 0 ]
  grep -q "<!-- rebuild-state digest=${DIGEST} days=1 last=2026-11-13 -->" "${WORK}/last-body"
}

@test "an open issue without a readable state line is treated as day 1 (rewritten, no comment)" {
  echo 42 > "${WORK}/open-issue"
  printf 'An issue from before the state line existed.\n' > "${WORK}/open-issue-body"
  run --separate-stderr "$SCRIPT" stable rebuild CVE-2026-109518 "$REF"
  [ "$status" -eq 0 ]
  [ "$output" = $'request=true\nstable=rebuild' ]
  [ "$(count 'gh issue comment')" -eq 0 ]
  grep -q "days=1 last=2026-11-13" "${WORK}/last-body"
  # A state line with a value that is not what the script writes is no state line.
  printf '<!-- rebuild-state digest=%s days=many last=2026-11-12 -->\n' "$DIGEST" > "${WORK}/open-issue-body"
  run --separate-stderr "$SCRIPT" stable rebuild CVE-2026-109518 "$REF"
  [ "$status" -eq 0 ]
  [ "$output" = $'request=true\nstable=rebuild' ]
}

@test "REBUILD_MAX_ATTEMPTS sets the number of days with a request" {
  open_issue 42 "$DIGEST" 1 2026-11-12
  REBUILD_MAX_ATTEMPTS=1 run --separate-stderr "$SCRIPT" stable rebuild CVE-2026-109518 "$REF"
  [ "$status" -eq 0 ]
  [ "$output" = $'request=false\nstable=none' ]
  [[ "$(cat "${WORK}/last-comment")" == *"1 rebuild request did not publish"* ]]
  open_issue 42 "$DIGEST" 4 2026-11-12
  REBUILD_MAX_ATTEMPTS=5 run --separate-stderr "$SCRIPT" stable rebuild CVE-2026-109518 "$REF"
  [ "$status" -eq 0 ]
  [ "$output" = $'request=true\nstable=rebuild' ]
  [[ "$(cat "${WORK}/last-comment")" == *"Requesting rebuild 5 of 5 now"* ]]
}

@test "a REBUILD_MAX_ATTEMPTS that is not a number from 1 to 99 is refused before gh is called" {
  for value in 0 abc 100 -1 "3 4"; do
    REBUILD_MAX_ATTEMPTS="$value" run "$SCRIPT" stable rebuild CVE-2026-109518 "$REF"
    [ "$status" -eq 2 ]
  done
  [ ! -s "${CALLS}" ]
}

@test "a clean scan while the issue is open: closed with the image that scanned clean, nothing requested" {
  open_issue 42 "$OTHER_DIGEST" 2 2026-11-12
  run --separate-stderr "$SCRIPT" latest none "" "$REF"
  [ "$status" -eq 0 ]
  [ "$output" = $'request=false\nlatest=none' ]
  grep -q '^gh issue close 42 -R example/repo --reason completed --comment ' "${CALLS}"
  [[ "$(cat "${WORK}/last-comment")" == *"${REF}"* ]]
  [ "$(count 'gh issue create')" -eq 0 ]
  [ "$(count 'gh issue edit')" -eq 0 ]
}

@test "a clean scan and no open issue: nothing is written, nothing requested" {
  run --separate-stderr "$SCRIPT" stable none "" "$REF"
  [ "$status" -eq 0 ]
  [ "$output" = $'request=false\nstable=none' ]
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
  run ! grep -q -- '--force' "${CALLS}"
  label_line="$(grep -n '^gh label create os-vulnerability' "${CALLS}" | cut -d: -f1)"
  create_line="$(grep -n '^gh issue create' "${CALLS}" | cut -d: -f1)"
  [ "${label_line}" -lt "${create_line}" ]
}

@test "a RUN_URL that is not a plain https URL is left out of the text" {
  for url in 'https://example.com/x) [click](https://evil.example/' 'javascript:alert(1)' 'http://github.com/example/repo/actions/runs/1' $'https://github.com/a\nb'; do
    : > "${WORK}/last-body"
    RUN_URL="$url" run "$SCRIPT" stable rebuild CVE-2026-109518 "$REF"
    [ "$status" -eq 0 ]
    run ! grep -q -e 'workflow run' -e 'evil' -e 'javascript' -e 'http://' "${WORK}/last-body"
    grep -q -- '- Last scan: 2026-11-13 05:30 UTC$' "${WORK}/last-body"
  done
}

@test "a lookup that fails writes nothing and requests nothing: no issue is created blind" {
  touch "${WORK}/fail-list"
  run --separate-stderr "$SCRIPT" stable rebuild CVE-2026-109518 "$REF"
  [ "$status" -ne 0 ]
  [ "$status" -ne 2 ]
  [ -z "$output" ]
  [ "$(count 'gh issue create')" -eq 0 ]
  [ "$(count 'gh issue edit')" -eq 0 ]
  [ "$(count 'gh issue comment')" -eq 0 ]
  [ "$(count 'gh label create')" -eq 0 ]
}

@test "an open issue whose text cannot be read: nothing is written, nothing requested" {
  open_issue 42 "$DIGEST" 1 2026-11-12
  touch "${WORK}/fail-view"
  run --separate-stderr "$SCRIPT" stable rebuild CVE-2026-109518 "$REF"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ "$(count 'gh issue edit')" -eq 0 ]
  [ "$(count 'gh issue comment')" -eq 0 ]
}

@test "GitHub refusing the new issue fails the script, and no request is printed" {
  touch "${WORK}/fail-create"
  run --separate-stderr "$SCRIPT" stable rebuild CVE-2026-109518 "$REF"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$(count 'gh issue create')" -eq 1 ]
}

@test "GitHub refusing the daily comment fails the script, and no request is printed" {
  open_issue 42 "$DIGEST" 1 2026-11-12
  touch "${WORK}/fail-comment"
  run --separate-stderr "$SCRIPT" stable rebuild CVE-2026-109518 "$REF"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "an issue number that is not a number is refused before anything is written" {
  echo "42 --title injected" > "${WORK}/open-issue"
  run "$SCRIPT" stable rebuild CVE-2026-109518 "$REF"
  [ "$status" -eq 2 ]
  run ! grep -q -e '^gh issue edit' -e '^gh issue create' -e '^gh issue close' -e '^gh issue view' "${CALLS}"
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
