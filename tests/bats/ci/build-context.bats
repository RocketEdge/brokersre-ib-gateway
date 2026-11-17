#!/usr/bin/env bats
# What the image build sends to the builder: the repository's .dockerignore applied to a
# checkout in which someone followed the quick start (IBKR credentials in compose/secrets,
# settings in .env files) and left tool folders behind. The context is copied into an empty
# image (FROM scratch, COPY . /ctx/) and exported to a local folder, so the test reads exactly
# what BuildKit received; nothing is pulled, kept or pushed. Needs Docker with buildx.
#   tests/.bats-core/bin/bats tests/bats/ci/build-context.bats
#
# The contract under test: scripts/build-image.sh, build-image.ps1 and the bake path all build
# with the repository root as the context, so .dockerignore alone decides what leaves the
# checkout. It admits the Dockerfile's inputs (Dockerfile, rootfs/, scripts/fetch-installer.sh,
# the installer in downloads/) and never a secrets/ folder, a .env file or anything else, even
# inside an admitted folder. Outside GitHub Actions a missing docker skips these tests; on the
# runner it fails them.

setup() {
  REPO="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  WORK="$(mktemp -d)"
  CTX="${WORK}/checkout"
  OUT="${WORK}/received"
  mkdir -p "${CTX}"
  cp "${REPO}/.dockerignore" "${CTX}/.dockerignore"
  printf 'FROM scratch\nCOPY . /ctx/\n' >"${WORK}/list.Dockerfile"
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

# host_path PATH: PATH as the Docker CLI on this host reads it (Git Bash on Windows hands the
# CLI a Windows path; elsewhere unchanged), as scripts/build-image.sh does.
host_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# plant FILE...: create each FILE (relative to the checkout) with a fake value.
plant() {
  local file
  for file in "$@"; do
    mkdir -p "$(dirname "${CTX}/${file}")"
    printf 'fake-%s\n' "${file##*/}" >"${CTX}/${file}"
  done
}

# received: the files the builder received, one relative path per line, sorted. The build's
# own messages (warnings included) are printed only when it fails.
received() {
  if ! docker buildx build --quiet --platform linux/amd64 -f "$(host_path "${WORK}/list.Dockerfile")" \
    --output "type=local,dest=$(host_path "${OUT}")" "$(host_path "${CTX}")" >/dev/null 2>"${WORK}/build.err"; then
    cat "${WORK}/build.err"
    return 1
  fi
  (cd "${OUT}/ctx" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
}

@test "a checkout with credentials and .env files sends only the Dockerfile's inputs" {
  require_command docker
  plant Dockerfile rootfs/etc/brokersre/jts.ini.tmpl scripts/fetch-installer.sh \
    downloads/ibgateway-10.50.1h-standalone-linux-x64.sh \
    compose/secrets/ib-username compose/secrets/ib-password compose/.env .env secrets/ib-password \
    windows/gateway.env .venv/lib/site.py .git/config scripts/build-image.sh downloads/notes.txt \
    sidecar/bin/Debug/app.dll
  run received
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "Dockerfile
downloads/ibgateway-10.50.1h-standalone-linux-x64.sh
rootfs/etc/brokersre/jts.ini.tmpl
scripts/fetch-installer.sh" ]
}

@test "a secrets/ folder or a .env file inside an admitted folder is not sent either" {
  require_command docker
  plant Dockerfile rootfs/etc/brokersre/jts.ini.tmpl \
    rootfs/secrets/ib-password rootfs/etc/brokersre/secrets/ib-username rootfs/.env \
    rootfs/etc/gateway.env downloads/secrets/ib-password.sh
  run received
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "Dockerfile
rootfs/etc/brokersre/jts.ini.tmpl" ]
}
