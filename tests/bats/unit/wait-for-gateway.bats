#!/usr/bin/env bats
# Unit tests for examples/wait-for-gateway.sh: strategy code must not start talking to a
# gateway that is not ready. "Ready" is more than an open port: the script waits until a TCP
# connection succeeds AND the TWS API handshake is answered. The gateway is played by socat
# stand-ins (a good server, a silent one, one that drops the client, one that speaks another
# protocol); nothing here contacts IBKR.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../examples/wait-for-gateway.sh"
  STUB="$(mktemp -d)"
  PORT=47001
  # The good server: read the client's 17 handshake bytes one by one (so that nothing after
  # them is swallowed), record them as hex, answer with a length-prefixed
  # "<server version>\0<connection time>\0" (26 bytes), then record whatever else arrives.
  printf '%s\n' '#!/usr/bin/env bash' \
    'dir="$1"' \
    'dd bs=1 count=17 2>/dev/null | od -An -v -tx1 | tr -d " \n" >"${dir}/hello.hex"' \
    "printf '\\0\\0\\0\\032178\\00020261112 10:00:00 UTC\\0'" \
    'cat >"${dir}/rest"' >"${STUB}/good.sh"
  # The silent server: accepts and never answers (a Gateway whose API thread is stuck).
  printf '%s\n' '#!/usr/bin/env bash' 'read -r -t 30 _ || true' >"${STUB}/silent.sh"
  # Another protocol on the port (a wrong port number in the configuration).
  printf '%s\n' '#!/usr/bin/env bash' "printf 'HTTP/1.1 400 Bad Request\\r\\n\\r\\n'" >"${STUB}/http.sh"
  chmod +x "${STUB}"/*.sh
}

teardown() {
  pkill -f "${STUB}" 2>/dev/null || true
  pkill -f "TCP-LISTEN:${PORT}" 2>/dev/null || true
  rm -rf "${STUB}"
}

# serve PROGRAM...: listen on 127.0.0.1:${PORT} and run PROGRAM for every connection. Output
# and descriptor 3 are closed so that bats does not wait for the listener.
serve() {
  socat "TCP-LISTEN:${PORT},bind=127.0.0.1,reuseaddr,fork" "EXEC:$*" >/dev/null 2>&1 3>&- &
  local deadline=$((SECONDS + 10))
  until bash -c "exec 3<>/dev/tcp/127.0.0.1/${PORT}" 2>/dev/null; do
    if ((SECONDS >= deadline)); then return 1; fi
    sleep 0.1
  done
  # The probe above was a connection of its own: let its handler finish and forget its traces.
  sleep 0.3
  rm -f "${STUB}/hello.hex" "${STUB}/rest"
}

@test "a gateway that answers the API handshake is ready: exit 0, the server version is reported" {
  serve "${STUB}/good.sh ${STUB}"
  run "${SCRIPT}" --host 127.0.0.1 --port "${PORT}" --timeout 10
  [ "$status" -eq 0 ]
  [[ "$output" == *"ready"* ]]
  [[ "$output" == *"server version 178"* ]]
}

@test "exactly the handshake is sent and nothing else: no startApi, no client id, no request" {
  serve "${STUB}/good.sh ${STUB}"
  run "${SCRIPT}" --host 127.0.0.1 --port "${PORT}" --timeout 10
  [ "$status" -eq 0 ]
  # "API\0", the big-endian length 9, "v157..178".
  local deadline=$((SECONDS + 5))
  until [ -e "${STUB}/rest" ]; do
    if ((SECONDS >= deadline)); then return 1; fi
    sleep 0.1
  done
  [ "$(cat "${STUB}/hello.hex")" == "4150490000000009763135372e2e313738" ]
  [ ! -s "${STUB}/rest" ]
}

@test "a server that accepts and stays silent is not ready: exit 1 at the timeout" {
  serve "${STUB}/silent.sh"
  local start=${SECONDS}
  run "${SCRIPT}" --host 127.0.0.1 --port "${PORT}" --timeout 3
  [ "$status" -eq 1 ]
  [[ "$output" == *"timeout"* ]]
  [[ "$output" == *"no answer to the API handshake"* ]]
  [ $((SECONDS - start)) -lt 10 ]
}

@test "a closed port is not ready: exit 1 at the timeout, the reason is 'cannot connect'" {
  local start=${SECONDS}
  run "${SCRIPT}" --host 127.0.0.1 --port "${PORT}" --timeout 2
  [ "$status" -eq 1 ]
  [[ "$output" == *"timeout"* ]]
  [[ "$output" == *"cannot connect"* ]]
  [ $((SECONDS - start)) -lt 8 ]
}

@test "a relay that accepts and drops the client (Gateway not logged in) is not ready" {
  serve true
  run "${SCRIPT}" --host 127.0.0.1 --port "${PORT}" --timeout 2
  [ "$status" -eq 1 ]
  [[ "$output" == *"closed the connection"* ]]
}

@test "another protocol on the port is not ready and is named as such" {
  serve "${STUB}/http.sh"
  run "${SCRIPT}" --host 127.0.0.1 --port "${PORT}" --timeout 2
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a TWS API"* ]]
}

@test "a gateway that becomes ready while the script waits ends the wait with exit 0" {
  (
    sleep 2
    socat "TCP-LISTEN:${PORT},bind=127.0.0.1,reuseaddr,fork" "EXEC:${STUB}/good.sh ${STUB}"
  ) >/dev/null 2>&1 3>&- &
  run "${SCRIPT}" --host 127.0.0.1 --port "${PORT}" --timeout 30
  [ "$status" -eq 0 ]
  [[ "$output" == *"cannot connect"* ]]
  [[ "$output" == *"ready"* ]]
}

@test "after '--' the command runs once the gateway is ready, with its arguments and exit status" {
  serve "${STUB}/good.sh ${STUB}"
  run "${SCRIPT}" --host 127.0.0.1 --port "${PORT}" --timeout 10 -- bash -c 'echo "strategy started: $1"; exit 7' _ arg-one
  [ "$status" -eq 7 ]
  [[ "$output" == *"strategy started: arg-one"* ]]
}

@test "after '--' the command does not run when the gateway never becomes ready" {
  run "${SCRIPT}" --host 127.0.0.1 --port "${PORT}" --timeout 2 -- touch "${STUB}/started"
  [ "$status" -eq 1 ]
  [ ! -e "${STUB}/started" ]
}

@test "--quiet prints nothing when the gateway is ready" {
  serve "${STUB}/good.sh ${STUB}"
  run "${SCRIPT}" --quiet --host 127.0.0.1 --port "${PORT}" --timeout 10
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "host and port come from IBGW_HOST and IBGW_PORT when no option is given; --opt=value works" {
  serve "${STUB}/good.sh ${STUB}"
  IBGW_HOST=127.0.0.1 IBGW_PORT="${PORT}" run "${SCRIPT}" --timeout=10
  [ "$status" -eq 0 ]
  run "${SCRIPT}" --host=127.0.0.1 --port="${PORT}" --timeout=10
  [ "$status" -eq 0 ]
}

@test "usage errors exit 2 and name the problem" {
  run "${SCRIPT}" --frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown option"* ]]
  run "${SCRIPT}" --port abc
  [ "$status" -eq 2 ]
  [[ "$output" == *"--port"* ]]
  run "${SCRIPT}" --port 70000
  [ "$status" -eq 2 ]
  run "${SCRIPT}" --timeout 0
  [ "$status" -eq 2 ]
  [[ "$output" == *"--timeout"* ]]
  run "${SCRIPT}" --timeout
  [ "$status" -eq 2 ]
  run "${SCRIPT}" --host 'bad host/name'
  [ "$status" -eq 2 ]
  [[ "$output" == *"--host"* ]]
  run "${SCRIPT}" stray-argument
  [ "$status" -eq 2 ]
}

@test "--help prints the usage with the exit codes and exits 0" {
  run "${SCRIPT}" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: wait-for-gateway.sh"* ]]
  [[ "$output" == *"0 ready"* ]]
}
