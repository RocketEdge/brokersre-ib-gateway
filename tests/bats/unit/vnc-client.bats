#!/usr/bin/env bats
# Unit tests for tests/container/vnc-client.sh, the bash VNC client the container suite uses to
# play a person on the break-glass console. Its DES must be exact: a wrong table entry would
# make the container test fail only for some of the random challenges the server sends.
#
# The expected values are published DES test vectors (the worked example used in teaching
# material for FIPS 46, the all-zero and all-one blocks, and "Now is t" under
# 0123456789abcdef); the bash code was also compared with OpenSSL on 300 random keys and
# blocks when it was written. The stand-in servers are socat listeners on loopback.

setup() {
  CLIENT="${BATS_TEST_DIRNAME}/../../container/vnc-client.sh"
  WORK="$(mktemp -d)"
  PORT=$((40000 + RANDOM % 20000))
  # Assembled, so that no scanner takes this file for a leak.
  SECRET="hunter2""vnc"
  printf '%s\n' "${SECRET}" >"${WORK}/pw"
}

teardown() {
  pkill -f "TCP-LISTEN:${PORT}" 2>/dev/null || true
  rm -rf "${WORK}"
}

# lib FUNCTION ARGS...: call one function of the client in a fresh bash.
lib() {
  VNC_CLIENT_LIB=1 bash -uc "source '${CLIENT}'; \"\$@\"" _ "$@"
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

# A server that speaks RFB 3.8 with VNC authentication as far as the client goes. It records
# what the client sent (hex, one item per line) in WORK/seen and answers the password check
# with the four bytes in RESULT. The challenge is the bytes 00 01 ... 0f. A probe connection
# that sends nothing ends at the first read.
rfb_server() { # RESULT (eight hex digits)
  serve 'seen="'"${WORK}"'/seen"
printf "RFB 003.008\n"
version="$(dd bs=1 count=12 2>/dev/null | od -An -v -tx1 | tr -d " \n")"
[ -n "${version}" ] || exit 0
printf "%s\n" "version ${version}" >>"${seen}"
printf "\x01\x02"
printf "%s\n" "type $(dd bs=1 count=1 2>/dev/null | od -An -v -tx1 | tr -d " \n")" >>"${seen}"
printf "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f"
printf "%s\n" "response $(dd bs=1 count=16 2>/dev/null | od -An -v -tx1 | tr -d " \n")" >>"${seen}"
printf "'"$(sed 's/../\\x&/g' <<<"$1")"'"
[ "'"$1"'" = "00000000" ] || exit 0
printf "%s\n" "init $(dd bs=1 count=1 2>/dev/null | od -An -v -tx1 | tr -d " \n")" >>"${seen}"
printf "\x04\x00\x03\x00\x10\x10\x00\xff\x00\x1f\x00\x3f\x00\x1f\x0b\x05\x00\x00\x00\x00\x00\x00\x00\x00"
printf "%s\n" "after $(timeout 2 dd bs=1 count=6 2>/dev/null | od -An -v -tx1 | tr -d " \n")" >>"${seen}"'
}

@test "DES encrypts the published test vectors" {
  run lib des_encrypt_block 133457799bbcdff1 0123456789abcdef
  [ "$output" == "85e813540f0ab405" ]
  run lib des_encrypt_block 0000000000000000 0000000000000000
  [ "$output" == "8ca64de9c1b123a7" ]
  run lib des_encrypt_block ffffffffffffffff ffffffffffffffff
  [ "$output" == "7359b2163e4edc58" ]
  run lib des_encrypt_block 0123456789abcdef 4e6f772069732074
  [ "$output" == "3fa40e8a984d4815" ]
}

@test "the VNC key is the password's first eight bytes, zero padded, each byte mirrored" {
  run lib vnc_des_key abc
  [ "$output" == "8646c60000000000" ]
  run lib vnc_des_key abcdefghIGNORED
  [ "$output" == "8646c626a666e616" ]
  run lib vnc_des_key ''
  [ "$output" == "0000000000000000" ]
}

@test "the answer to a challenge is each half encrypted with the VNC key" {
  key="$(lib vnc_des_key abcdefgh)"
  run lib vnc_response abcdefgh 0001020304050607ffffffffffffffff
  [ "${#output}" -eq 32 ]
  [ "${output:0:16}" == "$(lib des_encrypt_block "${key}" 0001020304050607)" ]
  [ "${output:16:16}" == "$(lib des_encrypt_block "${key}" ffffffffffffffff)" ]
}

@test "a call without a readable password file is a usage error" {
  run bash "${CLIENT}" --port 1
  [ "$status" -eq 2 ]
  run bash "${CLIENT}" --password-file "${WORK}/missing"
  [ "$status" -eq 2 ]
  run bash "${CLIENT}" --unknown
  [ "$status" -eq 2 ]
  run bash "${CLIENT}" --password-file "${WORK}/pw" --port http
  [ "$status" -eq 2 ]
}

@test "a closed port is a failure that names host and port, never the password" {
  run bash "${CLIENT}" --password-file "${WORK}/pw" --port 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"fail: cannot connect to 127.0.0.1:1"* ]]
  [[ "$output" != *"${SECRET}"* ]]
}

@test "a server that is not RFB 3.8 is a failure" {
  serve 'printf "SSH-2.0-nope\r\n"; sleep 2'
  run bash "${CLIENT}" --password-file "${WORK}/pw" --port "${PORT}" --hold 0
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not offer RFB 3.8"* ]]
}

@test "a full session: version, VNC authentication, the DES answer, ClientInit, one pointer event" {
  rfb_server 00000000
  run bash "${CLIENT}" --password-file "${WORK}/pw" --port "${PORT}" --hold 0 --move 123 77
  [ "$status" -eq 0 ]
  [ "$output" == "ok: session established (desktop 1024x768)" ]
  for _ in $(seq 1 50); do
    if grep -q '^after ' "${WORK}/seen"; then break; fi
    sleep 0.1
  done
  grep -q -x 'version 524642203030332e3030380a' "${WORK}/seen"
  grep -q -x 'type 02' "${WORK}/seen"
  grep -q -x "response $(lib vnc_response "${SECRET}" 000102030405060708090a0b0c0d0e0f)" "${WORK}/seen"
  grep -q -x 'init 01' "${WORK}/seen"
  # PointerEvent: type 5, no button, x = 123 (0x007b), y = 77 (0x004d)
  grep -q -x 'after 0500007b004d' "${WORK}/seen"
}

@test "a refused password is exit status 3 and the session goes no further" {
  rfb_server 00000001
  run bash "${CLIENT}" --password-file "${WORK}/pw" --port "${PORT}" --hold 0
  [ "$status" -eq 3 ]
  [ "$output" == "rejected: the server refused the password" ]
  ! grep -q '^init ' "${WORK}/seen"
}
