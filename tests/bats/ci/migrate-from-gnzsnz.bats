#!/usr/bin/env bats
# Unit tests for scripts/migrate-from-gnzsnz.sh: it turns the .env of a
# gnzsnz/ib-gateway-docker deployment into one for this image (stdout) and reports every
# variable it dropped or changed (stderr). The rules come from docs/migrating-from-gnzsnz.md and
# from the doctor's ignored-variable list. The property that matters most: a credential is
# carried over in its own line and appears nowhere else, least of all in the report.

setup() {
  REPO="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SCRIPT="${REPO}/scripts/migrate-from-gnzsnz.sh"
  DOCTOR="${REPO}/rootfs/usr/local/lib/brokersre/doctor.sh"
  WORK="$(mktemp -d)"
  # Obviously fake secrets, assembled at run time so that no scanner sees a literal assignment.
  CANARY_USER="CANARY_$(printf '%s' user)_1"
  CANARY_PASS="CANARY_$(printf '%s' pass)_2"
  CANARY_PAPER="CANARY_$(printf '%s' paper)_3"
  CANARY_VNC="CANARY_$(printf '%s' vnc)_4"
  CANARY_SSH="CANARY_$(printf '%s' ssh)_5"
  CANARY_PATH="/run/secrets/CANARY_$(printf '%s' path)_6"
  CANARY_UNKNOWN="CANARY_$(printf '%s' unknown)_7"
  CANARY_CONTENT="CANARY_$(printf '%s' content)_8"
}

teardown() {
  rm -rf "${WORK}"
}

# write_env LINE...: write the lines, LF-terminated, to ${WORK}/in.env.
write_env() {
  printf '%s\n' "$@" >"${WORK}/in.env"
}

# convert [FILE]: run the converter on FILE (default ${WORK}/in.env); stdout goes to
# ${WORK}/out, stderr to ${WORK}/err, the exit status to RC.
convert() {
  RC=0
  "${SCRIPT}" "${1:-${WORK}/in.env}" >"${WORK}/out" 2>"${WORK}/err" || RC=$?
}

# out_has LINE / out_lacks PATTERN: exact-line match on stdout, fixed-string absence on stdout.
out_has() { grep -q -F -x -- "$1" "${WORK}/out"; }
out_lacks() { ! grep -q -F -- "$1" "${WORK}/out"; }
err_has() { grep -q -F -- "$1" "${WORK}/err"; }
err_lacks() { ! grep -q -F -- "$1" "${WORK}/err"; }

@test "no argument, two arguments and a missing file are usage errors (exit 2), nothing on stdout" {
  RC=0
  "${SCRIPT}" >"${WORK}/out" 2>"${WORK}/err" || RC=$?
  [ "${RC}" -eq 2 ]
  err_has "usage: migrate-from-gnzsnz.sh"
  [ ! -s "${WORK}/out" ]

  RC=0
  "${SCRIPT}" a b >"${WORK}/out" 2>"${WORK}/err" || RC=$?
  [ "${RC}" -eq 2 ]
  [ ! -s "${WORK}/out" ]

  convert "${WORK}/does-not-exist.env"
  [ "${RC}" -eq 2 ]
  err_has "cannot read"
  [ ! -s "${WORK}/out" ]
}

@test "--help prints the usage and exits 0" {
  run "${SCRIPT}" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: migrate-from-gnzsnz.sh"* ]]
  [[ "$output" == *"exit status"* ]]
}

@test "variables with the same name in both images are carried over unchanged and not reported" {
  write_env \
    'TRADING_MODE=paper' \
    'READ_ONLY_API=no' \
    'TWOFA_TIMEOUT_ACTION=exit' \
    'RELOGIN_AFTER_TWOFA_TIMEOUT=yes' \
    'TWOFA_EXIT_INTERVAL=60' \
    'TWOFA_DEVICE=IB Key' \
    'EXISTING_SESSION_DETECTED_ACTION=primary' \
    'AUTO_RESTART_TIME=11:45 PM' \
    'AUTO_LOGOFF_TIME=' \
    'TIME_ZONE=Europe/Zurich' \
    'TZ=Europe/Zurich' \
    'TWS_SETTINGS_PATH=/home/ibgateway/Jts/settings' \
    'BYPASS_WARNING=yes' \
    'TWS_ACCEPT_INCOMING=reject' \
    'ALLOW_BLIND_TRADING=no' \
    'SAVE_TWS_SETTINGS=' \
    'TWS_MASTER_CLIENT_ID=' \
    'CUSTOM_CONFIG=no'
  convert
  [ "${RC}" -eq 0 ]
  cmp "${WORK}/in.env" "${WORK}/out"
  # No per-line item at all: the report is the summary and the closing hint.
  err_lacks ": line "
  err_lacks "note:"
  err_has "converted: 18 kept, 0 renamed, 0 dropped, 0 unknown"
}

@test "TWOFA_TIMEOUT_ACTION is kept with either value" {
  write_env 'TWOFA_TIMEOUT_ACTION=restart'
  convert
  [ "${RC}" -eq 0 ]
  out_has 'TWOFA_TIMEOUT_ACTION=restart'
  write_env 'TWOFA_TIMEOUT_ACTION=exit'
  convert
  [ "${RC}" -eq 0 ]
  out_has 'TWOFA_TIMEOUT_ACTION=exit'
  err_lacks "TWOFA_TIMEOUT_ACTION"
}

@test "comments, blank lines and the number of lines are preserved" {
  write_env \
    '# IB Gateway settings' \
    '' \
    '   # indented comment with = inside' \
    'TRADING_MODE=live' \
    '' \
    '#TWS_COLD_RESTART=11:00 PM' \
    'SSH_TUNNEL=yes' \
    '' \
    '# end'
  convert
  [ "${RC}" -eq 0 ]
  [ "$(wc -l <"${WORK}/out")" -eq "$(wc -l <"${WORK}/in.env")" ]
  [ "$(sed -n 1p "${WORK}/out")" == '# IB Gateway settings' ]
  [ "$(sed -n 2p "${WORK}/out")" == '' ]
  [ "$(sed -n 3p "${WORK}/out")" == '   # indented comment with = inside' ]
  [ "$(sed -n 4p "${WORK}/out")" == 'TRADING_MODE=live' ]
  [ "$(sed -n 6p "${WORK}/out")" == '#TWS_COLD_RESTART=11:00 PM' ]
  [ "$(sed -n 9p "${WORK}/out")" == '# end' ]
}

@test "CRLF input is converted: no CR in the output and the rules still apply" {
  printf '%s\r\n' '# from Windows' 'TRADING_MODE=live' 'JAVA_HEAP_SIZE=1024' 'SSH_TUNNEL=yes' 'TIME_ZONE=Etc/UTC' >"${WORK}/in.env"
  convert
  [ "${RC}" -eq 0 ]
  ! grep -q $'\r' "${WORK}/out"
  ! grep -q $'\r' "${WORK}/err"
  out_has '# from Windows'
  out_has 'TRADING_MODE=live'
  out_has 'JAVA_HEAP_MB=1024'
  out_has 'TIME_ZONE=Etc/UTC'
  out_lacks 'SSH_TUNNEL='
}

@test "CRLF input with TRADING_MODE=both is still refused" {
  printf '%s\r\n' 'TRADING_MODE=both' >"${WORK}/in.env"
  convert
  [ "${RC}" -eq 1 ]
}

@test "a UTF-8 byte-order mark is removed and the first variable is still recognised" {
  printf '\xef\xbb\xbfJAVA_HEAP_SIZE=2048\nTRADING_MODE=paper\n' >"${WORK}/in.env"
  convert
  [ "${RC}" -eq 0 ]
  [ "$(sed -n 1p "${WORK}/out")" == 'JAVA_HEAP_MB=2048' ]
}

@test "a UTF-16 file (Windows PowerShell 5.1 '>') is refused as a usage error with the fix" {
  printf 'T\0R\0A\0D\0I\0N\0G\0_\0M\0O\0D\0E\0=\0l\0i\0v\0e\0\n\0' >"${WORK}/in.env"
  convert
  [ "${RC}" -eq 2 ]
  err_has "UTF-8"
  [ ! -s "${WORK}/out" ]
}

@test "a last line without a newline is converted too" {
  printf 'TRADING_MODE=live\nJAVA_HEAP_SIZE=512' >"${WORK}/in.env"
  convert
  [ "${RC}" -eq 0 ]
  out_has 'JAVA_HEAP_MB=512'
}

@test "JAVA_HEAP_SIZE=N becomes JAVA_HEAP_MB=N and the report says so" {
  write_env 'JAVA_HEAP_SIZE=1024'
  convert
  [ "${RC}" -eq 0 ]
  out_has 'JAVA_HEAP_MB=1024'
  out_lacks 'JAVA_HEAP_SIZE'
  err_has "line 1: JAVA_HEAP_SIZE renamed to JAVA_HEAP_MB"
  err_has "converted: 0 kept, 1 renamed, 0 dropped, 0 unknown"
}

@test "the JAVA_HEAP_SIZE rename keeps export, quotes, spacing and an inline comment" {
  write_env 'export JAVA_HEAP_SIZE="2048"   # megabytes'
  convert
  [ "${RC}" -eq 0 ]
  out_has 'export JAVA_HEAP_MB="2048"   # megabytes'
}

@test "a JAVA_HEAP_SIZE that is not a number of megabytes is dropped, not carried into JAVA_HEAP_MB" {
  write_env 'JAVA_HEAP_SIZE=2g'
  convert
  [ "${RC}" -eq 0 ]
  out_lacks 'JAVA_HEAP_MB='
  out_lacks 'JAVA_HEAP_SIZE='
  err_has "line 1: JAVA_HEAP_SIZE dropped"
  err_has "megabytes"
}

@test "JAVA_HEAP_SIZE is dropped when the file already sets JAVA_HEAP_MB" {
  write_env 'JAVA_HEAP_SIZE=512' 'JAVA_HEAP_MB=1024'
  convert
  [ "${RC}" -eq 0 ]
  out_has 'JAVA_HEAP_MB=1024'
  out_lacks 'JAVA_HEAP_MB=512'
  [ "$(grep -c '^JAVA_HEAP_MB=' "${WORK}/out")" -eq 1 ]
  err_has "line 1: JAVA_HEAP_SIZE dropped"
}

@test "TRADING_MODE=both is refused: exit 1, nothing on stdout, the reason and the multi-gateway compose file" {
  write_env 'TWS_USERID=x' 'TRADING_MODE=both' 'JAVA_HEAP_SIZE=1024'
  convert
  [ "${RC}" -eq 1 ]
  [ ! -s "${WORK}/out" ]
  err_has "line 2: TRADING_MODE=both is refused"
  err_has "one brokerage session per container"
  err_has "compose/docker-compose.multi.yml"
  err_has "nothing was converted"
}

@test "TRADING_MODE=both is recognised in every spelling a .env file allows" {
  local line
  for line in 'TRADING_MODE="both"' "TRADING_MODE='both'" 'TRADING_MODE=both # live and paper' \
    '  TRADING_MODE = both  ' 'export TRADING_MODE=both' 'TRADING_MODE=BOTH'; do
    write_env "${line}"
    convert
    [ "${RC}" -eq 1 ] || {
      echo "not refused: ${line}"
      return 1
    }
    [ ! -s "${WORK}/out" ]
  done
}

@test "TRADING_MODE=live and TRADING_MODE=paper are kept" {
  write_env 'TRADING_MODE=live'
  convert
  [ "${RC}" -eq 0 ]
  out_has 'TRADING_MODE=live'
  write_env 'TRADING_MODE=paper'
  convert
  [ "${RC}" -eq 0 ]
  out_has 'TRADING_MODE=paper'
}

@test "a TRADING_MODE this image refuses is kept and flagged" {
  write_env 'TRADING_MODE=demo'
  convert
  [ "${RC}" -eq 0 ]
  out_has 'TRADING_MODE=demo'
  err_has "line 1: TRADING_MODE"
  err_has "live or paper"
}

@test "SSH_* variables are dropped with the reason" {
  write_env 'SSH_TUNNEL=yes' 'SSH_OPTIONS=-o ServerAliveInterval=30' 'SSH_USER_TUNNEL=user@host' \
    'SSH_REMOTE_PORT=4001' 'SSH_ALIVE_INTERVAL=20' 'SSH_ALIVE_COUNT=3' 'SSH_RESTART=5' 'SSH_VNC_PORT=5900' \
    'SSH_PASSPHRASE_FILE=/run/secrets/passphrase' 'SSH_SOMETHING_NEW=1'
  convert
  [ "${RC}" -eq 0 ]
  ! grep -q '^[^#]*SSH_' "${WORK}/out"
  [ "$(grep -c 'dropped: the SSH tunnel was removed' "${WORK}/err")" -eq 10 ]
  err_has "line 1: SSH_TUNNEL dropped: the SSH tunnel was removed"
  err_has "private network"
  err_has "converted: 0 kept, 0 renamed, 10 dropped, 0 unknown"
}

@test "the *_PAPER credentials are dropped with the reason" {
  write_env "TWS_USERID_PAPER=${CANARY_USER}" "TWS_PASSWORD_PAPER=${CANARY_PAPER}" 'TWS_PASSWORD_PAPER_FILE=/run/secrets/paper'
  convert
  [ "${RC}" -eq 0 ]
  ! grep -q '^[^#]*_PAPER' "${WORK}/out"
  err_has "line 1: TWS_USERID_PAPER dropped: dual mode was removed"
  err_has "line 2: TWS_PASSWORD_PAPER dropped: dual mode was removed"
  err_has "line 3: TWS_PASSWORD_PAPER_FILE dropped: dual mode was removed"
  err_has "compose/docker-compose.multi.yml"
}

@test "TWS_COLD_RESTART is dropped with the reason" {
  write_env 'TWS_COLD_RESTART=11:00 PM'
  convert
  [ "${RC}" -eq 0 ]
  out_lacks 'TWS_COLD_RESTART='
  err_has "line 1: TWS_COLD_RESTART dropped"
  err_has "AUTO_RESTART_TIME"
}

@test "the script-hook variables are dropped with the reason" {
  write_env 'START_SCRIPTS=/scripts/start' 'X_SCRIPTS=/scripts/x' 'IBC_SCRIPTS=/scripts/ibc'
  convert
  [ "${RC}" -eq 0 ]
  out_lacks 'START_SCRIPTS='
  out_lacks 'X_SCRIPTS='
  out_lacks 'IBC_SCRIPTS='
  [ "$(grep -c 'dropped: hook scripts were removed' "${WORK}/err")" -eq 3 ]
}

@test "GATEWAY_OR_TWS is dropped with the reason" {
  write_env 'GATEWAY_OR_TWS=gateway'
  convert
  [ "${RC}" -eq 0 ]
  out_lacks 'GATEWAY_OR_TWS='
  err_has "line 1: GATEWAY_OR_TWS dropped: this image runs IB Gateway only"
}

@test "a dropped variable leaves a comment that names it, in the same line position, without its value" {
  write_env 'TRADING_MODE=live' "TWS_PASSWORD_PAPER=${CANARY_PAPER}" 'TIME_ZONE=Etc/UTC'
  convert
  [ "${RC}" -eq 0 ]
  [ "$(sed -n 2p "${WORK}/out")" == '# TWS_PASSWORD_PAPER: removed by migrate-from-gnzsnz.sh (dual mode was removed)' ]
  [ "$(sed -n 3p "${WORK}/out")" == 'TIME_ZONE=Etc/UTC' ]
}

@test "unknown variables are kept unchanged and listed as unknown, kept" {
  write_env 'MY_STRATEGY_FLAG=on' 'TRADING_MODE=live' 'export OTHER_THING="a b"'
  convert
  [ "${RC}" -eq 0 ]
  out_has 'MY_STRATEGY_FLAG=on'
  out_has 'export OTHER_THING="a b"'
  err_has "line 1: MY_STRATEGY_FLAG unknown, kept"
  err_has "line 3: OTHER_THING unknown, kept"
  err_has "converted: 1 kept, 0 renamed, 0 dropped, 2 unknown"
}

@test "a line that is neither a comment nor an assignment is kept and reported by number only" {
  write_env 'TRADING_MODE=live' "this is ${CANARY_UNKNOWN} not an assignment"
  convert
  [ "${RC}" -eq 0 ]
  out_has "this is ${CANARY_UNKNOWN} not an assignment"
  err_has "line 2: not an assignment, kept as it is"
  err_lacks "${CANARY_UNKNOWN}"
}

@test "canary: a credential appears on stdout only inside its carried-over line and never in the report" {
  write_env \
    '# credentials' \
    "TWS_USERID=${CANARY_USER}" \
    "TWS_PASSWORD=${CANARY_PASS}" \
    "VNC_SERVER_PASSWORD=${CANARY_VNC}" \
    "TWS_PASSWORD_FILE=${CANARY_PATH}" \
    "TWS_PASSWORD_PAPER=${CANARY_PAPER}" \
    "SSH_PASSPHRASE=${CANARY_SSH}" \
    "MY_API_TOKEN=${CANARY_UNKNOWN}" \
    'TRADING_MODE=live'
  convert
  [ "${RC}" -eq 0 ]
  # Carried over: the exact input line, once, and nowhere else on stdout.
  out_has "TWS_USERID=${CANARY_USER}"
  out_has "TWS_PASSWORD=${CANARY_PASS}"
  out_has "VNC_SERVER_PASSWORD=${CANARY_VNC}"
  out_has "TWS_PASSWORD_FILE=${CANARY_PATH}"
  out_has "MY_API_TOKEN=${CANARY_UNKNOWN}"
  [ "$(grep -c -F "${CANARY_USER}" "${WORK}/out")" -eq 1 ]
  [ "$(grep -c -F "${CANARY_PASS}" "${WORK}/out")" -eq 1 ]
  [ "$(grep -c -F "${CANARY_VNC}" "${WORK}/out")" -eq 1 ]
  [ "$(grep -c -F "${CANARY_PATH}" "${WORK}/out")" -eq 1 ]
  [ "$(grep -c -F "${CANARY_UNKNOWN}" "${WORK}/out")" -eq 1 ]
  # Dropped secrets are gone from stdout altogether.
  out_lacks "${CANARY_PAPER}"
  out_lacks "${CANARY_SSH}"
  # The report names the variables and masks every value.
  err_lacks "CANARY_"
  err_has "line 2: TWS_USERID=<hidden> kept"
  err_has "line 3: TWS_PASSWORD=<hidden> kept"
  err_has "line 4: VNC_SERVER_PASSWORD=<hidden> kept"
  err_has "line 5: TWS_PASSWORD_FILE=<hidden> kept"
  err_has "line 8: MY_API_TOKEN unknown, kept"
}

@test "canary: a refused conversion prints no credential anywhere" {
  write_env "TWS_USERID=${CANARY_USER}" "TWS_PASSWORD=${CANARY_PASS}" "TWS_PASSWORD_PAPER=${CANARY_PAPER}" 'TRADING_MODE=both'
  convert
  [ "${RC}" -eq 1 ]
  [ ! -s "${WORK}/out" ]
  err_lacks "CANARY_"
}

@test "the file a *_FILE variable points at is never opened: its content appears nowhere" {
  printf '%s' "${CANARY_CONTENT}" >"${WORK}/secret-file"
  write_env "TWS_PASSWORD_FILE=${WORK}/secret-file" "TWS_USERID_FILE=${WORK}/secret-file" "VNC_SERVER_PASSWORD_FILE=${WORK}/secret-file"
  convert
  [ "${RC}" -eq 0 ]
  out_lacks "${CANARY_CONTENT}"
  err_lacks "${CANARY_CONTENT}"
  err_lacks "${WORK}/secret-file"
  out_has "TWS_PASSWORD_FILE=${WORK}/secret-file"
}

@test "a plain TWS_PASSWORD gets the advice to move it into a secret file" {
  write_env 'TWS_USERID=someone' 'TWS_PASSWORD=something'
  convert
  [ "${RC}" -eq 0 ]
  err_has "TWS_PASSWORD_FILE"
  err_has "TWS_USERID_FILE"
  err_lacks "someone"
  err_lacks "something"
}

@test "changed defaults are pointed out when the variable is absent" {
  write_env 'TRADING_MODE=live'
  convert
  [ "${RC}" -eq 0 ]
  err_has "note: READ_ONLY_API is not set"
  err_has "note: TWOFA_TIMEOUT_ACTION is not set"
}

@test "changed defaults are not pointed out when the variable is set" {
  write_env 'READ_ONLY_API=no' 'TWOFA_TIMEOUT_ACTION=exit'
  convert
  [ "${RC}" -eq 0 ]
  err_lacks "note: READ_ONLY_API"
  err_lacks "note: TWOFA_TIMEOUT_ACTION"
}

@test "the closing hint says how the converted file reaches the container" {
  # The reference compose interpolates four variables from the compose env file and passes
  # nothing else on: without both steps half of the converted file would silently not apply.
  write_env 'TRADING_MODE=live' 'TWOFA_DEVICE=IB Key'
  convert
  [ "${RC}" -eq 0 ]
  err_has "next: "
  err_has "docker compose --env-file"
  err_has "env_file:"
  err_has "doctor"
}

@test "the report goes to stderr only: stdout is exactly the converted file" {
  write_env 'TRADING_MODE=live' 'SSH_TUNNEL=yes' 'JAVA_HEAP_SIZE=1024' 'MY_FLAG=1'
  convert
  [ "${RC}" -eq 0 ]
  out_lacks "migrate-from-gnzsnz:"
  [ "$(wc -l <"${WORK}/out")" -eq 4 ]
  [ "$(grep -c '^migrate-from-gnzsnz: ' "${WORK}/err")" -eq "$(wc -l <"${WORK}/err")" ]
}

@test "every variable the doctor reports as an ignored gnzsnz variable is gone after the conversion" {
  write_env 'TRADING_MODE=paper' 'TIME_ZONE=Etc/UTC' 'TWS_USERID_PAPER=a' 'TWS_PASSWORD_PAPER=b' \
    'TWS_PASSWORD_PAPER_FILE=/c' 'TWS_COLD_RESTART=x' 'JAVA_HEAP_SIZE=1024' 'SSH_TUNNEL=yes' 'SSH_OPTIONS=o' \
    'START_SCRIPTS=/s' 'X_SCRIPTS=/x' 'IBC_SCRIPTS=/i' 'GATEWAY_OR_TWS=gateway'
  # The doctor's own verdict on a file: one WARN per ignored variable, or one PASS.
  doctor_verdict() {
    env -i PATH="${PATH}" bash -c 'set -a; source "$1"; set +a; source "$2"; check_ignored_variables' _ "$1" "${DOCTOR}"
  }
  # Before: the doctor names all eleven; the test would be empty otherwise.
  run doctor_verdict "${WORK}/in.env"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^WARN|ignored_variables|' <<<"$output")" -eq 11 ]
  convert
  [ "${RC}" -eq 0 ]
  run doctor_verdict "${WORK}/out"
  [ "$status" -eq 0 ]
  [[ "$output" == "PASS|ignored_variables|"* ]]
}

@test "no variable the doctor knows is reported as unknown" {
  # shellcheck source=/dev/null
  source "${DOCTOR}"
  local name
  : >"${WORK}/in.env"
  for name in "${doctor_known_names[@]}"; do
    case "${name}" in
      TRADING_MODE) printf 'TRADING_MODE=paper\n' >>"${WORK}/in.env" ;;
      *) printf '%s=1\n' "${name}" >>"${WORK}/in.env" ;;
    esac
  done
  convert
  [ "${RC}" -eq 0 ]
  err_lacks "unknown, kept"
}
