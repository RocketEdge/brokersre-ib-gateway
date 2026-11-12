#!/usr/bin/env bash
# Optional break-glass console: x11vnc on loopback only. Starts when VNC_SERVER_PASSWORD (or its
# _FILE) is set. Reaching it requires an SSH tunnel or `docker exec`, never a published port
# (docs/console.md). A person looks and acts there; nothing in the image does.
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
#
# View-only unless VNC_VIEW_ONLY=no (x11vnc -viewonly: "All VNC clients can only watch"). A look
# at a stuck dialog must not be able to click by accident; typing or clicking takes the
# deliberate `no`. Any other value stops the start with config_invalid (exit 1), like the other
# settings that decide who may do what: a console that silently read `false` as "input allowed",
# or as "view-only" at the moment someone needs to type, would be found out one login too late.
# The value is judged only when the console is on.
# The setting holds for the life of the container: x11vnc is started with -noremote. Without
# it any process that can reach the display switches view-only off while x11vnc runs
# (`x11vnc -R noviewonly`, measured with 0.9.17 in this image on 2026-11-12), unseen by the
# events below, which would go on saying "view-only". Nothing in the image uses that channel.
#
# Sessions are events. x11vnc runs vnc-hook.sh after it accepted and authenticated a client
# (-afteraccept) and when a client goes away (-gone); the hook emits vnc_client_connected and
# vnc_client_disconnected. Two facts about x11vnc 0.9.17 shape how it is started (both measured
# in this image on 2026-11-12):
#   - it prints `PORT=5900` on its stdout even with -quiet, and its log on stderr, so both
#     stay discarded: only events may reach the container's stdout (log contract);
#   - it runs a hook through system(3) with its own descriptors 0, 1 and 2 and closes every
#     other one. So the container's stdout is handed to x11vnc as descriptor 0 (which x11vnc
#     never reads without -inetd), and the hook command ends in `>&0`: the hook's events go to
#     the container's stdout, x11vnc's own output still goes nowhere.
# x11vnc has no option that disconnects an idle client (its -timeout is about the first
# connection after startup, -readtimeout about a stalled transfer), so there is no idle limit
# here: close the viewer, and unset the password when the intervention is over.
start_vnc() {
  local view_only="${VNC_VIEW_ONLY:-yes}" mode_text hook_cmd passfile="${RUN_DIR}/vncpasswd"
  local -a view_option=()
  file_env VNC_SERVER_PASSWORD
  if [ -z "${VNC_SERVER_PASSWORD:-}" ]; then
    log_event vnc info vnc_disabled "VNC_SERVER_PASSWORD not set; VNC disabled"
    return 0
  fi
  case "${view_only}" in
    yes)
      view_option=(-viewonly)
      mode_text="view-only"
      ;;
    no)
      mode_text="input allowed"
      ;;
    *)
      unset_secret VNC_SERVER_PASSWORD
      log_event vnc error config_invalid "VNC_VIEW_ONLY must be yes or no; the break-glass console was not started"
      exit 1
      ;;
  esac
  (
    umask 077
    printf '%s\n' "${VNC_SERVER_PASSWORD}" >"${passfile}"
  )
  unset_secret VNC_SERVER_PASSWORD
  # One command string for both hooks; x11vnc hands it to `sh -c`, hence the quoting.
  printf -v hook_cmd '%q >&0' "$(dirname "${BASH_SOURCE[0]}")/vnc-hook.sh"
  VNC_VIEW_ONLY="${view_only}" x11vnc -display "${DISPLAY}" -passwdfile "rm:${passfile}" -localhost -forever -shared -noipv6 -quiet \
    -noremote "${view_option[@]}" -afteraccept "${hook_cmd}" -gone "${hook_cmd}" 0<&1 >/dev/null 2>&1 &
  # shellcheck disable=SC2034  # read by entrypoint.sh after sourcing
  VNC_PID=$!
  log_event_data vnc warn vnc_enabled "$(json_object view_only "${view_only}")" \
    "x11vnc listening on 127.0.0.1:5900, ${mode_text} (break-glass; tunnel in)"
}
