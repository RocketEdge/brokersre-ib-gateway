#!/usr/bin/env bash
# Shared helpers for the entrypoint and its stages. Sourced, never executed.
#
# Design rules: secrets arrive through *_FILE variables (Docker secrets) and are read exactly
# once into the environment of the rendering step, then unset; nothing here prints a secret.

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/log.sh"

# secret_refused FILE_VAR REASON: stop with the secret_unreadable event. The message names the
# variable and the reason, never the file's content.
secret_refused() {
  log_event entrypoint error secret_unreadable "$1 $2"
  exit 1
}

# read_secret_file FILE_VAR PATH: read one secret from PATH into the global SECRET_VALUE.
#
# Contract: on return SECRET_VALUE holds the secret exactly as the user typed it; on any doubt
# the container stops (secret_unreadable) instead of logging in with a corrupted password, since
# repeated bad logins can lock an IBKR account. Runs in the caller's shell (never in a command
# substitution), so the exit really ends the entrypoint and nothing is captured from stdout.
#
# Secret files written on Windows are the reason for the normalisation:
#   - Notepad and Set-Content end the file with CR LF: trailing CR and LF bytes are removed;
#   - "UTF-8 with BOM" starts the file with EF BB BF: the byte-order mark is removed;
#   - Windows PowerShell 5.1 `>` and Out-File write UTF-16: that cannot be a valid secret file
#     (every second byte is NUL), so it is refused with the fix in the message.
# Bytes inside the secret (spaces, `$`, `*`, backslashes, non-ASCII UTF-8) are kept as they are.
read_secret_file() {
  local file_var="$1" path="$2" probe
  # Byte semantics for the prefix and suffix tests below, whatever locale the container has.
  local LC_ALL=C
  SECRET_VALUE=""
  if [ ! -f "${path}" ] || [ ! -r "${path}" ]; then
    secret_refused "${file_var}" "points at an unreadable file"
  fi
  # `read -d ''` succeeds only when it meets a NUL byte; UTF-16 text always contains one.
  if IFS= read -r -d '' probe <"${path}"; then
    secret_refused "${file_var}" "is not a UTF-8 text file (it contains NUL bytes, so it is probably UTF-16 written by Windows PowerShell '>' or Out-File); write it as UTF-8 without a byte-order mark"
  fi
  probe="$(<"${path}")"
  case "${probe}" in
    $'\xff\xfe'* | $'\xfe\xff'*)
      secret_refused "${file_var}" "starts with a UTF-16 byte-order mark; write it as UTF-8 without a byte-order mark"
      ;;
  esac
  probe="${probe#$'\xef\xbb\xbf'}"
  while [[ "${probe}" == *$'\r' || "${probe}" == *$'\n' ]]; do
    probe="${probe%?}"
  done
  if [ -z "${probe}" ]; then
    secret_refused "${file_var}" "points at an empty file"
  fi
  SECRET_VALUE="${probe}"
}

# file_env VAR [DEFAULT]: populate $VAR from $VAR_FILE if set (Docker secrets), refusing the
# ambiguous case where both are set. A value read from a file is normalised by read_secret_file.
file_env() {
  local var="$1" file_var="${1}_FILE" default="${2:-}"
  if [ -n "${!var:-}" ] && [ -n "${!file_var:-}" ]; then
    log_event entrypoint error config_conflict "both ${var} and ${file_var} are set; use one"
    exit 1
  fi
  local value="${default}"
  if [ -n "${!var:-}" ]; then
    value="${!var}"
  elif [ -n "${!file_var:-}" ]; then
    read_secret_file "${file_var}" "${!file_var}"
    value="${SECRET_VALUE}"
    unset SECRET_VALUE
  fi
  export "${var}=${value}"
}

# unset_secret VAR: remove a secret from the environment (after rendering) and its *_FILE path.
unset_secret() {
  unset "$1" "${1}_FILE"
}

# set_ports: derive API_PORT (Gateway's own listener) and SOCAT_PORT (relay on the NIC).
set_ports() {
  case "${TRADING_MODE:-}" in
    live)
      API_PORT=4001
      SOCAT_PORT=4003
      ;;
    paper)
      API_PORT=4002
      SOCAT_PORT=4004
      ;;
    *)
      log_event entrypoint error config_invalid "TRADING_MODE must be live or paper (got '${TRADING_MODE:-}'); one session per container"
      exit 1
      ;;
  esac
  export API_PORT SOCAT_PORT
}

# set_phase <phase>: record the gateway lifecycle phase for the agent (shared log volume).
set_phase() {
  printf '%s\n' "$1" >"${LOG_DIR}/state/phase.tmp" && mv -f "${LOG_DIR}/state/phase.tmp" "${LOG_DIR}/state/phase"
}

# wait_for_unix_socket <path> <timeout_s>
wait_for_unix_socket() {
  local path="$1" timeout="${2:-30}" waited=0
  until [ -S "${path}" ]; do
    sleep 0.5
    waited=$((waited + 1))
    if [ "${waited}" -ge $((timeout * 2)) ]; then
      return 1
    fi
  done
}

# tcp_open <host> <port> [timeout_s]: true when a TCP connection succeeds.
tcp_open() {
  timeout "${3:-3}" bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null
}
