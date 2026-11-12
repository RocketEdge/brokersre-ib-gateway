#!/usr/bin/env bash
# Prove that the Gateway's API answers, without making an API request.
#
# Usage: api-handshake.sh [host] [port] [timeout_s]
#   host       default 127.0.0.1 (the Gateway listens on loopback only)
#   port       default from TRADING_MODE: 4002 (paper) or 4001 (live)
#   timeout_s  default 5; whole seconds, covers connect and reply together
#
# Why: an open TCP port does not show that the Gateway works. A Gateway whose API thread has
# died still accepts connections and then never answers, and a port-only health check calls
# that healthy. The TWS API begins with a handshake: the client sends "API\0" followed by a
# length-prefixed version range ("v157..178", the range ib_async uses), and the server answers
# with a length-prefixed "<serverVersion>\0<connection time>\0". This script sends that and
# reads the answer. It stops there: no startApi, so it takes no client id (no error 326 for a
# strategy that uses the same id), requests nothing and cannot touch an order.
#
# Output and exit status:
#   0  "ok: API answered the handshake (server version N)"
#   1  "fail: ..." (cannot connect, no answer in time, connection closed, or not a TWS reply)
#   2  usage error
# Bash and coreutils only (dd, od, tr, timeout): nothing is added to the image.
set -u

host="${1:-127.0.0.1}"
port="${2:-}"
timeout_s="${3:-5}"

if [ -z "${port}" ]; then
  case "${TRADING_MODE:-}" in
    paper) port=4002 ;;
    live) port=4001 ;;
    *)
      echo "usage: api-handshake.sh [host] [port] [timeout_s] (no port given and TRADING_MODE is not live or paper)" >&2
      echo "fail: cannot choose a port: TRADING_MODE is '${TRADING_MODE:-}'"
      exit 2
      ;;
  esac
fi
if ! [[ "${port}" =~ ^[1-9][0-9]*$ ]] || ! [[ "${timeout_s}" =~ ^[1-9][0-9]*$ ]]; then
  echo "fail: port and timeout_s must be positive whole numbers (got port '${port}', timeout '${timeout_s}')"
  exit 2
fi

# Outer call: run the exchange itself (the inner call below) under `timeout`, so a server that
# accepts and then stays silent cannot hold this script longer than timeout_s.
if [ -z "${API_HANDSHAKE_INNER:-}" ]; then
  out="$(API_HANDSHAKE_INNER=1 timeout "${timeout_s}" "$0" "${host}" "${port}" "${timeout_s}")"
  rc=$?
  if [ "${rc}" -eq 124 ]; then
    echo "fail: no answer to the API handshake within ${timeout_s} s (${host}:${port} accepts connections but the API does not respond)"
    exit 1
  fi
  printf '%s\n' "${out}"
  exit "${rc}"
fi

# Inner call: one connection, one handshake.
if ! { exec 3<>"/dev/tcp/${host}/${port}"; } 2>/dev/null; then
  echo "fail: cannot connect to ${host}:${port}"
  exit 1
fi
# "API\0", then the 4-byte big-endian length (9) of "v157..178", then that text.
printf 'API\0\0\0\0\x09v157..178' >&3

# The reply starts with its own 4-byte big-endian length.
read -r b0 b1 b2 b3 <<<"$(dd bs=1 count=4 <&3 2>/dev/null | od -An -v -tu1)"
if [ -z "${b0:-}" ] || [ -z "${b3:-}" ]; then
  echo "fail: ${host}:${port} closed the connection without answering the API handshake"
  exit 1
fi
len=$(((b0 << 24) | (b1 << 16) | (b2 << 8) | b3))
# A real reply is a version number and a timestamp: a few dozen bytes.
if [ "${len}" -lt 2 ] || [ "${len}" -gt 256 ]; then
  echo "fail: the reply from ${host}:${port} is not a TWS API handshake (length field ${len})"
  exit 1
fi
payload="$(dd bs=1 count="${len}" <&3 2>/dev/null | tr '\0' '\n')"
version="${payload%%$'\n'*}"
if ! [[ "${version}" =~ ^[0-9]+$ ]]; then
  echo "fail: the reply from ${host}:${port} is not a TWS API handshake (no server version)"
  exit 1
fi
exec 3>&-
echo "ok: API answered the handshake (server version ${version})"
exit 0
