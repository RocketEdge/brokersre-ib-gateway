#!/usr/bin/env bats
# The Dockerfile's post-install stamp check, with a fake installer (fake-installer.bash): builds
# the setup stage only, with BuildKit, and keeps nothing (--output type=cacheonly). Needs Docker
# with buildx and jq; IBC is downloaded from its pinned release (GitHub) when the check passes.
# Never contacts IBKR: the installer comes from downloads/ of a temporary build context.
#   tests/.bats-core/bin/bats tests/bats/ci/dockerfile-stamp.bats
#
# The contract under test: when IB_GATEWAY_BUILD_STAMP is passed, the setup stage fails unless
# the installed Gateway's applicationVersion equals it and its version (applicationName's number
# plus the stamp's suffix) equals IB_GATEWAY_VERSION; the failure names both values. Outside
# GitHub Actions a missing docker or jq skips these tests; on the runner it fails them.

setup() {
  load fake-installer
  REPO="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  WORK="$(mktemp -d)"
  CTX="${WORK}/context"
  mkdir -p "${CTX}/scripts" "${CTX}/downloads"
  cp "${REPO}/Dockerfile" "${CTX}/Dockerfile"
  cp "${REPO}/scripts/fetch-installer.sh" "${CTX}/scripts/fetch-installer.sh"
  VERSION=10.50.9z
  STAMP="(.9z) 20261201 01:02:03"
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

# build_setup NAME APP_VERSION STAMP_ARG: put a fake installer named NAME / APP_VERSION into the
# context as the x64 installer of ${VERSION}, and build the setup stage with IB_GATEWAY_BUILD_STAMP
# set to STAMP_ARG (unset when STAMP_ARG is "-"); `run` captures the build log.
build_setup() {
  local name="$1" app_version="$2" stamp_arg="$3" installer sha versions stamp_args=()
  installer="${CTX}/downloads/ibgateway-${VERSION}-standalone-linux-x64.sh"
  make_fake_installer "${installer}" "${name}" "${app_version}" ibgateway-stable-standalone-linux-x64
  sha="$(sha256_of "${installer}")"
  versions="${REPO}/versions.json"
  if [ "${stamp_arg}" != "-" ]; then stamp_args=(--build-arg "IB_GATEWAY_BUILD_STAMP=${stamp_arg}"); fi
  run docker buildx build --progress plain --platform linux/amd64 --target setup --output type=cacheonly \
    --build-arg "UBUNTU_DIGEST=$(jq -r .base.digest "${versions}")" \
    --build-arg "IBC_VERSION=$(jq -r .ibc.version "${versions}")" \
    --build-arg "IBC_RELEASE_TAG=$(jq -r .ibc.release_tag "${versions}")" \
    --build-arg "IBC_SHA256=$(jq -r .ibc.sha256 "${versions}")" \
    --build-arg IB_GATEWAY_CHANNEL=stable \
    --build-arg "IB_GATEWAY_VERSION=${VERSION}" \
    --build-arg "IB_GATEWAY_SHA256_X64=${sha}" \
    --build-arg "IB_GATEWAY_SHA256_ARM=${sha}" \
    "${stamp_args[@]}" "${CTX}"
}

@test "setup stage: an installed stamp equal to IB_GATEWAY_BUILD_STAMP passes and says so" {
  require_command docker
  require_command jq
  build_setup "IB Gateway 10.50" "${STAMP}" "${STAMP}"
  echo "$output" | tail -20
  [ "$status" -eq 0 ]
  [[ "$output" == *"build stamp ok (${STAMP}, IB Gateway ${VERSION})"* ]]
}

@test "setup stage: a different installed stamp fails the build, naming expected and actual" {
  require_command docker
  require_command jq
  build_setup "IB Gateway 10.50" "(.9z) 20261201 01:02:04" "${STAMP}"
  echo "$output" | tail -20
  [ "$status" -ne 0 ]
  [[ "$output" == *"BUILD STAMP MISMATCH"* ]]
  [[ "$output" == *"expected ${STAMP}"* ]]
  [[ "$output" == *"actual   (.9z) 20261201 01:02:04"* ]]
}

@test "setup stage: the right stamp under another version number fails the build, naming both" {
  require_command docker
  require_command jq
  build_setup "IB Gateway 10.51" "${STAMP}" "${STAMP}"
  echo "$output" | tail -20
  [ "$status" -ne 0 ]
  [[ "$output" == *"VERSION MISMATCH"* ]]
  [[ "$output" == *"expected ${VERSION}"* ]]
  [[ "$output" == *"actual   10.51.9z"* ]]
}
