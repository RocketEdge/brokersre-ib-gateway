#!/usr/bin/env bats
# Unit tests for rootfs/usr/local/lib/brokersre/classify-ibc-log.sh (log contract v1).
# Run inside the built image or any bash 5 + GNU coreutils environment:
#   BROKERSRE_LIB=$PWD/rootfs/usr/local/lib/brokersre bats tests/bats/unit

setup() {
  : "${BROKERSRE_LIB:?set BROKERSRE_LIB to rootfs/usr/local/lib/brokersre}"
  export LOG_DIR="$(mktemp -d)"
  export IBC_PATTERNS="${BATS_TEST_DIRNAME}/../../../rootfs/etc/brokersre/ibc-patterns.tsv"
  export IBC_KNOWN_WINDOWS="${BATS_TEST_DIRNAME}/../../../rootfs/etc/brokersre/known-windows.txt"
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
  # One event per thing that happened: the Re-login dialog and IBC's "Re-login to session" are
  # one re-login, and IBC's stop message ("Login has completed: exiting via ...") is no login.
  # A rejected login is recorded (login_latch_set) and the next completed login removes the
  # record (login_latch_cleared): login-latch.bats covers that pair.
  expected=$'ibc_version\nlogin_dialog\ntwofa_initiated\ntwofa_dialog\nlogin_completed\ndaily_restart\nlogin_completed\nexisting_session\nrelogin_required\nlogin_failed_dialog\nlogin_latch_set\nlogin_failed\nlogin_completed\nlogin_latch_cleared'
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
  [ "$output" == "logged-in" ]
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

@test "REAL failed login (10.50.1g): version, login dialog and exactly one failure event" {
  # IBC logs Opened, Activated and Focused for every dialog; one dialog must be one event.
  REAL="${BATS_TEST_DIRNAME}/../../fixtures/ibc-real-failed-login.log"
  run bash -c "'${BROKERSRE_LIB}/classify-ibc-log.sh' < '${REAL}' | jq -r .event"
  [ "$status" -eq 0 ]
  # The rejection is one event; login_latch_set says that it was recorded for later starts.
  [ "$output" == $'ibc_version\nlogin_dialog\nlogin_failed_dialog\nlogin_latch_set' ]
  # IBC leaves the rejected-credentials dialog open and never retries: a person must act.
  [ "$(cat "${LOG_DIR}/state/phase")" == "needs-human" ]
}

# classify <line>...: feed lines to the classifier and print the event names.
classify() {
  printf '%s\n' "$@" | "${BROKERSRE_LIB}/classify-ibc-log.sh" | jq -r .event
}

@test "a window IBC has no handler for becomes one unknown_window event without its title" {
  run bash -c "printf '%s\n' \
    '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Hunter2 Promo Offer 12345; event=Opened' \
    '2026-11-11 23:23:04:158 IBC: detected dialog entitled: Hunter2 Promo Offer 12345; event=Activated' \
    '2026-11-11 23:23:04:160 IBC: detected dialog entitled: Hunter2 Promo Offer 12345; event=Focused' \
    | '${BROKERSRE_LIB}/classify-ibc-log.sh'"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l)" == "1" ]
  echo "$output" | jq -e '.event == "unknown_window" and .level == "warn" and .src == "ibc"' >/dev/null
  # The title is raw IBC text (it could carry an account or user name): never in the event.
  [[ "$output" != *"Hunter2"* ]]
  [[ "$output" != *"12345"* ]]
}

@test "windows that IBC handles or that are part of a normal start are not reported" {
  for title in "IBKR Gateway" "IB Gateway" "Login" "Configuration" "Second Factor Authentication" \
    "Existing session detected" "Re-login is required" "Tip of the Day" "Shutdown progress" \
    "Starting application..." "** no title **" "" "Password Notice" "Login Error" \
    "Connecting to server (trying for another 19 seconds)..." \
    "Attempt 3: connection error, will retry in 5 seconds..."; do
    run classify "2026-11-11 23:23:02:900 IBC: detected frame entitled: ${title}; event=Opened"
    [[ "$output" != *"unknown_window"* ]] || { echo "reported: ${title}"; false; }
  done
}

@test "without the list of known windows nothing is reported as unknown (no alert noise)" {
  export IBC_KNOWN_WINDOWS="${LOG_DIR}/does-not-exist.txt"
  run classify '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Something New; event=Opened'
  [ -z "$output" ]
}

@test "an unknown window leaves the phase untouched" {
  mkdir -p "${LOG_DIR}/state"; echo logged-in > "${LOG_DIR}/state/phase"
  classify '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Something New; event=Opened' >/dev/null
  [ "$(cat "${LOG_DIR}/state/phase")" == "logged-in" ]
}

@test "a Re-login dialog and IBC's handling of it are one event (ReloginDialogHandler logs both)" {
  run classify '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Re-login is required; event=Opened' \
    '2026-11-11 23:23:04:160 IBC: Re-login to session'
  [ "$output" == "relogin_required" ]
  [ "$(cat "${LOG_DIR}/state/phase")" == "login" ]
}

# The four tests below come from reading IBC 3.24.2's source, not from a real log (L01): the
# first versions of these rows matched text IBC writes in another situation, or never writes.

@test "IBC's stop message is not a completed login (StopTask: 'Login has completed: exiting via ...')" {
  mkdir -p "${LOG_DIR}/state"
  echo stopping >"${LOG_DIR}/state/phase"
  run classify '2026-11-11 23:59:00:000 IBC: Login has completed: exiting via [File, Close] menu'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "${LOG_DIR}/state/phase")" == "stopping" ]
}

@test "no classified line moves the phase out of stopping, stopped or exited" {
  mkdir -p "${LOG_DIR}/state"
  for phase in stopping stopped exited; do
    echo "${phase}" >"${LOG_DIR}/state/phase"
    run classify '2026-11-11 23:59:00:000 IBC: Login has completed' \
      '2026-11-11 23:59:00:100 IBC: Second Factor Authentication initiated' \
      '2026-11-11 23:59:00:200 IBC: version: 3.24.2'
    # The events are still reported: only the phase belongs to the entrypoint from here on.
    [ "$output" == $'login_completed\ntwofa_initiated\nibc_version' ]
    [ "$(cat "${LOG_DIR}/state/phase")" == "${phase}" ] || {
      echo "phase ${phase} became $(cat "${LOG_DIR}/state/phase")"
      return 1
    }
  done
}

@test "the daily restart is recognised from the start script's own line (no timestamp, no IBC prefix)" {
  run classify 'autorestart file found at /home/ibgateway/Jts/settings/abcdefgh/autorestart: authentication will not be required'
  [ "$output" == "daily_restart" ]
  [ "$(cat "${LOG_DIR}/state/phase")" == "restarting" ]
}

@test "the start script's other autorestart lines are not a restart" {
  run classify 'Finding autorestart file' \
    'WARNING: deleting extra autorestart file found at /home/ibgateway/Jts/settings/x/autorestart' \
    'WARNING: deleting first autorestart file found' \
    '2026-11-02 00:15:00:000 IBC: autorestart file found'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a second-factor timeout is an event of its own" {
  run classify '2026-11-11 23:30:00:000 IBC: Re-login after second factor authentication timeout in 5 second'
  [ "$output" == "twofa_timeout" ]
}

@test "without TWOFA_MAX_PROMPTS the second factor is re-prompted without limit" {
  unset TWOFA_MAX_PROMPTS
  run classify \
    '2026-11-11 23:30:00:000 IBC: Second Factor Authentication initiated' \
    '2026-11-11 23:33:00:000 IBC: Second Factor Authentication initiated' \
    '2026-11-11 23:36:00:000 IBC: Second Factor Authentication initiated' \
    '2026-11-11 23:39:00:000 IBC: Second Factor Authentication initiated'
  [[ "$output" != *"needs_human"* ]]
  [ "$(cat "${LOG_DIR}/state/phase")" == "2fa-pending" ]
}

@test "after TWOFA_MAX_PROMPTS unanswered prompts the gateway asks for a human and stops IBC" {
  STUB="$(mktemp -d)"
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s\n' \"\$*\" >>'${STUB}/calls'" >"${STUB}/ibc-cmd"
  chmod +x "${STUB}/ibc-cmd"
  export TWOFA_MAX_PROMPTS=2 IBC_CMD="${STUB}/ibc-cmd"
  run classify \
    '2026-11-11 23:30:00:000 IBC: Second Factor Authentication initiated' \
    '2026-11-11 23:33:00:000 IBC: Second Factor Authentication initiated' \
    '2026-11-11 23:36:00:000 IBC: Second Factor Authentication initiated'
  [ "$status" -eq 0 ]
  [ "$output" == $'twofa_initiated\ntwofa_initiated\ntwofa_initiated\nneeds_human' ]
  [ "$(cat "${LOG_DIR}/state/phase")" == "needs-human" ]
  # The stop request runs in the background; give it a moment, then expect exactly one STOP.
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "${STUB}/calls" ] && break; sleep 0.2; done
  [ "$(cat "${STUB}/calls")" == "STOP" ]
  rm -rf "${STUB}"
}

@test "a completed login resets the count of second-factor prompts" {
  export TWOFA_MAX_PROMPTS=2 IBC_CMD=/bin/true
  run classify \
    '2026-11-11 23:30:00:000 IBC: Second Factor Authentication initiated' \
    '2026-11-11 23:33:00:000 IBC: Second Factor Authentication initiated' \
    '2026-11-11 23:34:00:000 IBC: Login has completed' \
    '2026-11-12 23:30:00:000 IBC: Second Factor Authentication initiated' \
    '2026-11-12 23:33:00:000 IBC: Second Factor Authentication initiated'
  [[ "$output" != *"needs_human"* ]]
}

@test "the real fixture is labelled as real and holds only IBC lines" {
  REAL="${BATS_TEST_DIRNAME}/../../fixtures/ibc-real-failed-login.log"
  run head -1 "${REAL}"
  [[ "$output" == "# REAL LOG, scrubbed"* ]]
  run bash -c "tail -n +2 '${REAL}' | grep -c -v -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]+ IBC: '"
  [ "$output" == "0" ]
}

@test "a dialog that IBC reports as Opened, Activated and Focused is one event" {
  for title in "Existing session detected" "Re-login is required" "Unrecognized Username or Password"; do
    run bash -c "printf '%s\n' \
      '2026-11-11 23:23:04:155 IBC: detected dialog entitled: ${title}; event=Opened' \
      '2026-11-11 23:23:04:158 IBC: detected dialog entitled: ${title}; event=Activated' \
      '2026-11-11 23:23:04:160 IBC: detected dialog entitled: ${title}; event=Focused' \
      | '${BROKERSRE_LIB}/classify-ibc-log.sh' | grep -c -v '\"event\":\"login_latch_set\"'"
    # The dialog itself is one event (the record of a rejection is a second, different one).
    [ "$output" == "1" ]
  done
}

@test "the Gateway main window (same title as the login window) does not reset the phase" {
  mkdir -p "${LOG_DIR}/state"; echo logged-in > "${LOG_DIR}/state/phase"
  run bash -c "printf '%s\n' '2026-11-11 23:23:02:900 IBC: detected frame entitled: IBKR Gateway; event=Opened' | '${BROKERSRE_LIB}/classify-ibc-log.sh'"
  [ -z "$output" ]
  [ "$(cat "${LOG_DIR}/state/phase")" == "logged-in" ]
}

@test "timestamps are UTC ISO-8601 with milliseconds" {
  run bash -c "printf '%s\n' '2026-11-01 09:03:07:000 IBC: Login has completed' | '${BROKERSRE_LIB}/classify-ibc-log.sh' | jq -r .ts"
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$ ]]
}
