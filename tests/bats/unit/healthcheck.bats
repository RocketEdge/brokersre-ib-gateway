#!/usr/bin/env bats
# Unit tests for healthcheck.sh with the probes replaced by stubs.

setup() {
  : "${BROKERSRE_LIB:?set BROKERSRE_LIB to rootfs/usr/local/lib/brokersre}"
  HC="${BROKERSRE_LIB}/healthcheck.sh"
}

@test "healthy when the IBC process is alive and the API port accepts connections" {
  HEALTHCHECK_PGREP=true HEALTHCHECK_TCP=true TRADING_MODE=paper run "${HC}"
  [ "$status" -eq 0 ]
  [[ "$output" == healthy:* ]]
  [[ "$output" == *"4002"* ]]
}

@test "unhealthy when the process is dead" {
  HEALTHCHECK_PGREP=false HEALTHCHECK_TCP=true run "${HC}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"process not running"* ]]
}

@test "unhealthy while the API port is closed (for example 2FA pending)" {
  HEALTHCHECK_PGREP=true HEALTHCHECK_TCP=false run "${HC}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not accepting connections"* ]]
}

@test "live mode probes port 4001" {
  HEALTHCHECK_PGREP=true HEALTHCHECK_TCP=true TRADING_MODE=live run "${HC}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"4001"* ]]
}

@test "test mode (IBC_LAUNCH=no) is healthy when only the relay listens" {
  IBC_LAUNCH=no HEALTHCHECK_PGREP=false HEALTHCHECK_TCP=true TRADING_MODE=paper run "${HC}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"relay listening on 4004"* ]]
}

@test "an invalid TRADING_MODE is unhealthy" {
  TRADING_MODE=both run "${HC}"
  [ "$status" -eq 1 ]
}
