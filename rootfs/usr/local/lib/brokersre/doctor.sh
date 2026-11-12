#!/usr/bin/env bash
# doctor: preflight for the gateway container. It answers "will this container start and log
# in, and if not, what do I change?" before IBC is started, from the environment alone.
#
# Usage: doctor [--json] [--online] [--startup]
#   (no option)  an aligned table, one row per result, and a one-line summary;
#   --json       one JSON document on one line:
#                {"schema":"brokersre.doctor.v1","result":"pass|warn|fail",
#                 "checks":[{"name":"...","status":"pass|warn|fail|skip","detail":"...","fix":"..."}]}
#   --online     also test that IBKR's login servers accept a TCP connection (5 s per server);
#   --startup    for the entrypoint: no table; one log-contract event per WARN and per FAIL and
#                a final doctor_ok when nothing failed (see doctor_emit_startup).
# Exit status: 0 when no check failed, 1 when at least one did, 2 for a usage error. With
#   --startup and DOCTOR_STRICT=no a failure is logged and the status is 0.
# Environment read besides the image's documented variables: STRICT_ENV=yes (ignored variables
#   fail instead of warn), DOCTOR_STRICT=no, DISK_MIN_FREE_PCT (default 10), CGROUP_ROOT
#   (default /sys/fs/cgroup) and DOCTOR_TCP (a command taking host and port that replaces the
#   TCP probe; both exist for the tests).
#
# Design rules:
#   - Every check is one function check_<name> that prints one or more result lines
#     `STATUS|name|detail|fix` (STATUS is PASS, WARN, FAIL or SKIP) and nothing else. A check
#     that cannot measure prints SKIP with the reason, never PASS.
#   - Each check runs in its own subshell with its stderr discarded: a check that crashes is
#     reported as FAIL "check crashed" and the remaining checks still run.
#   - Nothing here prints a secret, its length, or the value of a variable that could hold one
#     by mistake (a *_FILE variable, an unknown variable): such variables are named, never
#     quoted. Secret files are examined with bash builtins only, so no secret reaches `ps`.
#   - Checks never change anything: no directory is created, no file is written.
#   - Pure bash plus coreutils; no time-zone database is needed or used.
#
# The file is both the executable and a library: sourcing it defines the functions and runs
# nothing, which is how tests/bats/unit/doctor.bats calls single checks.

# shellcheck source=/dev/null
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/log.sh"

# The checks in the order they run and are reported. `ibkr_reachable` is appended by --online.
doctor_checks=(trading_mode credentials secret_values auto_restart_time restart_window time_zone
  ignored_variables writable_dirs heap_vs_memory read_only_api relay_exposure disk_space)

# Every variable this image reads: the ones documented in docs/env-vars.md (a unit test keeps
# the two in step), the ones newer components read, and the image's own ENV. A variable that
# starts with one of doctor_watched_prefixes and is not listed here is reported as a typo.
doctor_known_names=(
  TWS_USERID TWS_USERID_FILE TWS_PASSWORD TWS_PASSWORD_FILE TRADING_MODE READ_ONLY_API
  TWOFA_TIMEOUT_ACTION RELOGIN_AFTER_TWOFA_TIMEOUT TWOFA_EXIT_INTERVAL TWOFA_DEVICE
  EXISTING_SESSION_DETECTED_ACTION AUTO_RESTART_TIME AUTO_LOGOFF_TIME TIME_ZONE TWS_SETTINGS_PATH
  TWS_ACCEPT_INCOMING ALLOW_BLIND_TRADING BYPASS_WARNING SAVE_TWS_SETTINGS TWS_MASTER_CLIENT_ID
  IBC_COMMAND_SERVER_PORT IBC_SUPPRESS_INFO_MESSAGES VNC_SERVER_PASSWORD VNC_SERVER_PASSWORD_FILE
  CUSTOM_CONFIG IBC_LAUNCH SOCAT_RESTART_DELAY JAVA_USER_HOME _JAVA_OPTIONS LOG_MAX_BYTES LOG_KEEP
  JAVA_HEAP_MB RELAY_MODE TWOFA_MAX_PROMPTS LOGIN_STALL_S DOCTOR_STRICT STRICT_ENV SAMPLE_INTERVAL_S
  DISK_MIN_FREE_PCT IBGW_INSTANCE BOOT_ID DOCTOR_TCP
  IB_GATEWAY_VERSION IB_GATEWAY_CHANNEL IBC_VERSION IBC_RELEASE_TAG IBC_PATH TWS_PATH LOG_DIR
  RUN_DIR IBC_PATTERNS IBC_TEMPLATE JTS_TEMPLATE BROKERSRE_LIB
)

# Name prefixes that belong to this image: an unknown variable with one of them is most likely
# a misspelt or outdated setting, and a setting that is silently ignored is the worst kind.
doctor_watched_prefixes=(TWS_ TWOFA_ IBC_ AUTO_ JAVA_ VNC_ LOG_ RELAY_ DOCTOR_)

# IBKR's server reset windows, each in its own local time: the list of docs/env-vars.md
# (AUTO_RESTART_TIME) plus the Saturday window. Disconnects are normal inside them.
doctor_reset_windows="North America 00:15-01:45 America/New_York, Europe 06:25-07:45 Europe/Zurich (CET), Asia 04:45-06:05 and 20:15-21:15 Asia/Hong_Kong, Saturday 00:00-02:00 America/New_York"

# The event a WARN of an ordinary check becomes in --startup mode. `config_deprecated` (ignored
# variables), `doctor_failed` and `doctor_ok` are fixed by the log contract.
doctor_warning_event="doctor_warning"

# Results of the current run, filled by doctor_run_check: four parallel arrays, one entry per
# result line.
doctor_r_status=()
doctor_r_name=()
doctor_r_detail=()
doctor_r_fix=()

# doctor_result STATUS NAME DETAIL [FIX]: print one result line `STATUS|NAME|DETAIL|FIX`.
#
# Contract: exactly one line; control characters in DETAIL and FIX become spaces and `|`
# becomes `/`, so a value taken from the environment can neither break the four-field format
# nor move the terminal cursor. Callers pass names of variables that may hold secrets, never
# their values.
doctor_result() {
  local status="$1" name="$2" detail="${3:-}" fix="${4:-}"
  detail="${detail//[[:cntrl:]]/ }"
  detail="${detail//|/\/}"
  fix="${fix//[[:cntrl:]]/ }"
  fix="${fix//|/\/}"
  printf '%s|%s|%s|%s\n' "${status}" "${name}" "${detail}" "${fix}"
}

# doctor_clip VALUE: print VALUE cut to 40 characters (with `...` when cut), for quoting a
# non-secret setting in a detail without letting a pasted blob flood the table.
doctor_clip() {
  local value="$1"
  if [ "${#value}" -gt 40 ]; then
    printf '%s...' "${value:0:40}"
  else
    printf '%s' "${value}"
  fi
}

# doctor_levenshtein A B [MAX]: print the edit distance between A and B (insertions, deletions
# and substitutions each cost 1).
#
# With MAX the computation stops as soon as the distance must exceed MAX and prints a number
# greater than MAX (not necessarily the exact distance); this keeps the typo search over all
# known names fast. Two rows of the classic dynamic-programming table are kept.
doctor_levenshtein() {
  local a="$1" b="$2" max="${3:-}"
  local -i i j cost best row_min la=${#a} lb=${#b}
  local -a prev=() cur=()
  for ((j = 0; j <= lb; j++)); do prev[j]=${j}; done
  for ((i = 1; i <= la; i++)); do
    cur=("${i}")
    row_min=${i}
    for ((j = 1; j <= lb; j++)); do
      cost=1
      if [ "${a:i-1:1}" = "${b:j-1:1}" ]; then cost=0; fi
      best=$((prev[j] + 1))
      if ((cur[j - 1] + 1 < best)); then best=$((cur[j - 1] + 1)); fi
      if ((prev[j - 1] + cost < best)); then best=$((prev[j - 1] + cost)); fi
      cur[j]=${best}
      if ((best < row_min)); then row_min=${best}; fi
    done
    if [ -n "${max}" ] && ((row_min > max)); then
      printf '%d' $((max + 1))
      return 0
    fi
    prev=("${cur[@]}")
  done
  printf '%d' "${prev[lb]}"
}

# doctor_known_variables: print every known variable name, one per line (doctor_known_names).
doctor_known_variables() {
  printf '%s\n' "${doctor_known_names[@]}"
}

# doctor_closest_known NAME: print the known variable name closest to NAME when it is at most
# two edits away (the first such name on a tie), or nothing. Names whose length differs by
# more than two cannot be that close and are skipped without computing a distance.
doctor_closest_known() {
  local name="$1" known best="" distance
  local -i best_distance=3 difference
  for known in "${doctor_known_names[@]}"; do
    difference=$((${#known} - ${#name}))
    if ((difference > 2 || difference < -2)); then continue; fi
    distance="$(doctor_levenshtein "${name}" "${known}" 2)"
    if ((distance < best_distance)); then
      best_distance=${distance}
      best="${known}"
    fi
  done
  printf '%s' "${best}"
}

# doctor_trim VALUE: print VALUE without leading and trailing whitespace. IBC trims every
# setting it reads from config.ini (DefaultSettings.getString), so a check that judges what
# IBC will see trims first.
doctor_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

# doctor_time_minutes VALUE: print the minutes after midnight of a time in IBC's format
# `hh:mm AM/PM`: a two-digit hour 00-12 (00 means 12), a colon, two-digit minutes, exactly one
# space, upper-case AM or PM.
#
# Returns 1 and prints nothing for anything else. The grammar is what IBC 3.24.2 accepts: it
# parses AutoRestartTime and AutoLogoffTime with DateTimeFormatter.ofPattern("hh:mm a")
# (ConfigureAutoLogoffOrRestartTimeTask), which rejects a one-digit hour (`1:05 AM`), lower
# case, a missing or doubled space and a 24-hour time; measured with the IBC.jar of the image
# on 2026-11-12. IBC does not apply a value it cannot parse, so "does it parse" is the check.
# VALUE is taken as given: trim it first (doctor_trim) where IBC would.
doctor_time_minutes() {
  local value="$1" pattern='^(0[0-9]|1[0-2]):([0-5][0-9]) (AM|PM)$'
  local -i hour minute
  local LC_ALL=C
  if ! [[ "${value}" =~ ${pattern} ]]; then return 1; fi
  hour=$((10#${BASH_REMATCH[1]}))
  minute=$((10#${BASH_REMATCH[2]}))
  if ((hour == 12)); then hour=0; fi
  if [ "${BASH_REMATCH[3]}" = "PM" ]; then hour=$((hour + 12)); fi
  printf '%d' $((hour * 60 + minute))
}

# doctor_suggest_time VALUE: print VALUE rewritten in IBC's format when its meaning is clear
# (a one-digit hour, a 24-hour time, a missing or doubled space, lower-case am/pm, trailing
# seconds), or nothing when it is not. Always returns 0. The result always has a two-digit
# hour, because IBC rejects anything else.
doctor_suggest_time() {
  local value half minute pattern='^([0-9]{1,2}):([0-9]{2})(:[0-9]{2})?[[:space:]]*([AaPp][Mm])?$'
  local -i hour
  local LC_ALL=C
  value="$(doctor_trim "$1")"
  if ! [[ "${value}" =~ ${pattern} ]]; then return 0; fi
  hour=$((10#${BASH_REMATCH[1]}))
  minute="${BASH_REMATCH[2]}"
  half="${BASH_REMATCH[4]^^}"
  if ((10#${minute} > 59)); then return 0; fi
  if [ -n "${half}" ]; then
    if ((hour > 12)); then return 0; fi
  else
    if ((hour > 23)); then return 0; fi
    half=AM
    if ((hour >= 12)); then half=PM; fi
    hour=$((hour % 12))
  fi
  if ((hour == 0)); then hour=12; fi
  printf '%02d:%s %s' "${hour}" "${minute}" "${half}"
}

# doctor_bad_time_result NAME VAR VALUE: print the FAIL line for a time VAR=VALUE that IBC
# cannot parse and therefore does not apply, with VALUE corrected in the fix when
# doctor_suggest_time can.
doctor_bad_time_result() {
  local name="$1" var="$2" value="$3" suggestion fix
  suggestion="$(doctor_suggest_time "${value}")"
  if [ -n "${suggestion}" ]; then
    fix="set ${var}=${suggestion}"
  else
    fix="use hh:mm AM/PM with a two-digit hour, one space and upper-case AM or PM, for example ${var}=11:45 PM"
  fi
  doctor_result FAIL "${name}" "${var} '$(doctor_clip "${value}")' is not in IBC's format hh:mm AM/PM (two-digit hour, one space, upper-case AM or PM); IBC does not apply a malformed value" "${fix}"
}

# doctor_secret_file_state PATH: classify a secret file without revealing anything about its
# content. Prints one token:
#   missing      nothing exists at PATH
#   not_regular  PATH is not a regular file (typically a directory Docker created for a bind
#                mount whose host file did not exist)
#   unreadable   this user cannot read it
#   utf16        it contains a NUL byte or starts with a UTF-16 byte-order mark (FF FE / FE FF)
#   empty        nothing is left after removing a UTF-8 byte-order mark and trailing CR/LF
#   ok           usable as it is
#   ok_bom, ok_eol, ok_bom_eol   usable; the entrypoint will strip a UTF-8 byte-order mark
#                and/or trailing line endings
#
# Why not read_secret_file (common.sh): that function exits the shell on a bad file, by design;
# the detection here is the same. Only bash builtins touch the content and it stays in a local
# variable. `read -d ''` succeeds only when it meets a NUL byte; when it fails it has read the
# whole file, trailing line endings included (a command substitution would drop those).
doctor_secret_file_state() {
  local path="$1" content="" has_nul=no bom="" eol=""
  # Byte semantics for the prefix and suffix tests, whatever locale the container has.
  local LC_ALL=C
  if [ ! -e "${path}" ]; then
    printf 'missing'
    return 0
  fi
  if [ ! -f "${path}" ]; then
    printf 'not_regular'
    return 0
  fi
  if [ ! -r "${path}" ]; then
    printf 'unreadable'
    return 0
  fi
  if IFS= read -r -d '' content <"${path}"; then has_nul=yes; fi
  case "${content}" in
    $'\xff\xfe'* | $'\xfe\xff'*) has_nul=yes ;;
  esac
  if [ "${has_nul}" = "yes" ]; then
    printf 'utf16'
    return 0
  fi
  if [[ "${content}" == $'\xef\xbb\xbf'* ]]; then
    bom="_bom"
    content="${content#$'\xef\xbb\xbf'}"
  fi
  while [[ "${content}" == *$'\r' || "${content}" == *$'\n' ]]; do
    content="${content%?}"
    eol="_eol"
  done
  if [ -z "${content}" ]; then
    printf 'empty'
    return 0
  fi
  printf 'ok%s%s' "${bom}" "${eol}"
}

# doctor_existing_ancestor PATH: print PATH when it exists, else its nearest existing parent
# directory (`/` or `.` at the latest). Used to judge a directory that does not exist yet by
# the place it would be created in, without creating it.
doctor_existing_ancestor() {
  local path="$1"
  while [ ! -e "${path}" ]; do
    case "${path}" in
      */*)
        path="${path%/*}"
        if [ -z "${path}" ]; then path="/"; fi
        ;;
      *) path="." ;;
    esac
  done
  printf '%s' "${path}"
}

# doctor_dir_state PATH: print `<state> <decisive path>` for a directory the container must be
# able to write, without creating anything:
#   ok             PATH is a directory this user can write and enter
#   creatable      PATH does not exist; its nearest existing parent is writable
#   not_dir        PATH exists and is not a directory
#   not_writable   PATH is a directory this user cannot write
#   not_creatable  PATH does not exist and its nearest existing parent is not a writable directory
# The decisive path is PATH itself or that parent.
doctor_dir_state() {
  local path="$1" anchor
  if [ -e "${path}" ]; then
    if [ ! -d "${path}" ]; then
      printf 'not_dir %s' "${path}"
    elif [ -w "${path}" ] && [ -x "${path}" ]; then
      printf 'ok %s' "${path}"
    else
      printf 'not_writable %s' "${path}"
    fi
    return 0
  fi
  anchor="$(doctor_existing_ancestor "${path}")"
  if [ -d "${anchor}" ] && [ -w "${anchor}" ] && [ -x "${anchor}" ]; then
    printf 'creatable %s' "${anchor}"
  else
    printf 'not_creatable %s' "${anchor}"
  fi
}

# doctor_tcp_connect HOST PORT: true when a TCP connection to HOST:PORT succeeds within 5 s.
# Prints nothing. DOCTOR_TCP, when set, is run instead with HOST and PORT (the tests' stub, like
# HEALTHCHECK_TCP in healthcheck.sh). Host and port reach the inner shell as arguments, never
# as script text.
doctor_tcp_connect() {
  if [ -n "${DOCTOR_TCP:-}" ]; then
    ${DOCTOR_TCP} "$1" "$2" >/dev/null 2>&1
    return $?
  fi
  # shellcheck disable=SC2016  # $1 and $2 belong to the inner shell
  timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$1" "$2" >/dev/null 2>&1
}

# check_trading_mode: TRADING_MODE is `live` or `paper`.
#
# FAIL otherwise, because the entrypoint stops on any other value; `both` (gnzsnz's dual mode)
# gets the specific fix: one brokerage session per container.
check_trading_mode() {
  local name=trading_mode mode="${TRADING_MODE:-}"
  case "${mode}" in
    live | paper)
      doctor_result PASS "${name}" "TRADING_MODE=${mode}"
      ;;
    both)
      doctor_result FAIL "${name}" "TRADING_MODE=both is not supported" \
        "one session per container: run two containers with two IBKR usernames, one with TRADING_MODE=live and one with TRADING_MODE=paper"
      ;;
    "")
      doctor_result FAIL "${name}" "TRADING_MODE is not set" "set TRADING_MODE=live or TRADING_MODE=paper"
      ;;
    *)
      doctor_result FAIL "${name}" "TRADING_MODE must be live or paper (got '$(doctor_clip "${mode}")')" \
        "set TRADING_MODE=live or TRADING_MODE=paper"
      ;;
  esac
}

# check_credentials: the username and the password each come from exactly one place, and a
# secret file is one the entrypoint will accept.
#
# Unless CUSTOM_CONFIG=yes: exactly one of VAR and VAR_FILE is set for TWS_USERID and for
# TWS_PASSWORD (FAIL when none or both), and a *_FILE points at a regular, readable, non-empty
# file that is not UTF-16 (FAIL with the fix). A UTF-8 byte-order mark or trailing CR/LF is a
# PASS whose detail says it will be stripped. With CUSTOM_CONFIG=yes only ${RUN_DIR}/config.ini
# must be readable.
# Prints one FAIL per problem, or one PASS. Never prints a credential, its length, or the value
# of a *_FILE variable (someone may have put the password there instead of a path).
check_credentials() {
  local name=credentials var file_var state role ini
  local -i problems=0
  local -a sources=() notes=()
  if [ "${CUSTOM_CONFIG:-no}" = "yes" ]; then
    ini="${RUN_DIR:-/run/brokersre}/config.ini"
    if [ -f "${ini}" ] && [ -r "${ini}" ]; then
      doctor_result PASS "${name}" "CUSTOM_CONFIG=yes: the operator-supplied ${ini} is readable; TWS_USERID and TWS_PASSWORD are not used"
    else
      doctor_result FAIL "${name}" "CUSTOM_CONFIG=yes but ${ini} is not a readable file" \
        "mount your IBC config.ini at ${ini}, readable by uid ${UID}, or set CUSTOM_CONFIG=no"
    fi
    return 0
  fi
  for var in TWS_USERID TWS_PASSWORD; do
    file_var="${var}_FILE"
    role="username"
    if [ "${var}" = "TWS_PASSWORD" ]; then role="password"; fi
    if [ -n "${!var:-}" ] && [ -n "${!file_var:-}" ]; then
      doctor_result FAIL "${name}" "both ${var} and ${file_var} are set" "set exactly one of them; prefer ${file_var} (a Docker secret)"
      problems=$((problems + 1))
      continue
    fi
    if [ -z "${!var:-}" ] && [ -z "${!file_var:-}" ]; then
      doctor_result FAIL "${name}" "neither ${var} nor ${file_var} is set" \
        "set ${file_var} to the path of a file inside the container that holds the ${role} (a Docker secret)"
      problems=$((problems + 1))
      continue
    fi
    if [ -n "${!var:-}" ]; then
      sources+=("${role} from ${var}")
      continue
    fi
    state="$(doctor_secret_file_state "${!file_var}")"
    case "${state}" in
      ok) ;;
      ok_bom) notes+=("${file_var} has a UTF-8 byte-order mark that will be stripped") ;;
      ok_eol) notes+=("${file_var} has a trailing line ending that will be stripped") ;;
      ok_bom_eol) notes+=("${file_var} has a UTF-8 byte-order mark and a trailing line ending that will be stripped") ;;
      missing)
        doctor_result FAIL "${name}" "${file_var} points at a file that does not exist" \
          "mount the secret file into the container and set ${file_var} to its path inside the container"
        ;;
      not_regular)
        doctor_result FAIL "${name}" "${file_var} points at something that is not a regular file" \
          "Docker creates a directory when the host file of a bind mount does not exist: remove that directory on the host, create the secret file, then start again"
        ;;
      unreadable)
        doctor_result FAIL "${name}" "${file_var} points at a file that is not readable by uid ${UID}" \
          "make the secret file readable by uid ${UID} (for example chmod 0444 on the host)"
        ;;
      utf16)
        doctor_result FAIL "${name}" "${file_var} is not UTF-8 text: it holds NUL bytes or a UTF-16 byte-order mark, which is what Windows PowerShell 5.1 '>' and Out-File write (UTF-16)" \
          "write the file as UTF-8 without a byte-order mark, for example in PowerShell: [IO.File]::WriteAllText(<full path>, <value>)"
        ;;
      empty)
        doctor_result FAIL "${name}" "${file_var} points at an empty file" "write the ${role} into the file"
        ;;
      *)
        doctor_result FAIL "${name}" "${file_var} could not be examined" "check the file ${file_var} points at"
        ;;
    esac
    case "${state}" in
      ok*) sources+=("${role} from ${file_var}") ;;
      *) problems=$((problems + 1)) ;;
    esac
  done
  if ((problems == 0)); then
    local detail="${sources[0]}, ${sources[1]}" note
    for note in "${notes[@]}"; do detail+="; ${note}"; done
    doctor_result PASS "${name}" "${detail}"
  fi
  return 0
}

# check_secret_values: a password passed in a plain environment variable is a WARN, one per
# variable (TWS_PASSWORD, VNC_SERVER_PASSWORD), because `docker inspect` shows it to anyone who
# can reach the Docker API; the fix is the *_FILE form. One PASS otherwise. Names only.
check_secret_values() {
  local name=secret_values var
  local -i found=0
  for var in TWS_PASSWORD VNC_SERVER_PASSWORD; do
    if [ -n "${!var:-}" ]; then
      doctor_result WARN "${name}" "${var} is passed in a plain environment variable, which is visible in docker inspect" \
        "use ${var}_FILE (a Docker secret)"
      found=$((found + 1))
    fi
  done
  if ((found == 0)); then
    doctor_result PASS "${name}" "no password is passed in a plain environment variable"
  fi
  return 0
}

# check_auto_restart_time: AUTO_RESTART_TIME and AUTO_LOGOFF_TIME are in IBC's format.
#
# AUTO_RESTART_TIME empty: WARN (without a daily restart the Gateway logs off daily and needs
# a full login). Malformed: FAIL with the corrected value, since IBC does not apply it and the
# operator finds out a day later, when the session is gone. AUTO_LOGOFF_TIME, when set, gets
# the same format check; a valid one next to a valid restart time is a WARN, because IBC then
# ignores the logoff ("AutoLogoffTime is ignored because AutoRestartTime is also set").
# Both values are trimmed first, as IBC trims them.
check_auto_restart_time() {
  local name=auto_restart_time restart logoff restart_valid=no
  restart="$(doctor_trim "${AUTO_RESTART_TIME:-}")"
  logoff="$(doctor_trim "${AUTO_LOGOFF_TIME:-}")"
  if [ -z "${restart}" ]; then
    doctor_result WARN "${name}" "no daily restart configured: the Gateway logs off daily and needs a full login" \
      "set AUTO_RESTART_TIME, for example AUTO_RESTART_TIME=11:45 PM"
  elif doctor_time_minutes "${restart}" >/dev/null; then
    doctor_result PASS "${name}" "AUTO_RESTART_TIME=${restart}"
    restart_valid=yes
  else
    doctor_bad_time_result "${name}" AUTO_RESTART_TIME "${restart}"
  fi
  if [ -n "${logoff}" ]; then
    if ! doctor_time_minutes "${logoff}" >/dev/null; then
      doctor_bad_time_result "${name}" AUTO_LOGOFF_TIME "${logoff}"
    elif [ "${restart_valid}" = "yes" ]; then
      doctor_result WARN "${name}" "AUTO_RESTART_TIME and AUTO_LOGOFF_TIME are both set: IBC ignores AUTO_LOGOFF_TIME when a restart time is set" \
        "remove AUTO_LOGOFF_TIME"
    fi
  fi
  return 0
}

# check_restart_window: the daily restart does not fall into one of IBKR's reset windows.
#
# The image has no time-zone database, so only a same-zone comparison is possible: when
# TIME_ZONE is in the zone a window is defined in (or a zone with the same wall clock), the
# restart time is compared with that region's window(s), both ends included: inside is a WARN
# with the window and a time that is outside every window, outside is a PASS. For New York
# time the Saturday window counts too, because a daily restart also runs on Saturday. Any
# other zone, an unset or a malformed restart time: SKIP with the reason. The restart time is
# trimmed first, as IBC trims it.
check_restart_window() {
  local name=restart_window restart zone="${TIME_ZONE:-}" where
  local -i minutes
  local fix="move the restart outside the window, for example AUTO_RESTART_TIME=11:45 PM"
  restart="$(doctor_trim "${AUTO_RESTART_TIME:-}")"
  if [ -z "${restart}" ]; then
    doctor_result SKIP "${name}" "AUTO_RESTART_TIME is not set: there is no restart time to compare with IBKR's reset windows"
    return 0
  fi
  if ! minutes="$(doctor_time_minutes "${restart}")"; then
    doctor_result SKIP "${name}" "AUTO_RESTART_TIME is not in IBC's format (see auto_restart_time): there is no restart time to compare"
    return 0
  fi
  where="AUTO_RESTART_TIME ${restart} (${zone})"
  case "${zone}" in
    America/New_York | US/Eastern)
      if ((minutes >= 15 && minutes <= 105)); then
        doctor_result WARN "${name}" "${where} is inside IBKR's North America reset window 00:15-01:45 ET" "${fix}"
      elif ((minutes <= 120)); then
        doctor_result WARN "${name}" "${where} is inside IBKR's Saturday reset window 00:00-02:00 ET, and a daily restart also runs on Saturday" "${fix}"
      else
        doctor_result PASS "${name}" "${where} is outside IBKR's North America reset windows (00:15-01:45 daily, Saturday 00:00-02:00 ET)"
      fi
      ;;
    Europe/Zurich | Europe/Berlin | Europe/Paris | Europe/Amsterdam)
      if ((minutes >= 385 && minutes <= 465)); then
        doctor_result WARN "${name}" "${where} is inside IBKR's Europe reset window 06:25-07:45 CET" "${fix}"
      else
        doctor_result PASS "${name}" "${where} is outside IBKR's Europe reset window (06:25-07:45 CET)"
      fi
      ;;
    Asia/Hong_Kong | Asia/Singapore | Asia/Shanghai)
      if ((minutes >= 285 && minutes <= 365)); then
        doctor_result WARN "${name}" "${where} is inside IBKR's Asia reset window 04:45-06:05 HKT" "${fix}"
      elif ((minutes >= 1215 && minutes <= 1275)); then
        doctor_result WARN "${name}" "${where} is inside IBKR's Asia reset window 20:15-21:15 HKT" "${fix}"
      else
        doctor_result PASS "${name}" "${where} is outside IBKR's Asia reset windows (04:45-06:05 and 20:15-21:15 HKT)"
      fi
      ;;
    *)
      doctor_result SKIP "${name}" "cannot compare without a time-zone database in the image (TIME_ZONE=$(doctor_clip "${zone}")); keep the restart outside IBKR's reset windows: ${doctor_reset_windows}"
      ;;
  esac
  return 0
}

# check_time_zone: TIME_ZONE looks like an IANA zone name (`Area/City`, further components
# allowed) or is `UTC`; FAIL otherwise or when it is not set. Only the shape can be tested:
# the image has no zone database to look the name up in.
check_time_zone() {
  local name=time_zone zone="${TIME_ZONE:-}" pattern='^[A-Za-z_]+(/[A-Za-z0-9_+-]+)+$'
  local fix="set TIME_ZONE to an IANA zone name such as America/New_York"
  local LC_ALL=C
  if [ -z "${zone}" ]; then
    doctor_result FAIL "${name}" "TIME_ZONE is not set" "${fix}"
  elif [ "${zone}" = "UTC" ] || [[ "${zone}" =~ ${pattern} ]]; then
    doctor_result PASS "${name}" "TIME_ZONE=${zone}"
  else
    doctor_result FAIL "${name}" "TIME_ZONE '$(doctor_clip "${zone}")' does not look like an IANA zone name (Area/City)" "${fix}"
  fi
}

# check_ignored_variables: every environment variable that this image ignores although its
# name says it was meant for it. One WARN per variable (FAIL with STRICT_ENV=yes), or one PASS.
#
#   - Variables of gnzsnz/ib-gateway-docker that have no effect here, each with its
#     replacement: the *_PAPER credentials, TWS_COLD_RESTART, JAVA_HEAP_SIZE, SSH_*, the hook
#     directories, GATEWAY_OR_TWS.
#   - TZ when TIME_ZONE is unset or still the image default while TZ names another zone.
#   - Likely typos: a name with one of doctor_watched_prefixes that is not in
#     doctor_known_names, with the closest known name when it is at most two edits away.
# Only names are printed: an unknown variable may be a misspelt password variable.
check_ignored_variables() {
  local name=ignored_variables status=WARN var known prefix closest note fix
  local -i found=0
  local -A is_known=()
  if [ "${STRICT_ENV:-no}" = "yes" ]; then status=FAIL; fi
  for known in "${doctor_known_names[@]}"; do is_known["${known}"]=1; done
  while IFS= read -r var; do
    if [ -z "${var}" ]; then continue; fi
    note=""
    case "${var}" in
      TWS_USERID_PAPER | TWS_PASSWORD_PAPER | TWS_PASSWORD_PAPER_FILE)
        note="dual mode was removed"
        fix="one container per session: run a second container with TRADING_MODE=paper and its own TWS_USERID_FILE and TWS_PASSWORD_FILE"
        ;;
      TWS_COLD_RESTART)
        note="a cold restart is not supported"
        fix="use AUTO_RESTART_TIME"
        ;;
      JAVA_HEAP_SIZE)
        note="it was renamed"
        fix="use JAVA_HEAP_MB"
        ;;
      SSH_*)
        note="the SSH tunnel was removed"
        fix="use a private network or a sidecar that shares the gateway's network namespace"
        ;;
      START_SCRIPTS | X_SCRIPTS | IBC_SCRIPTS)
        note="hook scripts were removed"
        fix="remove it and run such steps outside this container"
        ;;
      GATEWAY_OR_TWS)
        note="this image runs IB Gateway only"
        fix="remove it"
        ;;
    esac
    if [ -n "${note}" ]; then
      doctor_result "${status}" "${name}" "${var} is ignored: ${note}" "${fix}"
      found=$((found + 1))
      continue
    fi
    if [ "${var}" = "TZ" ]; then
      if [ -n "${TZ:-}" ] && [ "${TZ}" != "UTC" ] && [ "${TZ}" != "Etc/UTC" ] \
        && { [ -z "${TIME_ZONE:-}" ] || [ "${TIME_ZONE}" = "Etc/UTC" ]; }; then
        doctor_result "${status}" "${name}" "TZ is set while TIME_ZONE is unset or still the default Etc/UTC: the Gateway takes its time zone from TIME_ZONE, not from TZ" "use TIME_ZONE"
        found=$((found + 1))
      fi
      continue
    fi
    if [ -n "${is_known[${var}]:-}" ]; then continue; fi
    for prefix in "${doctor_watched_prefixes[@]}"; do
      if [[ "${var}" != "${prefix}"* ]]; then continue; fi
      closest="$(doctor_closest_known "${var}")"
      if [ -n "${closest}" ]; then
        fix="did you mean ${closest}?"
      else
        fix="check the name against docs/env-vars.md, or remove it"
      fi
      doctor_result "${status}" "${name}" "${var} is an unknown variable, ignored by this image" "${fix}"
      found=$((found + 1))
      break
    done
  done < <(compgen -e | LC_ALL=C sort)
  if ((found == 0)); then
    doctor_result PASS "${name}" "no ignored or unknown variable in the environment"
  fi
  return 0
}

# check_writable_dirs: LOG_DIR, RUN_DIR, TWS_SETTINGS_PATH and the Java home (JAVA_USER_HOME,
# default ${TWS_SETTINGS_PATH}/.java-home) exist or can be created, and are writable by this
# uid. One FAIL per directory that is not, with the tmpfs uid/gid fix (a tmpfs is root-owned
# 0755 unless its mount options say otherwise), or one PASS. A Java home with whitespace also
# fails: the JVM splits _JAVA_OPTIONS on spaces (java-env.sh). Nothing is created here.
check_writable_dirs() {
  local name=writable_dirs label path state decisive owner gid
  local -i i problems=0
  local settings="${TWS_SETTINGS_PATH:-/home/ibgateway/Jts/settings}"
  local -a labels=(LOG_DIR RUN_DIR TWS_SETTINGS_PATH "Java home")
  local -a paths=("${LOG_DIR:-/var/log/ibgateway}" "${RUN_DIR:-/run/brokersre}" "${settings}"
    "${JAVA_USER_HOME:-${settings}/.java-home}")
  gid="$(id -g)"
  local fix="mount it writable for uid ${UID}: a tmpfs needs the options uid=${UID},gid=${gid} (for example /run/brokersre:uid=${UID},gid=${gid},mode=0750), a volume must be owned by ${UID}:${gid}"
  for i in "${!labels[@]}"; do
    label="${labels[i]}"
    path="${paths[i]}"
    if [ "${label}" = "Java home" ] && [[ "${path}" =~ [[:space:]] ]]; then
      doctor_result FAIL "${name}" "${label} ${path} contains whitespace: the JVM splits its options on spaces and would not find it" \
        "set JAVA_USER_HOME (or TWS_SETTINGS_PATH) to a path without spaces"
      problems=$((problems + 1))
      continue
    fi
    read -r state decisive <<<"$(doctor_dir_state "${path}")"
    case "${state}" in
      ok | creatable) continue ;;
    esac
    owner="$(stat -c '%u:%g mode %a' "${decisive}" 2>/dev/null || printf 'unknown')"
    case "${state}" in
      not_dir)
        doctor_result FAIL "${name}" "${label} ${path} exists but is not a directory" "${fix}"
        ;;
      not_writable)
        doctor_result FAIL "${name}" "${label} ${path} is not writable by uid ${UID} (owner ${owner})" "${fix}"
        ;;
      *)
        doctor_result FAIL "${name}" "${label} ${path} does not exist and cannot be created by uid ${UID}: ${decisive} is not a writable directory (owner ${owner})" "${fix}"
        ;;
    esac
    problems=$((problems + 1))
  done
  if ((problems == 0)); then
    doctor_result PASS "${name}" "LOG_DIR, RUN_DIR, TWS_SETTINGS_PATH and the Java home are writable by uid ${UID}"
  fi
  return 0
}

# check_heap_vs_memory: the Java heap leaves room inside the container's memory limit.
#
# Heap in MB: JAVA_HEAP_MB when it is a number, 768 otherwise; `auto` is half of the limit
# clamped to 768..4096 (768 without a limit). Limit: ${CGROUP_ROOT:-/sys/fs/cgroup}/memory.max
# (cgroup v2), where `max` means none. Heap above 75% of the limit: FAIL (the JVM needs memory
# beyond the heap: metaspace, thread stacks, native buffers, and the kernel kills the container
# at the limit); above 60%: WARN; else PASS. No limit: SKIP, except that `auto` passes with its
# 768. An unreadable or unexpected memory.max: SKIP. The thresholds also apply to `auto`,
# whose 768 MB floor does not fit under a limit below 1024 MB.
check_heap_vs_memory() {
  local name=heap_vs_memory file="${CGROUP_ROOT:-/sys/fs/cgroup}/memory.max" setting="${JAVA_HEAP_MB:-}"
  local raw="" limit="unknown" subject detail
  local -i heap=768 limit_mb=0
  local fix="raise the container memory limit or lower the heap (JAVA_HEAP_MB)"
  local LC_ALL=C
  if [ -r "${file}" ]; then read -r raw <"${file}" || true; fi
  if [ "${raw}" = "max" ] || [[ "${raw}" =~ ^[0-9]{16,}$ ]]; then
    # A number this large (9 PB and more) is how "unlimited" looks when it is not spelt `max`.
    limit="none"
  elif [[ "${raw}" =~ ^[0-9]+$ ]]; then
    limit_mb=$((10#${raw} / 1048576))
    if ((limit_mb >= 1)); then limit="set"; fi
  fi
  if [ "${limit}" = "unknown" ]; then
    doctor_result SKIP "${name}" "cannot read a memory limit from ${file} (cgroup v2 memory.max is missing, unreadable or unexpected)"
    return 0
  fi
  if [ "${setting}" = "auto" ]; then
    if [ "${limit}" = "none" ]; then
      doctor_result PASS "${name}" "JAVA_HEAP_MB=auto resolves to heap 768 MB (no memory limit is set on the container)"
      return 0
    fi
    heap=$((limit_mb / 2))
    if ((heap < 768)); then heap=768; fi
    if ((heap > 4096)); then heap=4096; fi
    subject="JAVA_HEAP_MB=auto resolves to heap ${heap} MB (half of the limit, clamped to 768..4096), which"
  elif [[ "${setting}" =~ ^[1-9][0-9]{0,8}$ ]]; then
    heap=${setting}
    subject="heap ${heap} MB (JAVA_HEAP_MB)"
  elif [ -n "${setting}" ]; then
    subject="heap ${heap} MB (JAVA_HEAP_MB is not a number of megabytes, so the default applies)"
  else
    subject="heap ${heap} MB (default)"
  fi
  if [ "${limit}" = "none" ]; then
    doctor_result SKIP "${name}" "no memory limit is set on the container, so ${subject} cannot be compared with one" \
      "set a memory limit (for example mem_limit: 2g) so that a runaway process cannot take the host down"
    return 0
  fi
  detail="${subject} is $((heap * 100 / limit_mb))% of the ${limit_mb} MB memory limit"
  if ((heap * 100 > limit_mb * 75)); then
    doctor_result FAIL "${name}" "${detail}; the JVM needs memory beyond the heap" "${fix}"
  elif ((heap * 100 > limit_mb * 60)); then
    doctor_result WARN "${name}" "${detail}; the JVM needs memory beyond the heap" "${fix}"
  else
    doctor_result PASS "${name}" "${detail}"
  fi
  return 0
}

# check_read_only_api: a live session whose API accepts orders is worth a reminder.
#
# READ_ONLY_API=yes: PASS. TRADING_MODE=paper: PASS. TRADING_MODE=live with READ_ONLY_API=no:
# WARN (API clients can place orders; it may be intended, so it is not a FAIL). Anything else
# cannot be judged: SKIP.
check_read_only_api() {
  local name=read_only_api mode="${TRADING_MODE:-}" read_only="${READ_ONLY_API:-}"
  if [ "${read_only}" = "yes" ]; then
    doctor_result PASS "${name}" "READ_ONLY_API=yes: API clients cannot place orders"
  elif [ "${mode}" = "paper" ]; then
    doctor_result PASS "${name}" "TRADING_MODE=paper: API clients can place orders in the paper account only"
  elif [ "${mode}" = "live" ] && [ "${read_only}" = "no" ]; then
    doctor_result WARN "${name}" "TRADING_MODE=live with READ_ONLY_API=no: API clients can place orders in the live account" \
      "set READ_ONLY_API=yes unless this gateway must take orders, and let only trusted hosts reach the API port"
  elif [ "${mode}" = "live" ]; then
    doctor_result SKIP "${name}" "READ_ONLY_API is neither yes nor no, so this check cannot tell whether API clients can place orders" \
      "set READ_ONLY_API=yes or READ_ONLY_API=no"
  else
    doctor_result SKIP "${name}" "TRADING_MODE is neither live nor paper (see trading_mode)"
  fi
}

# check_relay_exposure: always SKIP. The container cannot see how the host publishes the relay
# port, so it cannot tell whether the API is reachable from the internet; the result carries
# the advice instead of a verdict.
check_relay_exposure() {
  local name=relay_exposure port="4003 (live) or 4004 (paper)"
  case "${TRADING_MODE:-}" in
    live) port="4003" ;;
    paper) port="4004" ;;
  esac
  doctor_result SKIP "${name}" "the container cannot see how the host publishes the relay port" \
    "publish relay port ${port} on 127.0.0.1 or a private address only, never on 0.0.0.0 of a host the internet can reach"
}

# check_disk_space: free space of the filesystems that hold LOG_DIR and TWS_SETTINGS_PATH.
#
# Free below 2%: FAIL; below DISK_MIN_FREE_PCT (default 10, a bad value means 10): WARN; else
# PASS. One result per filesystem: when both paths are on the same one it is reported once,
# naming both, so a full disk is one finding and not two. Two paths are on the same filesystem
# when df names the same block device or share for them (two named volumes on one Docker data
# disk have different mount points and the same device); a filesystem without a device path
# (tmpfs, overlay) is identified by its mount point, because that name is not unique.
# A path that does not exist yet is measured on its nearest existing parent. `df -P -k` runs
# under a 5 s timeout (a dead network mount must not hang the preflight); when df fails or its
# answer cannot be parsed the result is SKIP. Free is Available / (Used + Available), which is
# how df itself computes Capacity.
check_disk_space() {
  local name=disk_space minimum="${DISK_MIN_FREE_PCT:-10}" var path out line device used available mount key
  local label detail
  local -i i total percent
  local -a group_label=() group_key=() group_used=() group_available=()
  local fix="free space or grow the volume; LOG_MAX_BYTES and LOG_KEEP bound the logs the image writes"
  local LC_ALL=C
  if ! [[ "${minimum}" =~ ^[0-9]{1,3}$ ]] || ((10#${minimum} > 100)); then minimum=10; fi
  minimum=$((10#${minimum}))
  for var in LOG_DIR TWS_SETTINGS_PATH; do
    path="${LOG_DIR:-/var/log/ibgateway}"
    if [ "${var}" = "TWS_SETTINGS_PATH" ]; then path="${TWS_SETTINGS_PATH:-/home/ibgateway/Jts/settings}"; fi
    device="" used="" available="" mount=""
    if out="$(timeout 5 df -P -k -- "$(doctor_existing_ancestor "${path}")" 2>/dev/null)"; then
      line="${out##*$'\n'}"
      read -r device _ used available _ mount <<<"${line}" || true
    fi
    if ! [[ "${used}" =~ ^[0-9]+$ && "${available}" =~ ^[0-9]+$ ]] || [ -z "${mount}" ] \
      || ((10#${used} + 10#${available} == 0)); then
      group_label+=("${var}")
      group_key+=("")
      group_used+=(0)
      group_available+=(0)
      continue
    fi
    key="${mount}"
    if [[ "${device}" == /* ]]; then key="${device}"; fi
    for i in "${!group_key[@]}"; do
      if [ "${group_key[i]}" = "${key}" ]; then
        group_label[i]+=" and ${var}"
        continue 2
      fi
    done
    group_label+=("${var}")
    group_key+=("${key}")
    group_used+=("$((10#${used}))")
    group_available+=("$((10#${available}))")
  done
  for i in "${!group_label[@]}"; do
    label="${group_label[i]}"
    if [ -z "${group_key[i]}" ]; then
      doctor_result SKIP "${name}" "cannot measure the free space of the filesystem that holds ${label} (df failed or gave an unexpected answer)"
      continue
    fi
    total=$((group_used[i] + group_available[i]))
    percent=$((group_available[i] * 100 / total))
    detail="${label}: ${percent}% free ($((group_available[i] / 1024)) MB) on ${group_key[i]}"
    if ((group_available[i] * 100 < total * 2)); then
      doctor_result FAIL "${name}" "${detail}; the Gateway cannot write its logs and settings on a full disk" "${fix}"
    elif ((group_available[i] * 100 < total * minimum)); then
      doctor_result WARN "${name}" "${detail}, below DISK_MIN_FREE_PCT=${minimum}" "${fix}"
    else
      doctor_result PASS "${name}" "${detail}"
    fi
  done
  return 0
}

# check_ibkr_reachable (--online only): a TCP connection to one of IBKR's login servers
# (cdc1.ibllc.com:4001, then ndc1.ibllc.com:4001; 5 s each) succeeds: PASS, naming the server.
# Neither: FAIL, which means DNS or an outbound firewall. No data is sent; this is not a login.
check_ibkr_reachable() {
  local name=ibkr_reachable host
  for host in cdc1.ibllc.com ndc1.ibllc.com; do
    if doctor_tcp_connect "${host}" 4001; then
      doctor_result PASS "${name}" "${host}:4001 accepts a TCP connection"
      return 0
    fi
  done
  doctor_result FAIL "${name}" "cannot reach IBKR login servers (DNS or firewall): no TCP connection to cdc1.ibllc.com:4001 or ndc1.ibllc.com:4001 within 5 s each" \
    "check name resolution inside the container and allow outbound TCP port 4001 to IBKR's servers"
}

# doctor_add_result STATUS NAME DETAIL FIX: append one result to the doctor_r_* arrays.
doctor_add_result() {
  doctor_r_status+=("$1")
  doctor_r_name+=("$2")
  doctor_r_detail+=("$3")
  doctor_r_fix+=("$4")
}

# doctor_run_check NAME: run check_NAME isolated and append its results to the doctor_r_*
# arrays. Always returns 0.
#
# Isolation: the check runs in a command-substitution subshell with stderr discarded, so an
# `exit`, an unset variable under nounset or a failing command ends only that check, and a
# stray message (which could quote a value) reaches neither the terminal nor the log. The
# check counts as crashed when it exits non-zero, prints no result, or prints a line that is
# not `STATUS|NAME|detail|fix` for this NAME; valid lines printed before the crash are kept
# and one `FAIL|NAME|check crashed (...)` line is added, so a defect in doctor is never
# mistaken for a pass.
doctor_run_check() {
  local name="$1" out="" line status check_name detail fix crashed=""
  local -i rc=0 added=0
  if ! declare -F "check_${name}" >/dev/null; then
    crashed="no such check"
  else
    out="$("check_${name}" 2>/dev/null)" || rc=$?
    if ((rc != 0)); then crashed="exit status ${rc}"; fi
  fi
  while IFS= read -r line; do
    if [ -z "${line}" ]; then continue; fi
    status="" check_name="" detail="" fix=""
    IFS='|' read -r status check_name detail fix <<<"${line}" || true
    case "${status}" in
      PASS | WARN | FAIL | SKIP)
        if [ "${check_name}" = "${name}" ]; then
          doctor_add_result "${status}" "${name}" "${detail}" "${fix}"
          added=$((added + 1))
          continue
        fi
        ;;
    esac
    if [ -z "${crashed}" ]; then crashed="unexpected output"; fi
  done <<<"${out}"
  if [ -z "${crashed}" ] && ((added == 0)); then crashed="no result"; fi
  if [ -n "${crashed}" ]; then
    doctor_add_result FAIL "${name}" "check crashed (${crashed}); the other checks still ran" \
      "this is a defect in doctor, not in your configuration: report it with the output of doctor --json; DOCTOR_STRICT=no lets the container start meanwhile"
  fi
  return 0
}

# doctor_count STATUS: print how many results of the current run have STATUS.
doctor_count() {
  local status
  local -i count=0
  for status in "${doctor_r_status[@]}"; do
    if [ "${status}" = "$1" ]; then count=$((count + 1)); fi
  done
  printf '%d' "${count}"
}

# doctor_overall: print the result of the run: `fail` with at least one FAIL, else `warn` with
# at least one WARN, else `pass`. A SKIP does not change it; it is counted in the summary.
doctor_overall() {
  if [ "$(doctor_count FAIL)" -gt 0 ]; then
    printf 'fail'
  elif [ "$(doctor_count WARN)" -gt 0 ]; then
    printf 'warn'
  else
    printf 'pass'
  fi
}

# doctor_print_table: print the results as an aligned table (STATUS, CHECK, DETAIL), each fix
# on its own line under the detail it belongs to, then the one-line summary
# `doctor: <result> (<n> passed, <n> warned, <n> failed, <n> skipped)`.
doctor_print_table() {
  local name
  local -i i width=5 indent
  for name in "${doctor_r_name[@]}"; do
    if ((${#name} > width)); then width=${#name}; fi
  done
  indent=$((6 + 2 + width + 2))
  printf '%-6s  %-*s  %s\n' STATUS "${width}" CHECK DETAIL
  for i in "${!doctor_r_status[@]}"; do
    printf '%-6s  %-*s  %s\n' "${doctor_r_status[i]}" "${width}" "${doctor_r_name[i]}" "${doctor_r_detail[i]}"
    if [ -n "${doctor_r_fix[i]}" ]; then
      printf '%*s%s\n' "${indent}" '' "fix: ${doctor_r_fix[i]}"
    fi
  done
  printf 'doctor: %s (%d passed, %d warned, %d failed, %d skipped)\n' "$(doctor_overall)" \
    "$(doctor_count PASS)" "$(doctor_count WARN)" "$(doctor_count FAIL)" "$(doctor_count SKIP)"
}

# doctor_print_json: print the results as one JSON document on one line (schema
# brokersre.doctor.v1, see the file header). Strings are escaped with json_escape (log.sh);
# statuses are lower case; `fix` is an empty string when there is nothing to fix.
doctor_print_json() {
  local out separator=""
  local -i i
  out="{\"schema\":\"brokersre.doctor.v1\",\"result\":\"$(doctor_overall)\",\"checks\":["
  for i in "${!doctor_r_status[@]}"; do
    out+="${separator}{\"name\":\"$(json_escape "${doctor_r_name[i]}")\",\"status\":\"${doctor_r_status[i],,}\""
    out+=",\"detail\":\"$(json_escape "${doctor_r_detail[i]}")\",\"fix\":\"$(json_escape "${doctor_r_fix[i]}")\"}"
    separator=","
  done
  printf '%s]}\n' "${out}"
}

# doctor_emit_startup: report the results as log-contract events (src `doctor`) and decide
# whether the container may start. Returns 0 to start, 1 to stop.
#
#   WARN  -> level warn;  event config_deprecated for ignored_variables, else doctor_warning
#   FAIL  -> level error; event config_deprecated for ignored_variables, else doctor_failed
#   no FAIL -> one final doctor_ok (info) with the counts
# The message is `<check>: <detail> (fix: <fix>)`. PASS and SKIP are not logged one by one.
# DOCTOR_STRICT=no: a FAIL is logged with level warn and does not stop the start (the escape
# hatch for a check that is wrong about an unusual deployment); doctor_ok is still withheld.
doctor_emit_startup() {
  local strict="${DOCTOR_STRICT:-yes}" status name event level message
  local -i i failures=0
  for i in "${!doctor_r_status[@]}"; do
    status="${doctor_r_status[i]}"
    name="${doctor_r_name[i]}"
    case "${status}" in
      WARN)
        level="warn"
        event="${doctor_warning_event}"
        ;;
      FAIL)
        level="error"
        event="doctor_failed"
        failures=$((failures + 1))
        if [ "${strict}" = "no" ]; then level="warn"; fi
        ;;
      *) continue ;;
    esac
    if [ "${name}" = "ignored_variables" ]; then event="config_deprecated"; fi
    message="${name}: ${doctor_r_detail[i]}"
    if [ -n "${doctor_r_fix[i]}" ]; then message+=" (fix: ${doctor_r_fix[i]})"; fi
    log_event doctor "${level}" "${event}" "${message}"
  done
  if ((failures == 0)); then
    log_event doctor info doctor_ok "preflight passed: $(doctor_count PASS) passed, $(doctor_count WARN) warned, $(doctor_count SKIP) skipped"
    return 0
  fi
  if [ "${strict}" = "no" ]; then return 0; fi
  return 1
}

# doctor_usage: print the command-line help.
doctor_usage() {
  printf '%s\n' \
    "usage: doctor [--json] [--online] [--startup]" \
    "  (no option)  table of the preflight checks and a one-line summary" \
    "  --json       one JSON document (schema brokersre.doctor.v1)" \
    "  --online     also test that IBKR's login servers accept a TCP connection" \
    "  --startup    for the entrypoint: log events instead of a table" \
    "exit status: 0 no check failed, 1 at least one check failed, 2 usage error"
}

# doctor_main [--json] [--online] [--startup]: run every check and report in the chosen mode.
#
# Returns 0 when no check failed, 1 when at least one did (with --startup: unless
# DOCTOR_STRICT=no), 2 for an unknown option or for --json together with --startup. Resets and
# fills the doctor_r_* arrays; safe to call from a shell with errexit, nounset and pipefail.
doctor_main() {
  local mode="table" argument name
  local -a checks=("${doctor_checks[@]}")
  local json=no startup=no online=no
  for argument in "$@"; do
    case "${argument}" in
      --json) json=yes ;;
      --startup) startup=yes ;;
      --online) online=yes ;;
      -h | --help)
        doctor_usage
        return 0
        ;;
      *)
        printf 'doctor: unknown option %s\n' "${argument}" >&2
        doctor_usage >&2
        return 2
        ;;
    esac
  done
  if [ "${json}" = "yes" ] && [ "${startup}" = "yes" ]; then
    printf 'doctor: --json and --startup cannot be combined\n' >&2
    return 2
  fi
  if [ "${json}" = "yes" ]; then mode="json"; fi
  if [ "${startup}" = "yes" ]; then mode="startup"; fi
  if [ "${online}" = "yes" ]; then checks+=(ibkr_reachable); fi
  doctor_r_status=()
  doctor_r_name=()
  doctor_r_detail=()
  doctor_r_fix=()
  for name in "${checks[@]}"; do
    doctor_run_check "${name}"
  done
  case "${mode}" in
    startup)
      if doctor_emit_startup; then return 0; fi
      return 1
      ;;
    json) doctor_print_json ;;
    *) doctor_print_table ;;
  esac
  if [ "$(doctor_count FAIL)" -gt 0 ]; then return 1; fi
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  doctor_main "$@"
fi
