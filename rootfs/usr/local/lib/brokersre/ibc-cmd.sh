#!/usr/bin/env bash
# Send one command to the IBC command server over loopback (no telnet in the image).
#
# Usage: ibc-cmd <STOP|RESTART|PAUSE|RECONNECTDATA|RECONNECTACCOUNT|ENABLEAPI> [host] [port]
# Reads IBC_COMMAND_SERVER_PORT (default 7462) and prints the server's reply. Exit 2 when the
# command server is disabled (port 0), 1 when the connection fails.
set -euo pipefail

cmd="${1:?command required (STOP RESTART PAUSE RECONNECTDATA RECONNECTACCOUNT ENABLEAPI)}"
host="${2:-127.0.0.1}"
port="${3:-${IBC_COMMAND_SERVER_PORT:-7462}}"
case "${cmd}" in
  STOP | RESTART | PAUSE | RECONNECTDATA | RECONNECTACCOUNT | ENABLEAPI) ;;
  *)
    echo "ibc-cmd: unknown command '${cmd}'" >&2
    exit 2
    ;;
esac
if [ "${port}" = "0" ]; then
  echo "ibc-cmd: command server disabled (IBC_COMMAND_SERVER_PORT=0)" >&2
  exit 2
fi

exec 3<>"/dev/tcp/${host}/${port}" || {
  echo "ibc-cmd: cannot connect to ${host}:${port}" >&2
  exit 1
}
printf '%s\r\n' "${cmd}" >&3
# STOP closes the socket on the server side; EXIT is harmless after other commands.
if [ "${cmd}" != "STOP" ]; then printf 'EXIT\r\n' >&3; fi
timeout 5 cat <&3 || true
exec 3>&-
