#!/usr/bin/env bash
# Container entrypoint (run under tini). Orchestrates: ports, config rendering, Xvfb, optional
# VNC, the socat relay, the Gateway log mirror and IBC itself; on SIGTERM asks IBC to STOP the
# Gateway tidily through the command server before stopping the helpers.
#
# Stdout carries only structured JSON events (log contract v1); raw IBC/Gateway output goes to
# ${LOG_DIR}. With IBC_LAUNCH=no everything except IBC starts, which is how the offline tests
# prove rendering, secrets handling, the relay and the read-only filesystem without a login.
set -euo pipefail

BROKERSRE_LIB="${BROKERSRE_LIB:-/usr/local/lib/brokersre}"
# shellcheck source=/dev/null
source "${BROKERSRE_LIB}/common.sh"
# shellcheck source=/dev/null
source "${BROKERSRE_LIB}/render-config.sh"
# shellcheck source=/dev/null
source "${BROKERSRE_LIB}/start-xvfb.sh"
# shellcheck source=/dev/null
source "${BROKERSRE_LIB}/start-vnc.sh"
# shellcheck source=/dev/null
source "${BROKERSRE_LIB}/start-socat.sh"
# shellcheck source=/dev/null
source "${BROKERSRE_LIB}/java-env.sh"
# shellcheck source=/dev/null
source "${BROKERSRE_LIB}/start-ibc.sh"

IBC_PID="" XVFB_PID="" VNC_PID="" SOCAT_PID="" TAIL_PID=""

# shellcheck disable=SC2317,SC2329  # invoked through the TERM/INT trap, which shellcheck cannot follow
shutdown() {
  trap - TERM INT
  log_event entrypoint info shutdown_requested "SIGTERM/SIGINT received; stopping IB Gateway tidily"
  set_phase stopping
  if [ -n "${IBC_PID}" ] && kill -0 "${IBC_PID}" 2>/dev/null; then
    if [ "${IBC_COMMAND_SERVER_PORT}" != "0" ] && tcp_open 127.0.0.1 "${IBC_COMMAND_SERVER_PORT}" 1; then
      "${BROKERSRE_LIB}/ibc-cmd.sh" STOP >/dev/null 2>&1 || true
    else
      kill -TERM "${IBC_PID}" 2>/dev/null || true
    fi
    for _ in $(seq 1 60); do
      kill -0 "${IBC_PID}" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "${IBC_PID}" 2>/dev/null; then kill -KILL "${IBC_PID}" 2>/dev/null || true; fi
  fi
  for p in "${TAIL_PID}" "${SOCAT_PID}" "${VNC_PID}" "${XVFB_PID}"; do
    if [ -n "${p}" ]; then kill "${p}" 2>/dev/null || true; fi
  done
  pkill -x socat 2>/dev/null || true
  log_event entrypoint info shutdown_complete "all processes stopped"
  set_phase stopped
  exit 0
}
trap shutdown TERM INT

# Fail fast and legibly when a writable path is not writable by this uid. A tmpfs mounted
# without uid=1000,gid=1000 is root-owned 0755 (docs/env-vars.md, "Read-only root filesystem").
for dir in "${LOG_DIR}" "${RUN_DIR}" "${TWS_SETTINGS_PATH}"; do
  if ! mkdir -p "${dir}" 2>/dev/null || [ ! -w "${dir}" ]; then
    log_event entrypoint error dirs_not_writable "${dir} is not writable by uid $(id -u) (owner $(stat -c '%u:%g mode %a' "${dir}" 2>/dev/null || echo missing)); mount tmpfs with uid=1000,gid=1000 when running read-only"
    exit 1
  fi
done
mkdir -p "${LOG_DIR}/ibc" "${LOG_DIR}/jts" "${LOG_DIR}/state" "${LOG_DIR}/events" "${LOG_DIR}/metrics"
# From here on every event carries this start's boot id and a sequence number (log.sh).
new_boot_id
set_phase starting
log_event_data entrypoint info container_start \
  "$(json_object gateway_version "${IB_GATEWAY_VERSION}" channel "${IB_GATEWAY_CHANNEL}" ibc_version "${IBC_VERSION}" ibc_release "${IBC_RELEASE_TAG:-}" trading_mode "${TRADING_MODE:-}" instance "${IBGW_INSTANCE:-default}")" \
  "brokersre-ib-gateway ${IB_GATEWAY_VERSION} (${IB_GATEWAY_CHANNEL}) IBC ${IBC_VERSION} starting as uid $(id -u)"

set_ports
render_config
# Before any helper starts: a Java home that cannot be written must stop the container here,
# not leave a half-started one behind (java-env.sh explains why the Gateway needs it).
java_env
start_xvfb
start_vnc
start_socat
"${BROKERSRE_LIB}/tail-gateway-logs.sh" &
TAIL_PID=$!

if [ "${IBC_LAUNCH}" = "no" ]; then
  log_event entrypoint warn ibc_not_launched "IBC_LAUNCH=no: IBC and IB Gateway are NOT started (test mode)"
  set_phase test-mode
  wait "${SOCAT_PID}"
  exit 0
fi

start_ibc
rc=0
wait "${IBC_PID}" || rc=$?
log_event ibc warn ibc_exited "IBC process exited with status ${rc}"
if [ "$(current_phase)" = "needs-human" ]; then
  # IBC was stopped on purpose because only a person can go on (for example: the second factor
  # was not approved after TWOFA_MAX_PROMPTS prompts). Exiting here would let a restart policy
  # start the next login at once, and the next, defeating the cap. The container stays up,
  # unhealthy, with the phase needs-human, until a person restarts it; SIGTERM still runs the
  # normal shutdown through the trap.
  log_event entrypoint error needs_human "IBC has stopped and the gateway waits for a person; restart the container to log in again"
  while true; do
    sleep 3600 &
    wait $! 2>/dev/null || true
  done
fi
set_phase exited
exit "${rc}"
