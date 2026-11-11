#!/usr/bin/env bats
# Unit tests for scripts/release-decision.sh: what detect-releases.yml does with what IBKR serves.
# Runs on any bash 5 host (CI lint job, Git Bash):
#   tests/.bats-core/bin/bats tests/bats/ci
#
# The contract under test: a new version opens a pull request (auto-merged only on stable, the
# channel CI builds and tests); different bytes under the pinned version (an IBKR re-upload, seen
# for 10.51.1e on 2026-11-05) never auto-merge; identical bytes do nothing.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/release-decision.sh"
  A=$(printf 'a%.0s' {1..64})
  B=$(printf 'b%.0s' {1..64})
  C=$(printf 'c%.0s' {1..64})
  D=$(printf 'd%.0s' {1..64})
}

@test "same version and same bytes: nothing to do" {
  run "$SCRIPT" stable 10.50.1g "$A" "$B" 10.50.1g "$A" "$B"
  [ "$status" -eq 0 ]
  [ "$output" = $'action=none\nautomerge=false' ]
}

@test "new stable version: pull request that auto-merges once CI is green" {
  run "$SCRIPT" stable 10.50.1g "$A" "$B" 10.50.1h "$C" "$D"
  [ "$status" -eq 0 ]
  [ "$output" = $'action=new-version\nautomerge=true' ]
}

@test "new latest version: pull request without auto-merge (CI builds stable only)" {
  run "$SCRIPT" latest 10.51.1e "$A" "$B" 10.51.1f "$C" "$D"
  [ "$status" -eq 0 ]
  [ "$output" = $'action=new-version\nautomerge=false' ]
}

@test "same version, different x64 bytes: re-upload, never auto-merged" {
  run "$SCRIPT" stable 10.50.1g "$A" "$B" 10.50.1g "$C" "$B"
  [ "$status" -eq 0 ]
  [ "$output" = $'action=reupload\nautomerge=false' ]
}

@test "same version, different arm bytes only: still a re-upload" {
  run "$SCRIPT" latest 10.51.1e "$A" "$B" 10.51.1e "$A" "$D"
  [ "$status" -eq 0 ]
  [ "$output" = $'action=reupload\nautomerge=false' ]
}

@test "hash comparison ignores case (sha256sum prints lower case, a hand edit may not)" {
  upper=$(printf 'A%.0s' {1..64})
  run "$SCRIPT" stable 10.50.1g "$upper" "$B" 10.50.1g "$A" "$B"
  [ "$status" -eq 0 ]
  [ "$output" = $'action=none\nautomerge=false' ]
}

@test "unknown channel is refused" {
  run "$SCRIPT" beta 10.50.1g "$A" "$B" 10.50.1h "$C" "$D"
  [ "$status" -eq 2 ]
  [[ "$output" == *"channel"* ]]
}

@test "a malformed hash is refused rather than read as a re-upload" {
  run "$SCRIPT" stable 10.50.1g "$A" "$B" 10.50.1g "not-a-hash" "$B"
  [ "$status" -eq 2 ]
  [[ "$output" == *"SHA-256"* ]]
}

@test "an empty IBKR version (manifest not parsed) is refused" {
  run "$SCRIPT" stable 10.50.1g "$A" "$B" "" "$C" "$D"
  [ "$status" -eq 2 ]
  [[ "$output" == *"version"* ]]
}

@test "wrong number of arguments prints usage" {
  run "$SCRIPT" stable
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage"* ]]
}
