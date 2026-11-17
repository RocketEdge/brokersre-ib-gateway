# Stand-in TCP servers for the unit suites (bats `load socat-server`): a socat listener on
# loopback that runs a shell snippet for each connection. Used by api-handshake.bats and
# vnc-client.bats, which set WORK (a private temporary directory) and PORT in their setup().

# serve <script-body>: start a socat listener on PORT that runs the given shell snippet for
# each connection (stdin/stdout are the socket). Detached from bats' descriptors.
serve() {
  printf '%s\n' '#!/usr/bin/env bash' "$1" >"${WORK}/server.sh"
  chmod +x "${WORK}/server.sh"
  socat "TCP-LISTEN:${PORT},reuseaddr,fork" "EXEC:${WORK}/server.sh" >/dev/null 2>&1 3>&- &
  for _ in $(seq 1 50); do
    if timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/${PORT}" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  return 1
}
