#!/usr/bin/env bats
# Unit tests for start-socat.sh: the relay that publishes the Gateway's API port must listen
# only while the Gateway is logged in. A relay that listens earlier accepts a client and then
# drops it (the Gateway behind it is not there yet), which strategy code sees as a connection
# reset instead of a clean "connection refused".

setup() {
  : "${BROKERSRE_LIB:?set BROKERSRE_LIB to rootfs/usr/local/lib/brokersre}"
  export LOG_DIR="$(mktemp -d)"
  mkdir -p "${LOG_DIR}/state"
  STUB_DIR="$(mktemp -d)"
  export STARTS="${STUB_DIR}/starts"
  : >"${STARTS}"
  # A stand-in for socat: records that it was started with which arguments, then stays alive
  # under its own name (no exec), so the tests can find it by its path.
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >>"${STARTS}"' 'sleep 600 &' 'wait' >"${STUB_DIR}/socat"
  chmod +x "${STUB_DIR}/socat"
  export PATH="${STUB_DIR}:${PATH}"
  export SOCAT_PORT=4004 API_PORT=4002 TRADING_MODE=paper RELAY_POLL_S=0.2 SOCAT_RESTART_DELAY=0
  unset RELAY_MODE IBC_LAUNCH
  PIDFILE="${STUB_DIR}/pid"
}

teardown() {
  if [ -s "${PIDFILE}" ]; then
    pid="$(cat "${PIDFILE}")"
    kill "${pid}" 2>/dev/null || true
  fi
  # A supervisor that a test started without recording its pid (a start that should have been
  # refused and was not) must not outlive the test.
  pkill -f "source '${BROKERSRE_LIB}/start-socat.sh'" 2>/dev/null || true
  pkill -f "${STUB_DIR}/socat" 2>/dev/null || true
  # The real-socat tests: their backend and relay must be gone before the next test binds
  # the same ports, also when the test failed half way.
  if [ -s "${STUB_DIR}/backend.pid" ]; then
    kill "$(cat "${STUB_DIR}/backend.pid")" 2>/dev/null || true
  fi
  pkill -f 'TCP-LISTEN:1560' 2>/dev/null || true
  rm -rf "${LOG_DIR}" "${STUB_DIR}"
}

# start_relay: run start_socat in a background shell that stays alive, record the supervisor's
# pid and send the events to a file (descriptor 3 closed so bats does not wait for it).
start_relay() {
  bash -c "source '${BROKERSRE_LIB}/common.sh'; source '${BROKERSRE_LIB}/start-socat.sh'; start_socat; echo \"\${SOCAT_PID}\" >'${PIDFILE}'; wait" \
    >"${STUB_DIR}/events" 2>&1 3>&- &
}

wait_until() {
  local deadline=$((SECONDS + $1))
  shift
  until "$@" 2>/dev/null; do
    if ((SECONDS >= deadline)); then return 1; fi
    sleep 0.1
  done
}

starts() { wc -l <"${STARTS}"; }
# starts_are <n>: true once the stand-in has been started exactly <n> times (it records the
# start a moment after its process appears, so the count is polled, not read once).
starts_are() { [ "$(starts)" == "$1" ]; }
relay_running() { pgrep -f "${STUB_DIR}/socat" >/dev/null; }
# Called directly (not through bash -c): a shell whose own command line holds the stub path
# would be matched by pgrep -f and the relay would seem to run forever.
relay_stopped() { ! pgrep -f "${STUB_DIR}/socat" >/dev/null; }

@test "the relay stays closed while the Gateway is not logged in" {
  echo login >"${LOG_DIR}/state/phase"
  start_relay
  sleep 1
  [ "$(starts)" == "0" ]
  ! relay_running
}

@test "the relay opens when the phase becomes logged-in" {
  echo 2fa-pending >"${LOG_DIR}/state/phase"
  start_relay
  sleep 0.6
  [ "$(starts)" == "0" ]
  echo logged-in >"${LOG_DIR}/state/phase"
  wait_until 20 relay_running
  wait_until 20 starts_are 1
  grep -q 'TCP-LISTEN:4004' "${STARTS}"
  grep -q 'TCP:127.0.0.1:4002' "${STARTS}"
  wait_until 20 grep -q '"event":"relay_opened"' "${STUB_DIR}/events"
}

@test "the relay closes when the Gateway leaves logged-in (daily restart, re-login)" {
  echo logged-in >"${LOG_DIR}/state/phase"
  start_relay
  wait_until 20 relay_running
  echo restarting >"${LOG_DIR}/state/phase"
  wait_until 20 relay_stopped
  wait_until 20 grep -q '"event":"relay_closed"' "${STUB_DIR}/events"
  # ... and opens again after the restart.
  echo logged-in >"${LOG_DIR}/state/phase"
  wait_until 20 relay_running
  wait_until 20 starts_are 2
}

@test "RELAY_MODE=always keeps the old behaviour: the relay listens from the start" {
  export RELAY_MODE=always
  echo login >"${LOG_DIR}/state/phase"
  start_relay
  wait_until 20 relay_running
  wait_until 20 starts_are 1
}

@test "test mode (IBC_LAUNCH=no) listens without a login" {
  export IBC_LAUNCH=no
  echo test-mode >"${LOG_DIR}/state/phase"
  start_relay
  wait_until 20 relay_running
}

@test "a relay that dies while it is wanted is started again" {
  echo logged-in >"${LOG_DIR}/state/phase"
  start_relay
  wait_until 20 relay_running
  pkill -f "${STUB_DIR}/socat"
  wait_until 20 bash -c "[ \"\$(wc -l <'${STARTS}')\" -ge 2 ]"
  wait_until 20 relay_running
}

@test "stopping the supervisor stops the relay" {
  echo logged-in >"${LOG_DIR}/state/phase"
  start_relay
  wait_until 20 relay_running
  wait_until 20 test -s "${PIDFILE}"
  kill "$(cat "${PIDFILE}")"
  wait_until 20 relay_stopped
}

@test "an invalid RELAY_MODE is refused with config_invalid" {
  export RELAY_MODE=sometimes
  run bash -c "source '${BROKERSRE_LIB}/common.sh'; source '${BROKERSRE_LIB}/start-socat.sh'; start_socat"
  [ "$status" -ne 0 ]
  echo "$output" | tail -1 | jq -e '.event == "config_invalid"' >/dev/null
}

# ---------------------------------------------------------------------------------------------
# RELAY_ALLOW_CIDR: an optional allowlist for the relay. The API behind the relay has no
# authentication, so the network that may reach it is the only access control there is.
# ---------------------------------------------------------------------------------------------

# relay_fn ARGS...: call one function of start-socat.sh in a fresh shell.
relay_fn() {
  bash -c "source '${BROKERSRE_LIB}/common.sh'; source '${BROKERSRE_LIB}/start-socat.sh'; \"\$@\"" _ "$@"
}

# refusal PEER: one line as socat 1.8 writes it for a peer outside the range (copied from a
# real run in this image, with the peer replaced).
refusal() {
  printf '2026/11/12 03:26:53 socat[8] W refusing connection from AF=2 %s:42974 due to range option\n' "$1"
}

@test "without RELAY_ALLOW_CIDR the listener is started exactly as before" {
  export RELAY_MODE=always
  unset RELAY_ALLOW_CIDR
  start_relay
  wait_until 5 starts_are 1
  [ "$(cat "${STARTS}")" == "TCP-LISTEN:4004,fork,reuseaddr TCP:127.0.0.1:4002" ]
}

@test "RELAY_ALLOW_CIDR limits the listener to that network and the events name it" {
  export RELAY_MODE=always RELAY_ALLOW_CIDR=10.20.0.0/16 RUN_DIR="${STUB_DIR}"
  start_relay
  wait_until 5 starts_are 1
  grep -q -- "-lf ${STUB_DIR}/relay.log TCP-LISTEN:4004,fork,reuseaddr,range=10.20.0.0/16 TCP:127.0.0.1:4002" "${STARTS}"
  wait_until 5 grep -q '"event":"relay_opened"' "${STUB_DIR}/events"
  grep '"event":"socat_started"' "${STUB_DIR}/events" | grep -q '10.20.0.0/16'
  grep '"event":"relay_opened"' "${STUB_DIR}/events" | grep -q '10.20.0.0/16'
}

@test "relay_allow_cidr_valid accepts one IPv4 network in CIDR form" {
  for value in 10.0.0.0/8 172.18.0.0/16 192.168.1.7/32 127.0.0.1/32 0.0.0.0/0 255.255.255.255/32; do
    run relay_fn relay_allow_cidr_valid "${value}"
    [ "$status" -eq 0 ] || {
      echo "refused: ${value}"
      return 1
    }
  done
}

@test "relay_allow_cidr_valid refuses everything else, above all a second socat option" {
  for value in '' 10.0.0.0 10.0.0.0/33 300.1.1.1/8 10.0.0/8 '10.0.0.0/8,range=0.0.0.0/0' '10.0.0.0/8,fork' \
    '::1/128' 'fd00::/8' ' 10.0.0.0/8' '10.0.0.0/8 ' any '10.0.0.0/8/8' '10.0.0.0:255.0.0.0' '1e1.0.0.0/8' '10.0.0.0/-1'; do
    run relay_fn relay_allow_cidr_valid "${value}"
    # Exactly 1: a function that does not exist (127) must not count as a refusal.
    [ "$status" -eq 1 ] || {
      echo "status ${status} for '${value}'"
      return 1
    }
  done
}

@test "an invalid RELAY_ALLOW_CIDR is refused with config_invalid and no relay starts" {
  export RELAY_MODE=always RELAY_ALLOW_CIDR='10.0.0.0/8,range=0.0.0.0/0'
  # Output to a file, not through `run`: a start that is wrongly accepted leaves a supervisor
  # behind, and `run` would wait for it for ever instead of failing.
  status=0
  bash -c "source '${BROKERSRE_LIB}/common.sh'; source '${BROKERSRE_LIB}/start-socat.sh'; start_socat" \
    >"${STUB_DIR}/out" 2>&1 3>&- || status=$?
  [ "$status" -ne 0 ]
  tail -n 1 "${STUB_DIR}/out" | jq -e '.event == "config_invalid" and .level == "error" and (.msg | contains("RELAY_ALLOW_CIDR"))' >/dev/null
  [ "$(starts)" == "0" ]
}

@test "a refused peer is reported at once, with the peer and the allowed network" {
  export RELAY_ALLOW_CIDR=10.20.0.0/16
  refusal 172.18.0.9 >"${STUB_DIR}/relay.log"
  run relay_fn relay_refusals_poll "${STUB_DIR}/relay.log" 1000
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  echo "${lines[0]}" | jq -e '.event == "relay_refused" and .level == "warn" and .src == "socat"' >/dev/null
  echo "${lines[0]}" | jq -e '.data.count == "1" and .data.last_peer == "172.18.0.9" and .data.allow == "10.20.0.0/16"' >/dev/null
  # The lines were consumed: the file on the run directory never grows without limit.
  [ ! -s "${STUB_DIR}/relay.log" ]
}

@test "further refusals are held back for RELAY_REFUSED_REPORT_S and then reported as one count" {
  export RELAY_ALLOW_CIDR=10.20.0.0/16 RELAY_REFUSED_REPORT_S=60
  run bash -c "source '${BROKERSRE_LIB}/common.sh'; source '${BROKERSRE_LIB}/start-socat.sh'
    log='${STUB_DIR}/relay.log'
    printf '%s\n' '2026/11/12 03:26:53 socat[8] W refusing connection from AF=2 172.18.0.9:42974 due to range option' >\"\${log}\"
    relay_refusals_poll \"\${log}\" 1000
    for peer in 172.18.0.10 172.18.0.11 172.18.0.12; do
      printf '%s\n' \"2026/11/12 03:26:54 socat[8] W refusing connection from AF=2 \${peer}:5 due to range option\" >>\"\${log}\"
    done
    relay_refusals_poll \"\${log}\" 1010
    relay_refusals_poll \"\${log}\" 1059
    echo MARK
    relay_refusals_poll \"\${log}\" 1060
    relay_refusals_poll \"\${log}\" 1061"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  echo "${lines[0]}" | jq -e '.data.count == "1"' >/dev/null
  [ "${lines[1]}" == "MARK" ]
  echo "${lines[2]}" | jq -e '.event == "relay_refused" and .data.count == "3" and .data.last_peer == "172.18.0.12"' >/dev/null
}

@test "only range refusals are counted, and a peer that is not an IPv4 address is not echoed" {
  export RELAY_ALLOW_CIDR=10.20.0.0/16
  {
    echo '2026/11/12 03:26:54 socat[20] N listening on AF=2 0.0.0.0:4004'
    echo '2026/11/12 03:26:55 socat[26] W exiting on signal 15'
    echo '2026/11/12 03:26:56 socat[27] E connect(5, AF=2 127.0.0.1:4002, 16): Connection refused'
  } >"${STUB_DIR}/relay.log"
  run relay_fn relay_refusals_poll "${STUB_DIR}/relay.log" 1000
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  echo '2026/11/12 03:26:57 socat[28] W refusing connection from AF=2 "},{"x":"y due to range option' >"${STUB_DIR}/relay.log"
  run relay_fn relay_refusals_poll "${STUB_DIR}/relay.log" 2000
  [ "$status" -eq 0 ]
  echo "${lines[0]}" | jq -e '.data.count == "1" and .data.last_peer == "unknown"' >/dev/null
}

@test "a missing or empty relay log reports nothing" {
  export RELAY_ALLOW_CIDR=10.20.0.0/16
  run relay_fn relay_refusals_poll "${STUB_DIR}/absent.log" 1000
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  : >"${STUB_DIR}/relay.log"
  run relay_fn relay_refusals_poll "${STUB_DIR}/relay.log" 1000
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# The two tests below use the real socat of the image: they prove that the option does what
# this image relies on (a peer outside the network gets no byte of the API).

# real_relay CIDR: start a backend that answers `hello` and the relay in front of it.
real_relay() {
  export PATH="${PATH#"${STUB_DIR}:"}"
  export RELAY_MODE=always RELAY_ALLOW_CIDR="$1" RUN_DIR="${STUB_DIR}" SOCAT_PORT=15602 API_PORT=15601 RELAY_REFUSED_REPORT_S=1
  socat TCP-LISTEN:15601,fork,reuseaddr SYSTEM:'echo hello' >/dev/null 2>&1 3>&- &
  echo $! >"${STUB_DIR}/backend.pid"
  start_relay
  wait_until 10 grep -q '"event":"relay_opened"' "${STUB_DIR}/events"
  # A TCP connect that succeeds proves that the port listens. (For a peer outside the network
  # this probe is itself refused and counted, which the tests allow for.)
  wait_until 10 bash -c 'exec 9<>/dev/tcp/127.0.0.1/15601'
  wait_until 10 bash -c 'exec 9<>/dev/tcp/127.0.0.1/15602'
}

stop_real_relay() {
  kill "$(cat "${PIDFILE}")" 2>/dev/null || true
  kill "$(cat "${STUB_DIR}/backend.pid")" 2>/dev/null || true
  pkill -f 'TCP-LISTEN:1560' 2>/dev/null || true
}

@test "real socat: a peer inside RELAY_ALLOW_CIDR is relayed" {
  real_relay 127.0.0.0/8
  run timeout 10 socat -u TCP:127.0.0.1:15602 STDOUT
  stop_real_relay
  [ "$output" == "hello" ]
  ! grep -q '"event":"relay_refused"' "${STUB_DIR}/events"
}

@test "real socat: a peer outside RELAY_ALLOW_CIDR gets nothing and is reported" {
  real_relay 127.0.0.2/32
  run timeout 10 socat -u TCP:127.0.0.1:15602 STDOUT
  [ -z "$output" ]
  wait_until 10 grep -q '"event":"relay_refused"' "${STUB_DIR}/events"
  stop_real_relay
  grep '"event":"relay_refused"' "${STUB_DIR}/events" | head -1 | jq -e '.data.last_peer == "127.0.0.1" and .data.allow == "127.0.0.2/32"' >/dev/null
}
