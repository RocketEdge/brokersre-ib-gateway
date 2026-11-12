#!/usr/bin/env bats
# Unit tests for scripts/check-report-arch.sh: did Trivy scan the platform it was asked to scan?
# Runs wherever bash 5 and jq exist:
#   tests/.bats-core/bin/bats tests/bats/ci
#
# The contract under test: the workflows ask for a platform through an environment variable of
# the scanner action. If that variable were ever dropped or renamed, Trivy would scan the
# runner's own platform twice and both scans would pass. Each report must therefore name the
# platform that was asked for, or the job stops.
#
# The fixtures are real Trivy 0.76.2 reports (fixtures/trivy/README.md).

bats_require_minimum_version 1.5.0 # `run --separate-stderr`

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/check-report-arch.sh"
  FX="${BATS_TEST_DIRNAME}/fixtures/trivy"
  WORK="$(mktemp -d)"
}

teardown() {
  rm -rf "${WORK}"
}

@test "a linux/amd64 report asked for as linux/amd64 passes" {
  run "$SCRIPT" "${FX}/gateway-os-clean.json" linux/amd64
  [ "$status" -eq 0 ]
  [[ "$output" == *"linux/amd64"* ]]
}

@test "a linux/arm64 report asked for as linux/arm64 passes" {
  run "$SCRIPT" "${FX}/gateway-arm64-full.json" linux/arm64
  [ "$status" -eq 0 ]
  [[ "$output" == *"linux/arm64"* ]]
}

@test "an amd64 report where arm64 was asked for fails and names both" {
  run "$SCRIPT" "${FX}/gateway-os-clean.json" linux/arm64
  [ "$status" -eq 1 ]
  [[ "$output" == *"linux/amd64"* ]]
  [[ "$output" == *"linux/arm64"* ]]
}

@test "an arm64 report where amd64 was asked for fails" {
  run "$SCRIPT" "${FX}/debian-os-gate-arm64.json" linux/amd64
  [ "$status" -eq 1 ]
}

@test "a report that does not name its platform is refused, not passed" {
  jq 'del(.Metadata.ImageConfig)' "${FX}/gateway-os-clean.json" > "${WORK}/no-platform.json"
  run "$SCRIPT" "${WORK}/no-platform.json" linux/amd64
  [ "$status" -eq 2 ]
}

@test "a missing, empty, truncated or non-Trivy report is refused" {
  run "$SCRIPT" "${WORK}/missing.json" linux/amd64
  [ "$status" -eq 2 ]
  : > "${WORK}/empty.json"
  run "$SCRIPT" "${WORK}/empty.json" linux/amd64
  [ "$status" -eq 2 ]
  head -c 200 "${FX}/gateway-os-clean.json" > "${WORK}/truncated.json"
  run "$SCRIPT" "${WORK}/truncated.json" linux/amd64
  [ "$status" -eq 2 ]
  echo '{"Metadata":{"ImageConfig":{"os":"linux","architecture":"amd64"}}}' > "${WORK}/other.json"
  run "$SCRIPT" "${WORK}/other.json" linux/amd64
  [ "$status" -eq 2 ]
}

@test "only the two platforms this image is built for can be asked for" {
  run "$SCRIPT" "${FX}/gateway-os-clean.json" amd64
  [ "$status" -eq 2 ]
  run "$SCRIPT" "${FX}/gateway-os-clean.json" linux/riscv64
  [ "$status" -eq 2 ]
  run "$SCRIPT" "${FX}/gateway-os-clean.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage"* ]]
}

@test "a mismatch is reported on stdout, a refusal on stderr only" {
  run --separate-stderr "$SCRIPT" "${FX}/gateway-os-clean.json" linux/arm64
  [ "$status" -eq 1 ]
  [ -n "$output" ]
  run --separate-stderr "$SCRIPT" "${WORK}/missing.json" linux/amd64
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}
