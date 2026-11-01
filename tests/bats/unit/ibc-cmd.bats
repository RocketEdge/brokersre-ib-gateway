#!/usr/bin/env bats
# Unit tests for ibc-cmd.sh argument handling (the TCP path is covered by tests/container).

setup() {
  : "${BROKERSRE_LIB:?set BROKERSRE_LIB to rootfs/usr/local/lib/brokersre}"
  CMD="${BROKERSRE_LIB}/ibc-cmd.sh"
}

@test "unknown commands are rejected with exit 2" {
  run "${CMD}" FORMAT_DISK
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown command"* ]]
}

@test "a disabled command server (port 0) is reported with exit 2" {
  IBC_COMMAND_SERVER_PORT=0 run "${CMD}" STOP
  [ "$status" -eq 2 ]
  [[ "$output" == *"disabled"* ]]
}

@test "a closed port fails with exit 1 and a clear message" {
  run "${CMD}" RECONNECTDATA 127.0.0.1 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot connect"* ]]
}
