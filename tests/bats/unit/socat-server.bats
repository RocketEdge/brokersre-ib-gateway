#!/usr/bin/env bats
# Unit tests for socat-server.bash, the stand-in TCP server of api-handshake.bats and
# vnc-client.bats. serve() must hand its test a listening server whatever the container's
# network namespace already holds. In November 2026 a listener that never came up failed CI
# twice ("a full session" on #43, "a refused password" on main at f999345): the port drawn for
# it was the local port of an earlier client connection that was still in TIME_WAIT, so socat
# could not bind it even with reuseaddr, exited, and its error went to /dev/null.

load socat-server
bats_require_minimum_version 1.5.0

setup() {
  WORK="$(mktemp -d)"
  # The draw the suites made before serve() took a port from the kernel: 40000-59999 lies
  # inside Linux's ephemeral range (32768-60999), where any client connection may take it.
  PORT=$((40000 + RANDOM % 20000))
}

teardown() {
  stop_servers
  rm -rf "${WORK}"
}

@test "serve listens even when PORT names a port an earlier client still holds" {
  # The server only reads, so the client always closes first: its own port waits in
  # FIN-WAIT-2 until the server closes, then in TIME_WAIT for 60 s. Both states keep the port
  # bound without SO_REUSEADDR. (With a server that closes first, the TIME_WAIT lands on the
  # server's side and nothing is held on the client's: review of #47.) The old readiness probe
  # and every test client left ports like this.
  serve 'cat >/dev/null'
  bash -c "exec 3<>/dev/tcp/127.0.0.1/${PORT}"
  held=""
  for _ in $(seq 1 50); do
    # With two states ss prints the State column too: the local address is the second-last field.
    held="$(ss -Htan state time-wait state fin-wait-2 "dport = :${PORT}" | awk '{ n = split($(NF - 1), a, ":"); print a[n]; exit }')"
    if [ -n "${held}" ]; then break; fi
    sleep 0.1
  done
  [ -n "${held}" ]
  PORT="${held}"
  serve 'printf "second\n"'
  exec 4<>"/dev/tcp/127.0.0.1/${PORT}"
  IFS= read -r -t 2 reply <&4
  exec 4>&-
  [ "${reply}" == "second" ]
}

@test "a socat that is slow to start is waited for, also under errexit" {
  # A loaded runner starts socat late; serve() must keep polling its log, not stop at the
  # first poll that finds nothing (tests call serve directly, so errexit is on).
  real_socat="$(command -v socat)"
  mkdir "${WORK}/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'sleep 1' "exec '${real_socat}' \"\$@\"" >"${WORK}/bin/socat"
  chmod +x "${WORK}/bin/socat"
  PATH="${WORK}/bin:${PATH}" serve 'printf "late\n"'
  exec 4<>"/dev/tcp/127.0.0.1/${PORT}"
  IFS= read -r -t 2 reply <&4
  exec 4>&-
  [ "${reply}" == "late" ]
}

@test "serve puts each script in place as a new file and leaves the old one untouched" {
  # A handler of an earlier listener may be running the old script (bash keeps it open and
  # reads it as it goes) or still be in execve() of it. Rewriting that file in place changes
  # what it reads, and during its execve() the write is refused ("Text file busy", see the
  # next test). A rename gives the new script its own inode and leaves the old one alone.
  serve 'exit 0'
  exec 5<"${WORK}/server.sh"
  old_inode="$(stat -c %i "${WORK}/server.sh")"
  serve 'printf "second\n"'
  [ "$(stat -c %i "${WORK}/server.sh")" != "${old_inode}" ]
  old_text="$(cat <&5)"
  exec 5<&-
  [ "${old_text}" == "$(printf '%s\n' '#!/usr/bin/env bash' 'exit 0')" ]
  exec 4<>"/dev/tcp/127.0.0.1/${PORT}"
  IFS= read -r -t 2 reply <&4
  exec 4>&-
  [ "${reply}" == "second" ]
}

@test "serve replaces the script while other processes keep executing it" {
  # Linux refuses a write to a file that is in execve() ("Text file busy"); the denial lasts
  # only for the execve() itself, so this cannot be made deterministic from user space. Eight
  # loops keep executing WORK/server.sh while serve() replaces it 60 times: an in-place
  # rewrite was refused in 29 of 400 such calls, so the old helper fails this test with a
  # probability of about 99 % (review follow-up of #47).
  serve 'exit 0'
  : >"${WORK}/exec-loops.on"
  loops=()
  for _ in 1 2 3 4 5 6 7 8; do
    (while [ -e "${WORK}/exec-loops.on" ]; do "${WORK}/server.sh" </dev/null >/dev/null 2>&1 || true; done) >/dev/null 2>&1 3>&- &
    loops+=("$!")
  done
  for i in $(seq 1 60); do
    serve "printf 'v${i}\n'"
  done
  rm -f "${WORK}/exec-loops.on"
  wait "${loops[@]}"
  exec 4<>"/dev/tcp/127.0.0.1/${PORT}"
  IFS= read -r -t 2 reply <&4
  exec 4>&-
  [ "${reply}" == "v60" ]
}

@test "stop_servers without WORK fails and stops no server" {
  # A setup that fails before it sets WORK still runs teardown; "/server.sh" alone would match
  # every test's servers.
  serve 'printf "alive\n"'
  # bash leaves at the failed ${WORK:?} expansion (status 127 in bash 5.3): any failure will do.
  run ! env -u WORK bash -c "source '${BATS_TEST_DIRNAME}/socat-server.bash'; stop_servers"
  [[ "$output" == *"stop_servers needs WORK"* ]]
  exec 4<>"/dev/tcp/127.0.0.1/${PORT}"
  IFS= read -r -t 2 reply <&4
  exec 4>&-
  [ "${reply}" == "alive" ]
}

@test "stop_servers also ends the processes a handler started" {
  # A handler's children do not name WORK/server.sh in their command line, so matching on it
  # missed them: with `sleep 30` as its server body, api-handshake.bats left one sleep behind
  # on every run (review of #48). The handler below starts one and writes down its PID.
  serve "sleep 60 & echo \"\$!\" >'${WORK}/child.pid'; wait"
  exec 4<>"/dev/tcp/127.0.0.1/${PORT}"
  for _ in $(seq 1 50); do
    if [ -s "${WORK}/child.pid" ]; then break; fi
    sleep 0.1
  done
  child="$(cat "${WORK}/child.pid")"
  kill -0 "${child}"
  stop_servers
  exec 4>&-
  # Gone, or a zombie its new parent has not collected yet: either way it no longer runs.
  for _ in $(seq 1 50); do
    state="$(ps -o stat= -p "${child}" || true)"
    if [ -z "${state}" ] || [[ "${state}" == Z* ]]; then break; fi
    sleep 0.1
  done
  [ -z "${state}" ] || [[ "${state}" == Z* ]]
}

@test "stop_servers never signals the test's own process group" {
  # A process the test itself started that runs WORK/server.sh is in bats' process group, and
  # a kill of that group would end bats too. It is stopped by name instead (SIGTERM, 143), and
  # the test goes on to the end. The script waits in a builtin (read on a FIFO opened read-write,
  # which never blocks on open), so it starts no child that could outlive the test.
  mkfifo "${WORK}/hold"
  serve "read -t 5 -r _ <>'${WORK}/hold'"
  "${WORK}/server.sh" </dev/null >/dev/null 2>&1 3>&- &
  own=$!
  for _ in $(seq 1 50); do
    if pgrep -f "${WORK}/server.sh" | grep -qx "${own}"; then break; fi
    sleep 0.1
  done
  pgrep -f "${WORK}/server.sh" | grep -qx "${own}"
  stop_servers
  own_status=0
  wait "${own}" || own_status=$?
  [ "${own_status}" -eq 143 ]
}

@test "no unit suite uses a fixed port inside Linux's ephemeral range" {
  # Hardening (review of #47): serve() takes port 0. A suite with a fixed listener port, or a
  # port it expects to be closed, keeps it below 32768, where ip_local_port_range
  # (32768-60999) never hands it to a client: no earlier client can hold it, and a connect to
  # it never picks it as its own source port (a self-connection would look like a listener).
  found="$(grep -o -n -E '(TCP-LISTEN:|PORT=|/dev/tcp/[^/" ]+/|127\.0\.0\.1[: ])[0-9]+' "${BATS_TEST_DIRNAME}"/*.bats |
    awk -F'[^0-9]+' '{ if ($NF >= 32768 && $NF <= 60999) print }')"
  if [ -n "${found}" ]; then
    printf 'fixed ports inside 32768-60999:\n%s\n' "${found}"
    false
  fi
}

@test "a socat that cannot listen is reported at once, in its own words" {
  mkdir "${WORK}/bin"
  printf '%s\n' '#!/usr/bin/env bash' \
    'echo "socat[1] E bind(5, {AF=2 127.0.0.1:0}, 16): Address already in use" >&2' \
    'exit 1' >"${WORK}/bin/socat"
  chmod +x "${WORK}/bin/socat"
  start=${SECONDS}
  PATH="${WORK}/bin:${PATH}" run serve 'exit 0'
  [ "$status" -eq 1 ]
  [ $((SECONDS - start)) -le 2 ]
  [[ "$output" == *"Address already in use"* ]]
}
