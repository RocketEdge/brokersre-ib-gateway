#!/usr/bin/env bats
# Unit tests for scripts/detect-scope.sh (how much an hourly run of detect-releases.yml does),
# and the workflow wiring it depends on. `gh` is replaced by a stub on PATH; nothing reaches
# GitHub.
#   tests/.bats-core/bin/bats tests/bats/ci
#
# The contract under test:
#   * the daily run and a manual dispatch (check `full`) always do the full check: download,
#     hash, decide; that is what finds a re-upload and refreshes an open pull request;
#   * an hourly run does the full check only at the first sight of a version: IBKR's label
#     differs from the pin and no pull request was ever opened from its branch. Everything
#     else waits for the daily run, so ADR 0009 keeps its behaviour (a closed pull request is
#     opened again the next day, not within the hour);
#   * GitHub is asked only when the answer matters, and a failed lookup fails the run (never
#     read as "no pull request");
#   * bad input is refused with exit 2 and nothing on stdout (stdout goes to GITHUB_OUTPUT).

bats_require_minimum_version 1.5.0 # `run --separate-stderr`

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SCRIPT="${ROOT}/scripts/detect-scope.sh"
  WF="${ROOT}/.github/workflows/detect-releases.yml"
  LISTER="${BATS_TEST_DIRNAME}/workflow-steps.awk"
  WORK="$(mktemp -d)"
  STUB_BIN="${WORK}/bin"
  CALLS="${WORK}/gh.calls"
  mkdir -p "${STUB_BIN}"
  : > "${CALLS}"
  # gh stub: every call is appended to ${CALLS}; `pr list` prints ${WORK}/pr-count (default 0)
  # and fails when ${WORK}/fail-list exists.
  cat > "${STUB_BIN}/gh" <<EOF
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >> "${CALLS}"
if [ "\$1 \$2" = "pr list" ]; then
  if [ -f "${WORK}/fail-list" ]; then echo "HTTP 502" >&2; exit 1; fi
  if [ -f "${WORK}/pr-count" ]; then cat "${WORK}/pr-count"; else echo 0; fi
fi
exit 0
EOF
  chmod +x "${STUB_BIN}/gh"
  export PATH="${STUB_BIN}:${PATH}"
  export GITHUB_REPOSITORY="example/repo"
  export GH_TOKEN="test-token-not-a-secret"
}

teardown() {
  rm -rf "${WORK}"
}

@test "the daily run and a dispatch do the full check, whatever IBKR serves, without asking GitHub" {
  run --separate-stderr "${SCRIPT}" full stable 10.50.1g 10.50.1g
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "scope=full" ]
  [[ "${lines[1]}" == reason=* ]]
  [ "${#lines[@]}" -eq 2 ]
  run --separate-stderr "${SCRIPT}" full latest 10.53.1a 10.52.1d
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "scope=full" ]
  [ ! -s "${CALLS}" ]
}

@test "an hourly run while IBKR serves the pin skips (re-uploads are the daily run's)" {
  run --separate-stderr "${SCRIPT}" hourly stable 10.50.1g 10.50.1g
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "scope=skip" ]
  [[ "${lines[1]}" == "reason="*"10.50.1g"* ]]
  [ ! -s "${CALLS}" ]
}

@test "an hourly run at the first sight of a version does the full check" {
  run --separate-stderr "${SCRIPT}" hourly stable 10.50.1h 10.50.1g
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "scope=full" ]
  [[ "${lines[1]}" == "reason="*"10.50.1h"* ]]
  # GitHub is asked about every pull request ever opened from the branch the workflow uses.
  grep -q -F -- 'gh pr list -R example/repo --head update-stable-to-10.50.1h --state all --json number --jq length' "${CALLS}"
}

@test "an hourly run skips a version that already has a pull request, open, closed or merged" {
  echo 1 > "${WORK}/pr-count"
  run --separate-stderr "${SCRIPT}" hourly stable 10.50.1h 10.50.1g
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "scope=skip" ]
  echo 3 > "${WORK}/pr-count"
  run --separate-stderr "${SCRIPT}" hourly latest 10.53.1a 10.52.1d
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "scope=skip" ]
}

@test "an hourly run sees a lower version than the pin too (IBKR rolled the channel back)" {
  run --separate-stderr "${SCRIPT}" hourly stable 10.50.1f 10.50.1g
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "scope=full" ]
}

@test "a lookup that fails fails the run: it is never read as no pull request" {
  touch "${WORK}/fail-list"
  run --separate-stderr "${SCRIPT}" hourly stable 10.50.1h 10.50.1g
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"update-stable-to-10.50.1h"* ]]
}

@test "an answer from GitHub that is not a count fails the run" {
  echo "not a number" > "${WORK}/pr-count"
  run --separate-stderr "${SCRIPT}" hourly stable 10.50.1h 10.50.1g
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "bad input is refused with exit 2 and nothing on stdout" {
  for args in "daily stable 10.50.1h 10.50.1g" "full beta 10.50.1h 10.50.1g" "hourly stable 10.50 10.50.1g" \
    "hourly stable 10.50.1h 10.50.1g;id" "hourly stable 10.50.1h" "hourly stable 10.50.1h 10.50.1g extra"; do
    # shellcheck disable=SC2086 # the words of each case are the arguments
    run --separate-stderr "${SCRIPT}" ${args}
    [ "$status" -eq 2 ] || { echo "args: ${args} -> ${status}"; false; }
    [ -z "$output" ]
  done
  run --separate-stderr "${SCRIPT}" hourly stable $'10.50.1h\nscope=full' 10.50.1g
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ ! -s "${CALLS}" ]
}

@test "detect-releases.yml runs hourly and does the full check daily at the schedule it names" {
  crons="$(sed -n -E 's/^ +- cron: *"([^"]*)" *$/\1/p' "${WF}" | sort)"
  [ "${crons}" = "$(printf '%s\n' '0 6 * * *' '23 * * * *')" ]
  # The cron string the full-check condition compares with is one of the schedule's: if the
  # two drifted apart, every scheduled run would be hourly and a re-upload never found.
  daily="$(grep -o "github\.event\.schedule != '[^']*'" "${WF}" | sed -E "s/^[^']*'([^']*)'$/\1/" | sort -u)"
  [ "${daily}" = "0 6 * * *" ]
  printf '%s\n' "${crons}" | grep -q -x -F "${daily}"
}

@test "detect-releases.yml downloads and decides only when the scope says full" {
  facts="$(awk -f "${LISTER}" "${WF}")"
  scope="$(printf '%s\n' "${facts}" | awk -F '\t' '$2 == "id" && $3 == "scope" { print $1 }')"
  [ -n "${scope}" ]
  printf '%s\n' "${facts}" | awk -F '\t' -v step="${scope}" '$1 == step && $2 == "run"' | grep -q -F 'scripts/detect-scope.sh "$CHECK" "$CHANNEL" "$REMOTE" "$LOCAL"'
  [[ "$(printf '%s\n' "${facts}" | awk -F '\t' -v step="${scope}" '$1 == step && $2 == "env.CHECK" { print $3 }')" == *"github.event.schedule != '0 6 * * *'"* ]]
  for id in dl decide; do
    n="$(printf '%s\n' "${facts}" | awk -F '\t' -v id="${id}" '$2 == "id" && $3 == id { print $1 }')"
    [ -n "${n}" ]
    [ "${n}" -gt "${scope}" ]
    [ "$(printf '%s\n' "${facts}" | awk -F '\t' -v step="${n}" '$1 == step && $2 == "if" { print $3 }')" = "steps.scope.outputs.scope == 'full'" ]
  done
  # The branch the script asks about is the branch the pull request is opened from.
  grep -q -F 'branch: update-${{ matrix.channel }}-to-${{ steps.cmp.outputs.remote }}' "${WF}"
  grep -q -F 'update-${channel}-to-${remote}' "${SCRIPT}"
}

@test "two runs of detect-releases.yml never overlap" {
  grep -q -x 'concurrency:' "${WF}"
  grep -A2 -x 'concurrency:' "${WF}" | grep -q -x '  group: detect-releases'
  grep -A2 -x 'concurrency:' "${WF}" | grep -q -x '  cancel-in-progress: false'
}
