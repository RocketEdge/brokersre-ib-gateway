#!/usr/bin/env bats
# Unit tests for doctor.sh, the preflight of the gateway container.
#
# Every check is exercised for every status it can return (PASS, WARN, FAIL, SKIP) by calling
# its function in a fresh bash, then the three output modes (table, --json, --startup), the exit
# codes, crash isolation and the rule that no output of any mode contains a secret.
#
# Measurements are replaced at the boundary only: `df` by a stub on PATH, the cgroup files by
# CGROUP_ROOT, the TCP probe by DOCTOR_TCP (or a local socat listener). Nothing here contacts
# IBKR. Secret file bytes are generated with printf (see common.bats for why), and the canary
# secret is assembled from two parts so that no scanner mistakes this file for a leak.

setup() {
  : "${BROKERSRE_LIB:?set BROKERSRE_LIB to rootfs/usr/local/lib/brokersre}"
  DOCTOR="${BROKERSRE_LIB}/doctor.sh"
  T="$(mktemp -d)"
  export LOG_DIR="${T}/log" RUN_DIR="${T}/run" TWS_SETTINGS_PATH="${T}/settings" CGROUP_ROOT="${T}/cgroup"
  mkdir -p "${LOG_DIR}" "${RUN_DIR}" "${TWS_SETTINGS_PATH}" "${CGROUP_ROOT}" "${T}/secrets" "${T}/bin" "${T}/df"
  printf 'max\n' >"${CGROUP_ROOT}/memory.max"
  printf 'dummyuser' >"${T}/secrets/u"
  printf 'hunter2hunter2' >"${T}/secrets/p"
  export TWS_USERID_FILE="${T}/secrets/u" TWS_PASSWORD_FILE="${T}/secrets/p"
  export TRADING_MODE=paper READ_ONLY_API=yes CUSTOM_CONFIG=no TIME_ZONE=America/New_York
  export AUTO_RESTART_TIME='11:45 PM' BOOT_ID=0123456789abcdef
  unset TWS_USERID TWS_PASSWORD AUTO_LOGOFF_TIME JAVA_HEAP_MB JAVA_USER_HOME DISK_MIN_FREE_PCT \
    STRICT_ENV DOCTOR_STRICT DOCTOR_TCP DOCTOR_RESULT_FILE TZ VNC_SERVER_PASSWORD VNC_SERVER_PASSWORD_FILE
  RESULT="${RUN_DIR}/doctor.result"
  REAL_PATH="${PATH}"
  stub_df
  df_answer log 50000000 50000000 /mnt/data
  df_answer settings 50000000 50000000 /mnt/data
  CANARY="hunter2""CANARY"
  CRASH_DETAIL="check crashed (a defect in doctor, please report it); the start continues"
}

teardown() {
  if [ -n "${LISTENER_PID:-}" ]; then kill "${LISTENER_PID}" 2>/dev/null || true; fi
  chmod -R u+rwx "${T}" 2>/dev/null || true
  rm -rf "${T}"
}

# stub_df: put a `df` first on PATH that prints the canned answer stored for the basename of
# the path it is asked about (see df_answer) and fails when there is none.
stub_df() {
  printf '%s\n' '#!/usr/bin/env bash' \
    'answer="${FAKE_DF_DIR}/$(basename "${!#}")"' \
    '[ -f "${answer}" ] || exit 1' \
    'cat "${answer}"' >"${T}/bin/df"
  chmod +x "${T}/bin/df"
  export FAKE_DF_DIR="${T}/df" PATH="${T}/bin:${PATH}"
}

# df_answer NAME USED_KB AVAILABLE_KB MOUNT [DEVICE]: what the stub prints (in `df -P -k`
# layout) for a path whose last component is NAME. DEVICE defaults to /dev/fake.
df_answer() {
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n%s %s %s %s %s%% %s\n' \
    "${5:-/dev/fake}" "$(($2 + $3))" "$2" "$3" "$(($2 * 100 / ($2 + $3)))" "$4" >"${T}/df/$1"
}

# mem_limit_mb N: a container memory limit of N MiB in the fake cgroup directory.
mem_limit_mb() {
  printf '%s\n' "$(($1 * 1048576))" >"${CGROUP_ROOT}/memory.max"
}

# mem_limit_bytes N: a container memory limit of exactly N bytes, for boundaries between two MiB.
mem_limit_bytes() {
  printf '%s\n' "$1" >"${CGROUP_ROOT}/memory.max"
}

# check NAME: run one check function in a fresh bash with nounset (as the script runs) and print
# its result lines `STATUS|name|detail|fix`.
check() {
  bash -uc "source '${DOCTOR}'; check_$1"
}

# fn NAME ARGS...: call one library function of doctor.sh in a fresh bash with nounset.
fn() {
  bash -uc "source '${DOCTOR}'; \"\$@\"" _ "$@"
}

# one_result STATUS NAME: the last run succeeded and printed exactly one result line, for the
# check NAME with STATUS.
one_result() {
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == "$1|$2|"* ]]
}

# detail [INDEX] / fix [INDEX]: the third / fourth field of a result line of the last run.
detail() { printf '%s' "${lines[${1:-0}]}" | cut -d'|' -f3; }
fix() { printf '%s' "${lines[${1:-0}]}" | cut -d'|' -f4; }

# ---------------------------------------------------------------------------------------------
# Library functions
# ---------------------------------------------------------------------------------------------

@test "levenshtein counts substitutions, insertions and deletions" {
  [ "$(fn doctor_levenshtein TWS_USERID TWS_USERID)" == "0" ]
  [ "$(fn doctor_levenshtein TWS_USERID TWS_USERIX)" == "1" ]
  [ "$(fn doctor_levenshtein TWS_USERID TWS_USERI)" == "1" ]
  [ "$(fn doctor_levenshtein TWS_USERID TWS_USEERID)" == "1" ]
  [ "$(fn doctor_levenshtein TWS_PASSWROD TWS_PASSWORD)" == "2" ]
  [ "$(fn doctor_levenshtein kitten sitting)" == "3" ]
  [ "$(fn doctor_levenshtein '' abc)" == "3" ]
  [ "$(fn doctor_levenshtein abc '')" == "3" ]
}

@test "levenshtein with a bound stops early and reports more than the bound" {
  [ "$(fn doctor_levenshtein TWS_PASSWROD TWS_PASSWORD 2)" == "2" ]
  [ "$(fn doctor_levenshtein AAAAAAAAAA BBBBBBBBBB 2)" -gt 2 ]
  [ "$(fn doctor_levenshtein kitten sitting 2)" -gt 2 ]
}

@test "the closest known variable is suggested only within two edits" {
  [ "$(fn doctor_closest_known TWS_PASWORD)" == "TWS_PASSWORD" ]
  [ "$(fn doctor_closest_known AUTO_RESTRT_TIME)" == "AUTO_RESTART_TIME" ]
  [ "$(fn doctor_closest_known TWOFA_DEVISE)" == "TWOFA_DEVICE" ]
  [ -z "$(fn doctor_closest_known TWS_SOMETHING_ELSE_ENTIRELY)" ]
}

# The accepted and rejected forms below are what IBC 3.24's own parser does with them
# (DateTimeFormatter.ofPattern("hh:mm a") in ConfigureAutoLogoffOrRestartTimeTask), measured
# with the IBC.jar of the image: a two-digit hour is required, hour 00 is taken as 12.
@test "a 12-hour time converts to minutes after midnight" {
  [ "$(fn doctor_time_minutes '12:00 AM')" == "0" ]
  [ "$(fn doctor_time_minutes '12:30 AM')" == "30" ]
  [ "$(fn doctor_time_minutes '00:15 AM')" == "15" ]
  [ "$(fn doctor_time_minutes '01:05 AM')" == "65" ]
  [ "$(fn doctor_time_minutes '09:00 AM')" == "540" ]
  [ "$(fn doctor_time_minutes '12:30 PM')" == "750" ]
  [ "$(fn doctor_time_minutes '00:30 PM')" == "750" ]
  [ "$(fn doctor_time_minutes '11:45 PM')" == "1425" ]
}

@test "a time IBC's parser rejects has no minutes" {
  for value in '23:45' '1:05 AM' '9:30 PM' '11:45PM' '11:45 pm' '11:45  PM' ' 11:45 PM' '11:45 PM ' \
    '13:00 PM' '11:60 PM' ''; do
    run fn doctor_time_minutes "${value}"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
  done
}

@test "a malformed time is corrected to IBC's format when its meaning is clear" {
  [ "$(fn doctor_suggest_time '23:45')" == "11:45 PM" ]
  [ "$(fn doctor_suggest_time '0:30')" == "12:30 AM" ]
  [ "$(fn doctor_suggest_time '12:05')" == "12:05 PM" ]
  [ "$(fn doctor_suggest_time '7:05')" == "07:05 AM" ]
  [ "$(fn doctor_suggest_time '1:05 AM')" == "01:05 AM" ]
  [ "$(fn doctor_suggest_time '9:30 pm')" == "09:30 PM" ]
  [ "$(fn doctor_suggest_time '11:45PM')" == "11:45 PM" ]
  [ "$(fn doctor_suggest_time '11:45 pm')" == "11:45 PM" ]
  [ "$(fn doctor_suggest_time '11:45  am')" == "11:45 AM" ]
  [ "$(fn doctor_suggest_time ' 11:45 PM ')" == "11:45 PM" ]
  [ "$(fn doctor_suggest_time '23:45:00')" == "11:45 PM" ]
  [ -z "$(fn doctor_suggest_time 'midnight')" ]
  [ -z "$(fn doctor_suggest_time '25:00')" ]
  [ -z "$(fn doctor_suggest_time '13:00 PM')" ]
  [ -z "$(fn doctor_suggest_time '11:60 PM')" ]
}

@test "a result line never carries a field separator or a line break from its inputs" {
  run fn doctor_result WARN some_check "$(printf 'a|b\nc\td')" 'x|y'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$output" == "WARN|some_check|a/b c d|x/y" ]
}

@test "a long setting is quoted cut to 40 characters" {
  long="$(printf 'x%.0s' $(seq 1 100))"
  [ "$(fn doctor_clip "${long}")" == "${long:0:40}..." ]
  [ "$(fn doctor_clip short)" == "short" ]
  TRADING_MODE="${long}" run check trading_mode
  one_result FAIL trading_mode
  [[ "$(detail)" == *"'${long:0:40}...'"* ]]
}

# ---------------------------------------------------------------------------------------------
# 1. trading_mode
# ---------------------------------------------------------------------------------------------

@test "trading_mode: PASS for paper and for live" {
  TRADING_MODE=paper run check trading_mode
  one_result PASS trading_mode
  [[ "$(detail)" == *"paper"* ]]
  TRADING_MODE=live run check trading_mode
  one_result PASS trading_mode
  [[ "$(detail)" == *"live"* ]]
}

@test "trading_mode: FAIL for both, with the one-session-per-container fix" {
  TRADING_MODE=both run check trading_mode
  one_result FAIL trading_mode
  [[ "$(fix)" == *"one session per container"* ]]
  [[ "$(fix)" == *"two containers"* ]]
  [[ "$(fix)" == *"username"* ]]
}

@test "trading_mode: FAIL for any other value and when unset" {
  TRADING_MODE=demo run check trading_mode
  one_result FAIL trading_mode
  [[ "$(detail)" == *"demo"* ]]
  [[ "$(fix)" == *"live"*"paper"* ]]
  unset TRADING_MODE
  run check trading_mode
  one_result FAIL trading_mode
  [[ "$(detail)" == *"not set"* ]]
}

# ---------------------------------------------------------------------------------------------
# 2. credentials
# ---------------------------------------------------------------------------------------------

@test "credentials: PASS when username and password come from readable secret files" {
  run check credentials
  one_result PASS credentials
  [[ "$(detail)" == *"TWS_USERID_FILE"* ]]
  [[ "$(detail)" == *"TWS_PASSWORD_FILE"* ]]
  [[ "$(detail)" != *"stripped"* ]]
  [ -z "$(fix)" ]
}

@test "credentials: PASS when both are given directly in the environment" {
  unset TWS_USERID_FILE TWS_PASSWORD_FILE
  export TWS_USERID=dummyuser TWS_PASSWORD="${CANARY}"
  run check credentials
  one_result PASS credentials
  [[ "$output" != *"dummyuser"* ]]
  [[ "$output" != *"${CANARY}"* ]]
}

@test "credentials: FAIL when neither the username nor its file is set" {
  unset TWS_USERID_FILE
  run check credentials
  one_result FAIL credentials
  [[ "$(detail)" == *"TWS_USERID"*"TWS_USERID_FILE"* ]]
  [ -n "$(fix)" ]
}

@test "credentials: FAIL when neither the password nor its file is set" {
  unset TWS_PASSWORD_FILE
  run check credentials
  one_result FAIL credentials
  [[ "$(detail)" == *"TWS_PASSWORD"*"TWS_PASSWORD_FILE"* ]]
}

@test "credentials: one FAIL per missing credential when nothing is set" {
  unset TWS_USERID_FILE TWS_PASSWORD_FILE
  run check credentials
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "FAIL|credentials|"*"TWS_USERID"* ]]
  [[ "${lines[1]}" == "FAIL|credentials|"*"TWS_PASSWORD"* ]]
}

@test "credentials: FAIL when both the password and its file are set" {
  export TWS_PASSWORD="${CANARY}"
  run check credentials
  one_result FAIL credentials
  [[ "$(detail)" == *"both TWS_PASSWORD and TWS_PASSWORD_FILE"* ]]
  [[ "$(fix)" == *"TWS_PASSWORD_FILE"* ]]
  [[ "$output" != *"${CANARY}"* ]]
}

@test "credentials: FAIL when both the username and its file are set" {
  export TWS_USERID=dummyuser
  run check credentials
  one_result FAIL credentials
  [[ "$(detail)" == *"both TWS_USERID and TWS_USERID_FILE"* ]]
  [[ "$output" != *"dummyuser"* ]]
}

@test "credentials: FAIL when the secret file does not exist, without echoing the variable's value" {
  export TWS_PASSWORD_FILE="${T}/secrets/absent-${CANARY}"
  run check credentials
  one_result FAIL credentials
  [[ "$(detail)" == *"TWS_PASSWORD_FILE"*"does not exist"* ]]
  [[ "$output" != *"${CANARY}"* ]]
}

@test "credentials: FAIL when the secret path is a directory (a bind mount of a missing host file)" {
  mkdir "${T}/secrets/dir"
  export TWS_PASSWORD_FILE="${T}/secrets/dir"
  run check credentials
  one_result FAIL credentials
  [[ "$(detail)" == *"not a regular file"* ]]
  [[ "$(fix)" == *"directory"* ]]
}

@test "credentials: FAIL when the secret file is not readable by this user" {
  if [ "$(id -u)" -eq 0 ]; then skip "root ignores file permissions"; fi
  chmod 000 "${T}/secrets/p"
  run check credentials
  one_result FAIL credentials
  [[ "$(detail)" == *"not readable"* ]]
  [[ "$(fix)" == *"$(id -u)"* ]]
}

@test "credentials: FAIL when the secret file is empty" {
  : >"${T}/secrets/p"
  run check credentials
  one_result FAIL credentials
  [[ "$(detail)" == *"TWS_PASSWORD_FILE"*"empty"* ]]
}

@test "credentials: FAIL when the secret file holds only a byte-order mark and line endings" {
  printf '\xef\xbb\xbf\r\n' >"${T}/secrets/p"
  run check credentials
  one_result FAIL credentials
  [[ "$(detail)" == *"empty"* ]]
}

@test "credentials: FAIL for a UTF-16LE file with a byte-order mark (Windows PowerShell 5.1 '>')" {
  printf '\xff\xfeh\x00u\x00n\x00t\x00e\x00r\x002\x00\r\x00\n\x00' >"${T}/secrets/p"
  run check credentials
  one_result FAIL credentials
  [[ "$(detail)" == *"UTF-16"* ]]
  [[ "$(fix)" == *"UTF-8 without a byte-order mark"* ]]
}

@test "credentials: FAIL for a UTF-16BE file with a byte-order mark" {
  printf '\xfe\xff\x00h\x00u\x00n\x00t\x00e\x00r\x002' >"${T}/secrets/p"
  run check credentials
  one_result FAIL credentials
  [[ "$(detail)" == *"UTF-16"* ]]
}

@test "credentials: FAIL for a UTF-16 byte-order mark even when no byte is NUL" {
  printf '\xff\xfe\x3d\x04\x3e\x04' >"${T}/secrets/p"
  run check credentials
  one_result FAIL credentials
  [[ "$(detail)" == *"UTF-16"* ]]
}

@test "credentials: FAIL for a UTF-16 file without a byte-order mark (NUL bytes)" {
  printf 'h\x00u\x00n\x00t\x00e\x00r\x002\x00' >"${T}/secrets/u"
  run check credentials
  one_result FAIL credentials
  [[ "$(detail)" == *"TWS_USERID_FILE"*"UTF-16"* ]]
}

@test "credentials: PASS with a UTF-8 byte-order mark, saying it will be stripped" {
  printf '\xef\xbb\xbf%s' "${CANARY}" >"${T}/secrets/p"
  run check credentials
  one_result PASS credentials
  [[ "$(detail)" == *"TWS_PASSWORD_FILE"*"byte-order mark"*"stripped"* ]]
  [[ "$output" != *"${CANARY}"* ]]
}

@test "credentials: PASS with a trailing CR LF, saying it will be stripped" {
  printf '%s\r\n' "${CANARY}" >"${T}/secrets/p"
  run check credentials
  one_result PASS credentials
  [[ "$(detail)" == *"TWS_PASSWORD_FILE"*"line ending"*"stripped"* ]]
  [[ "$output" != *"${CANARY}"* ]]
}

@test "credentials: PASS with a trailing LF on both files names both" {
  printf 'dummyuser\n' >"${T}/secrets/u"
  printf 'hunter2hunter2\n' >"${T}/secrets/p"
  run check credentials
  one_result PASS credentials
  [[ "$(detail)" == *"TWS_USERID_FILE"*"stripped"* ]]
  [[ "$(detail)" == *"TWS_PASSWORD_FILE"*"stripped"* ]]
}

@test "credentials: neither the secret nor its length is ever printed" {
  # The canary is 13 characters long; no status of the check may mention that number.
  for content in "${CANARY}" "${CANARY}"$'\r\n' $'\xef\xbb\xbf'"${CANARY}"; do
    printf '%s' "${content}" >"${T}/secrets/p"
    run check credentials
    one_result PASS credentials
    [[ "$output" != *"${CANARY}"* ]]
    [[ "$output" != *"hunter2"* ]]
    [[ "$output" != *"13"* ]]
  done
}

@test "credentials: with CUSTOM_CONFIG=yes a readable config.ini is all that is needed" {
  unset TWS_USERID_FILE TWS_PASSWORD_FILE
  export CUSTOM_CONFIG=yes
  printf 'IbLoginId=custom\n' >"${RUN_DIR}/config.ini"
  run check credentials
  one_result PASS credentials
  [[ "$(detail)" == *"CUSTOM_CONFIG=yes"* ]]
  [[ "$(detail)" == *"${RUN_DIR}/config.ini"* ]]
  [[ "$output" != *"IbLoginId"* ]]
}

@test "credentials: with CUSTOM_CONFIG=yes a missing config.ini is a FAIL" {
  export CUSTOM_CONFIG=yes
  run check credentials
  one_result FAIL credentials
  [[ "$(detail)" == *"${RUN_DIR}/config.ini"* ]]
  [ -n "$(fix)" ]
}

# ---------------------------------------------------------------------------------------------
# 3. secret_values
# ---------------------------------------------------------------------------------------------

@test "secret_values: PASS when no password is in a plain environment variable" {
  run check secret_values
  one_result PASS secret_values
}

@test "secret_values: WARN when the password is in the environment, with the _FILE fix" {
  unset TWS_PASSWORD_FILE
  export TWS_PASSWORD="${CANARY}"
  run check secret_values
  one_result WARN secret_values
  [[ "$(detail)" == *"TWS_PASSWORD"*"docker inspect"* ]]
  [[ "$(fix)" == *"use TWS_PASSWORD_FILE"* ]]
  [[ "$output" != *"${CANARY}"* ]]
}

@test "secret_values: WARN for a VNC password in the environment too" {
  export VNC_SERVER_PASSWORD="${CANARY}"
  run check secret_values
  one_result WARN secret_values
  [[ "$(fix)" == *"use VNC_SERVER_PASSWORD_FILE"* ]]
  [[ "$output" != *"${CANARY}"* ]]
}

# ---------------------------------------------------------------------------------------------
# 4. auto_restart_time
# ---------------------------------------------------------------------------------------------

@test "auto_restart_time: PASS for IBC's format (two-digit hour, one space, AM or PM)" {
  for value in '11:45 PM' '01:05 AM' '12:00 AM' '10:59 PM' '00:15 AM'; do
    AUTO_RESTART_TIME="${value}" run check auto_restart_time
    one_result PASS auto_restart_time
    [[ "$(detail)" == *"${value}"* ]]
  done
}

@test "auto_restart_time: PASS with whitespace around the value, which IBC trims" {
  AUTO_RESTART_TIME='  11:45 PM ' run check auto_restart_time
  one_result PASS auto_restart_time
  [[ "$(detail)" == *"AUTO_RESTART_TIME=11:45 PM"* ]]
}

@test "auto_restart_time: FAIL for a one-digit hour, which IBC's parser rejects, with the corrected value" {
  AUTO_RESTART_TIME='1:05 AM' run check auto_restart_time
  one_result FAIL auto_restart_time
  [[ "$(detail)" == *"two-digit hour"* ]]
  [[ "$(fix)" == *"AUTO_RESTART_TIME=01:05 AM"* ]]
}

@test "auto_restart_time: WARN when no daily restart is configured" {
  AUTO_RESTART_TIME='' run check auto_restart_time
  one_result WARN auto_restart_time
  [[ "$(detail)" == *"no daily restart configured"* ]]
  [[ "$(detail)" == *"full login"* ]]
  [[ "$(fix)" == *"11:45 PM"* ]]
  unset AUTO_RESTART_TIME
  run check auto_restart_time
  one_result WARN auto_restart_time
}

@test "auto_restart_time: FAIL for a 24-hour value, with the corrected value" {
  AUTO_RESTART_TIME='23:45' run check auto_restart_time
  one_result FAIL auto_restart_time
  [[ "$(detail)" == *"23:45"* ]]
  [[ "$(detail)" == *"IBC does not apply a malformed value"* ]]
  [[ "$(fix)" == *"AUTO_RESTART_TIME=11:45 PM"* ]]
}

@test "auto_restart_time: FAIL without the single space or in lower case, with the corrected value" {
  AUTO_RESTART_TIME='11:15PM' run check auto_restart_time
  one_result FAIL auto_restart_time
  [[ "$(fix)" == *"AUTO_RESTART_TIME=11:15 PM"* ]]
  AUTO_RESTART_TIME='11:15 pm' run check auto_restart_time
  one_result FAIL auto_restart_time
  [[ "$(fix)" == *"AUTO_RESTART_TIME=11:15 PM"* ]]
}

@test "auto_restart_time: FAIL for a value that cannot be corrected, with an example" {
  for value in 'midnight' '13:00 PM' '11:60 PM' '11:45 XM' '11.45 PM'; do
    AUTO_RESTART_TIME="${value}" run check auto_restart_time
    one_result FAIL auto_restart_time
    [[ "$(fix)" == *"11:45 PM"* ]]
  done
}

@test "auto_restart_time: FAIL for a malformed AUTO_LOGOFF_TIME" {
  AUTO_LOGOFF_TIME='22:00' AUTO_RESTART_TIME='' run check auto_restart_time
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAIL|auto_restart_time|AUTO_LOGOFF_TIME"*"AUTO_LOGOFF_TIME=10:00 PM"* ]]
}

@test "auto_restart_time: a valid AUTO_LOGOFF_TIME alone still warns that there is no daily restart" {
  AUTO_LOGOFF_TIME='10:00 PM' AUTO_RESTART_TIME='' run check auto_restart_time
  one_result WARN auto_restart_time
  [[ "$(detail)" == *"no daily restart configured"* ]]
}

@test "auto_restart_time: WARN when restart and logoff are both set (IBC ignores the logoff)" {
  AUTO_LOGOFF_TIME='10:00 PM' run check auto_restart_time
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "PASS|auto_restart_time|"* ]]
  [[ "${lines[1]}" == "WARN|auto_restart_time|"*"AUTO_LOGOFF_TIME"*"ignore"* ]]
}

# ---------------------------------------------------------------------------------------------
# 5. restart_window
# ---------------------------------------------------------------------------------------------

@test "restart_window: WARN inside the North America window for New York time" {
  for zone in America/New_York US/Eastern; do
    for value in '12:15 AM' '01:00 AM' '01:45 AM'; do
      TIME_ZONE="${zone}" AUTO_RESTART_TIME="${value}" run check restart_window
      one_result WARN restart_window
      [[ "$(detail)" == *"North America"*"00:15-01:45"* ]]
      [[ "$(fix)" == *"11:45 PM"* ]]
    done
  done
}

@test "restart_window: WARN inside the Saturday window for New York time (a daily restart runs on Saturday too)" {
  for value in '12:00 AM' '12:14 AM' '01:46 AM' '02:00 AM'; do
    AUTO_RESTART_TIME="${value}" run check restart_window
    one_result WARN restart_window
    [[ "$(detail)" == *"Saturday"*"00:00-02:00"* ]]
  done
}

@test "restart_window: PASS outside the windows for New York time" {
  for value in '11:59 PM' '02:01 AM' '11:45 PM' '12:00 PM'; do
    AUTO_RESTART_TIME="${value}" run check restart_window
    one_result PASS restart_window
    [[ "$(detail)" == *"outside"* ]]
  done
}

@test "restart_window: WARN inside and PASS outside the Europe window for the CET family" {
  for zone in Europe/Zurich Europe/Berlin Europe/Paris Europe/Amsterdam; do
    for value in '06:25 AM' '07:00 AM' '07:45 AM'; do
      TIME_ZONE="${zone}" AUTO_RESTART_TIME="${value}" run check restart_window
      one_result WARN restart_window
      [[ "$(detail)" == *"Europe"*"06:25-07:45"* ]]
    done
    for value in '06:24 AM' '07:46 AM' '11:45 PM' '12:30 AM'; do
      TIME_ZONE="${zone}" AUTO_RESTART_TIME="${value}" run check restart_window
      one_result PASS restart_window
    done
  done
}

@test "restart_window: WARN inside and PASS outside both Asia windows for the UTC+8 family" {
  for zone in Asia/Hong_Kong Asia/Singapore Asia/Shanghai; do
    for value in '04:45 AM' '06:05 AM'; do
      TIME_ZONE="${zone}" AUTO_RESTART_TIME="${value}" run check restart_window
      one_result WARN restart_window
      [[ "$(detail)" == *"Asia"*"04:45-06:05"* ]]
    done
    for value in '08:15 PM' '09:15 PM'; do
      TIME_ZONE="${zone}" AUTO_RESTART_TIME="${value}" run check restart_window
      one_result WARN restart_window
      [[ "$(detail)" == *"Asia"*"20:15-21:15"* ]]
    done
    for value in '04:44 AM' '06:06 AM' '08:14 PM' '09:16 PM' '11:45 PM' '12:30 AM'; do
      TIME_ZONE="${zone}" AUTO_RESTART_TIME="${value}" run check restart_window
      one_result PASS restart_window
    done
  done
}

@test "restart_window: SKIP for any other zone, listing every window to stay out of" {
  for zone in Asia/Tokyo Etc/UTC UTC Europe/London America/Chicago; do
    TIME_ZONE="${zone}" run check restart_window
    one_result SKIP restart_window
    [[ "$(detail)" == *"cannot compare without a time-zone database in the image"* ]]
    for window in '00:15-01:45' '06:25-07:45' '04:45-06:05' '20:15-21:15' '00:00-02:00'; do
      [[ "${lines[0]}" == *"${window}"* ]]
    done
  done
}

@test "restart_window: SKIP when there is no restart time to compare" {
  AUTO_RESTART_TIME='' run check restart_window
  one_result SKIP restart_window
  [[ "$(detail)" == *"AUTO_RESTART_TIME is not set"* ]]
}

@test "restart_window: SKIP when the restart time is malformed" {
  for value in '23:45' '1:00 AM'; do
    AUTO_RESTART_TIME="${value}" run check restart_window
    one_result SKIP restart_window
    [[ "$(detail)" == *"not in IBC's format"* ]]
  done
}

@test "restart_window: whitespace around the restart time is ignored, as IBC trims it" {
  AUTO_RESTART_TIME=' 12:30 AM ' run check restart_window
  one_result WARN restart_window
  [[ "$(detail)" == *"AUTO_RESTART_TIME 12:30 AM (America/New_York)"* ]]
}

# ---------------------------------------------------------------------------------------------
# 6. time_zone
# ---------------------------------------------------------------------------------------------

@test "time_zone: PASS for UTC, GMT, Etc/... and Area/City names" {
  for zone in UTC GMT Etc/UTC Etc/GMT+5 America/New_York America/Argentina/Buenos_Aires Asia/Hong_Kong \
    America/Port-au-Prince; do
    TIME_ZONE="${zone}" run check time_zone
    one_result PASS time_zone
    [[ "$(detail)" == *"${zone}"* ]]
  done
}

# The image has no zone database, so a name of another shape may still be one the Gateway
# knows (Singapore, Japan, EST5EDT): it cannot be verified, which is a WARN, never a FAIL.
@test "time_zone: WARN for any other name, because it cannot be verified" {
  for zone in Singapore Japan EST5EDT EST 'GMT+8' 'New York' 'America/New York' '+08:00' 'America/' '/Zurich'; do
    TIME_ZONE="${zone}" run check time_zone
    one_result WARN time_zone
    [[ "$(detail)" == *"${zone}"* ]]
    [[ "$(detail)" == *"cannot be verified: the image has no time-zone database; IBC and the Gateway fall back silently on an unknown zone"* ]]
    [[ "$(fix)" == *"America/New_York"* ]]
  done
}

@test "time_zone: WARN when empty or unset" {
  TIME_ZONE='' run check time_zone
  one_result WARN time_zone
  [[ "$(detail)" == *"not set"* ]]
  [[ "$(fix)" == *"America/New_York"* ]]
  unset TIME_ZONE
  run check time_zone
  one_result WARN time_zone
  [[ "$(detail)" == *"not set"* ]]
}

# ---------------------------------------------------------------------------------------------
# 7. ignored_variables
# ---------------------------------------------------------------------------------------------

@test "ignored_variables: one PASS line when nothing is wrong" {
  run check ignored_variables
  one_result PASS ignored_variables
}

@test "ignored_variables: one WARN per variable carried over from gnzsnz, naming the replacement" {
  export TWS_USERID_PAPER=x TWS_PASSWORD_PAPER=x TWS_PASSWORD_PAPER_FILE=/x TWS_COLD_RESTART=yes \
    JAVA_HEAP_SIZE=1024 SSH_TUNNEL=yes SSH_OPTIONS=x START_SCRIPTS=/a X_SCRIPTS=/b IBC_SCRIPTS=/c \
    GATEWAY_OR_TWS=tws
  run check ignored_variables
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 11 ]
  for line in "${lines[@]}"; do
    [[ "${line}" == "WARN|ignored_variables|"* ]]
  done
  for name in TWS_USERID_PAPER TWS_PASSWORD_PAPER TWS_PASSWORD_PAPER_FILE; do
    grep -q "^WARN|ignored_variables|${name} .*dual mode.*|.*one container per session" <<<"$output"
  done
  grep -q '^WARN|ignored_variables|TWS_COLD_RESTART .*not supported.*|.*AUTO_RESTART_TIME' <<<"$output"
  grep -q '^WARN|ignored_variables|JAVA_HEAP_SIZE .*|.*JAVA_HEAP_MB' <<<"$output"
  for name in SSH_TUNNEL SSH_OPTIONS; do
    grep -q "^WARN|ignored_variables|${name} .*removed.*|.*private network.*sidecar" <<<"$output"
  done
  for name in START_SCRIPTS X_SCRIPTS IBC_SCRIPTS; do
    grep -q "^WARN|ignored_variables|${name} .*hook" <<<"$output"
  done
  grep -q '^WARN|ignored_variables|GATEWAY_OR_TWS .*Gateway only' <<<"$output"
}

@test "ignored_variables: supported gnzsnz variables are not reported" {
  export VNC_SERVER_PASSWORD=x TWOFA_TIMEOUT_ACTION=restart BYPASS_WARNING=yes SAVE_TWS_SETTINGS=x
  run check ignored_variables
  one_result PASS ignored_variables
}

@test "ignored_variables: WARN for TZ when TIME_ZONE is unset or left at the image default" {
  export TZ=Europe/Zurich
  unset TIME_ZONE
  run check ignored_variables
  one_result WARN ignored_variables
  [[ "$(detail)" == "TZ "* ]]
  [[ "$(fix)" == *"use TIME_ZONE"* ]]
  export TIME_ZONE=Etc/UTC
  run check ignored_variables
  one_result WARN ignored_variables
}

@test "ignored_variables: TZ is not reported when TIME_ZONE is set or TZ is UTC anyway" {
  export TZ=Europe/Zurich TIME_ZONE=Europe/Zurich
  run check ignored_variables
  one_result PASS ignored_variables
  export TZ=UTC TIME_ZONE=Etc/UTC
  run check ignored_variables
  one_result PASS ignored_variables
}

@test "ignored_variables: WARN for a likely typo, with the closest known name" {
  export TWS_PASWORD_FILE=/x AUTO_RESTRT_TIME=x
  run check ignored_variables
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  grep -q '^WARN|ignored_variables|AUTO_RESTRT_TIME .*unknown variable, ignored.*|.*AUTO_RESTART_TIME' <<<"$output"
  grep -q '^WARN|ignored_variables|TWS_PASWORD_FILE .*unknown variable, ignored.*|.*TWS_PASSWORD_FILE' <<<"$output"
}

@test "ignored_variables: WARN for an unknown variable of every watched prefix, without a guess when nothing is close" {
  export TWS_ZZZZZZZZ=1 TWOFA_ZZZZZZZZ=1 IBC_ZZZZZZZZ=1 AUTO_ZZZZZZZZ=1 JAVA_ZZZZZZZZ=1 VNC_ZZZZZZZZ=1 \
    LOG_ZZZZZZZZ=1 RELAY_ZZZZZZZZ=1 DOCTOR_ZZZZZZZZ=1
  run check ignored_variables
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 9 ]
  for line in "${lines[@]}"; do
    [[ "${line}" == "WARN|ignored_variables|"*"unknown variable, ignored"* ]]
    [[ "${line}" != *"did you mean"* ]]
  done
}

@test "ignored_variables: variables outside the watched prefixes are left alone" {
  export MY_OWN_SETTING=1 HTTP_PROXY=x TWSX=1 LOGLEVEL=debug
  run check ignored_variables
  one_result PASS ignored_variables
}

@test "ignored_variables: none of the known variables is reported" {
  while read -r name; do
    if [ -z "${!name:-}" ]; then export "${name}=x"; fi
  done < <(fn doctor_known_variables)
  run check ignored_variables
  one_result PASS ignored_variables
}

@test "ignored_variables: every variable documented in docs/env-vars.md is known" {
  docs="${BATS_TEST_DIRNAME}/../../../docs/env-vars.md"
  documented="$(grep -E '^\| `' "${docs}" | cut -d'|' -f2 | grep -oE '`[A-Z_][A-Z0-9_]*`' | tr -d '`' | sort -u)"
  [ "$(wc -l <<<"${documented}")" -ge 30 ]
  known="$(fn doctor_known_variables)"
  for name in ${documented}; do
    if ! grep -qxF "${name}" <<<"${known}"; then
      echo "documented but not known to doctor: ${name}"
      false
    fi
  done
}

@test "ignored_variables: variables the image reads that are not in docs/env-vars.md yet are known too" {
  known="$(fn doctor_known_variables)"
  for name in JAVA_USER_HOME JAVA_HEAP_MB LOG_MAX_BYTES LOG_KEEP RELAY_MODE TWOFA_MAX_PROMPTS LOGIN_STALL_S \
    DOCTOR_STRICT STRICT_ENV SAMPLE_INTERVAL_S DISK_MIN_FREE_PCT IBGW_INSTANCE BOOT_ID IB_GATEWAY_VERSION \
    IB_GATEWAY_CHANNEL IBC_VERSION IBC_RELEASE_TAG IBC_PATH TWS_PATH LOG_DIR RUN_DIR IBC_PATTERNS IBC_TEMPLATE \
    JTS_TEMPLATE BROKERSRE_LIB DOCTOR_TCP; do
    grep -qxF "${name}" <<<"${known}"
  done
}

@test "ignored_variables: STRICT_ENV=yes turns every WARN into a FAIL" {
  export STRICT_ENV=yes JAVA_HEAP_SIZE=1024 TWS_PASWORD_FILE=/x
  run check ignored_variables
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  for line in "${lines[@]}"; do
    [[ "${line}" == "FAIL|ignored_variables|"* ]]
  done
}

@test "ignored_variables: only names are printed, never a value" {
  export TWS_PASSWROD="${CANARY}" TWS_PASSWORD_PAPER="${CANARY}" SSH_PASSPHRASE="${CANARY}"
  run check ignored_variables
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [[ "$output" != *"${CANARY}"* ]]
}

# ---------------------------------------------------------------------------------------------
# 8. writable_dirs
# ---------------------------------------------------------------------------------------------

@test "writable_dirs: PASS when every directory exists and is writable" {
  run check writable_dirs
  one_result PASS writable_dirs
  [[ "$(detail)" == *"LOG_DIR"*"RUN_DIR"*"TWS_SETTINGS_PATH"*"Java home"* ]]
}

@test "writable_dirs: PASS when a directory is missing but can be created, and nothing is created" {
  export LOG_DIR="${T}/new/log" RUN_DIR="${T}/new/run" TWS_SETTINGS_PATH="${T}/new/deep/settings"
  run check writable_dirs
  one_result PASS writable_dirs
  [ ! -e "${T}/new" ]
}

@test "writable_dirs: FAIL with the tmpfs uid/gid fix when a directory is not writable" {
  if [ "$(id -u)" -eq 0 ]; then skip "root ignores directory permissions"; fi
  chmod 0500 "${RUN_DIR}"
  run check writable_dirs
  one_result FAIL writable_dirs
  [[ "$(detail)" == *"RUN_DIR"*"${RUN_DIR}"*"not writable by uid $(id -u)"* ]]
  [[ "$(fix)" == *"tmpfs"*"uid=$(id -u),gid=$(id -g)"* ]]
}

@test "writable_dirs: FAIL when a missing directory cannot be created" {
  if [ "$(id -u)" -eq 0 ]; then skip "root ignores directory permissions"; fi
  mkdir "${T}/locked"
  chmod 0500 "${T}/locked"
  export LOG_DIR="${T}/locked/log"
  run check writable_dirs
  one_result FAIL writable_dirs
  [[ "$(detail)" == *"LOG_DIR"*"cannot be created"* ]]
}

@test "writable_dirs: one FAIL per unwritable directory, the settings directory taking its Java home with it" {
  if [ "$(id -u)" -eq 0 ]; then skip "root ignores directory permissions"; fi
  chmod 0500 "${LOG_DIR}" "${TWS_SETTINGS_PATH}"
  run check writable_dirs
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == "FAIL|writable_dirs|LOG_DIR "* ]]
  [[ "${lines[1]}" == "FAIL|writable_dirs|TWS_SETTINGS_PATH "* ]]
  [[ "${lines[2]}" == "FAIL|writable_dirs|Java home "* ]]
}

@test "writable_dirs: FAIL when a path exists but is not a directory" {
  : >"${T}/file"
  export LOG_DIR="${T}/file"
  run check writable_dirs
  one_result FAIL writable_dirs
  [[ "$(detail)" == *"LOG_DIR"*"not a directory"* ]]
}

@test "writable_dirs: JAVA_USER_HOME replaces the default Java home" {
  if [ "$(id -u)" -eq 0 ]; then skip "root ignores directory permissions"; fi
  mkdir "${T}/javahome"
  chmod 0500 "${T}/javahome"
  export JAVA_USER_HOME="${T}/javahome"
  run check writable_dirs
  one_result FAIL writable_dirs
  [[ "$(detail)" == "Java home "*"${T}/javahome"* ]]
}

@test "writable_dirs: FAIL for a Java home with whitespace (the JVM splits its options on spaces)" {
  export JAVA_USER_HOME="${T}/java home"
  run check writable_dirs
  one_result FAIL writable_dirs
  [[ "$(detail)" == *"whitespace"* ]]
}

# ---------------------------------------------------------------------------------------------
# 9. heap_vs_memory
# ---------------------------------------------------------------------------------------------

@test "heap_vs_memory: SKIP when the container has no memory limit" {
  run check heap_vs_memory
  one_result SKIP heap_vs_memory
  [[ "$(detail)" == *"no memory limit"* ]]
}

@test "heap_vs_memory: SKIP when the limit cannot be read" {
  rm "${CGROUP_ROOT}/memory.max"
  run check heap_vs_memory
  one_result SKIP heap_vs_memory
  [[ "$(detail)" == *"memory.max"* ]]
  printf 'garbage\n' >"${CGROUP_ROOT}/memory.max"
  run check heap_vs_memory
  one_result SKIP heap_vs_memory
}

@test "heap_vs_memory: PASS for the default 768 MB heap up to exactly 75% of the limit" {
  mem_limit_mb 2048
  run check heap_vs_memory
  one_result PASS heap_vs_memory
  [[ "$(detail)" == *"768 MB"*"37%"*"2048 MB"* ]]
  [ -z "$(fix)" ]
  mem_limit_mb 1024
  run check heap_vs_memory
  one_result PASS heap_vs_memory
  [[ "$(detail)" == *"75%"* ]]
}

@test "heap_vs_memory: WARN above 75% of the limit while the heap is still smaller than the limit" {
  mem_limit_mb 1023
  run check heap_vs_memory
  one_result WARN heap_vs_memory
  [[ "$(detail)" == *"the JVM needs memory beyond the heap"* ]]
  [[ "$(fix)" == *"raise the"*"limit"*"lower"*"heap"* ]]
  # One byte more than the heap is still a limit the heap fits under.
  mem_limit_bytes $((768 * 1048576 + 1))
  run check heap_vs_memory
  one_result WARN heap_vs_memory
  [[ "$(detail)" == *"99%"* ]]
}

@test "heap_vs_memory: FAIL only when the heap is as large as the limit or larger" {
  mem_limit_mb 768
  run check heap_vs_memory
  one_result FAIL heap_vs_memory
  [[ "$(detail)" == *"768 MB"*"the JVM cannot get its heap"* ]]
  [[ "$(fix)" == *"raise the"*"limit"*"lower"*"heap"* ]]
  mem_limit_mb 512
  run check heap_vs_memory
  one_result FAIL heap_vs_memory
}

@test "heap_vs_memory: a numeric JAVA_HEAP_MB is the heap, with the same three tiers" {
  export JAVA_HEAP_MB=2048
  mem_limit_mb 4096
  run check heap_vs_memory
  one_result PASS heap_vs_memory
  [[ "$(detail)" == *"2048 MB"*"50%"*"4096 MB"* ]]
  mem_limit_mb 2731
  run check heap_vs_memory
  one_result PASS heap_vs_memory
  mem_limit_mb 2730
  run check heap_vs_memory
  one_result WARN heap_vs_memory
  mem_limit_mb 2049
  run check heap_vs_memory
  one_result WARN heap_vs_memory
  mem_limit_mb 2048
  run check heap_vs_memory
  one_result FAIL heap_vs_memory
  mem_limit_mb 1024
  run check heap_vs_memory
  one_result FAIL heap_vs_memory
}

@test "heap_vs_memory: a JAVA_HEAP_MB that is not a number counts as the default 768" {
  export JAVA_HEAP_MB=2g
  mem_limit_mb 2048
  run check heap_vs_memory
  one_result PASS heap_vs_memory
  [[ "$(detail)" == *"768 MB"* ]]
  [[ "$(detail)" == *"not a number"* ]]
}

@test "heap_vs_memory: JAVA_HEAP_MB=auto is half the limit" {
  export JAVA_HEAP_MB=auto
  mem_limit_mb 4096
  run check heap_vs_memory
  one_result PASS heap_vs_memory
  [[ "$(detail)" == *"auto"*"2048 MB"* ]]
}

@test "heap_vs_memory: JAVA_HEAP_MB=auto is clamped to 768..4096" {
  export JAVA_HEAP_MB=auto
  mem_limit_mb 16384
  run check heap_vs_memory
  one_result PASS heap_vs_memory
  [[ "$(detail)" == *"4096 MB"* ]]
  mem_limit_mb 1400
  run check heap_vs_memory
  one_result PASS heap_vs_memory
  [[ "$(detail)" == *"768 MB"* ]]
}

@test "heap_vs_memory: JAVA_HEAP_MB=auto without a limit is a SKIP that names the 768 MB it resolves to" {
  export JAVA_HEAP_MB=auto
  run check heap_vs_memory
  one_result SKIP heap_vs_memory
  [[ "$(detail)" == *"no memory limit"* ]]
  [[ "$(detail)" == *"auto"*"768 MB"* ]]
}

@test "heap_vs_memory: JAVA_HEAP_MB=auto follows the same tiers when its 768 MB floor fills the limit" {
  export JAVA_HEAP_MB=auto
  mem_limit_mb 1024
  run check heap_vs_memory
  one_result PASS heap_vs_memory
  [[ "$(detail)" == *"768 MB"*"75%"* ]]
  mem_limit_mb 900
  run check heap_vs_memory
  one_result WARN heap_vs_memory
  [[ "$(detail)" == *"768 MB"*"900 MB"* ]]
  mem_limit_mb 768
  run check heap_vs_memory
  one_result FAIL heap_vs_memory
  [[ "$(detail)" == *"the JVM cannot get its heap"* ]]
  mem_limit_mb 600
  run check heap_vs_memory
  one_result FAIL heap_vs_memory
}

@test "heap_vs_memory: JAVA_HEAP_MB=auto with an unreadable limit is a SKIP" {
  export JAVA_HEAP_MB=auto
  rm "${CGROUP_ROOT}/memory.max"
  run check heap_vs_memory
  one_result SKIP heap_vs_memory
}

# ---------------------------------------------------------------------------------------------
# 10. read_only_api
# ---------------------------------------------------------------------------------------------

@test "read_only_api: WARN for live trading with the read-only API switched off" {
  TRADING_MODE=live READ_ONLY_API=no run check read_only_api
  one_result WARN read_only_api
  [[ "$(detail)" == *"API clients can place orders"* ]]
  [ -n "$(fix)" ]
}

@test "read_only_api: PASS for paper, and for live with the read-only API on" {
  TRADING_MODE=paper READ_ONLY_API=no run check read_only_api
  one_result PASS read_only_api
  TRADING_MODE=paper READ_ONLY_API=yes run check read_only_api
  one_result PASS read_only_api
  TRADING_MODE=live READ_ONLY_API=yes run check read_only_api
  one_result PASS read_only_api
}

@test "read_only_api: SKIP for live when READ_ONLY_API is neither yes nor no" {
  TRADING_MODE=live READ_ONLY_API='' run check read_only_api
  one_result SKIP read_only_api
  TRADING_MODE=live READ_ONLY_API=maybe run check read_only_api
  one_result SKIP read_only_api
}

# ---------------------------------------------------------------------------------------------
# 11. relay_exposure
# ---------------------------------------------------------------------------------------------

@test "relay_exposure: always a SKIP with the advice to publish on loopback or a private address" {
  TRADING_MODE=paper run check relay_exposure
  one_result SKIP relay_exposure
  [[ "$(detail)" == *"cannot see"* ]]
  [[ "$(fix)" == *"127.0.0.1"*"private"* ]]
  [[ "$(fix)" == *"4004"* ]]
  TRADING_MODE=live run check relay_exposure
  one_result SKIP relay_exposure
  [[ "$(fix)" == *"4003"* ]]
}

# ---------------------------------------------------------------------------------------------
# 12. disk_space
# ---------------------------------------------------------------------------------------------

@test "disk_space: PASS with enough free space, one line when both paths share a filesystem" {
  run check disk_space
  one_result PASS disk_space
  [[ "$(detail)" == *"LOG_DIR"*"TWS_SETTINGS_PATH"*"47.6 GiB free of 95.3 GiB (50% free)"* ]]
  [ -z "$(fix)" ]
}

@test "disk_space: one line per filesystem when the paths are on different ones" {
  df_answer settings 10000000 90000000 /mnt/settings /dev/other
  run check disk_space
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "PASS|disk_space|LOG_DIR"*"50% free"*"/dev/fake"* ]]
  [[ "${lines[1]}" == "PASS|disk_space|TWS_SETTINGS_PATH"*"90% free"*"/dev/other"* ]]
}

@test "disk_space: two volumes on one block device are one filesystem, reported once" {
  df_answer log 50000000 50000000 /var/log/ibgateway /dev/sde
  df_answer settings 50000000 50000000 /home/ibgateway/Jts/settings /dev/sde
  run check disk_space
  one_result PASS disk_space
  [[ "$(detail)" == *"LOG_DIR"*"TWS_SETTINGS_PATH"*"50% free"*"/dev/sde"* ]]
}

@test "disk_space: filesystems without a block device (tmpfs) are told apart by their mount point" {
  df_answer log 50000000 50000000 /var/log/ibgateway tmpfs
  df_answer settings 10000000 90000000 /home/ibgateway/Jts/settings tmpfs
  run check disk_space
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "PASS|disk_space|LOG_DIR"*"50% free"*"/var/log/ibgateway"* ]]
  [[ "${lines[1]}" == "PASS|disk_space|TWS_SETTINGS_PATH"*"90% free"*"/home/ibgateway/Jts/settings"* ]]
}

@test "disk_space: WARN below DISK_MIN_FREE_PCT (default 10), with the numbers" {
  df_answer log 91000000 9000000 /mnt/log /dev/logdisk
  run check disk_space
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "WARN|disk_space|LOG_DIR"*"8.5 GiB free of 95.3 GiB (9% free)"*"DISK_MIN_FREE_PCT=10"* ]]
  [ -n "$(fix 0)" ]
  [[ "${lines[1]}" == "PASS|disk_space|TWS_SETTINGS_PATH"* ]]
}

@test "disk_space: exactly the minimum percentage is still a PASS" {
  df_answer log 90000000 10000000 /mnt/data
  df_answer settings 90000000 10000000 /mnt/data
  run check disk_space
  one_result PASS disk_space
}

@test "disk_space: a nearly full large disk with gigabytes left is a WARN, never a FAIL" {
  df_answer log 3900000000 70000000 /mnt/data
  df_answer settings 3900000000 70000000 /mnt/data
  run check disk_space
  one_result WARN disk_space
  [[ "$(detail)" == *"66.7 GiB free"*"(1% free)"* ]]
}

@test "disk_space: FAIL below the absolute floor of 16 MiB free" {
  df_answer log 99990000 10000 /mnt/data
  df_answer settings 99990000 10000 /mnt/data
  run check disk_space
  one_result FAIL disk_space
  [[ "$(detail)" == *"9.7 MiB free of 95.3 GiB (0% free)"* ]]
  [[ "$(detail)" == *"less than 16 MiB free"*"cannot write"* ]]
  [ -n "$(fix)" ]
}

@test "disk_space: a hundred megabytes free on a full large disk is a WARN, not a FAIL" {
  df_answer log 99900000 100000 /mnt/data
  df_answer settings 99900000 100000 /mnt/data
  run check disk_space
  one_result WARN disk_space
  [[ "$(detail)" == *"97.6 MiB free of 95.3 GiB (0% free)"* ]]
}

@test "disk_space: the floor is absolute: a small volume fails one kilobyte below 16 MiB even when half free" {
  df_answer log 16385 16383 /mnt/data
  df_answer settings 16385 16383 /mnt/data
  run check disk_space
  one_result FAIL disk_space
  [[ "$(detail)" == *"15.9 MiB free of 32.0 MiB (49% free)"* ]]
}

@test "disk_space: exactly 16 MiB free is not a FAIL" {
  df_answer log 16384 16384 /mnt/data
  df_answer settings 16384 16384 /mnt/data
  run check disk_space
  one_result PASS disk_space
  [[ "$(detail)" == *"16.0 MiB free of 32.0 MiB (50% free)"* ]]
  df_answer log 99983616 16384 /mnt/data
  df_answer settings 99983616 16384 /mnt/data
  run check disk_space
  one_result WARN disk_space
}

# A small tmpfs for the settings directory is a supported setup: it is judged by the
# percentage like any other volume and never fails while 16 MiB are free.
@test "disk_space: a 64 MiB tmpfs that is half free passes, or warns by percentage, and never fails" {
  df_answer settings 32768 32768 /home/ibgateway/Jts/settings tmpfs
  run check disk_space
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "PASS|disk_space|LOG_DIR:"* ]]
  [[ "${lines[1]}" == "PASS|disk_space|TWS_SETTINGS_PATH: 32.0 MiB free of 64.0 MiB (50% free) on /home/ibgateway/Jts/settings|"* ]]
  DISK_MIN_FREE_PCT=60 run check disk_space
  [[ "${lines[1]}" == "WARN|disk_space|TWS_SETTINGS_PATH: 32.0 MiB free of 64.0 MiB (50% free)"*"DISK_MIN_FREE_PCT=60"* ]]
  df_answer settings 45875 19661 /home/ibgateway/Jts/settings tmpfs
  DISK_MIN_FREE_PCT=60 run check disk_space
  [[ "${lines[1]}" == "WARN|disk_space|TWS_SETTINGS_PATH: 19.2 MiB free of 64.0 MiB (30% free)"* ]]
}

@test "disk_space: only the filesystem that is below the floor fails" {
  df_answer log 99990000 10000 /mnt/log /dev/logdisk
  run check disk_space
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "FAIL|disk_space|LOG_DIR:"* ]]
  [[ "${lines[1]}" == "PASS|disk_space|TWS_SETTINGS_PATH:"* ]]
}

@test "disk_space: DISK_MIN_FREE_PCT moves the warning threshold and a bad value means the default" {
  df_answer log 80000000 20000000 /mnt/data
  df_answer settings 80000000 20000000 /mnt/data
  DISK_MIN_FREE_PCT=30 run check disk_space
  one_result WARN disk_space
  [[ "$(detail)" == *"(20% free)"*"DISK_MIN_FREE_PCT=30"* ]]
  DISK_MIN_FREE_PCT=lots run check disk_space
  one_result PASS disk_space
  DISK_MIN_FREE_PCT=20 run check disk_space
  one_result PASS disk_space
}

@test "disk_space: SKIP when free space cannot be measured" {
  rm "${T}/df/log" "${T}/df/settings"
  run check disk_space
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "SKIP|disk_space|"*"LOG_DIR"* ]]
  [[ "${lines[1]}" == "SKIP|disk_space|"*"TWS_SETTINGS_PATH"* ]]
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nnonsense\n' >"${T}/df/log"
  run check disk_space
  [[ "${lines[0]}" == "SKIP|disk_space|"*"LOG_DIR"* ]]
}

@test "disk_space: a directory that does not exist yet is measured on its nearest existing parent" {
  export LOG_DIR="${T}/log/not/yet/there"
  run check disk_space
  one_result PASS disk_space
}

@test "disk_space: the real df of the image is understood" {
  export PATH="${REAL_PATH}"
  run check disk_space
  [ "$status" -eq 0 ]
  for line in "${lines[@]}"; do
    [[ "${line}" =~ ^(PASS|WARN|FAIL)\|disk_space\|.*[0-9]+%\ free ]]
  done
}

# ---------------------------------------------------------------------------------------------
# 13. ibkr_reachable (--online only)
# ---------------------------------------------------------------------------------------------

@test "ibkr_reachable: PASS when a login server accepts the connection" {
  DOCTOR_TCP=true run check ibkr_reachable
  one_result PASS ibkr_reachable
  [[ "$(detail)" == *"cdc1.ibllc.com:4001"* ]]
}

@test "ibkr_reachable: FAIL when no login server can be reached" {
  DOCTOR_TCP=false run check ibkr_reachable
  one_result FAIL ibkr_reachable
  [[ "$(detail)" == *"cannot reach IBKR login servers (DNS or firewall)"* ]]
  [ -n "$(fix)" ]
}

@test "ibkr_reachable: PASS when only the second server answers, and exactly the two servers are probed" {
  printf '%s\n' '#!/usr/bin/env bash' 'echo "$1:$2" >>"${TCP_CALLS}"' '[ "$1" = "ndc1.ibllc.com" ]' >"${T}/bin/tcp-stub"
  chmod +x "${T}/bin/tcp-stub"
  export TCP_CALLS="${T}/tcp-calls"
  DOCTOR_TCP="${T}/bin/tcp-stub" run check ibkr_reachable
  one_result PASS ibkr_reachable
  [[ "$(detail)" == *"ndc1.ibllc.com:4001"* ]]
  [ "$(cat "${TCP_CALLS}")" == "$(printf 'cdc1.ibllc.com:4001\nndc1.ibllc.com:4001')" ]
}

@test "the TCP probe is true for a listening local port and false for a closed one" {
  socat TCP-LISTEN:47631,bind=127.0.0.1,fork,reuseaddr /dev/null >/dev/null 2>&1 3>&- &
  LISTENER_PID=$!
  for _ in $(seq 1 50); do
    if fn doctor_tcp_connect 127.0.0.1 47631; then break; fi
    sleep 0.1
  done
  run fn doctor_tcp_connect 127.0.0.1 47631
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run fn doctor_tcp_connect 127.0.0.1 47632
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "ibkr_reachable runs only with --online" {
  run "${DOCTOR}" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.checks[].name] | index("ibkr_reachable") == null' >/dev/null
  DOCTOR_TCP=true run "${DOCTOR}" --json --online
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.checks[-1] | .name == "ibkr_reachable" and .status == "pass"' >/dev/null
  DOCTOR_TCP=false run "${DOCTOR}" --json --online
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.result == "fail" and (.checks[-1] | .name == "ibkr_reachable" and .status == "fail")' >/dev/null
}

# ---------------------------------------------------------------------------------------------
# Output modes and exit codes
# ---------------------------------------------------------------------------------------------

@test "default output is an aligned table with one row per check and a one-line summary" {
  run "${DOCTOR}"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^STATUS\ +CHECK\ +DETAIL$ ]]
  for name in trading_mode credentials secret_values auto_restart_time restart_window time_zone \
    ignored_variables writable_dirs heap_vs_memory read_only_api relay_exposure disk_space; do
    grep -Eq "^(PASS|WARN|FAIL|SKIP) +${name} +[^ ]" <<<"$output"
  done
  [ "${lines[-1]}" == "doctor: pass (10 passed, 0 warned, 0 failed, 2 skipped)" ]
}

@test "the table columns line up and a fix is printed under its row" {
  export TRADING_MODE=both
  unset AUTO_RESTART_TIME
  run "${DOCTOR}"
  [ "$status" -eq 1 ]
  header="${lines[0]}"
  before_check="${header%%CHECK*}"
  before_detail="${header%%DETAIL*}"
  rows=0
  fixes=0
  for line in "${lines[@]:1:${#lines[@]}-2}"; do
    if [[ "${line}" =~ ^(PASS|WARN|FAIL|SKIP)\  ]]; then
      rows=$((rows + 1))
      [ "${line:${#before_check}-1:1}" == " " ]
      [ "${line:${#before_check}:1}" != " " ]
      [ "${line:${#before_detail}-1:1}" == " " ]
      [ "${line:${#before_detail}:1}" != " " ]
    else
      fixes=$((fixes + 1))
      [ "${line:0:${#before_detail}}" == "$(printf '%*s' "${#before_detail}" '')" ]
      [[ "${line:${#before_detail}}" == "fix: "* ]]
    fi
  done
  [ "${rows}" -eq 12 ]
  [ "${fixes}" -ge 2 ]
  grep -Eq '^FAIL +trading_mode ' <<<"$output"
  grep -Eq '^WARN +auto_restart_time ' <<<"$output"
  [[ "${lines[-1]}" == "doctor: fail ("*" 1 failed, "* ]]
}

@test "the exit code is 0 with warnings only and 1 with at least one FAIL" {
  unset AUTO_RESTART_TIME
  run "${DOCTOR}"
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == "doctor: warn ("* ]]
  export TRADING_MODE=both
  run "${DOCTOR}"
  [ "$status" -eq 1 ]
}

@test "--json prints one valid document with the schema, the result and every check" {
  run "${DOCTOR}" --json
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  echo "$output" | jq -e 'keys == ["checks", "result", "schema"]' >/dev/null
  echo "$output" | jq -e '.schema == "brokersre.doctor.v1" and .result == "pass" and (.checks | length) == 12' >/dev/null
  echo "$output" | jq -e 'all(.checks[]; keys == ["detail", "fix", "name", "status"])' >/dev/null
  echo "$output" | jq -e 'all(.checks[]; .status | IN("pass", "warn", "fail", "skip"))' >/dev/null
  echo "$output" | jq -e '[.checks[].name] == ["trading_mode", "credentials", "secret_values", "auto_restart_time", "restart_window", "time_zone", "ignored_variables", "writable_dirs", "heap_vs_memory", "read_only_api", "relay_exposure", "disk_space"]' >/dev/null
  echo "$output" | jq -e '[.checks[] | select(.status == "skip") | .name] == ["heap_vs_memory", "relay_exposure"]' >/dev/null
}

@test "--json result is warn with a WARN and fail (exit 1) with a FAIL, and carries the fix" {
  unset AUTO_RESTART_TIME
  run "${DOCTOR}" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result == "warn"' >/dev/null
  echo "$output" | jq -e '.checks[] | select(.name == "auto_restart_time") | .status == "warn" and (.fix | contains("11:45 PM"))' >/dev/null
  export TRADING_MODE=both
  run "${DOCTOR}" --json
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.result == "fail"' >/dev/null
  echo "$output" | jq -e '.checks[] | select(.name == "trading_mode") | .status == "fail" and (.fix | length) > 0' >/dev/null
}

@test "--json stays valid when a value holds quotes, backslashes and control characters" {
  export TRADING_MODE="$(printf 'a"b\\c\td\001e')"
  run "${DOCTOR}" --json
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 1 ]
  echo "$output" | jq -e '.checks[] | select(.name == "trading_mode") | .status == "fail" and (.detail | contains("a\"b\\c"))' >/dev/null
}

@test "--startup with nothing to report emits only doctor_ok and exits 0" {
  run "${DOCTOR}" --startup
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  echo "$output" | jq -e '.src == "doctor" and .level == "info" and .event == "doctor_ok" and .boot_id == "0123456789abcdef" and .seq == 1' >/dev/null
  echo "$output" | jq -e '.msg | contains("10 passed") and contains("2 skipped")' >/dev/null
  [ "$(cat "${LOG_DIR}/events/events.jsonl")" == "$output" ]
}

@test "--startup emits one warn event per WARN, then doctor_ok, and still exits 0" {
  unset AUTO_RESTART_TIME TWS_PASSWORD_FILE
  export TWS_PASSWORD="${CANARY}"
  run "${DOCTOR}" --startup
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  echo "$output" | jq -es 'all(.src == "doctor")' >/dev/null
  echo "$output" | jq -es '[.[] | .event] == ["doctor_warning", "doctor_warning", "doctor_ok"]' >/dev/null
  echo "$output" | jq -es '[.[] | .level] == ["warn", "warn", "info"]' >/dev/null
  echo "$output" | jq -es '.[0].msg | startswith("secret_values: ") and contains("use TWS_PASSWORD_FILE")' >/dev/null
  echo "$output" | jq -es '.[1].msg | startswith("auto_restart_time: ") and contains("no daily restart configured")' >/dev/null
  echo "$output" | jq -es '.[2].msg | contains("2 warned")' >/dev/null
  [[ "$output" != *"${CANARY}"* ]]
}

@test "--startup reports an ignored variable as config_deprecated (warn)" {
  export JAVA_HEAP_SIZE=1024
  run "${DOCTOR}" --startup
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  echo "$output" | jq -es '.[0] | .event == "config_deprecated" and .level == "warn" and (.msg | contains("JAVA_HEAP_SIZE") and contains("JAVA_HEAP_MB"))' >/dev/null
  echo "$output" | jq -es '.[1].event == "doctor_ok"' >/dev/null
}

@test "--startup emits doctor_failed (error) per FAIL, no doctor_ok, and exits 1" {
  export TRADING_MODE=both AUTO_RESTART_TIME='23:45'
  run "${DOCTOR}" --startup
  [ "$status" -eq 1 ]
  echo "$output" | jq -es 'all(.src == "doctor")' >/dev/null
  echo "$output" | jq -es '[.[] | select(.event == "doctor_failed" and .level == "error")] | length == 2' >/dev/null
  echo "$output" | jq -es '[.[] | select(.event == "doctor_failed") | .msg | split(":")[0]] == ["trading_mode", "auto_restart_time"]' >/dev/null
  echo "$output" | jq -es '[.[] | select(.event == "doctor_ok")] | length == 0' >/dev/null
  echo "$output" | jq -es '.[0].msg | contains("two containers")' >/dev/null
}

# A start is stopped only by what makes the gateway unable to work. What is merely likely, or
# what the image cannot verify, is a warning and the gateway starts.
@test "--startup: an unverifiable time zone, a tight heap and a low free-space percentage warn and never stop the start" {
  export TIME_ZONE=Singapore
  mem_limit_mb 900
  df_answer log 91000000 9000000 /mnt/data
  df_answer settings 91000000 9000000 /mnt/data
  run "${DOCTOR}" --startup
  [ "$status" -eq 0 ]
  echo "$output" | jq -es '[.[] | .event] == ["doctor_warning", "doctor_warning", "doctor_warning", "doctor_ok"]' >/dev/null
  echo "$output" | jq -es '[.[] | .level] == ["warn", "warn", "warn", "info"]' >/dev/null
  echo "$output" | jq -es '[.[0:3][] | .msg | split(":")[0]] == ["time_zone", "heap_vs_memory", "disk_space"]' >/dev/null
}

@test "--startup: a heap as large as the memory limit and a disk below 16 MiB free stop a strict start" {
  mem_limit_mb 768
  df_answer log 99990000 10000 /mnt/data
  df_answer settings 99990000 10000 /mnt/data
  run "${DOCTOR}" --startup
  [ "$status" -eq 1 ]
  echo "$output" | jq -es '[.[] | select(.event == "doctor_failed" and .level == "error") | .msg | split(":")[0]] == ["heap_vs_memory", "disk_space"]' >/dev/null
  echo "$output" | jq -es '[.[] | select(.event == "doctor_ok")] | length == 0' >/dev/null
}

@test "--startup with DOCTOR_STRICT=no logs each FAIL as doctor_failed (warn) and exits 0" {
  export TRADING_MODE=both DOCTOR_STRICT=no
  run "${DOCTOR}" --startup
  [ "$status" -eq 0 ]
  echo "$output" | jq -es '[.[] | select(.event == "doctor_failed")] | length == 1 and .[0].level == "warn"' >/dev/null
  echo "$output" | jq -es '[.[] | select(.level == "error")] | length == 0' >/dev/null
  echo "$output" | jq -es '[.[] | select(.event == "doctor_ok")] | length == 0' >/dev/null
}

@test "--startup with STRICT_ENV=yes turns an ignored variable into config_deprecated (error) and exits 1" {
  export JAVA_HEAP_SIZE=1024 STRICT_ENV=yes
  run "${DOCTOR}" --startup
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 1 ]
  echo "$output" | jq -e '.event == "config_deprecated" and .level == "error" and (.msg | contains("JAVA_HEAP_SIZE"))' >/dev/null
}

@test "--startup with STRICT_ENV=yes and DOCTOR_STRICT=no logs config_deprecated (warn) and exits 0" {
  export JAVA_HEAP_SIZE=1024 STRICT_ENV=yes DOCTOR_STRICT=no
  run "${DOCTOR}" --startup
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  echo "$output" | jq -e '.event == "config_deprecated" and .level == "warn"' >/dev/null
}

@test "--startup prints nothing but events, even for a UTF-16 secret file" {
  printf '\xff\xfeh\x00u\x00n\x00t\x00e\x00r\x002\x00\r\x00\n\x00' >"${T}/secrets/p"
  run "${DOCTOR}" --startup
  [ "$status" -eq 1 ]
  echo "$output" | jq -es 'all(has("ts") and has("src") and has("level") and has("event") and has("msg"))' >/dev/null
  echo "$output" | jq -es '.[0] | .event == "doctor_failed" and (.msg | startswith("credentials: ") and contains("UTF-16"))' >/dev/null
}

# ---------------------------------------------------------------------------------------------
# The verdict file of --startup
#
# The exit status alone cannot tell "a check failed" from "the preflight ended abnormally", so
# a --startup run leaves its verdict in ${RUN_DIR}/doctor.result: one line, fail, warn or pass.
# The entrypoint stops a start only when the status is 1 AND the file says fail.
# ---------------------------------------------------------------------------------------------

# verdict_is WORD: the result file holds exactly the one line WORD.
verdict_is() {
  [ -f "${RESULT}" ]
  [ "$(wc -l <"${RESULT}")" -eq 1 ]
  [ "$(cat "${RESULT}")" == "$1" ]
}

@test "--startup writes pass to the result file when nothing failed or warned, and leaves no temporary file" {
  run "${DOCTOR}" --startup
  [ "$status" -eq 0 ]
  verdict_is pass
  [ "$(ls -A "${RUN_DIR}")" == "doctor.result" ]
}

@test "--startup writes warn to the result file when a check warned" {
  unset AUTO_RESTART_TIME
  run "${DOCTOR}" --startup
  [ "$status" -eq 0 ]
  verdict_is warn
}

@test "--startup writes fail to the result file when the run exits 1" {
  export TRADING_MODE=both
  run "${DOCTOR}" --startup
  [ "$status" -eq 1 ]
  verdict_is fail
  [ "$(ls -A "${RUN_DIR}")" == "doctor.result" ]
}

@test "--startup with DOCTOR_STRICT=no and a failing check writes warn, because the start is not stopped" {
  export TRADING_MODE=both DOCTOR_STRICT=no
  run "${DOCTOR}" --startup
  [ "$status" -eq 0 ]
  verdict_is warn
}

@test "--startup with STRICT_ENV=yes writes fail for an ignored variable, and warn when DOCTOR_STRICT=no overrules it" {
  export JAVA_HEAP_SIZE=1024 STRICT_ENV=yes
  run "${DOCTOR}" --startup
  [ "$status" -eq 1 ]
  verdict_is fail
  DOCTOR_STRICT=no run "${DOCTOR}" --startup
  [ "$status" -eq 0 ]
  verdict_is warn
}

@test "--startup writes warn, never fail, when the only finding is a crashed check" {
  run bash -uc "source '${DOCTOR}'; check_time_zone() { exit 7; }; doctor_main --startup"
  [ "$status" -eq 0 ]
  verdict_is warn
}

@test "a stale fail from a previous run is gone when the new run passes" {
  printf 'fail\n' >"${RESULT}"
  run "${DOCTOR}" --startup
  [ "$status" -eq 0 ]
  verdict_is pass
}

@test "the stale result file is removed at the start of a --startup run, before any check runs" {
  printf 'fail\n' >"${RESULT}"
  run bash -uc "source '${DOCTOR}'; check_time_zone() { if [ -e '${RESULT}' ]; then doctor_result FAIL time_zone 'the stale file is still there'; else doctor_result PASS time_zone 'no stale file'; fi; }; doctor_main --startup"
  [ "$status" -eq 0 ]
  verdict_is pass
}

@test "a result file that cannot be written is one doctor_warning event and does not change the exit status" {
  # A directory in the file's place: it can be neither removed nor replaced.
  mkdir "${RESULT}"
  run "${DOCTOR}" --startup
  [ "$status" -eq 0 ]
  echo "$output" | jq -es --arg path "${RESULT}" '[.[] | select(.event == "doctor_warning" and .level == "warn" and (.msg | contains("result file") and contains($path)))] | length == 1' >/dev/null
  echo "$output" | jq -es '.[-1].event == "doctor_ok"' >/dev/null
  [ -d "${RESULT}" ]
  [ -z "$(ls -A "${RESULT}")" ]
  [ "$(ls -A "${RUN_DIR}")" == "doctor.result" ]
  export TRADING_MODE=both
  run "${DOCTOR}" --startup
  [ "$status" -eq 1 ]
  echo "$output" | jq -es '[.[] | select(.event == "doctor_warning" and (.msg | contains("result file")))] | length == 1' >/dev/null
  echo "$output" | jq -es '[.[] | select(.event == "doctor_failed")] | length == 1' >/dev/null
}

@test "DOCTOR_RESULT_FILE moves the result file, and a missing directory there is the same warning" {
  export DOCTOR_RESULT_FILE="${T}/elsewhere.result" TRADING_MODE=both
  run "${DOCTOR}" --startup
  [ "$status" -eq 1 ]
  [ "$(cat "${T}/elsewhere.result")" == "fail" ]
  [ ! -e "${RESULT}" ]
  export DOCTOR_RESULT_FILE="${T}/no-such-directory/doctor.result"
  run "${DOCTOR}" --startup
  [ "$status" -eq 1 ]
  echo "$output" | jq -es '[.[] | select(.event == "doctor_warning" and (.msg | contains("result file") and contains("no-such-directory")))] | length == 1' >/dev/null
  [ ! -e "${T}/no-such-directory" ]
}

@test "the result file is never written, and a present one never touched, without --startup" {
  run "${DOCTOR}"
  [ ! -e "${RESULT}" ]
  run "${DOCTOR}" --json
  [ ! -e "${RESULT}" ]
  DOCTOR_TCP=true run "${DOCTOR}" --online
  [ ! -e "${RESULT}" ]
  export TRADING_MODE=both
  run "${DOCTOR}" --json
  [ "$status" -eq 1 ]
  [ ! -e "${RESULT}" ]
  printf 'pass\n' >"${RESULT}"
  run "${DOCTOR}"
  [ "$status" -eq 1 ]
  verdict_is pass
}

# ---------------------------------------------------------------------------------------------
# An abort of doctor's own code is not a failed check
#
# Status 1 means "a check failed". When doctor's own main code aborts (an unset variable under
# nounset is the realistic case) the program exits 70 instead, so that nobody reads a defect
# of the preflight as a reason to stop the gateway.
# ---------------------------------------------------------------------------------------------

@test "the program exits with the status of the run: 0, 1 for a failed check, 2 for a usage error" {
  run bash -c "source '${DOCTOR}'; doctor_cli --json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result == "pass"' >/dev/null
  TRADING_MODE=both run bash -c "source '${DOCTOR}'; doctor_cli --json"
  [ "$status" -eq 1 ]
  run bash -c "source '${DOCTOR}'; doctor_cli --bogus"
  [ "$status" -eq 2 ]
}

@test "an abort of doctor's own code exits 70, not 1" {
  run bash -c "source '${DOCTOR}'; doctor_print_table() { printf '%s' \"\${NO_SUCH_VARIABLE}\"; }; doctor_cli"
  [ "$status" -eq 70 ]
  export TRADING_MODE=both
  run bash -c "source '${DOCTOR}'; doctor_print_json() { printf '%s' \"\${NO_SUCH_VARIABLE}\"; }; doctor_cli --json"
  [ "$status" -eq 70 ]
}

@test "--startup: an abort before the verdict exits 70 and leaves no result file, not even a stale one" {
  printf 'fail\n' >"${RESULT}"
  export TRADING_MODE=both
  run bash -c "source '${DOCTOR}'; doctor_emit_startup() { printf '%s' \"\${NO_SUCH_VARIABLE}\"; }; doctor_cli --startup"
  [ "$status" -eq 70 ]
  [ ! -e "${RESULT}" ]
}

@test "a crashed check is still not an abort: the program exits 0 and reports the WARN" {
  run bash -c "source '${DOCTOR}'; check_time_zone() { exit 7; }; doctor_cli --json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg detail "${CRASH_DETAIL}" '.checks[] | select(.name == "time_zone") | .status == "warn" and .detail == $detail' >/dev/null
  echo "$output" | jq -e '[.checks[] | select(.status == "pass")] | length == 9' >/dev/null
}

@test "--help prints the usage and exits 0; an unknown option exits 2" {
  run "${DOCTOR}" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--json"*"--online"*"--startup"* ]]
  run "${DOCTOR}" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"--bogus"* ]]
  run "${DOCTOR}" --json --startup
  [ "$status" -eq 2 ]
}

@test "doctor runs through a symlink and without BROKERSRE_LIB, as installed in the image" {
  ln -s "${DOCTOR}" "${T}/bin/doctor"
  run env -u BROKERSRE_LIB "${T}/bin/doctor" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result == "pass"' >/dev/null
}

@test "doctor finishes well within five seconds without --online" {
  started="${EPOCHSECONDS}"
  run "${DOCTOR}"
  [ "$status" -eq 0 ]
  [ $((EPOCHSECONDS - started)) -lt 5 ]
}

@test "doctor_main is safe to call from a shell with errexit, nounset and pipefail" {
  run bash -euo pipefail -c "source '${DOCTOR}'; doctor_main --json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result == "pass"' >/dev/null
  export TRADING_MODE=both JAVA_HEAP_SIZE=1 TWS_PASWORD_FILE=/x
  run bash -euo pipefail -c "source '${DOCTOR}'; doctor_main --json"
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.result == "fail" and (.checks | length) == 13' >/dev/null
}

# ---------------------------------------------------------------------------------------------
# Crash isolation
# ---------------------------------------------------------------------------------------------

# A crash is a defect in doctor, not in the operator's configuration: it is shown as a WARN in
# every mode and never changes the exit code by itself, so the preflight cannot stop a gateway
# by being wrong about itself.

@test "a check that exits is reported as WARN 'check crashed', the other checks still run and the exit code stays 0" {
  run bash -uc "source '${DOCTOR}'; check_time_zone() { exit 7; }; doctor_main --json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result == "warn" and (.checks | length) == 12' >/dev/null
  echo "$output" | jq -e --arg detail "${CRASH_DETAIL}" '.checks[] | select(.name == "time_zone") | .status == "warn" and .detail == $detail' >/dev/null
  echo "$output" | jq -e '.checks[] | select(.name == "time_zone") | .fix | contains("exit status 7")' >/dev/null
  echo "$output" | jq -e '[.checks[] | select(.status == "fail")] | length == 0' >/dev/null
  echo "$output" | jq -e '.checks[-1].name == "disk_space"' >/dev/null
}

@test "a crashed check is a WARN row of the table and the exit code stays 0" {
  run bash -uc "source '${DOCTOR}'; check_time_zone() { exit 7; }; doctor_main"
  [ "$status" -eq 0 ]
  grep -Eq "^WARN +time_zone +${CRASH_DETAIL//[()]/.}\$" <<<"$output"
  [[ "${lines[-1]}" == "doctor: warn (9 passed, 1 warned, 0 failed, 2 skipped)" ]]
}

@test "an unset variable inside a check (nounset) crashes that check only" {
  run bash -uc "source '${DOCTOR}'; check_trading_mode() { printf '%s' \"\${NO_SUCH_VARIABLE}\"; }; doctor_main --json"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  echo "$output" | jq -e --arg detail "${CRASH_DETAIL}" '.checks[0] | .name == "trading_mode" and .status == "warn" and .detail == $detail' >/dev/null
  echo "$output" | jq -e '(.checks | length) == 12' >/dev/null
}

@test "a check that prints something other than a result line is reported as crashed" {
  run bash -uc "source '${DOCTOR}'; check_time_zone() { echo 'not a result'; }; doctor_main --json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg detail "${CRASH_DETAIL}" '[.checks[] | select(.name == "time_zone")] | length == 1 and .[0].status == "warn" and .[0].detail == $detail' >/dev/null
  [[ "$output" != *"not a result"* ]]
}

@test "a check that prints nothing is reported as crashed" {
  run bash -uc "source '${DOCTOR}'; check_time_zone() { :; }; doctor_main --json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg detail "${CRASH_DETAIL}" '.checks[] | select(.name == "time_zone") | .status == "warn" and .detail == $detail' >/dev/null
}

@test "results printed before a crash are kept next to the crash report" {
  run bash -uc "source '${DOCTOR}'; check_time_zone() { doctor_result PASS time_zone 'seen before the crash'; exit 3; }; doctor_main --json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.checks[] | select(.name == "time_zone") | .status] == ["pass", "warn"]' >/dev/null
}

@test "a crashed check does not hide a real failure: the exit code is still 1" {
  export TRADING_MODE=both
  run bash -uc "source '${DOCTOR}'; check_time_zone() { exit 7; }; doctor_main --json"
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.result == "fail"' >/dev/null
  echo "$output" | jq -e '[.checks[] | select(.status == "fail") | .name] == ["trading_mode"]' >/dev/null
}

@test "--startup: a crashed check is a doctor_warning and the start continues" {
  run bash -uc "source '${DOCTOR}'; check_time_zone() { exit 7; }; doctor_main --startup"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  echo "$output" | jq -es --arg detail "${CRASH_DETAIL}" '.[0] | .event == "doctor_warning" and .level == "warn" and (.msg | startswith("time_zone: " + $detail))' >/dev/null
  echo "$output" | jq -es '.[1] | .event == "doctor_ok" and .level == "info"' >/dev/null
}

@test "--startup: a crash of the ignored-variable check is a doctor_warning, not config_deprecated" {
  run bash -uc "source '${DOCTOR}'; check_ignored_variables() { exit 7; }; doctor_main --startup"
  [ "$status" -eq 0 ]
  echo "$output" | jq -es '[.[] | .event] == ["doctor_warning", "doctor_ok"]' >/dev/null
}

@test "--startup: even when every check crashes the start continues, also with STRICT_ENV=yes" {
  export STRICT_ENV=yes
  run bash -uc "source '${DOCTOR}'; for name in \"\${doctor_checks[@]}\"; do eval \"check_\${name}() { exit 9; }\"; done; doctor_main --startup"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 13 ]
  echo "$output" | jq -es '[.[0:12][] | select(.event == "doctor_warning" and .level == "warn")] | length == 12' >/dev/null
  echo "$output" | jq -es '.[12].event == "doctor_ok"' >/dev/null
}

# ---------------------------------------------------------------------------------------------
# No secret in any output
# ---------------------------------------------------------------------------------------------

# no_canary_in_any_mode: run every output mode in the current environment and require that the
# canary is in none of them, nor in anything written to the log volume or the run directory
# (the result file). Each run must really
# have been a doctor run (exit status 0 or 1 and some output), so that a script that did not
# start cannot pass as "nothing leaked".
no_canary_in_any_mode() {
  local mode
  for mode in "" "--json" "--startup" "--online" "--json --online" "--startup --online"; do
    # shellcheck disable=SC2086
    DOCTOR_TCP=false run "${DOCTOR}" ${mode}
    if [ "$status" -gt 1 ] || [ -z "$output" ]; then
      echo "doctor did not run in mode '${mode}' (status $status)"
      return 1
    fi
    if [[ "$output" == *"${CANARY}"* ]]; then
      echo "the canary leaked in mode '${mode}'"
      return 1
    fi
    # shellcheck disable=SC2086
    DOCTOR_STRICT=no STRICT_ENV=yes run "${DOCTOR}" ${mode}
    if [ "$status" -gt 1 ] || [ -z "$output" ]; then
      echo "doctor did not run in mode '${mode}' with DOCTOR_STRICT=no STRICT_ENV=yes (status $status)"
      return 1
    fi
    if [[ "$output" == *"${CANARY}"* ]]; then
      echo "the canary leaked in mode '${mode}' with DOCTOR_STRICT=no STRICT_ENV=yes"
      return 1
    fi
  done
  if grep -rqF "${CANARY}" "${LOG_DIR}" "${RUN_DIR}"; then
    echo "the canary leaked into the log volume or the run directory"
    return 1
  fi
}

@test "canary: a password in a secret file appears in no output of any mode" {
  printf '%s\r\n' "${CANARY}" >"${T}/secrets/p"
  no_canary_in_any_mode
  printf '\xef\xbb\xbf%s' "${CANARY}" >"${T}/secrets/p"
  no_canary_in_any_mode
}

@test "canary: a password in the environment appears in no output of any mode" {
  unset TWS_PASSWORD_FILE
  export TWS_PASSWORD="${CANARY}"
  no_canary_in_any_mode
}

@test "canary: a password in both the file and the environment appears in no output of any mode" {
  printf '%s' "${CANARY}" >"${T}/secrets/p"
  export TWS_PASSWORD="${CANARY}"
  no_canary_in_any_mode
}

@test "canary: a password in misused and misspelled variables appears in no output of any mode" {
  export TWS_PASSWORD_FILE="${CANARY}" TWS_USERID_FILE="${CANARY}" TWS_PASSWROD="${CANARY}" \
    TWS_PASSWORD_PAPER="${CANARY}" VNC_SERVER_PASSWORD="${CANARY}" SSH_PASSPHRASE="${CANARY}"
  no_canary_in_any_mode
}

@test "canary: a password in an unusable secret file appears in no output of any mode" {
  printf '%s\x00%s' "${CANARY}" "${CANARY}" >"${T}/secrets/p"
  no_canary_in_any_mode
  printf '\xff\xfe%s' "${CANARY}" >"${T}/secrets/p"
  no_canary_in_any_mode
}
