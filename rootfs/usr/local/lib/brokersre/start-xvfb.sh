#!/usr/bin/env bash
# Start the virtual X server IB Gateway needs and wait for its socket.
# Sourced by entrypoint.sh after common.sh. Sets XVFB_PID.
#
# With SCREENSHOTS=yes (opt-in, see screenshot.sh) Xvfb keeps its framebuffer in a file under
# ${RUN_DIR}/xvfb (tmpfs, 0700; about 1.5 MB for this screen), which is what a screenshot
# copies. With any other value Xvfb is started exactly as it was before that option existed.
# A framebuffer directory that cannot be created costs the screenshots, never the screen.
start_xvfb() {
  local fb_dir="${RUN_DIR:-/run/brokersre}/xvfb"
  local -a framebuffer=()
  rm -f "/tmp/.X${DISPLAY#:}-lock"
  if [ "${SCREENSHOTS:-no}" = "yes" ]; then
    if mkdir -p "${fb_dir}" 2>/dev/null && chmod 0700 "${fb_dir}" 2>/dev/null; then
      framebuffer=(-fbdir "${fb_dir}")
    else
      log_event xvfb warn screenshots_unavailable "SCREENSHOTS=yes, but ${fb_dir} cannot be created: the virtual screen starts without a framebuffer file and no screenshot will be taken"
    fi
  fi
  Xvfb "${DISPLAY}" -ac -nolisten tcp -screen 0 1024x768x16 "${framebuffer[@]}" >/dev/null 2>&1 &
  # shellcheck disable=SC2034  # read by entrypoint.sh after sourcing
  XVFB_PID=$!
  if wait_for_unix_socket "/tmp/.X11-unix/X${DISPLAY#:}" 30; then
    log_event xvfb info xvfb_started "Xvfb listening on ${DISPLAY}"
  else
    log_event xvfb error xvfb_failed "Xvfb socket did not appear within 30 s"
    exit 1
  fi
}
