#!/usr/bin/env bats
# Unit tests for rootfs/usr/local/lib/brokersre/classify-ibc-log.sh (log contract v1).
# Run inside the built image or any bash 5 + GNU coreutils environment:
#   BROKERSRE_LIB=$PWD/rootfs/usr/local/lib/brokersre bats tests/bats/unit

setup() {
  : "${BROKERSRE_LIB:?set BROKERSRE_LIB to rootfs/usr/local/lib/brokersre}"
  export LOG_DIR="$(mktemp -d)"
  export IBC_PATTERNS="${BATS_TEST_DIRNAME}/../../../rootfs/etc/brokersre/ibc-patterns.tsv"
  FIXTURE="${BATS_TEST_DIRNAME}/../../fixtures/ibc-synthetic.log"
}

teardown() {
  rm -rf "${LOG_DIR}"
}

@test "fixture is marked synthetic so nobody mistakes it for real evidence" {
  run head -1 "${FIXTURE}"
  [[ "$output" == "# SYNTHETIC FIXTURE"* ]]
}

@test "every matched line becomes one JSON event with the five contract keys" {
  run bash -c "'${BROKERSRE_LIB}/classify-ibc-log.sh' < '${FIXTURE}'"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  while IFS= read -r line; do
    echo "$line" | jq -e 'has("ts") and has("src") and has("level") and has("event") and has("msg") and (.src == "ibc")' >/dev/null
  done <<< "$output"
}

@test "2FA, login, restart, existing-session and failure events are recognised in order" {
  run bash -c "'${BROKERSRE_LIB}/classify-ibc-log.sh' < '${FIXTURE}' | jq -r .event"
  [ "$status" -eq 0 ]
  expected=$'ibc_version\nlogin_dialog\ntwofa_initiated\ntwofa_dialog\nlogin_completed\ndaily_restart\nlogin_completed\nexisting_session\nrelogin_required\nlogin_failed_dialog\nlogin_failed'
  [ "$output" == "$expected" ]
}

@test "raw lines never reach stdout: the credential-bearing line produces no event text" {
  run bash -c "'${BROKERSRE_LIB}/classify-ibc-log.sh' < '${FIXTURE}'"
  [[ "$output" != *"hunter2hunter2"* ]]
  [[ "$output" != *"ABC123"* ]]
  [[ "$output" != *"Password="* ]]
}

@test "the phase file ends at the last phase-bearing event" {
  bash -c "'${BROKERSRE_LIB}/classify-ibc-log.sh' < '${FIXTURE}'" >/dev/null
  run cat "${LOG_DIR}/state/phase"
  [ "$output" == "login" ]
}

@test "a 2FA dialog sets phase 2fa-pending and login completion sets logged-in" {
  printf '%s\n' "2026-11-01 09:00:05:010 IBC: detected dialog entitled: Second Factor Authentication; event=Opened" \
    | bash -c "'${BROKERSRE_LIB}/classify-ibc-log.sh'" >/dev/null
  [ "$(cat "${LOG_DIR}/state/phase")" == "2fa-pending" ]
  printf '%s\n' "2026-11-01 09:03:07:000 IBC: Login has completed" \
    | bash -c "'${BROKERSRE_LIB}/classify-ibc-log.sh'" >/dev/null
  [ "$(cat "${LOG_DIR}/state/phase")" == "logged-in" ]
}

@test "unmatched lines produce no output and leave the phase untouched" {
  mkdir -p "${LOG_DIR}/state"; echo logged-in > "${LOG_DIR}/state/phase"
  run bash -c "printf '%s\n' 'IBC: some unrelated chatter' | '${BROKERSRE_LIB}/classify-ibc-log.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "${LOG_DIR}/state/phase")" == "logged-in" ]
}

@test "timestamps are UTC ISO-8601 with milliseconds" {
  run bash -c "printf '%s\n' '2026-11-01 09:03:07:000 IBC: Login has completed' | '${BROKERSRE_LIB}/classify-ibc-log.sh' | jq -r .ts"
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$ ]]
}
