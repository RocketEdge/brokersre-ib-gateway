#!/usr/bin/env bash
# Docker HEALTHCHECK. Healthy means: the IBC/Gateway Java process is alive AND the Gateway's API
# port accepts a TCP connection on loopback. A pending 2FA therefore reports unhealthy, which is
# the truth; nothing restarts the container on unhealthy (the agent and the host watchdog read
# ${LOG_DIR}/state/phase before acting). With IBC_LAUNCH=no (offline tests) health means the
# socat relay is listening.
#
# Testability: the two probes are functions overridable through HEALTHCHECK_PGREP (a command
# that exits 0 when the process is alive) and HEALTHCHECK_TCP (a command taking host and port).
set -u

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
echo "healthy: process alive, API port ${API_PORT} open"
exit 0
