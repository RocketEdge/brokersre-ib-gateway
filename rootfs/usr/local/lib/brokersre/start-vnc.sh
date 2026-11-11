#!/usr/bin/env bash
# Optional break-glass VNC on loopback only. Starts when VNC_SERVER_PASSWORD (or its _FILE)
# is set. Reaching it requires an SSH tunnel or `docker exec`, never a published port.
#
# start_vnc: sets VNC_PID when x11vnc was started.
#
# How the password reaches x11vnc, and why: every process in the container can read every
# other process's argument list, so the password is never passed as an argument
# (`x11vnc -storepasswd <password> <file>` and `-passwd` both expose it to `ps`). It is written
# with a bash builtin to a 0600 file in the tmpfs run directory and handed over with
# `-passwdfile rm:<file>`: x11vnc reads the first line and deletes the file, so the secret ends
# up only in x11vnc's memory. The variable is unset before x11vnc starts.
# Note: the VNC protocol uses at most the first eight characters of a password.
start_vnc() {
  file_env VNC_SERVER_PASSWORD
  if [ -z "${VNC_SERVER_PASSWORD:-}" ]; then
    log_event vnc info vnc_disabled "VNC_SERVER_PASSWORD not set; VNC disabled"
    return 0
  fi
  local passfile="${RUN_DIR}/vncpasswd"
  (
    umask 077
    printf '%s\n' "${VNC_SERVER_PASSWORD}" >"${passfile}"
  )
  unset_secret VNC_SERVER_PASSWORD
  x11vnc -display "${DISPLAY}" -passwdfile "rm:${passfile}" -localhost -forever -shared -noipv6 -quiet >/dev/null 2>&1 &
  # shellcheck disable=SC2034  # read by entrypoint.sh after sourcing
  VNC_PID=$!
  log_event vnc warn vnc_enabled "x11vnc listening on 127.0.0.1:5900 (break-glass; tunnel in)"
}
