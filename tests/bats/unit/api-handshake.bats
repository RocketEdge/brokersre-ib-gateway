#!/usr/bin/env bats
# Unit tests for api-handshake.sh: a read-only proof that the Gateway's API answers.
#
# An open TCP port is not enough: a Gateway whose API thread is dead still accepts connections
# (reported upstream as "accepts TCP but never answers"). The TWS API starts with a handshake:
# the client sends "API\0" and a length-prefixed version range, the server answers with a
# length-prefixed "<serverVersion>\0<connection time>\0". Nothing else is sent: no startApi, no
# client id, no request, so the probe cannot collide with a strategy's client id or touch
# an order. The fake servers below are socat listeners; no test contacts IBKR.

setup() {
  : "${BROKERSRE_LIB:?set BROKERSRE_LIB to rootfs/usr/local/lib/brokersre}"
  WORK="$(mktemp -d)"
  PORT=$((40000 + RANDOM % 20000))
  PROBE="${BROKERSRE_LIB}/api-handshake.sh"
}

teardown() {
  pkill -f "TCP-LISTEN:${PORT}" 2>/dev/null || true
  rm -rf "${WORK}"
}

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

# A server that behaves like the Gateway: reads the 17 handshake bytes, records them as hex,
# and answers "176\0" + "20261112 08:00:00 EST\0" (26 bytes, length prefix 0x0000001a).
good_server='dd bs=1 count=17 2>/dev/null | od -An -v -tx1 | tr -d " \n" >>"'"REQ"'"; printf "\x00\x00\x00\x1a176\x0020261112 08:00:00 EST\x00"; sleep 1'

@test "a Gateway that answers the handshake is reported with its server version" {
  serve "${good_server/REQ/${WORK}/request.hex}"
  run "${PROBE}" 127.0.0.1 "${PORT}" 5
  [ "$status" -eq 0 ]
  [[ "$output" == "ok: API answered the handshake (server version 176)"* ]]
}

@test "the probe sends exactly the TWS API handshake and nothing else" {
  serve "${good_server/REQ/${WORK}/request.hex}"
  "${PROBE}" 127.0.0.1 "${PORT}" 5 >/dev/null
  # "API\0", big-endian length 9, "v157..178"
  [ "$(cat "${WORK}/request.hex")" == "4150490000000009763135372e2e313738" ]
}

@test "a server that accepts the connection but never answers is a failure within the timeout" {
  serve 'sleep 30'
  start=${SECONDS}
  run "${PROBE}" 127.0.0.1 "${PORT}" 2
  [ "$status" -eq 1 ]
  [ $((SECONDS - start)) -le 5 ]
  [[ "$output" == "fail: no answer to the API handshake within 2 s"* ]]
}

@test "a reply that is not a TWS API handshake is a failure" {
  serve 'dd bs=1 count=17 >/dev/null 2>&1; printf "HTTP/1.1 400 Bad Request\r\n\r\n"; sleep 1'
  run "${PROBE}" 127.0.0.1 "${PORT}" 3
  [ "$status" -eq 1 ]
  [[ "$output" == fail:* ]]
}

@test "a reply whose server version is not a number is a failure" {
  serve 'dd bs=1 count=17 >/dev/null 2>&1; printf "\x00\x00\x00\x08abc\x00xyz\x00"; sleep 1'
  run "${PROBE}" 127.0.0.1 "${PORT}" 3
  [ "$status" -eq 1 ]
  [[ "$output" == fail:* ]]
}

@test "a server that closes the connection without answering is a failure" {
  serve 'dd bs=1 count=17 >/dev/null 2>&1'
  run "${PROBE}" 127.0.0.1 "${PORT}" 3
  [ "$status" -eq 1 ]
  [[ "$output" == fail:* ]]
}

@test "a closed port is a failure, quickly" {
  start=${SECONDS}
  run "${PROBE}" 127.0.0.1 "${PORT}" 5
  [ "$status" -eq 1 ]
  [ $((SECONDS - start)) -le 3 ]
  [[ "$output" == "fail: cannot connect to 127.0.0.1:${PORT}"* ]]
}

@test "the default port follows TRADING_MODE" {
  run env TRADING_MODE=banana "${PROBE}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"TRADING_MODE"* ]]
}

@test "a timeout that is not a positive number is a usage error" {
  run "${PROBE}" 127.0.0.1 "${PORT}" soon
  [ "$status" -eq 2 ]
}
