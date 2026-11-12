#!/usr/bin/env bats
# Unit tests for vnc-hook.sh: what x11vnc's -afteraccept and -gone hooks turn into events.
#
# The hook is run by x11vnc with RFB_* variables that describe the client. Some of them are
# shaped by the client or by name resolution, so the hook echoes a value only after it matched
# a strict form; everything else becomes `unknown` or is left out. The hostile values below are
# what a test can put there, not what x11vnc is known to pass.

setup() {
  : "${BROKERSRE_LIB:?set BROKERSRE_LIB to rootfs/usr/local/lib/brokersre}"
  HOOK="${BROKERSRE_LIB}/vnc-hook.sh"
  T="$(mktemp -d)"
  export LOG_DIR="${T}"
  export BOOT_ID=0123456789abcdef
  export RFB_MODE=afteraccept RFB_STATE=NORMAL RFB_CLIENT_IP=127.0.0.1 RFB_CLIENT_ID=0x1 \
    RFB_CLIENT_COUNT=1 RFB_LOGIN_TIME=1000 RFB_CURRENT_TIME=1000 RFB_USERNAME=unknown-user \
    VNC_VIEW_ONLY=yes
  unset VNC_SERVER_PASSWORD VNC_SERVER_PASSWORD_FILE
  # Assembled, so that no scanner takes this file for a leak.
  SECRET="hunter2""vnc"
}

teardown() {
  rm -rf "${T}"
}

# one_event NAME: the last run succeeded and printed exactly one line, the event NAME.
one_event() {
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  echo "$output" | jq -e --arg e "$1" '.event == $e and .src == "vnc"' >/dev/null
}

# silent: the last run succeeded, printed nothing and wrote no event.
silent() {
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "${LOG_DIR}/events/events.jsonl" ]
}

@test "an accepted client is vnc_client_connected (warn) with its address, id and the view-only state" {
  run "${HOOK}"
  one_event vnc_client_connected
  echo "$output" | jq -e '.level == "warn" and .boot_id == "0123456789abcdef" and .seq == 1' >/dev/null
  echo "$output" | jq -e '.data == {"client_ip":"127.0.0.1","client_id":"0x1","clients":"1","view_only":"yes"}' >/dev/null
  echo "$output" | jq -e '.msg | contains("127.0.0.1") and contains("view-only")' >/dev/null
  [ "$(cat "${LOG_DIR}/events/events.jsonl")" == "$output" ]
}

@test "with input allowed the event says so" {
  VNC_VIEW_ONLY=no run "${HOOK}"
  one_event vnc_client_connected
  echo "$output" | jq -e '.data.view_only == "no" and (.msg | contains("input allowed"))' >/dev/null
}

@test "a view-only state the hook was not told is reported as unknown, never as view-only" {
  VNC_VIEW_ONLY=maybe run "${HOOK}"
  one_event vnc_client_connected
  echo "$output" | jq -e '.data.view_only == "unknown"' >/dev/null
  unset VNC_VIEW_ONLY
  run "${HOOK}"
  one_event vnc_client_connected
  echo "$output" | jq -e '.data.view_only == "unknown"' >/dev/null
}

@test "a client that leaves is vnc_client_disconnected (info) with the length of its session" {
  export RFB_MODE=gone RFB_CLIENT_COUNT=0 RFB_CURRENT_TIME=1042
  run "${HOOK}"
  one_event vnc_client_disconnected
  echo "$output" | jq -e '.level == "info" and .data == {"client_ip":"127.0.0.1","client_id":"0x1","clients":"0","session_s":"42"}' >/dev/null
  echo "$output" | jq -e '.msg | contains("127.0.0.1") and contains("42 s")' >/dev/null
}

@test "a client that never reached the normal state is no event, when it arrives and when it leaves" {
  for state in PROTOCOL_VERSION SECURITY_TYPE AUTHENTICATION INITIALISATION UNKNOWN ''; do
    RFB_MODE=gone RFB_STATE="${state}" run "${HOOK}"
    silent
    RFB_MODE=afteraccept RFB_STATE="${state}" run "${HOOK}"
    silent
  done
}

@test "any other mode, and no mode at all, is no event" {
  RFB_MODE=accept run "${HOOK}"
  silent
  RFB_MODE=env run "${HOOK}"
  silent
  unset RFB_MODE
  run "${HOOK}"
  silent
}

@test "a client address that is not a plain IPv4 address is reported as unknown and never echoed" {
  for ip in 'evil.example.org' '127.0.0.1"; rm -rf /' '127.0.0.1 extra' '::1' '1.2.3' '1.2.3.4.5' '999.1.1.1' \
    "$(printf 'a\nb')" "$(printf '127.0.0.1\033[31m')" ''; do
    rm -rf "${LOG_DIR}/events"
    RFB_CLIENT_IP="${ip}" run "${HOOK}"
    one_event vnc_client_connected
    echo "$output" | jq -e '.data.client_ip == "unknown"' >/dev/null
    [[ "$output" != *"evil"* ]]
    [[ "$output" != *"rm -rf"* ]]
    [[ "$output" != *"extra"* ]]
    [[ "$output" != *"999.1.1.1"* ]]
    [[ "$output" != *"[31m"* ]]
  done
}

@test "an id, a count or a time in another form is left out, never echoed" {
  export RFB_CLIENT_ID='0x1; reboot' RFB_CLIENT_COUNT='many' RFB_LOGIN_TIME='then' RFB_CURRENT_TIME='now'
  run "${HOOK}"
  one_event vnc_client_connected
  echo "$output" | jq -e '.data == {"client_ip":"127.0.0.1","view_only":"yes"}' >/dev/null
  [[ "$output" != *"reboot"* ]]
  [[ "$output" != *"many"* ]]
  export RFB_MODE=gone
  rm -rf "${LOG_DIR}/events"
  run "${HOOK}"
  one_event vnc_client_disconnected
  echo "$output" | jq -e '.data == {"client_ip":"127.0.0.1"}' >/dev/null
  [[ "$output" != *"then"* ]]
  [[ "$output" != *"now"* ]]
}

@test "a session that would have a negative length has no length" {
  export RFB_MODE=gone RFB_LOGIN_TIME=2000 RFB_CURRENT_TIME=1000
  run "${HOOK}"
  one_event vnc_client_disconnected
  echo "$output" | jq -e '.data | has("session_s") | not' >/dev/null
}

@test "text the client could shape and secrets in the environment never reach an event" {
  export RFB_USERNAME='mallory"$(id)' RFB_SSL_CLIENT_CERT='CERT-TEXT' VNC_SERVER_PASSWORD="${SECRET}"
  run "${HOOK}"
  one_event vnc_client_connected
  [[ "$output" != *"mallory"* ]]
  [[ "$output" != *"CERT-TEXT"* ]]
  [[ "$output" != *"${SECRET}"* ]]
  ! grep -rq -e mallory -e CERT-TEXT -e "${SECRET}" "${LOG_DIR}" || false
}

@test "the hook always ends with status 0, also when the log volume cannot be written" {
  export LOG_DIR="/proc/nonexistent-log-dir"
  run "${HOOK}"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.event == "vnc_client_connected" and (has("seq") | not)' >/dev/null
}
