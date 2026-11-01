#!/usr/bin/env bash
# Start the virtual X server IB Gateway needs and wait for its socket.
# Sourced by entrypoint.sh after common.sh. Sets XVFB_PID.
start_xvfb() {
  rm -f "/tmp/.X${DISPLAY#:}-lock"
  Xvfb "${DISPLAY}" -ac -nolisten tcp -screen 0 1024x768x16 >/dev/null 2>&1 &
  # shellcheck disable=SC2034  # read by entrypoint.sh after sourcing
  XVFB_PID=$!
  if wait_for_unix_socket "/tmp/.X11-unix/X${DISPLAY#:}" 30; then
    log_event xvfb info xvfb_started "Xvfb listening on ${DISPLAY}"
  else
    log_event xvfb error xvfb_failed "Xvfb socket did not appear within 30 s"
    exit 1
  fi
}
