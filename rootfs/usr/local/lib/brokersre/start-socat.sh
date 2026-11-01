#!/usr/bin/env bash
# Relay the Gateway's loopback-only API port to the container interface for the strategy host.
# IB Gateway accepts connections from TrustedIPs=127.0.0.1 only, so socat on 0.0.0.0:SOCAT_PORT
# forwards to 127.0.0.1:API_PORT. Compose binds SOCAT_PORT to the VM's private NIC only.
# Restarts socat if it exits (e.g. after an abrupt disconnect). Sets SOCAT_PID (the loop).
start_socat() {
  (
    while true; do
      socat "TCP-LISTEN:${SOCAT_PORT},fork,reuseaddr" "TCP:127.0.0.1:${API_PORT}" >/dev/null 2>&1
      sleep "${SOCAT_RESTART_DELAY:-5}"
    done
  ) &
  # shellcheck disable=SC2034  # read by entrypoint.sh after sourcing
  SOCAT_PID=$!
  log_event socat info socat_started "relaying 0.0.0.0:${SOCAT_PORT} -> 127.0.0.1:${API_PORT} (${TRADING_MODE})"
}
