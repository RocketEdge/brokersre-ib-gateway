#!/usr/bin/env bash
# Session hook of the break-glass console: turns a VNC client that was let in, and one that
# left, into events, so the log shows that a person was on the console and for how long.
#
# x11vnc runs this file (start-vnc.sh passes it as -afteraccept and as -gone) and describes the
# client in RFB_* variables. Read here:
#   RFB_MODE          `afteraccept` (a client was accepted and authenticated) or `gone`
#   RFB_STATE         how far the client got; only NORMAL is a session
#   RFB_CLIENT_IP     the peer address
#   RFB_CLIENT_ID     x11vnc's id of the client (0x1, 0x2, ...), the same in both events
#   RFB_CLIENT_COUNT  clients connected after this one arrived or left
#   RFB_LOGIN_TIME, RFB_CURRENT_TIME   epoch seconds; their difference is the session length
#   VNC_VIEW_ONLY     `yes` or `no` as start-vnc.sh resolved it (not an x11vnc variable)
#
# Events (src `vnc`, written through log_event like every other event):
#   vnc_client_connected     warn  data: client_ip, client_id, clients, view_only
#   vnc_client_disconnected  info  data: client_ip, client_id, clients, session_s
#
# Rules:
#   - Only a client that reached the state NORMAL is reported. x11vnc also runs -gone for a
#     connection that never authenticated (measured: RFB_STATE=PROTOCOL_VERSION); that is no
#     session, it was never announced, so it is not "disconnected" either.
#   - Nothing is echoed as it came. Each value must match a strict form (a dotted IPv4 address
#     with octets up to 255, 0x and hex digits, a short number) or it becomes `unknown`
#     (address, view-only state) or is left out (id, count, session length). RFB_USERNAME and
#     the certificate text are never read: a client can shape them.
#   - The password is not in this process's environment (start-vnc.sh unsets it before x11vnc
#     starts) and nothing here reads a file.
#   - x11vnc ignores the hook's status and waits for it, so the hook always ends with 0 and
#     does nothing but write the event.
#
# The file is both the executable and a library: sourcing it defines the function and runs
# nothing.

# shellcheck source=/dev/null
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/log.sh"

# vnc_hook_main: emit the event for the session change described by the RFB_* variables, or
# nothing when it is not one (see the rules above). Always returns 0.
vnc_hook_main() {
  local mode="${RFB_MODE:-}" ip="unknown" view="unknown" view_text="view-only state unknown" msg octet
  local -a data=()
  local -i session=-1
  local LC_ALL=C
  if [ "${RFB_STATE:-}" != "NORMAL" ]; then return 0; fi
  case "${mode}" in
    afteraccept | gone) ;;
    *) return 0 ;;
  esac
  if [[ "${RFB_CLIENT_IP:-}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    ip="${RFB_CLIENT_IP}"
    for octet in "${BASH_REMATCH[@]:1:4}"; do
      # 10# so that a leading zero is not read as octal.
      if ((10#${octet} > 255)); then ip="unknown"; fi
    done
  fi
  data=(client_ip "${ip}")
  if [[ "${RFB_CLIENT_ID:-}" =~ ^0x[0-9a-f]{1,8}$ ]]; then data+=(client_id "${RFB_CLIENT_ID}"); fi
  if [[ "${RFB_CLIENT_COUNT:-}" =~ ^[0-9]{1,4}$ ]]; then data+=(clients "${RFB_CLIENT_COUNT}"); fi
  if [ "${mode}" = "afteraccept" ]; then
    case "${VNC_VIEW_ONLY:-}" in
      yes)
        view="yes"
        view_text="view-only"
        ;;
      no)
        view="no"
        view_text="input allowed"
        ;;
    esac
    data+=(view_only "${view}")
    msg="a VNC client connected to the break-glass console from ${ip} (${view_text})"
    log_event_data vnc warn vnc_client_connected "$(json_object "${data[@]}")" "${msg}" || true
    return 0
  fi
  if [[ "${RFB_LOGIN_TIME:-}" =~ ^[0-9]{1,12}$ ]] && [[ "${RFB_CURRENT_TIME:-}" =~ ^[0-9]{1,12}$ ]]; then
    session=$((10#${RFB_CURRENT_TIME} - 10#${RFB_LOGIN_TIME}))
  fi
  msg="the VNC client from ${ip} left the break-glass console"
  if ((session >= 0)); then
    data+=(session_s "${session}")
    msg+=" after ${session} s"
  fi
  log_event_data vnc info vnc_client_disconnected "$(json_object "${data[@]}")" "${msg}" || true
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  vnc_hook_main
  exit 0
fi
