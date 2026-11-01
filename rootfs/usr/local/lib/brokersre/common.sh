#!/usr/bin/env bash
# Shared helpers for the entrypoint and its stages. Sourced, never executed.
#
# Design rules: secrets arrive through *_FILE variables (Docker secrets) and are read exactly
# once into the environment of the rendering step, then unset; nothing here prints a secret.

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/log.sh"

# file_env VAR [DEFAULT]: populate $VAR from $VAR_FILE if set (Docker secrets), refusing the
# ambiguous case where both are set.
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
    if [ ! -r "${!file_var}" ]; then
      log_event entrypoint error secret_unreadable "${file_var} points at an unreadable file"
      exit 1
    fi
    value="$(<"${!file_var}")"
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
