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
  # Reported at once here: this test is about the event, the grace period has its own tests.
  export UNKNOWN_WINDOW_GRACE_S=0
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
  # Without a grace period, so that the list is what is tested and not the end of the input.
  export UNKNOWN_WINDOW_GRACE_S=0
  for title in "IBKR Gateway" "IB Gateway" "Login" "Configuration" "Second Factor Authentication" \
    "Existing session detected" "Re-login is required" "Tip of the Day" "Shutdown progress" \
    "Starting application..." "** no title **" "" "Password Notice" "Login Error" \
    "Connecting to server (trying for another 19 seconds)..." \
    "Attempt 3: connection error, will retry in 5 seconds..." \
    "Authenticating..." "DUX000000 Trader Workstation Configuration (Simulated Trading)"; do
    run classify "2026-11-11 23:23:02:900 IBC: detected frame entitled: ${title}; event=Opened"
    [[ "$output" != *"unknown_window"* ]] || { echo "reported: ${title}"; false; }
  done
}

@test "a start-up step nobody has seen yet is not reported: its title ends with an ellipsis" {
  # The start-up frame is titled with the step it is in ("Connecting to server ...",
  # "Authenticating...", "Starting application..."). A start that hangs in a step is reported
  # by login_stalled; the frame itself asks nothing of a person.
  export UNKNOWN_WINDOW_GRACE_S=0
  run classify '2026-11-11 23:23:02:900 IBC: detected frame entitled: Loading a step of some later Gateway...; event=Opened'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a dialog whose title ends with an ellipsis is not a start-up step: it is reported" {
  # The family rule is for frames. A dialog titled like a progress text may be waiting for an
  # answer, and the stalled-login event covers only the login.
  export UNKNOWN_WINDOW_GRACE_S=0
  run classify '2026-11-11 23:23:02:900 IBC: detected dialog entitled: Waiting for your approval...; event=Opened'
  [ "$status" -eq 0 ]
  [ "$output" == "unknown_window" ]
}

@test "without the list of known windows nothing is reported as unknown (no alert noise)" {
  export IBC_KNOWN_WINDOWS="${LOG_DIR}/does-not-exist.txt" UNKNOWN_WINDOW_GRACE_S=0
  run classify '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Something New; event=Opened'
  [ -z "$output" ]
}

@test "an unknown window leaves the phase untouched" {
  export UNKNOWN_WINDOW_GRACE_S=0
  mkdir -p "${LOG_DIR}/state"; echo logged-in > "${LOG_DIR}/state/phase"
  run classify '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Something New; event=Opened'
  [ "$output" == "unknown_window" ]
  [ "$(cat "${LOG_DIR}/state/phase")" == "logged-in" ]
}

# --- the grace period: a window is reported when it STAYS open ---------------------------------
# Seen in the first completed paper logins (2026-11-15): the dialog "Warning" (this is not a
# brokerage account) opens after every paper login and IBC accepts it in the same millisecond;
# it is gone 0.3 s later. Reporting a window the moment it opens called that a window nobody
# handles. What needs a person is a window that is still there after a while.
#
# The tests below feed the classifier through a pipe that stays open (`sleep` in the writer):
# when the input ends, every wait ends with it, and a test that only replays a file would
# pass whatever the classifier does with a waiting window. The second-factor timeout line is
# used as a marker: it is an event of its own and has nothing to do with windows.

MARKER='2026-11-11 23:23:04:200 IBC: Re-login after second factor authentication timeout in 5 second'

@test "a window that closes within the grace period is not reported: IBC or the Gateway dealt with it" {
  export UNKNOWN_WINDOW_GRACE_S=2
  run bash -c "{ printf '%s\n' \
    '2026-11-15 15:15:41:567 IBC: detected dialog entitled: Warning; event=Opened' \
    '2026-11-15 15:15:41:567 IBC: Click button: I understand and accept' \
    '2026-11-15 15:15:41:645 IBC: detected dialog entitled: Warning; event=Activated' \
    '2026-11-15 15:15:41:645 IBC: detected dialog entitled: Warning; event=Focused' \
    '2026-11-15 15:15:41:858 IBC: detected dialog entitled: Warning; event=Closed'; sleep 6; } \
    | '${BROKERSRE_LIB}/classify-ibc-log.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a window still open after the grace period is reported once, while IBC keeps running" {
  export UNKNOWN_WINDOW_GRACE_S=1
  # The marker shows that the window was NOT reported when it opened, and the login line shows
  # that it WAS reported before IBC said anything further.
  run bash -c "{ printf '%s\n' \
    '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Something New; event=Opened' \
    '2026-11-11 23:23:04:158 IBC: detected dialog entitled: Something New; event=Activated' \
    '2026-11-11 23:23:04:160 IBC: detected dialog entitled: Something New; event=Focused' \
    '${MARKER}'; sleep 6; \
    printf '%s\n' '2026-11-11 23:23:09:000 IBC: Login has completed'; } \
    | '${BROKERSRE_LIB}/classify-ibc-log.sh' | jq -r .event"
  [ "$status" -eq 0 ]
  [ "$output" == $'twofa_timeout\nunknown_window\nlogin_completed' ]
}

@test "a window is not reported before the grace period is over" {
  export UNKNOWN_WINDOW_GRACE_S=5
  # The marker arrives 2 s after the window opened: the window must not have been reported yet.
  run bash -c "{ printf '%s\n' \
    '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Something New; event=Opened'; sleep 2; \
    printf '%s\n' '${MARKER}'; sleep 7; } \
    | '${BROKERSRE_LIB}/classify-ibc-log.sh' | jq -r .event"
  [ "$status" -eq 0 ]
  [ "$output" == $'twofa_timeout\nunknown_window' ]
}

@test "by default a window is reported after 10 seconds: not after 7, and by 14" {
  unset UNKNOWN_WINDOW_GRACE_S
  run bash -c "{ printf '%s\n' \
    '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Something New; event=Opened'; sleep 7; \
    printf '%s\n' '${MARKER}'; sleep 7; \
    printf '%s\n' '2026-11-11 23:23:18:000 IBC: Login has completed'; } \
    | '${BROKERSRE_LIB}/classify-ibc-log.sh' | jq -r .event"
  [ "$status" -eq 0 ]
  [ "$output" == $'twofa_timeout\nunknown_window\nlogin_completed' ]
}

@test "a waiting window is reported while IBC keeps writing other lines" {
  export UNKNOWN_WINDOW_GRACE_S=1
  # A line every 0.3 s for 6 s: the read never runs into its time limit, so the report has to
  # be made between two lines.
  run bash -c "{ printf '%s\n' \
    '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Something New; event=Opened'; \
    for n in \$(seq 1 20); do printf '%s\n' \"2026-11-11 23:23:05:000 IBC: chatter \${n}\"; sleep 0.3; done; \
    printf '%s\n' '2026-11-11 23:23:11:000 IBC: Login has completed'; } \
    | '${BROKERSRE_LIB}/classify-ibc-log.sh' | jq -r .event"
  [ "$status" -eq 0 ]
  [ "$output" == $'unknown_window\nlogin_completed' ]
}

@test "a flood of lines postpones the report of a due window only so far" {
  export UNKNOWN_WINDOW_GRACE_S=1
  # Lines that are already waiting are read before a due window is reported (one of them may
  # close it), but not without limit. 200,000 lines keep the classifier busy for many seconds
  # with input always waiting: the window must be reported long before the last of them.
  run bash -c "{ printf '%s\n' \
    '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Something New; event=Opened'; \
    yes '2026-11-11 23:23:05:000 IBC: chatter' | head -n 200000; \
    printf '%s\n' '2026-11-11 23:23:11:000 IBC: Login has completed'; sleep 3; } \
    | '${BROKERSRE_LIB}/classify-ibc-log.sh' | jq -r .event"
  [ "$status" -eq 0 ]
  [ "$output" == $'unknown_window\nlogin_completed' ]
}

@test "the end of IBC's output ends the wait: a window that went down with IBC is not reported" {
  export UNKNOWN_WINDOW_GRACE_S=60
  started="${SECONDS}"
  run classify '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Something New; event=Opened'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # The classifier ends with its input; it does not sit out the grace period.
  [ "$((SECONDS - started))" -lt 20 ]
}

@test "a new IBC ends the wait: a window of the Gateway process that was replaced is not reported" {
  export UNKNOWN_WINDOW_GRACE_S=1
  # ibcstart.sh starts the Gateway again inside one classifier run (daily restart, restart
  # after a second-factor timeout). The old process writes no Closed line for its windows.
  run bash -c "{ printf '%s\n' \
    '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Something New; event=Opened' \
    '2026-11-11 23:23:04:900 IBC: version: 3.24.2'; sleep 5; } \
    | '${BROKERSRE_LIB}/classify-ibc-log.sh' | jq -r .event"
  [ "$status" -eq 0 ]
  [ "$output" == "ibc_version" ]
}

@test "a window reported before a restart does not make the next answered one look unknown" {
  export UNKNOWN_WINDOW_GRACE_S=1
  run bash -c "{ printf '%s\n' \
    '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Warning; event=Opened'; sleep 5; \
    printf '%s\n' \
    '2026-11-11 23:23:09:000 IBC: version: 3.24.2' \
    '2026-11-11 23:23:12:000 IBC: detected dialog entitled: Warning; event=Opened' \
    '2026-11-11 23:23:12:300 IBC: detected dialog entitled: Warning; event=Closed'; sleep 5; } \
    | '${BROKERSRE_LIB}/classify-ibc-log.sh' | jq -r .event"
  [ "$status" -eq 0 ]
  [ "$output" == $'unknown_window\nibc_version' ]
}

@test "of two windows with one title, the one that stays open is still reported" {
  export UNKNOWN_WINDOW_GRACE_S=1
  run bash -c "{ printf '%s\n' \
    '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Warning; event=Opened' \
    '2026-11-11 23:23:04:255 IBC: detected dialog entitled: Warning; event=Opened' \
    '2026-11-11 23:23:04:355 IBC: detected dialog entitled: Warning; event=Closed'; sleep 5; } \
    | '${BROKERSRE_LIB}/classify-ibc-log.sh' | jq -r .event"
  [ "$status" -eq 0 ]
  [ "$output" == "unknown_window" ]
}

@test "a window that stays open keeps its due time when others with its title open and close" {
  export UNKNOWN_WINDOW_GRACE_S=5
  # The first Warning is never answered. One with the same title opens and closes every
  # second: each closing takes the NEWEST waiting window off the list, so the first is
  # reported 5 s after it opened, before the marker at 9 s, and not 5 s after the last answered one.
  run bash -c "{ printf '%s\n' \
    '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Warning; event=Opened'; \
    for n in \$(seq 1 9); do sleep 1; printf '%s\n' \
      '2026-11-11 23:23:05:000 IBC: detected dialog entitled: Warning; event=Opened' \
      '2026-11-11 23:23:05:300 IBC: detected dialog entitled: Warning; event=Closed'; done; \
    printf '%s\n' '${MARKER}'; sleep 3; } \
    | '${BROKERSRE_LIB}/classify-ibc-log.sh' | jq -r .event"
  [ "$status" -eq 0 ]
  [ "$output" == $'unknown_window\ntwofa_timeout' ]
}

@test "after a window was reported, an answered window with its title is not reported" {
  export UNKNOWN_WINDOW_GRACE_S=1
  run bash -c "{ printf '%s\n' \
    '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Warning; event=Opened'; sleep 5; \
    printf '%s\n' \
    '2026-11-11 23:23:08:155 IBC: detected dialog entitled: Warning; event=Opened' \
    '2026-11-11 23:23:08:255 IBC: detected dialog entitled: Warning; event=Closed'; sleep 5; } \
    | '${BROKERSRE_LIB}/classify-ibc-log.sh' | jq -r .event"
  [ "$status" -eq 0 ]
  [ "$output" == "unknown_window" ]
}

@test "of two waiting windows the one that is due first is reported first, on time" {
  export UNKNOWN_WINDOW_GRACE_S=6
  # Opened at 0 s and at 4 s, so due at 6 s and at 10 s; the marker comes at 8 s.
  run bash -c "{ printf '%s\n' \
    '2026-11-11 23:23:04:155 IBC: detected dialog entitled: First; event=Opened'; sleep 4; \
    printf '%s\n' '2026-11-11 23:23:08:155 IBC: detected dialog entitled: Second; event=Opened'; sleep 4; \
    printf '%s\n' '${MARKER}'; sleep 5; } \
    | '${BROKERSRE_LIB}/classify-ibc-log.sh' | jq -r .event"
  [ "$status" -eq 0 ]
  [ "$output" == $'unknown_window\ntwofa_timeout\nunknown_window' ]
}

@test "a window that only lost the focus is still open" {
  export UNKNOWN_WINDOW_GRACE_S=1
  run bash -c "{ printf '%s\n' \
    '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Something New; event=Opened' \
    '2026-11-11 23:23:04:255 IBC: detected dialog entitled: Something New; event=Lost focus' \
    '2026-11-11 23:23:04:256 IBC: detected dialog entitled: Something New; event=Deactivated'; sleep 5; } \
    | '${BROKERSRE_LIB}/classify-ibc-log.sh' | jq -r .event"
  [ "$status" -eq 0 ]
  [ "$output" == "unknown_window" ]
}

@test "a title is compared as text: a closing window titled * closes no other" {
  export UNKNOWN_WINDOW_GRACE_S=1
  run bash -c "{ printf '%s\n' \
    '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Something New; event=Opened' \
    '2026-11-11 23:23:04:255 IBC: detected dialog entitled: *; event=Closed'; sleep 5; } \
    | '${BROKERSRE_LIB}/classify-ibc-log.sh' | jq -r .event"
  [ "$status" -eq 0 ]
  [ "$output" == "unknown_window" ]
}

@test "a title full of pattern characters closes the window of exactly that title" {
  export UNKNOWN_WINDOW_GRACE_S=1
  run bash -c "{ printf '%s\n' \
    '2026-11-11 23:23:04:355 IBC: detected dialog entitled: [x] what? * \$HOME \$(true); event=Opened' \
    '2026-11-11 23:23:04:455 IBC: detected dialog entitled: [x] what? * \$HOME \$(true); event=Closed'; sleep 5; } \
    | '${BROKERSRE_LIB}/classify-ibc-log.sh' | jq -r .event"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no more than 32 windows wait at a time: the first 32 are followed, a further one is not" {
  export UNKNOWN_WINDOW_GRACE_S=1
  # 40 windows open; windows 1, 2 and 40 close again. 1 and 2 were followed (two reports
  # less); 40 never was (its closing changes nothing): 30 reports. Had the oldest been dropped
  # to make room, 1 and 2 would no longer be followed and 40 would: 31.
  run bash -c "{ for n in \$(seq 1 40); do \
    printf '%s\n' \"2026-11-11 23:23:04:155 IBC: detected dialog entitled: Stray window \${n}; event=Opened\"; done; \
    printf '%s\n' \
    '2026-11-11 23:23:04:255 IBC: detected dialog entitled: Stray window 1; event=Closed' \
    '2026-11-11 23:23:04:255 IBC: detected dialog entitled: Stray window 2; event=Closed' \
    '2026-11-11 23:23:04:256 IBC: detected dialog entitled: Stray window 40; event=Closed'; \
    sleep 5; } | '${BROKERSRE_LIB}/classify-ibc-log.sh' | jq -r .event | sort | uniq -c | tr -s ' '"
  [ "$status" -eq 0 ]
  [ "$output" == " 30 unknown_window" ]
}

@test "a window is reported once however long it stays open" {
  export UNKNOWN_WINDOW_GRACE_S=1
  run bash -c "{ printf '%s\n' \
    '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Something New; event=Opened'; sleep 6; \
    printf '%s\n' '2026-11-11 23:23:10:000 IBC: detected dialog entitled: Something New; event=Closed'; sleep 3; } \
    | '${BROKERSRE_LIB}/classify-ibc-log.sh' | jq -r .event"
  [ "$status" -eq 0 ]
  [ "$output" == "unknown_window" ]
}

@test "a line that arrives in two pieces while a window is waiting is still one line, and the next is too" {
  export UNKNOWN_WINDOW_GRACE_S=1
  # The wait for the window ends between the two halves of the login line: the halves must be
  # joined again, or 'Login has completed' would be lost (and with it the phase logged-in).
  # The line after it must not get the old half in front: the restart line is matched from
  # its first character.
  run bash -c "{ printf '%s\n' \
    '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Something New; event=Opened' \
    '${MARKER}'; \
    printf '%s' '2026-11-11 23:23:05:000 IBC: Login has'; sleep 5; printf '%s\n' ' completed' \
    'autorestart file found at /home/ibgateway/Jts/settings/abcdefgh/autorestart: authentication will not be required'; } \
    | '${BROKERSRE_LIB}/classify-ibc-log.sh' | jq -r .event"
  [ "$status" -eq 0 ]
  [ "$output" == $'twofa_timeout\nunknown_window\nlogin_completed\ndaily_restart' ]
  [ "$(cat "${LOG_DIR}/state/phase")" == "restarting" ]
}

@test "a pause of the classifier does not turn an answered window into an unknown one" {
  export UNKNOWN_WINDOW_GRACE_S=2
  # The classifier is stopped (as a paused container or a suspended host stops it) right after
  # the window opened. IBC closes the window 0.3 s later; when the classifier runs again the
  # grace period is long over AND the closing line is in the pipe. It must read that line
  # before it decides.
  fifo="${LOG_DIR}/ibc.fifo"
  mkfifo "${fifo}"
  "${BROKERSRE_LIB}/classify-ibc-log.sh" <"${fifo}" >"${LOG_DIR}/classified.jsonl" &
  classifier_pid=$!
  exec 9>"${fifo}"
  printf '%s\n' '2026-11-15 15:15:41:567 IBC: detected dialog entitled: Warning; event=Opened' >&9
  sleep 1
  kill -STOP "${classifier_pid}"
  printf '%s\n' '2026-11-15 15:15:41:858 IBC: detected dialog entitled: Warning; event=Closed' >&9
  sleep 5
  kill -CONT "${classifier_pid}"
  sleep 2
  exec 9>&-
  wait "${classifier_pid}"
  [ ! -s "${LOG_DIR}/classified.jsonl" ]
}

@test "a last line without a line end is still classified" {
  run bash -c "printf '%s' '2026-11-01 09:03:07:000 IBC: Login has completed' | '${BROKERSRE_LIB}/classify-ibc-log.sh' | jq -r .event"
  [ "$status" -eq 0 ]
  [ "$output" == "login_completed" ]
}

@test "UNKNOWN_WINDOW_GRACE_S that is not a whole number of seconds falls back to the default" {
  # With the default (10 s) a window that closes at once is not reported; with 0 it would be.
  for bad in soon -1 1.5 ""; do
    export UNKNOWN_WINDOW_GRACE_S="${bad}"
    run classify \
      '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Warning; event=Opened' \
      '2026-11-11 23:23:04:355 IBC: detected dialog entitled: Warning; event=Closed'
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "reported with UNKNOWN_WINDOW_GRACE_S='${bad}'"; false; }
  done
}

@test "UNKNOWN_WINDOW_GRACE_S with a leading zero is a decimal number of seconds" {
  export UNKNOWN_WINDOW_GRACE_S=08
  # bash reads 08 as a broken octal number; the classifier must not print an error or stop.
  run bash -c "{ printf '%s\n' \
    '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Something New; event=Opened'; sleep 3; \
    printf '%s\n' '${MARKER}'; sleep 8; } \
    | '${BROKERSRE_LIB}/classify-ibc-log.sh' 2>&1 | jq -r .event"
  [ "$status" -eq 0 ]
  [ "$output" == $'twofa_timeout\nunknown_window' ]
}

@test "REAL completed paper logins (10.50.1g): version, login dialog, login completed, no unknown window" {
  REAL="${BATS_TEST_DIRNAME}/../../fixtures/ibc-real-paper-login.log"
  export UNKNOWN_WINDOW_GRACE_S=1
  # The pipe stays open well past the grace period: a window of the real log that the
  # classifier still waited for would be reported here.
  run bash -c "{ cat '${REAL}'; sleep 5; } | '${BROKERSRE_LIB}/classify-ibc-log.sh' | jq -r .event"
  [ "$status" -eq 0 ]
  # Two starts of one session. IBC's stop message between them ("Login has completed: exiting
  # via [File, Close] menu") is no login, and the windows of a normal paper login (the
  # start-up steps, the paper-account warning IBC accepts, the configuration dialog titled
  # with the account id) are no unknown windows.
  [ "$output" == $'ibc_version\nlogin_dialog\nlogin_completed\nibc_version\nlogin_dialog\nlogin_completed' ]
  [ "$(cat "${LOG_DIR}/state/phase")" == "logged-in" ]
}

@test "REAL completed paper logins: without the lines that close the warning, it is reported" {
  # The counterpart of the test above, on the same real log: take away IBC's report that the
  # paper-account warning closed, and the warning of the running Gateway is an unknown window.
  # (The warning of the first start is not: a new IBC started after it.)
  REAL="${BATS_TEST_DIRNAME}/../../fixtures/ibc-real-paper-login.log"
  export UNKNOWN_WINDOW_GRACE_S=1
  run bash -c "{ grep -v 'entitled: Warning; event=Closed' '${REAL}'; sleep 5; } \
    | '${BROKERSRE_LIB}/classify-ibc-log.sh' | jq -r .event"
  [ "$status" -eq 0 ]
  [ "$output" == $'ibc_version\nlogin_dialog\nlogin_completed\nibc_version\nlogin_dialog\nlogin_completed\nunknown_window' ]
}

@test "REAL completed paper logins: only the paper-account warning relies on the grace period" {
  # The title "Warning" is deliberately not on the list of known windows: a warning that IBC
  # does not answer must be reported. Without a grace period it is the only window reported.
  REAL="${BATS_TEST_DIRNAME}/../../fixtures/ibc-real-paper-login.log"
  export UNKNOWN_WINDOW_GRACE_S=0
  run bash -c "'${BROKERSRE_LIB}/classify-ibc-log.sh' < '${REAL}' | jq -r .event | grep -c unknown_window"
  [ "$output" == "2" ]
  [ "$(grep -c 'entitled: Warning; event=Opened' "${REAL}")" == "2" ]
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

@test "the real fixtures are labelled as real and hold only IBC lines" {
  for name in ibc-real-failed-login.log ibc-real-paper-login.log; do
    REAL="${BATS_TEST_DIRNAME}/../../fixtures/${name}"
    run head -1 "${REAL}"
    [[ "$output" == "# REAL LOG, scrubbed"* ]] || { echo "${name}: ${output:0:60}"; false; }
    run bash -c "tail -n +2 '${REAL}' | grep -c -v -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]+ IBC: '"
    [ "$output" == "0" ] || { echo "${name}: ${output} lines that are not IBC lines"; false; }
  done
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
