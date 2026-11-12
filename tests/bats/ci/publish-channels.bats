#!/usr/bin/env bats
# Unit tests for scripts/publish-channels.sh: turn the `channels` input of publish.yml into the
# JSON list its build matrix runs over. Needs bash only:
#   tests/.bats-core/bin/bats tests/bats/ci
#
# The contract under test: the input is text typed by whoever dispatches the workflow, and the
# jobs it selects hold `packages: write` and `id-token: write`. Only the two channel names may
# come out; anything else (a command substitution, a glob, a line break, an unknown name) is
# refused before a matrix exists, and nothing in the input is ever executed or expanded.

bats_require_minimum_version 1.5.0 # `run --separate-stderr`

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/publish-channels.sh"
  WORK="$(mktemp -d)"
}

teardown() {
  rm -rf "${WORK}"
}

@test "both channels (the default of a push): a matrix of both" {
  run "$SCRIPT" "stable latest"
  [ "$status" -eq 0 ]
  [ "$output" = 'channels=["stable","latest"]' ]
}

@test "one channel (a fix-driven rebuild): a matrix of that channel only" {
  run "$SCRIPT" "latest"
  [ "$status" -eq 0 ]
  [ "$output" = 'channels=["latest"]' ]
  run "$SCRIPT" "stable"
  [ "$status" -eq 0 ]
  [ "$output" = 'channels=["stable"]' ]
}

@test "order, repeats and extra spaces do not matter: each channel once, stable first" {
  run "$SCRIPT" "  latest   stable latest "
  [ "$status" -eq 0 ]
  [ "$output" = 'channels=["stable","latest"]' ]
}

@test "a command substitution is refused and never run" {
  run "$SCRIPT" "\$(touch ${WORK}/pwned)"
  [ "$status" -eq 2 ]
  [ ! -e "${WORK}/pwned" ]
  run "$SCRIPT" "stable \`touch ${WORK}/pwned\`"
  [ "$status" -eq 2 ]
  [ ! -e "${WORK}/pwned" ]
  run "$SCRIPT" 'stable;id'
  [ "$status" -eq 2 ]
}

@test "a glob is refused and never expanded, even when the directory holds files named like channels" {
  cd "${WORK}"
  touch stable latest
  run "$SCRIPT" '*'
  [ "$status" -eq 2 ]
  run "$SCRIPT" 'stable *'
  [ "$status" -eq 2 ]
  run "$SCRIPT" 'st?ble'
  [ "$status" -eq 2 ]
}

@test "a line break or a tab in the list is refused" {
  run "$SCRIPT" $'stable\nlatest'
  [ "$status" -eq 2 ]
  run "$SCRIPT" $'stable\nchannels=["x"]'
  [ "$status" -eq 2 ]
  run "$SCRIPT" $'stable\tlatest'
  [ "$status" -eq 2 ]
}

@test "an unknown name is refused, also beside a valid one and in another case" {
  run "$SCRIPT" "beta"
  [ "$status" -eq 2 ]
  [[ "$output" == *"beta"* ]]
  run "$SCRIPT" "stable latest beta"
  [ "$status" -eq 2 ]
  run "$SCRIPT" "STABLE"
  [ "$status" -eq 2 ]
  run "$SCRIPT" "stablelatest"
  [ "$status" -eq 2 ]
}

@test "an empty or blank list is refused: no silent default" {
  run "$SCRIPT" ""
  [ "$status" -eq 2 ]
  [[ "$output" == *"empty"* ]]
  run "$SCRIPT" "   "
  [ "$status" -eq 2 ]
}

@test "wrong number of arguments prints usage" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage"* ]]
  run "$SCRIPT" stable latest
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage"* ]]
}

@test "a refusal goes to stderr only, so it can never reach GITHUB_OUTPUT" {
  run --separate-stderr "$SCRIPT" 'stable $(id)'
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"publish-channels"* ]]
}
