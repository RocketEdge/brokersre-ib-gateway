#!/usr/bin/env bash
# migrate-from-gnzsnz.sh: turn the .env of a gnzsnz/ib-gateway-docker deployment into one for
# brokersre-ib-gateway.
#
# Usage: scripts/migrate-from-gnzsnz.sh <gnzsnz.env>  > new.env
#   stdout  the converted file, line for line: line N of the input is line N of the output;
#   stderr  the report: every variable that was dropped, renamed or is unknown, every variable
#           that carries a secret (value hidden), and the defaults that differ.
# Exit status: 0 converted; 1 refused (TRADING_MODE=both; nothing is written to stdout);
#   2 usage error (wrong arguments, unreadable file, a file that is not UTF-8 text).
#
# Rules (docs/migrating-from-gnzsnz.md and the doctor's check_ignored_variables):
#   - a variable both images read under the same name is carried over unchanged;
#   - JAVA_HEAP_SIZE=N becomes JAVA_HEAP_MB=N (N a whole number of megabytes);
#   - TRADING_MODE=both is refused: one brokerage session per container, so "live and paper"
#     is two services (compose/docker-compose.multi.yml);
#   - the *_PAPER credentials, TWS_COLD_RESTART, SSH_*, the hook-script variables and
#     GATEWAY_OR_TWS are dropped; a comment naming the variable takes the line's place;
#   - a variable neither image documents is kept and listed as "unknown, kept";
#   - comments, blank lines and lines that are not assignments are kept as they are;
#   - CRLF line endings and a UTF-8 byte-order mark are removed; the output is LF.
#
# Secrets: a line is copied to stdout or left out; no value ever reaches the report. The report
# names variables and prints `<hidden>` in place of a value, because any value in a .env file
# may be a credential (a misspelt password variable is "unknown"). The only value it quotes is
# the literal `both` of TRADING_MODE. A file a *_FILE variable points at is never opened.
#
# Using the result with compose/docker-compose.example.yml: that file interpolates TRADING_MODE,
# READ_ONLY_API, AUTO_RESTART_TIME and TIME_ZONE from the compose env file
# (`docker compose --env-file new.env ...`) and passes no other variable on, so the remaining
# variables reach the container only when the service also names the file under `env_file:`.
# Move TWS_USERID and TWS_PASSWORD into secret files first: the compose file sets the *_FILE
# forms, and the container refuses to start when both forms are set.
#
# Not supported: values that span several lines. Bash 5 and nothing else, so it runs in Git
# Bash on Windows as well as on Linux and macOS.
set -uo pipefail
# Byte semantics for the patterns below, whatever locale the caller has.
LC_ALL=C

program="migrate-from-gnzsnz"

# Variables this image reads (docs/env-vars.md and the doctor's doctor_known_names; a unit test
# keeps the two in step), the variables the reference compose files interpolate, and TZ, which
# gnzsnz deployments set next to TIME_ZONE and which is harmless here.
known_names=(
  TWS_USERID TWS_USERID_FILE TWS_PASSWORD TWS_PASSWORD_FILE TRADING_MODE READ_ONLY_API
  TWOFA_TIMEOUT_ACTION RELOGIN_AFTER_TWOFA_TIMEOUT TWOFA_EXIT_INTERVAL TWOFA_DEVICE
  EXISTING_SESSION_DETECTED_ACTION AUTO_RESTART_TIME AUTO_LOGOFF_TIME TIME_ZONE TWS_SETTINGS_PATH
  TWS_ACCEPT_INCOMING ALLOW_BLIND_TRADING BYPASS_WARNING SAVE_TWS_SETTINGS TWS_MASTER_CLIENT_ID
  IBC_COMMAND_SERVER_PORT IBC_SUPPRESS_INFO_MESSAGES VNC_SERVER_PASSWORD VNC_SERVER_PASSWORD_FILE
  CUSTOM_CONFIG IBC_LAUNCH SOCAT_RESTART_DELAY JAVA_USER_HOME _JAVA_OPTIONS LOG_MAX_BYTES LOG_KEEP
  JAVA_HEAP_MB RELAY_MODE TWOFA_MAX_PROMPTS LOGIN_STALL_S DOCTOR_STRICT STRICT_ENV SAMPLE_INTERVAL_S
  DISK_MIN_FREE_PCT IBGW_INSTANCE BOOT_ID DOCTOR_TCP DOCTOR_RESULT_FILE HEALTHCHECK_API
  RELAY_ALLOW_CIDR RELAY_REFUSED_REPORT_S
  MEM_HIGH_PCT MEM_HIGH_FOR_S RELAY_POLL_S IBC_KNOWN_WINDOWS IBC_CMD
  IB_GATEWAY_VERSION IB_GATEWAY_CHANNEL IBC_VERSION IBC_RELEASE_TAG IBC_PATH TWS_PATH LOG_DIR
  RUN_DIR IBC_PATTERNS IBC_TEMPLATE JTS_TEMPLATE BROKERSRE_LIB
  TZ IBGW_IMAGE IBGW_MEM_LIMIT IBGW_SECRETS_DIR PRIVATE_IP
)

# One assignment: optional indentation, optional `export`, the name, `=` (spaces allowed
# before it), the rest of the line. Groups: 1 indentation, 2 export, 3 name, 4 separator, 5 rest.
assignment_re='^([[:space:]]*)(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)([[:space:]]*=)(.*)$'

# State of one run, filled by convert_file.
out_lines=()
report_lines=()
declare -A seen_names=()
declare -i kept=0 renamed=0 dropped=0 unknown=0

# usage: print the command-line help.
usage() {
  printf '%s\n' \
    "usage: migrate-from-gnzsnz.sh <gnzsnz.env>  > new.env" \
    "  Converts the .env file of a gnzsnz/ib-gateway-docker deployment for brokersre-ib-gateway." \
    "  stdout: the converted file. stderr: what was dropped, renamed or is unknown, and why." \
    "  No value is printed in the report; a credential stays in its own line of the output." \
    "exit status: 0 converted, 1 refused (TRADING_MODE=both), 2 usage error"
}

# say MESSAGE: print one report line to stderr, prefixed with the program name.
say() {
  printf '%s: %s\n' "${program}" "$1" >&2
}

# note MESSAGE: queue one report line; convert_file prints the queue only when the conversion
# succeeded, so a refused run reports the refusal and nothing else.
note() {
  report_lines+=("$1")
}

# env_value REST: print the value a .env parser would read from REST, the text after `=`.
#
# Leading blanks are skipped; a value in double or single quotes ends at the closing quote; an
# unquoted value ends before a blank followed by `#` (an inline comment) and loses trailing
# blanks. Used only to judge TRADING_MODE and JAVA_HEAP_SIZE and to tell "set" from "empty";
# the result is never printed.
env_value() {
  local rest="$1" value
  rest="${rest#"${rest%%[![:space:]]*}"}"
  case "${rest}" in
    \"*)
      value="${rest#\"}"
      value="${value%%\"*}"
      ;;
    \'*)
      value="${rest#\'}"
      value="${value%%\'*}"
      ;;
    *)
      value="${rest%%[[:space:]]#*}"
      value="${value%"${value##*[![:space:]]}"}"
      ;;
  esac
  printf '%s' "${value}"
}

# drop_reason NAME: for a variable this image ignores, set the globals `reason` (why it is
# gone) and `advice` (what replaces it) and return 0; return 1 for any other variable.
#
# The names and reasons are those of the doctor's check_ignored_variables, so a container
# started with the converted file passes that check. SSH_* comes before any *_FILE handling on
# purpose: SSH_PASSPHRASE_FILE is dropped, not kept.
drop_reason() {
  case "$1" in
    TWS_USERID_PAPER | TWS_PASSWORD_PAPER | TWS_PASSWORD_PAPER_FILE)
      reason="dual mode was removed"
      advice="the paper account is a second gateway with its own credentials: compose/docker-compose.multi.yml"
      ;;
    TWS_COLD_RESTART)
      reason="a cold restart is not supported"
      advice="use AUTO_RESTART_TIME"
      ;;
    SSH_*)
      reason="the SSH tunnel was removed"
      advice="use a private network or a sidecar that shares the gateway's network namespace"
      ;;
    START_SCRIPTS | X_SCRIPTS | IBC_SCRIPTS)
      reason="hook scripts were removed"
      advice="run such steps outside this container"
      ;;
    GATEWAY_OR_TWS)
      reason="this image runs IB Gateway only"
      advice="there is no Trader Workstation image"
      ;;
    *) return 1 ;;
  esac
  return 0
}

# secret_advice NAME: for a known variable that carries a credential or the path of one, print
# the advice that follows `NAME=<hidden> kept; ` in the report and return 0; return 1 for any
# other variable.
secret_advice() {
  case "$1" in
    TWS_USERID | TWS_PASSWORD)
      printf '%s' "better: put the value into a secret file and set ${1}_FILE instead (README, Quick start). The reference compose sets ${1}_FILE already, and the container refuses to start when both are set"
      ;;
    VNC_SERVER_PASSWORD)
      printf '%s' "better: VNC_SERVER_PASSWORD_FILE. VNC listens on 127.0.0.1 inside the container only"
      ;;
    TWS_USERID_FILE | TWS_PASSWORD_FILE | VNC_SERVER_PASSWORD_FILE)
      printf '%s' "the path must exist inside the new container (a Docker secret is mounted under /run/secrets)"
      ;;
    *) return 1 ;;
  esac
  return 0
}

# refuse_both LINE_NUMBER: explain on stderr why TRADING_MODE=both cannot be converted.
refuse_both() {
  say "line $1: TRADING_MODE=both is refused: this image runs one brokerage session per container"
  say "run two gateways instead, one with TRADING_MODE=live and one with TRADING_MODE=paper, each with its own IBKR username: compose/docker-compose.multi.yml (see compose/README.md)"
  say "split this file in two (the *_PAPER credentials are the paper gateway's username and password) and convert each part"
  say "nothing was converted"
}

# convert_line NUMBER LINE: convert one input line. Appends exactly one line to out_lines and
# zero or more lines to the report queue; updates the counters and seen_names.
#
# Returns 1 when the line is TRADING_MODE=both (the caller refuses the whole file), else 0.
convert_line() {
  local number="$1" line="$2" name value advice
  if [[ "${line}" =~ ^[[:space:]]*(#.*)?$ ]]; then
    out_lines+=("${line}")
    return 0
  fi
  if ! [[ "${line}" =~ ${assignment_re} ]]; then
    out_lines+=("${line}")
    note "line ${number}: not an assignment, kept as it is"
    return 0
  fi
  local indent="${BASH_REMATCH[1]}" export_word="${BASH_REMATCH[2]}" separator="${BASH_REMATCH[4]}" rest="${BASH_REMATCH[5]}"
  name="${BASH_REMATCH[3]}"
  value="$(env_value "${rest}")"
  if [ -n "${value}" ]; then seen_names["${name}"]=1; fi

  if drop_reason "${name}"; then
    out_lines+=("# ${name}: removed by ${program}.sh (${reason})")
    note "line ${number}: ${name} dropped: ${reason}; ${advice}"
    dropped+=1
    return 0
  fi
  case "${name}" in
    TRADING_MODE)
      case "${value,,}" in
        both) return 1 ;;
        live | paper | "") ;;
        *) note "line ${number}: TRADING_MODE must be live or paper: this image refuses to start with any other value" ;;
      esac
      out_lines+=("${line}")
      kept+=1
      return 0
      ;;
    JAVA_HEAP_SIZE)
      if [ -n "${has_heap_mb}" ]; then
        out_lines+=("# ${name}: removed by ${program}.sh (JAVA_HEAP_MB is set in this file)")
        note "line ${number}: ${name} dropped: the file sets JAVA_HEAP_MB already, which replaces it"
        dropped+=1
      elif [[ "${value}" =~ ^[1-9][0-9]*$ ]]; then
        out_lines+=("${indent}${export_word}JAVA_HEAP_MB${separator}${rest}")
        note "line ${number}: ${name} renamed to JAVA_HEAP_MB"
        renamed+=1
      else
        out_lines+=("# ${name}: removed by ${program}.sh (not a whole number of megabytes)")
        note "line ${number}: ${name} dropped: its value is not a whole number of megabytes; set JAVA_HEAP_MB yourself (the default is 768)"
        dropped+=1
      fi
      return 0
      ;;
  esac
  out_lines+=("${line}")
  if advice="$(secret_advice "${name}")"; then
    note "line ${number}: ${name}=<hidden> kept; ${advice}"
    kept+=1
  elif [ -n "${is_known[${name}]:-}" ]; then
    kept+=1
  else
    note "line ${number}: ${name} unknown, kept"
    unknown+=1
  fi
  return 0
}

# convert_file PATH: convert the file at PATH; print the result to stdout and the report to
# stderr. Returns 0 converted, 1 refused, 2 unreadable or not UTF-8 text.
#
# Nothing is printed to stdout before the whole file has been read, so a refused or unreadable
# file never leaves half a result behind.
convert_file() {
  local path="$1" probe="" line
  local -a lines=()
  local -i number=0
  declare -g -A is_known=()
  declare -g has_heap_mb=""
  if [ ! -f "${path}" ] || [ ! -r "${path}" ]; then
    say "cannot read ${path}"
    return 2
  fi
  # `read -d ''` succeeds only when it meets a NUL byte: UTF-16 text is full of them.
  if IFS= read -r -d '' probe <"${path}" || [[ "${probe}" == $'\xff\xfe'* || "${probe}" == $'\xfe\xff'* ]]; then
    say "${path} is not UTF-8 text (it holds NUL bytes or a UTF-16 byte-order mark, which is what Windows PowerShell 5.1 '>' writes); save it as UTF-8 and run again"
    return 2
  fi
  mapfile -t lines <"${path}"
  if [ "${#lines[@]}" -gt 0 ]; then lines[0]="${lines[0]#$'\xef\xbb\xbf'}"; fi
  for line in "${known_names[@]}"; do is_known["${line}"]=1; done
  # JAVA_HEAP_SIZE must know whether JAVA_HEAP_MB is set anywhere in the file, also below it.
  for line in "${lines[@]}"; do
    line="${line%$'\r'}"
    if [[ "${line}" =~ ${assignment_re} ]] && [ "${BASH_REMATCH[3]}" = "JAVA_HEAP_MB" ] \
      && [ -n "$(env_value "${BASH_REMATCH[5]}")" ]; then
      has_heap_mb=1
    fi
  done
  for line in "${lines[@]}"; do
    number+=1
    if ! convert_line "${number}" "${line%$'\r'}"; then
      refuse_both "${number}"
      return 1
    fi
  done
  if [ -z "${seen_names[READ_ONLY_API]:-}" ]; then
    note "note: READ_ONLY_API is not set: this image then defaults to yes (read-only API, orders are rejected), gnzsnz had no default. Set READ_ONLY_API=no only if this gateway must take orders"
  fi
  if [ -z "${seen_names[TWOFA_TIMEOUT_ACTION]:-}" ]; then
    note "note: TWOFA_TIMEOUT_ACTION is not set: this image then defaults to restart (it asks for the second factor again), gnzsnz defaulted to exit"
  fi
  if [ "${#out_lines[@]}" -gt 0 ]; then printf '%s\n' "${out_lines[@]}"; fi
  for line in "${report_lines[@]}"; do say "${line}"; done
  say "converted: ${kept} kept, ${renamed} renamed, ${dropped} dropped, ${unknown} unknown"
  say "next: start with 'docker compose --env-file <this file> -f compose/docker-compose.example.yml up -d': that applies TRADING_MODE, READ_ONLY_API, AUTO_RESTART_TIME and TIME_ZONE. Every other variable reaches the container only when the service also lists the file under 'env_file:'"
  say "next: check the result with 'docker compose run --rm ib-gateway doctor'; docs/migrating-from-gnzsnz.md lists every difference"
  return 0
}

# main ARGS...: parse the command line and convert. Returns the exit status of the script.
main() {
  if [ "$#" -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
    usage
    return 0
  fi
  if [ "$#" -ne 1 ]; then
    usage >&2
    return 2
  fi
  convert_file "$1"
}

main "$@"
