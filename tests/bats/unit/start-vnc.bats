#!/usr/bin/env bats
# Unit tests for start-vnc.sh, the break-glass console.
#
# The VNC password must never appear in a process argument list (`ps` shows argv to every
# process in the container), in an event or in a hook, and must not stay on disk. The console is
# view-only unless VNC_VIEW_ONLY=no, and a client that connects or leaves becomes an event on the
# container's stdout although x11vnc's own stdout is discarded.
#
# x11vnc is replaced by a stand-in on PATH that records how it was started and, on request,
# plays one client session the way x11vnc 0.9.17 does: it runs the -afteraccept and the -gone
# command through `sh -c` (system(3)) with the RFB_* variables set, its own stdout and stderr
# being whatever start_vnc gave it.

setup() {
  : "${BROKERSRE_LIB:?set BROKERSRE_LIB to rootfs/usr/local/lib/brokersre}"
  export RUN_DIR="$(mktemp -d)"
  export LOG_DIR="$(mktemp -d)"
  export DISPLAY=":1"
  STUB_DIR="$(mktemp -d)"
  ARGV_LOG="${STUB_DIR}/argv.log"
  ARGS_FILE="${STUB_DIR}/args.txt"
  ENV_FILE="${STUB_DIR}/env.txt"
  export ARGV_LOG ARGS_FILE ENV_FILE
  # The stand-in. For -passwdfile it records the mode and content of the file it was pointed at
  # (as the real one reads it). With FAKE_VNC_SESSION=1 it plays one client that connects and
  # leaves; with FAKE_VNC_SESSION=left-early the client leaves before it authenticated.
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" "ARGV: $*" >>"${ARGV_LOG}"' \
    'printf "%s\n" "$@" >"${ARGS_FILE}"' \
    'env >"${ENV_FILE}"' \
    'prev="" after="" gone=""' \
    'for a in "$@"; do' \
    '  case "${prev}" in' \
    '    -passwdfile)' \
    '      f="${a#rm:}"' \
    '      printf "%s\n" "MODE: $(stat -c %a "${f}")" "CONTENT: $(cat "${f}")" "RM_PREFIX: ${a%%:*}" >>"${ARGV_LOG}"' \
    '      ;;' \
    '    -afteraccept) after="${a}" ;;' \
    '    -gone) gone="${a}" ;;' \
    '  esac' \
    '  prev="${a}"' \
    'done' \
    'export RFB_CLIENT_IP=127.0.0.1 RFB_CLIENT_ID=0x1 RFB_X11VNC_PID=$$ RFB_USERNAME=unknown-user' \
    'if [ -n "${FAKE_VNC_SESSION:-}" ]; then' \
    '  # A client arrives after the console was announced: wait for that event, at most 5 s.' \
    '  for _ in $(seq 1 100); do' \
    '    if grep -q vnc_enabled "${LOG_DIR}/events/events.jsonl" 2>/dev/null; then break; fi' \
    '    sleep 0.05' \
    '  done' \
    'fi' \
    'case "${FAKE_VNC_SESSION:-}" in' \
    '  1)' \
    '    RFB_MODE=afteraccept RFB_STATE=NORMAL RFB_CLIENT_COUNT=1 RFB_LOGIN_TIME=1000 RFB_CURRENT_TIME=1000 sh -c "${after}"' \
    '    RFB_MODE=gone RFB_STATE=NORMAL RFB_CLIENT_COUNT=0 RFB_LOGIN_TIME=1000 RFB_CURRENT_TIME=1042 sh -c "${gone}"' \
    '    ;;' \
    '  left-early)' \
    '    RFB_MODE=gone RFB_STATE=AUTHENTICATION RFB_CLIENT_COUNT=0 RFB_LOGIN_TIME=1000 RFB_CURRENT_TIME=1001 sh -c "${gone}"' \
    '    ;;' \
    'esac' \
    'exit 0' >"${STUB_DIR}/x11vnc"
  chmod +x "${STUB_DIR}/x11vnc"
  export PATH="${STUB_DIR}:${PATH}"
  unset VNC_SERVER_PASSWORD VNC_SERVER_PASSWORD_FILE VNC_VIEW_ONLY FAKE_VNC_SESSION BOOT_ID
  # Assembled, so that no scanner takes this file for a leak.
  SECRET="hunter2""vnc"
}

teardown() {
  rm -rf "${RUN_DIR}" "${LOG_DIR}" "${STUB_DIR}"
}

# vnc COMMAND: start the console in a fresh bash, wait for the stand-in to end, run COMMAND.
vnc() {
  bash -c "source '${BROKERSRE_LIB}/common.sh'; source '${BROKERSRE_LIB}/start-vnc.sh'; start_vnc; wait; $1"
}

# event NAME: the line of the last run's output that is the event NAME (empty when absent).
event() {
  grep -F "\"event\":\"$1\"" <<<"$output" || true
}

# has_arg OPTION: true when the stand-in was started with OPTION as one whole argument.
has_arg() {
  grep -q -x -e "$1" "${ARGS_FILE}"
}

@test "without a password VNC stays disabled and x11vnc is never started" {
  run vnc 'true'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.event == "vnc_disabled"' >/dev/null
  [ ! -e "${ARGV_LOG}" ]
}

@test "the password never appears in any x11vnc argument list" {
  export VNC_SERVER_PASSWORD="${SECRET}"
  run vnc 'true'
  [ "$status" -eq 0 ]
  grep -q '^ARGV: ' "${ARGV_LOG}"
  ! grep '^ARGV: ' "${ARGV_LOG}" | grep -q "${SECRET}" || false
}

@test "x11vnc reads the password from a private file that it removes after reading" {
  export VNC_SERVER_PASSWORD="${SECRET}"
  run vnc 'true'
  [ "$status" -eq 0 ]
  grep -q -x 'MODE: 600' "${ARGV_LOG}"
  grep -q -x "CONTENT: ${SECRET}" "${ARGV_LOG}"
  grep -q -x 'RM_PREFIX: rm' "${ARGV_LOG}"
}

@test "VNC listens on loopback only and the secret leaves the environment" {
  export VNC_SERVER_PASSWORD="${SECRET}"
  run vnc 'echo "P=${VNC_SERVER_PASSWORD:-unset}"'
  [ "$status" -eq 0 ]
  grep '^ARGV: ' "${ARGV_LOG}" | grep -q -- '-localhost'
  [[ "$output" == *"P=unset"* ]]
  [[ "$output" != *"${SECRET}"* ]]
}

@test "the console is view-only by default, and the event says so" {
  export VNC_SERVER_PASSWORD="${SECRET}"
  run vnc 'true'
  [ "$status" -eq 0 ]
  has_arg -viewonly
  event vnc_enabled | jq -e '.src == "vnc" and .level == "warn" and .data.view_only == "yes" and (.msg | contains("view-only"))' >/dev/null
}

@test "VNC_VIEW_ONLY=yes is the same as the default" {
  export VNC_SERVER_PASSWORD="${SECRET}" VNC_VIEW_ONLY=yes
  run vnc 'true'
  [ "$status" -eq 0 ]
  has_arg -viewonly
  event vnc_enabled | jq -e '.data.view_only == "yes"' >/dev/null
}

@test "VNC_VIEW_ONLY=no starts x11vnc without -viewonly, and the event says input is allowed" {
  export VNC_SERVER_PASSWORD="${SECRET}" VNC_VIEW_ONLY=no
  run vnc 'true'
  [ "$status" -eq 0 ]
  ! has_arg -viewonly || false
  event vnc_enabled | jq -e '.level == "warn" and .data.view_only == "no" and (.msg | contains("input allowed"))' >/dev/null
}

@test "x11vnc's remote-control channel is off, so nothing can lift view-only while it runs" {
  export VNC_SERVER_PASSWORD="${SECRET}"
  run vnc 'true'
  [ "$status" -eq 0 ]
  has_arg -noremote
  VNC_VIEW_ONLY=no run vnc 'true'
  [ "$status" -eq 0 ]
  has_arg -noremote
}

@test "any other VNC_VIEW_ONLY stops the start before x11vnc runs or the password is written" {
  export VNC_SERVER_PASSWORD="${SECRET}"
  for value in true No YES 1 'yes '; do
    VNC_VIEW_ONLY="${value}" run vnc 'echo not-reached'
    [ "$status" -eq 1 ]
    event config_invalid | jq -e '.src == "vnc" and .level == "error" and (.msg | contains("VNC_VIEW_ONLY must be yes or no"))' >/dev/null
    [[ "$output" != *"not-reached"* ]]
    [[ "$output" != *"${SECRET}"* ]]
    [ ! -e "${ARGV_LOG}" ]
    [ ! -e "${RUN_DIR}/vncpasswd" ]
  done
}

@test "an empty VNC_VIEW_ONLY is the default, as for an unset variable" {
  export VNC_SERVER_PASSWORD="${SECRET}" VNC_VIEW_ONLY=""
  run vnc 'true'
  [ "$status" -eq 0 ]
  has_arg -viewonly
}

@test "VNC_VIEW_ONLY is not judged while the console is off" {
  export VNC_VIEW_ONLY=nonsense
  run vnc 'true'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.event == "vnc_disabled"' >/dev/null
  [ ! -e "${ARGV_LOG}" ]
}

@test "x11vnc is given the session hook for a client that connects and for one that leaves" {
  export VNC_SERVER_PASSWORD="${SECRET}"
  run vnc 'true'
  [ "$status" -eq 0 ]
  after="$(grep -x -A1 -e '-afteraccept' "${ARGS_FILE}" | tail -n 1)"
  gone="$(grep -x -A1 -e '-gone' "${ARGS_FILE}" | tail -n 1)"
  [[ "${after}" == *"${BROKERSRE_LIB}/vnc-hook.sh"* ]]
  [ "${after}" == "${gone}" ]
  [[ "${after}" != *"${SECRET}"* ]]
}

@test "a client session becomes two events on stdout although x11vnc's own stdout is discarded" {
  export VNC_SERVER_PASSWORD="${SECRET}" FAKE_VNC_SESSION=1 BOOT_ID=0123456789abcdef
  run vnc 'true'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  echo "${lines[0]}" | jq -e '.event == "vnc_enabled" and .seq == 1' >/dev/null
  echo "${lines[1]}" | jq -e '.event == "vnc_client_connected" and .src == "vnc" and .level == "warn" and .seq == 2 and .data.view_only == "yes" and .data.client_ip == "127.0.0.1"' >/dev/null
  echo "${lines[2]}" | jq -e '.event == "vnc_client_disconnected" and .src == "vnc" and .level == "info" and .seq == 3 and .data.session_s == "42"' >/dev/null
  [ "$(cat "${LOG_DIR}/events/events.jsonl")" == "$output" ]
}

@test "the session events say that input was allowed when VNC_VIEW_ONLY=no" {
  export VNC_SERVER_PASSWORD="${SECRET}" VNC_VIEW_ONLY=no FAKE_VNC_SESSION=1 BOOT_ID=0123456789abcdef
  run vnc 'true'
  [ "$status" -eq 0 ]
  event vnc_client_connected | jq -e '.data.view_only == "no" and (.msg | contains("input allowed"))' >/dev/null
}

@test "a client that leaves before it authenticated is no session and no event" {
  export VNC_SERVER_PASSWORD="${SECRET}" FAKE_VNC_SESSION=left-early BOOT_ID=0123456789abcdef
  run vnc 'true'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  echo "${lines[0]}" | jq -e '.event == "vnc_enabled"' >/dev/null
}

@test "nothing but events reaches stdout: x11vnc's own output stays discarded" {
  export VNC_SERVER_PASSWORD="${SECRET}" FAKE_VNC_SESSION=1 BOOT_ID=0123456789abcdef
  printf '%s\n' 'echo "PORT=5900"' 'echo "The VNC desktop is: localhost:0" >&2' >>"${STUB_DIR}/x11vnc"
  sed -i 's/^exit 0$//' "${STUB_DIR}/x11vnc"
  run vnc 'true'
  [ "$status" -eq 0 ]
  [[ "$output" != *"PORT=5900"* ]]
  [[ "$output" != *"VNC desktop"* ]]
  echo "$output" | jq -es 'length == 3 and all(has("ts") and has("src") and has("level") and has("event") and has("msg"))' >/dev/null
}

@test "the password is in no event, no hook command and not in x11vnc's environment" {
  export VNC_SERVER_PASSWORD="${SECRET}" FAKE_VNC_SESSION=1 BOOT_ID=0123456789abcdef
  run vnc 'true'
  [ "$status" -eq 0 ]
  [[ "$output" != *"${SECRET}"* ]]
  ! grep -q "${SECRET}" "${ARGS_FILE}" || false
  ! grep -q "${SECRET}" "${ENV_FILE}" || false
  ! grep -rq "${SECRET}" "${LOG_DIR}" || false
  ! grep -q '^VNC_SERVER_PASSWORD' "${ENV_FILE}" || false
}

@test "a password from a secret file is handled the same way and its path leaves the environment" {
  printf '%s\n' "${SECRET}" >"${STUB_DIR}/vnc-secret"
  export VNC_SERVER_PASSWORD_FILE="${STUB_DIR}/vnc-secret" FAKE_VNC_SESSION=1 BOOT_ID=0123456789abcdef
  run vnc 'echo "F=${VNC_SERVER_PASSWORD_FILE:-unset}"'
  [ "$status" -eq 0 ]
  grep -q -x "CONTENT: ${SECRET}" "${ARGV_LOG}"
  [[ "$output" == *"F=unset"* ]]
  [[ "$output" != *"${SECRET}"* ]]
  ! grep -q "${SECRET}" "${ARGS_FILE}" "${ENV_FILE}" || false
  ! grep -q '^VNC_SERVER_PASSWORD' "${ENV_FILE}" || false
}
