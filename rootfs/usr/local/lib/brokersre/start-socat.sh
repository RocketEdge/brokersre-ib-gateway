#!/usr/bin/env bash
# Relay the Gateway's loopback-only API port to the container interface for the strategy host.
# IB Gateway accepts connections from TrustedIPs=127.0.0.1 only, so socat on 0.0.0.0:SOCAT_PORT
# forwards to 127.0.0.1:API_PORT. Compose binds SOCAT_PORT to a private address only.
#
# The relay follows the Gateway's phase (RELAY_MODE=gated, the default): it listens only while
# the phase is `logged-in`. A relay that listens before the Gateway is logged in accepts a
# client and then drops it, which strategy code sees as a connection reset; a closed port is a
# clean "connection refused" that every client library retries. The same applies during the
# daily restart. RELAY_MODE=always restores the old behaviour (listen from container start).
# With IBC_LAUNCH=no (offline tests) there is no login, so the relay listens at once.

# relay_wanted: true when the relay should be listening right now.
relay_wanted() {
  [ "${RELAY_MODE:-gated}" = "always" ] || [ "${IBC_LAUNCH:-yes}" = "no" ] || [ "$(current_phase)" = "logged-in" ]
}

# relay_supervise: run until terminated; keep socat running exactly while relay_wanted.
#
# Polls every RELAY_POLL_S (default 1 s). Opening and closing emit relay_opened/relay_closed.
# A relay that exits while it is wanted is started again after SOCAT_RESTART_DELAY (default
# 5 s). Closing also ends the per-connection children socat forked, so no client keeps a
# half-dead connection to a Gateway that is restarting. TERM/INT stop the relay and return.
relay_supervise() {
  local pid="" poll="${RELAY_POLL_S:-1}"
  # shellcheck disable=SC2317,SC2329  # invoked through the TERM/INT trap and from the loop
  relay_stop() {
    if [ -n "${pid}" ]; then
      pkill -TERM -P "${pid}" 2>/dev/null || true
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
      pid=""
    fi
  }
  trap 'relay_stop; exit 0' TERM INT
  while true; do
    if relay_wanted; then
      if [ -n "${pid}" ] && ! kill -0 "${pid}" 2>/dev/null; then
        wait "${pid}" 2>/dev/null || true
        pid=""
        log_event socat warn relay_closed "relay on ${SOCAT_PORT} exited unexpectedly; restarting it"
        sleep "${SOCAT_RESTART_DELAY:-5}" &
        wait $! 2>/dev/null || true
      fi
      if [ -z "${pid}" ]; then
        socat "TCP-LISTEN:${SOCAT_PORT},fork,reuseaddr" "TCP:127.0.0.1:${API_PORT}" >/dev/null 2>&1 &
        pid=$!
        log_event socat info relay_opened "relay listening on ${SOCAT_PORT} -> 127.0.0.1:${API_PORT}"
      fi
    elif [ -n "${pid}" ]; then
      relay_stop
      log_event socat info relay_closed "relay on ${SOCAT_PORT} closed: the Gateway is not logged in (phase $(current_phase))"
    fi
    # `sleep` in the background plus `wait` lets the TERM trap run at once.
    sleep "${poll}" &
    wait $! 2>/dev/null || true
  done
}

# start_socat: start the relay supervisor in the background. Sets SOCAT_PID (the supervisor).
# Fails with config_invalid (exit 1) when RELAY_MODE is neither `gated` nor `always`.
start_socat() {
  case "${RELAY_MODE:-gated}" in
    gated | always) ;;
    *)
      log_event socat error config_invalid "RELAY_MODE must be gated or always (got '${RELAY_MODE}')"
      exit 1
      ;;
  esac
  relay_supervise &
  # shellcheck disable=SC2034  # read by entrypoint.sh after sourcing
  SOCAT_PID=$!
  log_event socat info socat_started "relay 0.0.0.0:${SOCAT_PORT} -> 127.0.0.1:${API_PORT} (${TRADING_MODE}); mode ${RELAY_MODE:-gated}"
}
