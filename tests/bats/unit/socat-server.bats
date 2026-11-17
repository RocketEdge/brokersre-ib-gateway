#!/usr/bin/env bats
# Unit tests for socat-server.bash, the stand-in TCP server of api-handshake.bats and
# vnc-client.bats. serve() must hand its test a listening server whatever the container's
# network namespace already holds. In November 2026 a listener that never came up failed CI
# twice ("a full session" on #43, "a refused password" on main at f999345): the port drawn for
# it was the local port of an earlier client connection that was still in TIME_WAIT, so socat
# could not bind it even with reuseaddr, exited, and its error went to /dev/null.

load socat-server

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

@test "serve listens even when PORT names a client's port that is still in TIME_WAIT" {
  serve 'exit 0'
  # The client closes first, so its own port stays in TIME_WAIT (60 s on Linux). The old
  # readiness probe and every test client did exactly this.
  bash -c "exec 3<>/dev/tcp/127.0.0.1/${PORT}"
  held=""
  for _ in $(seq 1 20); do
    held="$(ss -Htan state time-wait "dport = :${PORT}" | awk '{ split($3, a, ":"); print a[2]; exit }')"
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
