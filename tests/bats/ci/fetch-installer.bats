#!/usr/bin/env bats
# Unit tests for scripts/fetch-installer.sh, the build-time installer fetch of the Dockerfile's
# setup stage. Runs wherever bash 5 and coreutils exist; no network, no Docker:
#   tests/.bats-core/bin/bats tests/bats/ci
#
# The contract under test:
#   - `fetch-installer.sh <dest>` (unchanged): a pre-fetched installer in /tmp/downloads is used
#     only when its SHA-256 equals the pin; otherwise the build fails. Only the pre-fetched path
#     is exercised here (the download path needs IBKR).
#   - `fetch-installer.sh --read-stamp <install dir>` prints what the installed Gateway says it
#     is, read from `<install dir>/.install4j/i4jparams.conf`: `version: 10.50.1h` (the number
#     of applicationName plus the suffix in applicationVersion's parentheses), `build_stamp:
#     (.1h) 20261116 16:02:08` (applicationVersion as written) and `media: <mediaName>`.
#   - `fetch-installer.sh --check-stamp <install dir>` compares that with IB_GATEWAY_BUILD_STAMP
#     and IB_GATEWAY_VERSION when IB_GATEWAY_BUILD_STAMP is set, and fails naming expected and
#     actual; with it unset the check is skipped (exit 0). The real file of 10.50.1g reads
#     `applicationName="IB Gateway 10.50" applicationVersion="(.1g) 20261109 16:10:13"`.

setup() {
  REPO="${BATS_TEST_DIRNAME}/../../.."
  SCRIPT="${REPO}/scripts/fetch-installer.sh"
  WORK="$(mktemp -d)"
  INSTALL="${WORK}/install"
  unset IB_GATEWAY_BUILD_STAMP IB_GATEWAY_VERSION
}

teardown() {
  rm -rf "${WORK}"
}

# installed NAME VERSION [MEDIA]: write an i4jparams.conf as install4j writes it into
# ${INSTALL}/.install4j (the attributes this check reads, in their real order).
installed() {
  mkdir -p "${INSTALL}/.install4j"
  cat >"${INSTALL}/.install4j/i4jparams.conf" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<config install4jVersion="12.0.5" install4jBuild="12102" type="unix" archive="false" bitness="undefined">
  <general applicationName="$1" applicationVersion="$2" mediaSetId="1335" status="LCOK" mediaName="${3:-ibgateway-stable-standalone-linux-x64}" jreVersion="25.0.5.0.3-zulu" />
</config>
EOF
}

@test "--read-stamp prints the version, the build stamp and the media name of the installed Gateway" {
  installed "IB Gateway 10.50" "(.1h) 20261116 16:02:08"
  run "$SCRIPT" --read-stamp "${INSTALL}"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "version: 10.50.1h" ]
  [ "${lines[1]}" = "build_stamp: (.1h) 20261116 16:02:08" ]
  [ "${lines[2]}" = "media: ibgateway-stable-standalone-linux-x64" ]
}

@test "--read-stamp fails when the install has no i4jparams.conf" {
  mkdir -p "${INSTALL}"
  run "$SCRIPT" --read-stamp "${INSTALL}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"i4jparams.conf"* ]]
}

@test "--read-stamp fails when the stamp names no version (no number in the name, no suffix)" {
  installed "IB Gateway" "20261116 16:02:08"
  run "$SCRIPT" --read-stamp "${INSTALL}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot derive a version"* ]]
}

@test "--check-stamp passes when the installed stamp and version equal what the build expects" {
  installed "IB Gateway 10.50" "(.1g) 20261109 16:10:13"
  IB_GATEWAY_VERSION=10.50.1g IB_GATEWAY_BUILD_STAMP="(.1g) 20261109 16:10:13" run "$SCRIPT" --check-stamp "${INSTALL}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"build stamp ok"* ]]
}

@test "--check-stamp fails naming expected and actual when the build stamp differs" {
  installed "IB Gateway 10.50" "(.1h) 20261116 16:02:08"
  IB_GATEWAY_VERSION=10.50.1h IB_GATEWAY_BUILD_STAMP="(.1h) 20261116 16:02:09" run "$SCRIPT" --check-stamp "${INSTALL}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BUILD STAMP MISMATCH"* ]]
  [[ "$output" == *"expected (.1h) 20261116 16:02:09"* ]]
  [[ "$output" == *"actual   (.1h) 20261116 16:02:08"* ]]
}

@test "--check-stamp fails naming both versions when the stamp matches but the version does not" {
  installed "IB Gateway 10.51" "(.1h) 20261116 16:02:08"
  IB_GATEWAY_VERSION=10.50.1h IB_GATEWAY_BUILD_STAMP="(.1h) 20261116 16:02:08" run "$SCRIPT" --check-stamp "${INSTALL}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VERSION MISMATCH"* ]]
  [[ "$output" == *"expected 10.50.1h"* ]]
  [[ "$output" == *"actual   10.51.1h"* ]]
}

@test "--check-stamp is skipped when IB_GATEWAY_BUILD_STAMP is not set" {
  installed "IB Gateway 10.50" "(.1h) 20261116 16:02:08"
  IB_GATEWAY_VERSION=10.50.1g run "$SCRIPT" --check-stamp "${INSTALL}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not checked"* ]]
}

@test "--check-stamp fails when IB_GATEWAY_BUILD_STAMP is set and the install has no stamp" {
  mkdir -p "${INSTALL}"
  IB_GATEWAY_VERSION=10.50.1g IB_GATEWAY_BUILD_STAMP="(.1g) 20261109 16:10:13" run "$SCRIPT" --check-stamp "${INSTALL}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"i4jparams.conf"* ]]
}

@test "the fetch contract is unchanged: a pre-fetched installer matching the pin is used" {
  [ -w /tmp ] || skip "needs a writable /tmp"
  # The script looks for /tmp/downloads/<file>; a private directory stands in through a copy
  # of the script whose prefetch path points there (the script's only absolute path).
  mkdir -p "${WORK}/downloads"
  printf 'installer bytes\n' >"${WORK}/downloads/ibgateway-10.50.1g-standalone-linux-x64.sh"
  sha=$(sha256sum "${WORK}/downloads/ibgateway-10.50.1g-standalone-linux-x64.sh" | cut -d' ' -f1)
  sed "s|/tmp/downloads/|${WORK}/downloads/|" "$SCRIPT" >"${WORK}/fetch.sh"
  TARGETARCH=amd64 IB_GATEWAY_VERSION=10.50.1g IB_GATEWAY_CHANNEL=stable IB_GATEWAY_SHA256_X64="$sha" \
    IB_GATEWAY_URL_BASE=https://invalid.example run bash "${WORK}/fetch.sh" "${WORK}/out.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sha256 ok (pre-fetched)"* ]]
  cmp "${WORK}/out.sh" "${WORK}/downloads/ibgateway-10.50.1g-standalone-linux-x64.sh"
}

@test "the fetch contract is unchanged: a pre-fetched installer that does not match the pin fails" {
  mkdir -p "${WORK}/downloads"
  printf 'other bytes\n' >"${WORK}/downloads/ibgateway-10.50.1g-standalone-linux-x64.sh"
  sed "s|/tmp/downloads/|${WORK}/downloads/|" "$SCRIPT" >"${WORK}/fetch.sh"
  TARGETARCH=amd64 IB_GATEWAY_VERSION=10.50.1g IB_GATEWAY_CHANNEL=stable IB_GATEWAY_SHA256_X64="$(printf '0%.0s' {1..64})" \
    IB_GATEWAY_URL_BASE=https://invalid.example run bash "${WORK}/fetch.sh" "${WORK}/out.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not match the pinned sha256"* ]]
}
