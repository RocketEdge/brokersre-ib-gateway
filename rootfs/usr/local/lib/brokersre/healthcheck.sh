#!/usr/bin/env bash
# Docker HEALTHCHECK. Healthy means: the IBC/Gateway Java process is alive AND the Gateway's API
# port accepts a TCP connection on loopback. A pending 2FA therefore reports unhealthy, which is
# the truth; nothing restarts the container on unhealthy (the agent and the host watchdog read
# ${LOG_DIR}/state/phase before acting). With IBC_LAUNCH=no (offline tests) health means the
# socat relay is listening.
#
# HEALTHCHECK_API=handshake (opt-in; default `port`) adds a third condition: the API must answer
# the TWS API handshake (api-handshake.sh). That catches a Gateway whose port is open but whose
# API no longer responds. It is opt-in because it opens one short connection to the Gateway at
# every health check and its effect on a logged-in Gateway is not yet observed in a real
# session (docs/limitations.md); the handshake takes no client id and makes no request.
#
# Testability: the probes are functions overridable through HEALTHCHECK_PGREP (a command that
# exits 0 when the process is alive), HEALTHCHECK_TCP (a command taking host and port) and
# HEALTHCHECK_HANDSHAKE (a command taking host and port).
set -u

case "${HEALTHCHECK_API:-port}" in
  port | handshake) ;;
  *)
    echo "unhealthy: HEALTHCHECK_API must be port or handshake (got '${HEALTHCHECK_API}')"
    exit 1
    ;;
esac

TRADING_MODE="${TRADING_MODE:-paper}"
case "${TRADING_MODE}" in
  live)
    API_PORT=4001
    SOCAT_PORT=4003
    ;;
  paper)
    API_PORT=4002
    SOCAT_PORT=4004
    ;;
  *)
    echo "unhealthy: invalid TRADING_MODE '${TRADING_MODE}'"
    exit 1
    ;;
esac

process_alive() {
  if [ -n "${HEALTHCHECK_PGREP:-}" ]; then
    ${HEALTHCHECK_PGREP}
    return $?
  fi
  pgrep -f 'ibcalpha\.ibc' >/dev/null 2>&1
}

port_open() {
  if [ -n "${HEALTHCHECK_TCP:-}" ]; then
    ${HEALTHCHECK_TCP} "$1" "$2"
    return $?
  fi
  timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null
}

api_answers() {
  if [ -n "${HEALTHCHECK_HANDSHAKE:-}" ]; then
    ${HEALTHCHECK_HANDSHAKE} "$1" "$2"
    return $?
  fi
  "$(dirname "${BASH_SOURCE[0]}")/api-handshake.sh" "$1" "$2" 2 >/dev/null 2>&1
}

if [ "${IBC_LAUNCH:-yes}" = "no" ]; then
  if port_open 127.0.0.1 "${SOCAT_PORT}"; then
    echo "healthy: relay listening on ${SOCAT_PORT} (IBC not launched)"
    exit 0
  fi
  echo "unhealthy: relay not listening on ${SOCAT_PORT}"
  exit 1
fi

if ! process_alive; then
  echo "unhealthy: IBC/Gateway process not running"
  exit 1
fi
if ! port_open 127.0.0.1 "${API_PORT}"; then
  echo "unhealthy: API port ${API_PORT} not accepting connections (not logged in?)"
  exit 1
fi
if [ "${HEALTHCHECK_API:-port}" = "handshake" ]; then
  # 2 s: the Gateway is on loopback and answers in milliseconds; Docker allows 5 s in total.
  if ! api_answers 127.0.0.1 "${API_PORT}"; then
    echo "unhealthy: API port ${API_PORT} is open but the API does not answer its handshake"
    exit 1
  fi
  echo "healthy: process alive, API answered its handshake on ${API_PORT}"
  exit 0
fi
echo "healthy: process alive, API port ${API_PORT} open"
exit 0
