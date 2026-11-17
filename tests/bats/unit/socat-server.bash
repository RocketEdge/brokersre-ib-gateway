# Stand-in TCP servers for the unit suites (bats `load socat-server`): a socat listener on
# loopback that runs a shell snippet for each connection. Used by api-handshake.bats and
# vnc-client.bats; their setup() creates WORK (a private temporary directory) and their
# teardown() calls stop_servers. Tested by socat-server.bats.
#
# Why the kernel picks the port: a port the test picks can already be taken. Any port in
# Linux's ephemeral range (ip_local_port_range, 32768-60999 by default) may be the local port
# of an earlier client connection in the same network namespace, and a client that closes
# first keeps its port in TIME_WAIT for 60 s. That socket was made without SO_REUSEADDR, so a
# listener cannot bind the port even with socat's reuseaddr: socat exits with "Address already
# in use". The suites drew from 40000-59999, and every readiness probe and test client left
# such a port behind; a draw that hit one failed CI with "serve failed" and no reason
# (docs/changes.md, 2026-11-18). Port 0 makes the kernel hand out a port nothing holds, and
# socat's own "listening on" notice, written after listen() returned, names it. No probe
# connection is needed, so serve() itself leaves nothing in TIME_WAIT.

# serve <script-body>: start a socat listener on a loopback port the kernel picks, running the
# given shell snippet for each connection (stdin/stdout are the socket, stderr goes to socat's
# log). Detached from bats' descriptors (closes 3, see the bats note in CLAUDE.md).
#   Requires: WORK, a writable directory private to the test.
#   Writes:   WORK/server.sh (replaced on every call) and one log WORK/socat.XXXXXX per call.
#   Returns:  0 once socat listens, with PORT set to its port (a later call replaces PORT);
#             1 when socat exits or does not listen within 5 s, after printing socat's log on
#             stderr, which bats shows with the failure.
serve() {
  local log pid line
  printf '%s\n' '#!/usr/bin/env bash' "$1" >"${WORK}/server.sh"
  chmod +x "${WORK}/server.sh"
  log="$(mktemp "${WORK}/socat.XXXXXX")"
  socat -d -d "TCP-LISTEN:0,bind=127.0.0.1,fork" "EXEC:${WORK}/server.sh" >/dev/null 2>"${log}" 3>&- &
  pid=$!
  for _ in $(seq 1 50); do
    # socat 1.8: "2026/11/17 20:18:44 socat[8] N listening on AF=2 127.0.0.1:37401".
    # The grep is the if's condition: bats runs tests under errexit, and a bare
    # line="$(grep ...)" that finds nothing yet would end the test at the first poll.
    if line="$(grep -m 1 ' listening on AF=2 127\.0\.0\.1:[0-9][0-9]*$' "${log}")"; then
      # shellcheck disable=SC2034  # PORT is the calling test's variable: serve's output
      PORT="${line##*:}"
      return 0
    fi
    kill -0 "${pid}" 2>/dev/null || break
    sleep 0.1
  done
  echo "serve: socat is not listening; its log:" >&2
  cat "${log}" >&2
  return 1
}

# stop_servers: stop every listener serve() started in this test and the processes it forked
# for connections. All of them carry WORK/server.sh in their command line, and WORK is private
# to the test, so no other test's server is touched.
stop_servers() {
  pkill -f "${WORK}/server.sh" 2>/dev/null || true
}
