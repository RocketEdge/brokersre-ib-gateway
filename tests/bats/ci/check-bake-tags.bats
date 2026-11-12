#!/usr/bin/env bats
# Unit tests for scripts/check-bake-tags.sh: the two channels must never claim the same tag.
# Runs wherever bash 5 and jq exist:
#   tests/.bats-core/bin/bats tests/bats/ci
#
# The contract under test: publish.yml publishes the channels in two independent jobs, each
# moving its own tags. A tag in both lists (IBKR puts both channels on one major.minor, or on
# one version) would be moved by both, the last writer would win and the other channel's
# check would fail after its channel tag had moved. That must stop a build before it starts.
#
# The fixtures are real `docker buildx bake --print stable latest` outputs of this repository's
# docker-bake.hcl: with the pinned versions, with a rebuild suffix, and with the latest
# channel's version variables set to the stable minor and to the stable version.

bats_require_minimum_version 1.5.0 # `run --separate-stderr`

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/check-bake-tags.sh"
  FX="${BATS_TEST_DIRNAME}/fixtures/bake"
  WORK="$(mktemp -d)"
}

teardown() {
  rm -rf "${WORK}"
}

@test "the pinned versions: the two channels share no tag" {
  run "$SCRIPT" "${FX}/bake-print.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"share no tag"* ]]
}

@test "a rebuild suffix adds a tag per channel and still shares none" {
  run "$SCRIPT" "${FX}/bake-print-rebuild.json"
  [ "$status" -eq 0 ]
}

@test "both channels on one major.minor: the shared minor tag is named and the check fails" {
  run "$SCRIPT" "${FX}/bake-print-same-minor.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ghcr.io/rocketedge/brokersre-ib-gateway:10.50"* ]]
  [[ "$output" != *":10.50.2a"* ]]
}

@test "both channels on one version: version and minor tags are both named" {
  run "$SCRIPT" "${FX}/bake-print-same-version.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ghcr.io/rocketedge/brokersre-ib-gateway:10.50.1g"* ]]
  [[ "$output" == *"ghcr.io/rocketedge/brokersre-ib-gateway:10.50"$'\n'* ]]
}

@test "the definition is read from standard input when no file is given" {
  run bash -c "'$SCRIPT' < '${FX}/bake-print-same-minor.json'"
  [ "$status" -eq 1 ]
  run bash -c "'$SCRIPT' < '${FX}/bake-print.json'"
  [ "$status" -eq 0 ]
}

@test "a definition that lacks one of the two targets is refused: nothing was compared" {
  run "$SCRIPT" "${FX}/bake-print-stable-only.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"latest"* ]]
}

@test "a target without tags is refused" {
  jq '.target.latest.tags = []' "${FX}/bake-print.json" > "${WORK}/empty-tags.json"
  run "$SCRIPT" "${WORK}/empty-tags.json"
  [ "$status" -eq 2 ]
}

@test "truncated, empty or non-bake input is refused, never read as disjoint" {
  head -c 300 "${FX}/bake-print.json" > "${WORK}/truncated.json"
  run "$SCRIPT" "${WORK}/truncated.json"
  [ "$status" -eq 2 ]
  : > "${WORK}/empty.json"
  run "$SCRIPT" "${WORK}/empty.json"
  [ "$status" -eq 2 ]
  echo '{}' > "${WORK}/other.json"
  run "$SCRIPT" "${WORK}/other.json"
  [ "$status" -eq 2 ]
  run "$SCRIPT" "${WORK}/missing.json"
  [ "$status" -eq 2 ]
  [[ "$output" != *"share no tag"* ]]
}

@test "the shared tags are reported on stdout, a refusal on stderr only" {
  run --separate-stderr "$SCRIPT" "${FX}/bake-print-same-minor.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *":10.50"* ]]
  run --separate-stderr "$SCRIPT" "${WORK}/missing.json"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "more than one argument prints usage" {
  run "$SCRIPT" a b
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage"* ]]
}
