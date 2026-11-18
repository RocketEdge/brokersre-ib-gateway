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
#   Writes:   WORK/server.sh, replaced on every call by renaming a new file onto it (never
#             rewritten in place), and one log WORK/socat.XXXXXX per call.
#   Starts:   socat in a session and process group of its own (setsid), which its handlers and
#             everything they start inherit, so stop_servers can end all of them at once.
#   Returns:  0 once socat listens, with PORT set to its port (a later call replaces PORT);
#             1 when socat exits or does not listen within 5 s, after printing socat's log on
#             stderr, which bats shows with the failure.
# Why the rename: an earlier listener's handler may be in execve() of WORK/server.sh, and Linux
# refuses a write to a file that is being exec'd ("Text file busy"; the suspected, unconfirmed
# cause of one failure in 800 loaded runs of a test that calls serve twice, review of #47, its
# log lost). rename(2) only swaps the directory entry: a handler that has opened the script
# keeps reading the old inode; one still starting runs the new script, which is harmless
# because every listener runs WORK/server.sh.
serve() {
  local log pid line script
  script="$(mktemp "${WORK}/server.XXXXXX")"
  printf '%s\n' '#!/usr/bin/env bash' "$1" >"${script}"
  chmod +x "${script}"
  mv -f "${script}" "${WORK}/server.sh"
  log="$(mktemp "${WORK}/socat.XXXXXX")"
  # A background job of a shell without job control is no group leader, so setsid calls
  # setsid() and execs socat: $! is socat. Were it a leader, setsid would fork, and -w keeps
  # it running (and $! meaningful) until socat ends.
  setsid -w socat -d -d "TCP-LISTEN:0,bind=127.0.0.1,fork" "EXEC:${WORK}/server.sh" >/dev/null 2>"${log}" 3>&- &
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

# stop_servers: stop every listener serve() started in this test, the handlers it forked for
# connections and whatever those handlers started (a `sleep` in a server body, dd, od).
#   Finds:  the processes that carry WORK/server.sh in their command line (listeners, handlers);
#           WORK is private to the test, so no other test's server is touched. Without WORK (a
#           setup that failed before setting it) the pattern would be "/server.sh", every test's
#           servers: it fails instead.
#   Stops:  the whole process group of each (SIGTERM), never the test's own group, then by name
#           whatever matched in the test's own group (a script the test ran itself).
#   Returns: 0.
# Why groups: a handler's children do not name WORK/server.sh, so matching on it left them
# running (a `sleep 30` per api-handshake.bats run, review of #48). serve() puts each listener
# in a group of its own, and one kill(-group) reaches every member at once; walking the
# process tree instead races with a handler that forks while it is walked.
stop_servers() {
  local pattern own pids group
  pattern="${WORK:?stop_servers needs WORK, the private directory of the test}/server.sh"
  own="$(ps -o pgid= -p "$$" | tr -d ' ')"
  pids="$(pgrep -d , -f "${pattern}" || true)"
  if [ -n "${pids}" ]; then
    for group in $(ps -o pgid= -p "${pids}" | sort -u); do
      if [ "${group}" != "${own}" ]; then kill -TERM -- "-${group}" 2>/dev/null || true; fi
    done
  fi
  pkill -f "${pattern}" 2>/dev/null || true
}
