#!/usr/bin/env bats
# Unit tests for scripts/rebuild-channels.sh: turn the two per-channel decisions of the daily
# scan into the one `channels` value that rebuild.yml hands to publish.yml. Needs bash only:
#   tests/.bats-core/bin/bats tests/bats/ci
#
# The contract under test: only a channel whose scan said `rebuild` is named; a channel whose
# scan leg failed reports nothing and is left out without stopping the other; an empty list is
# an error, because publish.yml would read an empty `channels` input as "both".

bats_require_minimum_version 1.5.0 # `run --separate-stderr`

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/rebuild-channels.sh"
}

@test "both channels need a rebuild: one request names both, stable first" {
  run "$SCRIPT" rebuild rebuild
  [ "$status" -eq 0 ]
  [ "$output" = "channels=stable latest" ]
}

@test "one channel needs a rebuild: only that channel is named" {
  run "$SCRIPT" rebuild none
  [ "$status" -eq 0 ]
  [ "$output" = "channels=stable" ]
  run "$SCRIPT" none rebuild
  [ "$status" -eq 0 ]
  [ "$output" = "channels=latest" ]
}

@test "a channel whose scan failed reports nothing: the other channel's rebuild is still requested" {
  run "$SCRIPT" rebuild ""
  [ "$status" -eq 0 ]
  [ "$output" = "channels=stable" ]
  run "$SCRIPT" "" rebuild
  [ "$status" -eq 0 ]
  [ "$output" = "channels=latest" ]
}

@test "no channel needs a rebuild: an error, never an empty list (publish.yml reads empty as both)" {
  for pair in "none none" "none " " none" " "; do
    stable="${pair%% *}"
    latest="${pair#* }"
    run --separate-stderr "$SCRIPT" "$stable" "$latest"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
  done
}

@test "a value that is not rebuild, none or empty is refused" {
  run "$SCRIPT" 'rebuild;id' none
  [ "$status" -eq 2 ]
  run "$SCRIPT" none '$(id)'
  [ "$status" -eq 2 ]
  run "$SCRIPT" REBUILD none
  [ "$status" -eq 2 ]
  run "$SCRIPT" true rebuild
  [ "$status" -eq 2 ]
}

@test "wrong number of arguments prints usage; a refusal goes to stderr only" {
  run "$SCRIPT" rebuild
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage"* ]]
  run --separate-stderr "$SCRIPT" rebuild maybe
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"rebuild-channels"* ]]
}
