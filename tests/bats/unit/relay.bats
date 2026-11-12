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
  pkill -f "${STUB_DIR}/socat" 2>/dev/null || true
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
  wait_until 5 relay_running
  wait_until 5 starts_are 1
  grep -q 'TCP-LISTEN:4004' "${STARTS}"
  grep -q 'TCP:127.0.0.1:4002' "${STARTS}"
  wait_until 5 grep -q '"event":"relay_opened"' "${STUB_DIR}/events"
}

@test "the relay closes when the Gateway leaves logged-in (daily restart, re-login)" {
  echo logged-in >"${LOG_DIR}/state/phase"
  start_relay
  wait_until 5 relay_running
  echo restarting >"${LOG_DIR}/state/phase"
  wait_until 5 relay_stopped
  wait_until 5 grep -q '"event":"relay_closed"' "${STUB_DIR}/events"
  # ... and opens again after the restart.
  echo logged-in >"${LOG_DIR}/state/phase"
  wait_until 5 relay_running
  wait_until 5 starts_are 2
}

@test "RELAY_MODE=always keeps the old behaviour: the relay listens from the start" {
  export RELAY_MODE=always
  echo login >"${LOG_DIR}/state/phase"
  start_relay
  wait_until 5 relay_running
  wait_until 5 starts_are 1
}

@test "test mode (IBC_LAUNCH=no) listens without a login" {
  export IBC_LAUNCH=no
  echo test-mode >"${LOG_DIR}/state/phase"
  start_relay
  wait_until 5 relay_running
}

@test "a relay that dies while it is wanted is started again" {
  echo logged-in >"${LOG_DIR}/state/phase"
  start_relay
  wait_until 5 relay_running
  pkill -f "${STUB_DIR}/socat"
  wait_until 5 bash -c "[ \"\$(wc -l <'${STARTS}')\" -ge 2 ]"
  wait_until 5 relay_running
}

@test "stopping the supervisor stops the relay" {
  echo logged-in >"${LOG_DIR}/state/phase"
  start_relay
  wait_until 5 relay_running
  wait_until 5 test -s "${PIDFILE}"
  kill "$(cat "${PIDFILE}")"
  wait_until 5 relay_stopped
}

@test "an invalid RELAY_MODE is refused with config_invalid" {
  export RELAY_MODE=sometimes
  run bash -c "source '${BROKERSRE_LIB}/common.sh'; source '${BROKERSRE_LIB}/start-socat.sh'; start_socat"
  [ "$status" -ne 0 ]
  echo "$output" | tail -1 | jq -e '.event == "config_invalid"' >/dev/null
}
