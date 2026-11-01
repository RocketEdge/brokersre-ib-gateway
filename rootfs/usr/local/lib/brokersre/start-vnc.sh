#!/usr/bin/env bash
# Optional break-glass VNC on loopback only. Starts when VNC_SERVER_PASSWORD (or its _FILE)
# is set; the password is read into the x11vnc password file in tmpfs and unset immediately.
# Reaching it requires an SSH tunnel or `docker exec`, never a published port. Sets VNC_PID.
start_vnc() {
  file_env VNC_SERVER_PASSWORD
  if [ -z "${VNC_SERVER_PASSWORD:-}" ]; then
    log_event vnc info vnc_disabled "VNC_SERVER_PASSWORD not set; VNC disabled"
    return 0
  fi
  local passfile="${RUN_DIR}/vncpasswd"
  (
    umask 077
    x11vnc -storepasswd "${VNC_SERVER_PASSWORD}" "${passfile}" >/dev/null 2>&1
  )
  unset_secret VNC_SERVER_PASSWORD
  x11vnc -display "${DISPLAY}" -rfbauth "${passfile}" -localhost -forever -shared -noipv6 -quiet >/dev/null 2>&1 &
  # shellcheck disable=SC2034  # read by entrypoint.sh after sourcing
  VNC_PID=$!
  log_event vnc warn vnc_enabled "x11vnc listening on 127.0.0.1:5900 (break-glass; tunnel in)"
}
