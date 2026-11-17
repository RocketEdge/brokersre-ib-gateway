#!/usr/bin/env bats
# scripts/bake-env.sh and docker-bake.hcl pass IBKR's build stamp of the pinned version to the
# Dockerfile, so a bake build (CI, publish.yml) gets the same post-install stamp check as the
# build helper, and is labelled qualified. Needs jq; the bake test also needs docker buildx.
#   tests/.bats-core/bin/bats tests/bats/ci/bake-env.bats
#
# The contract under test: for each channel, `<CHANNEL>_BUILD_STAMP` is
# "(.<last part of the version>) <build_datetime>" (10.50.1g, "20261109 16:10:13" ->
# "(.1g) 20261109 16:10:13", the stamp the published 10.50.1g image carries), and the bake
# targets pass it as IB_GATEWAY_BUILD_STAMP together with IB_GATEWAY_QUALIFIED=yes (a bake
# build verifies the pinned SHA-256). Outside GitHub Actions a missing jq or docker skips.

bats_require_minimum_version 1.5.0 # `run --separate-stderr`

setup() {
  REPO="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  WORK="$(mktemp -d)"
}

teardown() {
  rm -rf "${WORK}"
}

# require_command NAME: succeed when NAME is installed; otherwise skip the test, except on
# GitHub Actions, where a missing tool fails it.
require_command() {
  if command -v "$1" >/dev/null 2>&1; then
    return 0
  fi
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    echo "$1 is not installed on the runner"
    return 1
  fi
  skip "$1 is not installed here; the lint job of ci.yml runs this test"
}

@test "bake-env.sh exports each channel's build stamp from versions.json" {
  require_command jq
  jq '.channels.stable.version = "10.50.1g" | .channels.stable.build_datetime = "20261109 16:10:13"
      | .channels.latest.version = "10.52.1d" | .channels.latest.build_datetime = "20261112 16:03:29"' \
    "${REPO}/versions.json" >"${WORK}/versions.json"
  run "${REPO}/scripts/bake-env.sh" "${WORK}/versions.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"export STABLE_BUILD_STAMP='(.1g) 20261109 16:10:13'"* ]]
  [[ "$output" == *"export LATEST_BUILD_STAMP='(.1d) 20261112 16:03:29'"* ]]
}

@test "bake-env.sh refuses a versions.json without a build_datetime for a channel" {
  require_command jq
  jq 'del(.channels.latest.build_datetime)' "${REPO}/versions.json" >"${WORK}/versions.json"
  run "${REPO}/scripts/bake-env.sh" "${WORK}/versions.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"build_datetime"* ]]
}

@test "the bake targets pass the pinned build stamp, qualified=yes and installer source ibkr to the Dockerfile" {
  require_command jq
  require_command docker
  eval "$("${REPO}/scripts/bake-env.sh")"
  run --separate-stderr docker buildx bake -f "${REPO}/docker-bake.hcl" --print stable latest
  [ "$status" -eq 0 ]
  stable_stamp="($(jq -r '.channels.stable.version | split(".") | ".\(.[2])"' "${REPO}/versions.json")) $(jq -r .channels.stable.build_datetime "${REPO}/versions.json")"
  latest_stamp="($(jq -r '.channels.latest.version | split(".") | ".\(.[2])"' "${REPO}/versions.json")) $(jq -r .channels.latest.build_datetime "${REPO}/versions.json")"
  printf '%s' "$output" | jq -e --arg s "${stable_stamp}" --arg l "${latest_stamp}" '
    .target.stable.args.IB_GATEWAY_BUILD_STAMP == $s and .target.latest.args.IB_GATEWAY_BUILD_STAMP == $l
    and .target.stable.args.IB_GATEWAY_QUALIFIED == "yes" and .target.latest.args.IB_GATEWAY_QUALIFIED == "yes"
    and .target.stable.args.IB_GATEWAY_INSTALLER_SOURCE == "ibkr" and .target.latest.args.IB_GATEWAY_INSTALLER_SOURCE == "ibkr"'
}
