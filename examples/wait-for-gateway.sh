#!/usr/bin/env bash
# wait-for-gateway.sh: block until an IB Gateway really answers, then (optionally) start the
# strategy.
#
# Usage: wait-for-gateway.sh [--host HOST] [--port PORT] [--timeout SECONDS] [--quiet] [-- COMMAND [ARG...]]
#   --host HOST        gateway host name or address   (default: $IBGW_HOST, else 127.0.0.1)
#   --port PORT        API port                       (default: $IBGW_PORT, else 4002)
#   --timeout SECONDS  how long to wait in total      (default: $IBGW_WAIT_TIMEOUT, else 300)
#   --quiet            no progress lines; a timeout is still reported
#   -- COMMAND ...     replace this script with COMMAND once the gateway is ready
# Exit status: 0 ready (or COMMAND's own status), 1 timeout, 2 usage error.
# Environment: IBGW_ATTEMPT_TIMEOUT (default 5) bounds one connection attempt, in seconds.
#
# What "ready" means: a TCP connection succeeds AND the TWS API handshake is answered. An open
# port alone proves little: a relay in front of a Gateway that is not logged in accepts the
# connection and drops it, and a Gateway whose API thread is stuck accepts and stays silent.
# The TWS API begins with a handshake: the client sends "API\0" and a length-prefixed version
# range ("v157..178"), the server answers with a length-prefixed
# "<server version>\0<connection time>\0". This script sends that, reads the answer and closes
# the connection. Nothing else is sent: no startApi, so it takes no client id and cannot
# collide with the strategy's; no request; nothing that could touch an order.
#
# Retries: a refused connection, a dropped connection and a missing answer all mean "not ready
# yet", so the script tries again with a growing pause (1, 2, 4, then 8 s, each plus up to
# 0.9 s of jitter) until the overall timeout. That covers a gateway that is still logging in,
# one that waits for a second factor, and the daily restart.
#
# Three ways to use it:
#   entrypoint wrapper   entrypoint: ["/wait-for-gateway.sh", "--host", "ib-gateway", "--port", "4004", "--"]
#                        command: ["python", "strategy.py"]
#   compose healthcheck  test: ["CMD", "/wait-for-gateway.sh", "--host", "ib-gateway", "--port", "4004", "--timeout", "5", "--quiet"]
#   by hand              examples/wait-for-gateway.sh --port 4002 && echo ready
#
# Needs bash and coreutils (timeout, dd, od, tr). Readiness is a moment, not a promise: the
# strategy must still handle a lost connection (examples/README.md).
set -uo pipefail

program="wait-for-gateway"

# usage: print the command-line help.
usage() {
  printf '%s\n' \
    "usage: wait-for-gateway.sh [--host HOST] [--port PORT] [--timeout SECONDS] [--quiet] [-- COMMAND [ARG...]]" \
    "  Waits until HOST:PORT accepts a TCP connection and answers the TWS API handshake." \
    "  --host HOST        default: \$IBGW_HOST, else 127.0.0.1" \
    "  --port PORT        default: \$IBGW_PORT, else 4002" \
    "  --timeout SECONDS  overall limit; default: \$IBGW_WAIT_TIMEOUT, else 300" \
    "  --quiet            no progress lines" \
    "  -- COMMAND ...     run COMMAND once the gateway is ready" \
    "exit status: 0 ready, 1 timeout, 2 usage error"
}

# say MESSAGE: print one progress line to stderr unless --quiet was given. Stdout is left to
# the wrapped command.
say() {
  if [ "${quiet}" != "yes" ]; then printf '%s: %s\n' "${program}" "$1" >&2; fi
}

# usage_error MESSAGE: report a command-line mistake and exit 2.
usage_error() {
  printf '%s: %s\n' "${program}" "$1" >&2
  usage >&2
  exit 2
}

# gateway_probe HOST PORT: one connection, one handshake.
#
# Prints `connected` as soon as the TCP connection stands, then one line with the finding.
# Returns 0 when the reply is a TWS API handshake (finding: `server version N`), 1 otherwise
# (cannot connect, connection closed, not a TWS reply). It has no timeout of its own: the
# caller runs it under `timeout`, and the `connected` line tells a silent server from an
# unreachable one. Self-contained on purpose: it is handed to a child shell with `declare -f`.
# shellcheck disable=SC2329  # invoked in the child shell that probe_once starts
gateway_probe() {
  local host="$1" port="$2" b0="" b1="" b2="" b3="" payload version
  local -i len
  # A peer that has already closed must give a write error, not kill this shell.
  trap '' PIPE
  if ! { exec 3<>"/dev/tcp/${host}/${port}"; } 2>/dev/null; then
    echo "cannot connect to ${host}:${port}"
    return 1
  fi
  echo "connected"
  # "API\0", then the 4-byte big-endian length (9) of "v157..178", then that text.
  if ! printf 'API\0\0\0\0\x09v157..178' >&3 2>/dev/null; then
    echo "${host}:${port} closed the connection without answering the API handshake"
    return 1
  fi
  # The reply starts with its own 4-byte big-endian length; dd reads byte by byte so that
  # nothing beyond the reply is consumed. A process substitution, not a here-string: bash
  # before 5.1 writes a here-string to a temporary file, which a read-only container lacks.
  read -r b0 b1 b2 b3 < <(dd bs=1 count=4 <&3 2>/dev/null | od -An -v -tu1)
  if [ -z "${b3}" ]; then
    echo "${host}:${port} closed the connection without answering the API handshake"
    return 1
  fi
  len=$(((b0 << 24) | (b1 << 16) | (b2 << 8) | b3))
  # A real reply is a version number and a timestamp: a few dozen bytes.
  if ((len < 2 || len > 256)); then
    echo "the reply from ${host}:${port} is not a TWS API handshake (length field ${len})"
    return 1
  fi
  payload="$(dd bs=1 count="${len}" <&3 2>/dev/null | tr '\0' '\n')"
  version="${payload%%$'\n'*}"
  if ! [[ "${version}" =~ ^[0-9]+$ ]]; then
    echo "the reply from ${host}:${port} is not a TWS API handshake (no server version)"
    return 1
  fi
  exec 3>&-
  echo "server version ${version}"
  return 0
}

# probe_once HOST PORT SECONDS: run gateway_probe in a child shell for at most SECONDS.
#
# Sets the global `finding` to one line of text and returns 0 (ready) or 1 (not ready). The
# child runs under `timeout`, which also ends the dd that may be blocked on a silent server.
probe_once() {
  local host="$1" port="$2" seconds="$3" output
  local -i rc=0
  # shellcheck disable=SC2016  # $1 and $2 belong to the child shell: host and port are passed as arguments, never as script text
  output="$(timeout "${seconds}" bash -c "$(declare -f gateway_probe)"'; gateway_probe "$1" "$2"' _ "${host}" "${port}")" || rc=$?
  finding="${output##*$'\n'}"
  case "${rc}" in
    0) return 0 ;;
    124 | 137 | 143)
      # Ended by `timeout` (124 from coreutils, a signal status from other implementations).
      if [[ "${output}" == connected* ]]; then
        finding="no answer to the API handshake from ${host}:${port} within ${seconds} s (it accepts connections but the API does not respond)"
      else
        finding="cannot connect to ${host}:${port} within ${seconds} s"
      fi
      ;;
  esac
  if [ -z "${finding}" ] || [ "${finding}" = "connected" ]; then
    finding="the handshake with ${host}:${port} ended unexpectedly (status ${rc})"
  fi
  return 1
}

# wait_for_gateway HOST PORT TIMEOUT ATTEMPT_TIMEOUT: probe until ready or until TIMEOUT
# seconds have passed. Returns 0 ready, 1 timeout. Reports each change of the finding once.
wait_for_gateway() {
  local host="$1" port="$2" last=""
  local -i timeout_s="$3" attempt_timeout="$4" start=${SECONDS} deadline remaining per pause=1
  deadline=$((start + timeout_s))
  say "waiting for ${host}:${port} to answer the TWS API handshake (timeout ${timeout_s} s)"
  while true; do
    remaining=$((deadline - SECONDS))
    if ((remaining <= 0)); then break; fi
    per=$((remaining < attempt_timeout ? remaining : attempt_timeout))
    if probe_once "${host}" "${port}" "${per}"; then
      say "ready: ${host}:${port} answered the API handshake (${finding}) after $((SECONDS - start)) s"
      return 0
    fi
    if [ "${finding}" != "${last}" ]; then
      say "not ready: ${finding}"
      last="${finding}"
    fi
    remaining=$((deadline - SECONDS))
    if ((remaining <= 0)); then break; fi
    # Capped exponential back-off with jitter; never sleep past the deadline.
    if ((pause >= remaining)); then
      sleep "${remaining}"
    else
      sleep "${pause}.$((RANDOM % 10))"
    fi
    if ((pause < 8)); then pause=$((pause * 2)); fi
  done
  # A timeout is reported even with --quiet: a failure must be visible.
  printf '%s: timeout after %d s: %s\n' "${program}" "${timeout_s}" "${last:-no attempt was made}" >&2
  return 1
}

# main ARGS...: parse the command line, wait, then exec the command after `--` if there is one.
main() {
  local host="${IBGW_HOST:-127.0.0.1}" port="${IBGW_PORT:-4002}" timeout_s="${IBGW_WAIT_TIMEOUT:-300}"
  local attempt_timeout="${IBGW_ATTEMPT_TIMEOUT:-5}" option tool
  local -a command=()
  quiet="no"
  finding=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --host | --port | --timeout)
        if [ "$#" -lt 2 ]; then usage_error "$1 needs a value"; fi
        option="$1=$2"
        shift 2
        ;;
      --host=* | --port=* | --timeout=*)
        option="$1"
        shift
        ;;
      --quiet | -q)
        quiet="yes"
        shift
        continue
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      --)
        shift
        command=("$@")
        break
        ;;
      *) usage_error "unknown option or argument: $1" ;;
    esac
    case "${option}" in
      --host=*) host="${option#*=}" ;;
      --port=*) port="${option#*=}" ;;
      --timeout=*) timeout_s="${option#*=}" ;;
    esac
  done
  if ! [[ "${host}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    usage_error "--host must be a host name or an IP address"
  fi
  if ! [[ "${port}" =~ ^[1-9][0-9]{0,4}$ ]] || ((port > 65535)); then
    usage_error "--port must be a number from 1 to 65535"
  fi
  if ! [[ "${timeout_s}" =~ ^[1-9][0-9]{0,8}$ ]]; then
    usage_error "--timeout must be a positive whole number of seconds"
  fi
  if ! [[ "${attempt_timeout}" =~ ^[1-9][0-9]{0,3}$ ]]; then attempt_timeout=5; fi
  for tool in timeout dd od tr; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      printf '%s: %s is required (coreutils) and was not found\n' "${program}" "${tool}" >&2
      exit 2
    fi
  done
  if ! wait_for_gateway "${host}" "${port}" "${timeout_s}" "${attempt_timeout}"; then exit 1; fi
  if [ "${#command[@]}" -gt 0 ]; then exec "${command[@]}"; fi
  exit 0
}

main "$@"
