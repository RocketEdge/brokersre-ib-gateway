#!/usr/bin/env bats
# Unit tests for start-vnc.sh: the break-glass VNC password must never appear in a process
# argument list (`ps` shows argv to every process in the container) and must not stay on disk.

setup() {
  : "${BROKERSRE_LIB:?set BROKERSRE_LIB to rootfs/usr/local/lib/brokersre}"
  export RUN_DIR="$(mktemp -d)"
  export LOG_DIR="$(mktemp -d)"
  export DISPLAY=":1"
  STUB_DIR="$(mktemp -d)"
  ARGV_LOG="${STUB_DIR}/argv.log"
  export ARGV_LOG
  # A stand-in for x11vnc that records every invocation's arguments, and for -passwdfile
  # records the mode and content of the file it was pointed at (as the real one reads it).
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" "ARGV: $*" >>"${ARGV_LOG}"' \
    'prev=""' \
    'for a in "$@"; do' \
    '  if [ "${prev}" = "-passwdfile" ]; then' \
    '    f="${a#rm:}"' \
    '    printf "%s\n" "MODE: $(stat -c %a "${f}")" "CONTENT: $(cat "${f}")" "RM_PREFIX: ${a%%:*}" >>"${ARGV_LOG}"' \
    '  fi' \
    '  prev="${a}"' \
    'done' >"${STUB_DIR}/x11vnc"
  chmod +x "${STUB_DIR}/x11vnc"
  export PATH="${STUB_DIR}:${PATH}"
  unset VNC_SERVER_PASSWORD VNC_SERVER_PASSWORD_FILE
}

teardown() {
  rm -rf "${RUN_DIR}" "${LOG_DIR}" "${STUB_DIR}"
}

vnc() {
  bash -c "source '${BROKERSRE_LIB}/common.sh'; source '${BROKERSRE_LIB}/start-vnc.sh'; start_vnc; wait; $1"
}

@test "without a password VNC stays disabled and x11vnc is never started" {
  run vnc 'true'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.event == "vnc_disabled"' >/dev/null
  [ ! -e "${ARGV_LOG}" ]
}

@test "the password never appears in any x11vnc argument list" {
  export VNC_SERVER_PASSWORD='hunter2vnc'
  run vnc 'true'
  [ "$status" -eq 0 ]
  grep -q '^ARGV: ' "${ARGV_LOG}"
  ! grep '^ARGV: ' "${ARGV_LOG}" | grep -q 'hunter2vnc' || false
}

@test "x11vnc reads the password from a private file that it removes after reading" {
  export VNC_SERVER_PASSWORD='hunter2vnc'
  run vnc 'true'
  [ "$status" -eq 0 ]
  grep -q -x 'MODE: 600' "${ARGV_LOG}"
  grep -q -x 'CONTENT: hunter2vnc' "${ARGV_LOG}"
  grep -q -x 'RM_PREFIX: rm' "${ARGV_LOG}"
}

@test "VNC listens on loopback only and the secret leaves the environment" {
  export VNC_SERVER_PASSWORD='hunter2vnc'
  run vnc 'echo "P=${VNC_SERVER_PASSWORD:-unset}"'
  [ "$status" -eq 0 ]
  grep '^ARGV: ' "${ARGV_LOG}" | grep -q -- '-localhost'
  [[ "$output" == *"P=unset"* ]]
  [[ "$output" != *"hunter2vnc"* ]]
}
