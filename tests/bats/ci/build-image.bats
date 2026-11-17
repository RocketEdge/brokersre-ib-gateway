#!/usr/bin/env bats
# scripts/build-image.sh and its helper scripts/resolve-installer.sh against a fake IBKR server
# (fake-ibkr.py) and fake installers (fake-installer.bash). Nothing contacts IBKR: the helper is
# pointed at the fake server through BROKERSRE_TEST_IBKR_BASE_URL, the test-only override.
# Needs bash, curl, jq, python3, coreutils, tar and gzip (the GitHub runner has them):
#   tests/.bats-core/bin/bats tests/bats/ci/build-image.bats
#
# How it runs without Docker: a stub `docker` on PATH records every call; for `docker run` of
# the build helper image it runs the helper's command on this host with the `-v` mounts mapped
# back to host paths (so the real resolve-installer.sh does the work), `docker buildx build`
# only records its arguments, and the IBC smoke test meets a stub that makes it fail. The
# repository is copied to a temporary directory whose versions.json pins two fake installers
# (stable 10.50.1g, x64 and arm), so a "pinned" build is possible with fake bytes.
#
# The contract under test is the interface section of
# docs/specs/2026-11-17-private-image-public-recipe.md: options, exit codes (0 built, 1 failed,
# 2 usage, 3 IBKR unreachable and nothing usable cached, 4 --strict and IBKR serves another
# version), the seven last lines, the labels passed as build arguments, the cache, --print-plan.
# Outside GitHub Actions a missing tool skips these tests; on the runner it fails them.

bats_require_minimum_version 1.5.0 # `run --separate-stderr`

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

setup() {
  load fake-installer
  for tool in curl jq python3 tar gzip; do require_command "${tool}"; done
  SRC="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  WORK="$(mktemp -d)"
  REPO="${WORK}/repo"
  mkdir -p "${REPO}/scripts" "${REPO}/tests/container" "${REPO}/downloads" "${WORK}/bin" "${WORK}/stub"
  cp "${SRC}/scripts/build-image.sh" "${SRC}/scripts/resolve-installer.sh" "${SRC}/scripts/fetch-installer.sh" "${REPO}/scripts/"
  cp -R "${SRC}/scripts/build-helper" "${REPO}/scripts/build-helper"
  cp "${SRC}/tests/container/run.sh" "${REPO}/tests/container/run.sh"
  cp "${SRC}/Dockerfile" "${REPO}/Dockerfile"
  CACHE="${WORK}/cache"
  WWW="${WORK}/www"
  mkdir -p "${WWW}/stable-standalone" "${WWW}/latest-standalone"
  make_fake_installer "${WORK}/pinned-x64.sh" "IB Gateway 10.50" "(.1g) 20261109 16:10:13" ibgateway-stable-standalone-linux-x64
  make_fake_installer "${WORK}/pinned-arm.sh" "IB Gateway 10.50" "(.1g) 20261109 16:10:13" ibgateway-stable-standalone-linux-arm
  make_fake_installer "${WORK}/newer-x64.sh" "IB Gateway 10.50" "(.1h) 20261116 16:02:08" ibgateway-stable-standalone-linux-x64
  PIN_X64="$(sha256_of "${WORK}/pinned-x64.sh")"
  PIN_ARM="$(sha256_of "${WORK}/pinned-arm.sh")"
  NEWER_X64="$(sha256_of "${WORK}/newer-x64.sh")"
  jq --arg x "${PIN_X64}" --arg a "${PIN_ARM}" '.channels.stable.version = "10.50.1g"
      | .channels.stable.build_datetime = "20261109 16:10:13" | .channels.stable.sha256 = {x64: $x, arm: $a}' \
    "${SRC}/versions.json" >"${REPO}/versions.json"
  write_stub_docker
  export PATH="${WORK}/bin:${PATH}"
  export STUB_DIR="${WORK}/stub"
  unset XDG_CACHE_HOME STUB_ARCH STUB_BUILD_RC STUB_EXEC_RC STUB_RUN_RC STUB_DAEMON_DOWN
  unset HTTPS_PROXY HTTP_PROXY NO_PROXY https_proxy http_proxy no_proxy
  start_server
  export BROKERSRE_TEST_IBKR_BASE_URL="http://127.0.0.1:${PORT}"
}

teardown() {
  if [ -n "${SERVER_PID:-}" ]; then kill "${SERVER_PID}" 2>/dev/null || true; fi
  rm -rf "${WORK}"
}

# start_server: start fake-ibkr.py on a free port (PORT), serving ${WWW}, logging to
# ${WORK}/requests.log.
start_server() {
  : >"${WORK}/requests.log"
  python3 "${BATS_TEST_DIRNAME}/fake-ibkr.py" "${WWW}" "${WORK}/port" "${WORK}/requests.log" >/dev/null 2>&1 3>&- &
  SERVER_PID=$!
  for _ in $(seq 1 100); do
    [ -s "${WORK}/port" ] && break
    sleep 0.1
  done
  PORT="$(cat "${WORK}/port")"
}

# write_stub_docker: the stub described in the header, at ${WORK}/bin/docker.
write_stub_docker() {
  cat >"${WORK}/bin/docker" <<'STUB'
#!/usr/bin/env bash
# Stub docker for build-image.bats: records each call in ${STUB_DIR}/calls.
printf '%s\n' "$*" >>"${STUB_DIR}/calls"
case "$1" in
  info)
    if [ -n "${STUB_DAEMON_DOWN:-}" ]; then echo "error during connect: daemon not running" >&2 && exit 1; fi
    echo "${STUB_ARCH:-x86_64}"
    ;;
  version)
    if [ -n "${STUB_DAEMON_DOWN:-}" ]; then echo "error during connect: daemon not running" >&2 && exit 1; fi
    echo "29.9.3"
    ;;
  context) echo "desktop-linux" ;;
  build) echo "sha256:helper" ;;
  buildx)
    case "$2" in
      version) echo "github.com/docker/buildx v0.38.1 stub" ;;
      build)
        case " $* " in *" brokersre-ib-gateway-build-helper:local "*) echo "sha256:helper" && exit 0 ;; esac
        shift 2
        printf '%s\n' "$@" >"${STUB_DIR}/buildx-args"
        ls "${*: -1}/downloads" >"${STUB_DIR}/context-downloads" 2>&1
        exit "${STUB_BUILD_RC:-0}"
        ;;
      *) exit 1 ;;
    esac
    ;;
  image) echo "sha256:$(printf '%s' "${*: -1}" | sha256sum | cut -c1-64)" ;;
  exec) exit "${STUB_EXEC_RC:-0}" ;;
  run)
    if [ -n "${STUB_RUN_RC:-}" ]; then exit "${STUB_RUN_RC}"; fi
    shift
    case " $* " in *" brokersre-ib-gateway-build-helper:local "*) ;; *) exit 0 ;; esac
    mounts=()
    envs=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --rm | -i | -t) shift ;;
        -v | --volume)
          spec="${2%:ro}"
          mounts+=("${spec##*:}=${spec%:*}")
          shift 2
          ;;
        -e | --env)
          if [[ "$2" == *=* ]]; then envs+=("$2"); elif [ -n "${!2+x}" ]; then envs+=("$2=${!2}"); fi
          shift 2
          ;;
        -u | --user | -w | --workdir | --entrypoint | --network) shift 2 ;;
        *)
          shift
          break
          ;;
      esac
    done
    args=()
    for a in "$@"; do
      for m in "${mounts[@]}"; do
        dst="${m%%=*}"
        src="${m#*=}"
        if [ "$a" = "$dst" ] || [[ "$a" == "$dst"/* ]]; then
          a="${src}${a#"$dst"}"
          break
        fi
      done
      args+=("$a")
    done
    # What the helper's environment would be (docker passes only the -e variables), recorded
    # for the proxy tests; proxies of the test's own shell never leak in otherwise.
    for e in "${envs[@]}"; do printf '%s\n' "$e"; done >"${STUB_DIR}/helper-env"
    exec env -u BROKERSRE_TEST_IBKR_BASE_URL -u HTTPS_PROXY -u HTTP_PROXY -u NO_PROXY -u https_proxy -u http_proxy -u no_proxy "${envs[@]}" "${args[@]}"
    ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "${WORK}/bin/docker"
}

# serve_version CHANNEL VERSION DATETIME [N]: IBKR's version.json (JSONP) for CHANNEL, as the
# N-th answer when N is given.
serve_version() {
  printf 'ibgateway%s_callback({"buildVersion":"%s","buildDateTime":"%s"});' "$1" "$2" "$3" \
    >"${WWW}/$1-standalone/version.json${4:+.$4}"
}

# serve_installer CHANNEL ARCH FILE [N]: IBKR's unversioned installer URL for CHANNEL/ARCH
# answers with FILE (as the N-th answer when N is given).
serve_installer() {
  cp "$3" "${WWW}/$1-standalone/ibgateway-$1-standalone-linux-$2.sh${4:+.$4}"
}

# build ARGS...: run the build helper with the test cache; stdout in $output, stderr in $stderr.
build() {
  run --separate-stderr "${REPO}/scripts/build-image.sh" --cache-dir "${CACHE}" "$@"
}

# buildx_arg NAME: the value of `--build-arg NAME=...` of the recorded `docker buildx build`.
buildx_arg() {
  sed -n "s/^$1=//p" "${WORK}/stub/buildx-args"
}

# buildx_option OPTION: the values following OPTION in the recorded `docker buildx build`.
buildx_option() {
  awk -v o="$1" 'prev == o { print } { prev = $0 }' "${WORK}/stub/buildx-args"
}

# installer_requests CHANNEL ARCH: how many times the fake server served that installer.
installer_requests() {
  grep -c "^GET /$1-standalone/ibgateway-$1-standalone-linux-$2.sh$" "${WORK}/requests.log" || true
}

# no_runs_left: a failed resolve or build leaves no run directory (with its download) behind.
no_runs_left() {
  [ -z "$(ls -A "${CACHE}/runs" 2>/dev/null)" ]
}

# last_lines: the seven machine-readable lines the interface promises at the end of stdout.
last_lines() {
  printf '%s\n' "$output" | tail -n 7
}

@test "--help prints the interface and exits 0" {
  run "${REPO}/scripts/build-image.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--channel stable|latest"* ]]
  [[ "$output" == *"--print-plan"* ]]
  [[ "$output" == *"--installer FILE"* ]]
}

@test "--help says what qualified_by_project: yes means, and that a paper login is separate" {
  # A stable bump can become the pin without a person (ADR 0009, 0018): `yes` means "equals
  # the pin, which passed the offline CI", never "logged in with".
  run "${REPO}/scripts/build-image.sh" --help
  [ "$status" -eq 0 ]
  text="$(printf '%s\n' "$output" | tr -s ' \n' '  ')"
  [[ "${text}" == *"qualified_by_project: yes means the version and the installer's SHA-256 equal the pin in versions.json, which passed the project's offline CI"* ]]
  [[ "${text}" == *"a paper login is a separate qualification (scripts/qualify-paper.sh)"* ]]
}

@test "usage errors exit 2: unknown option, bad channel, bad platform, installer file missing" {
  build --bogus
  [ "$status" -eq 2 ]
  build --channel beta
  [ "$status" -eq 2 ]
  build --platform linux/386
  [ "$status" -eq 2 ]
  build --installer "${WORK}/no-such-installer.sh"
  [ "$status" -eq 2 ]
  build --tag
  [ "$status" -eq 2 ]
  [ ! -e "${WORK}/stub/buildx-args" ]
}

@test "IBKR serves the pin: SHA-256 verified, built qualified, the seven last lines" {
  serve_version stable 10.50.1g "20261109 16:10:13"
  serve_installer stable x64 "${WORK}/pinned-x64.sh"
  build --no-smoke
  echo "$stderr"
  [ "$status" -eq 0 ]
  last_lines >"${WORK}/last"
  [ "$(sed -n 1p "${WORK}/last")" = "version: 10.50.1g" ]
  [ "$(sed -n 2p "${WORK}/last")" = "channel: stable" ]
  [ "$(sed -n 3p "${WORK}/last")" = "qualified_by_project: yes" ]
  [ "$(sed -n 4p "${WORK}/last")" = "installer_sha256: ${PIN_X64}" ]
  [ "$(sed -n 5p "${WORK}/last")" = "ibkr_build_stamp: (.1g) 20261109 16:10:13" ]
  [ "$(sed -n 6p "${WORK}/last")" = "image: brokersre-ib-gateway:stable" ]
  [[ "$(sed -n 7p "${WORK}/last")" =~ ^image_id:\ sha256:[0-9a-f]{64}$ ]]
  [ "$(buildx_arg IB_GATEWAY_VERSION)" = 10.50.1g ]
  [ "$(buildx_arg IB_GATEWAY_CHANNEL)" = stable ]
  [ "$(buildx_arg IB_GATEWAY_SHA256_X64)" = "${PIN_X64}" ]
  [ "$(buildx_arg IB_GATEWAY_BUILD_STAMP)" = "(.1g) 20261109 16:10:13" ]
  [ "$(buildx_arg IB_GATEWAY_QUALIFIED)" = yes ]
  [ "$(buildx_arg IBC_SHA256)" = "$(jq -r .ibc.sha256 "${REPO}/versions.json")" ]
  [ "$(buildx_arg UBUNTU_DIGEST)" = "$(jq -r .base.digest "${REPO}/versions.json")" ]
  [ "$(buildx_option --platform)" = linux/amd64 ]
  [ "$(buildx_option -t | tr '\n' ' ')" = "brokersre-ib-gateway:stable brokersre-ib-gateway:10.50.1g " ]
  grep -qx -- --load "${WORK}/stub/buildx-args"
  # The helper image is built with buildx and loaded: a docker-container default builder would
  # otherwise keep it in the build cache only.
  grep -q "^buildx build --load -q -t brokersre-ib-gateway-build-helper:local " "${WORK}/stub/calls"
  # The installer was in the build context during the build, and is gone afterwards.
  grep -qx ibgateway-10.50.1g-standalone-linux-x64.sh "${WORK}/stub/context-downloads"
  [ ! -e "${REPO}/downloads/ibgateway-10.50.1g-standalone-linux-x64.sh" ]
  # Accepted into the cache by version and SHA-256.
  cmp "${CACHE}/installers/10.50.1g/x64/${PIN_X64}/ibgateway-10.50.1g-standalone-linux-x64.sh" "${WORK}/pinned-x64.sh"
  grep -qx "sha256: ${PIN_X64}" "${CACHE}/installers/10.50.1g/x64/${PIN_X64}/meta"
}

@test "IBKR serves the pinned version with other bytes: SHA-256 mismatch, exit 1, nothing built or cached" {
  make_fake_installer "${WORK}/reupload.sh" "IB Gateway 10.50" "(.1g) 20261109 16:10:13" ibgateway-stable-standalone-linux-x64 re-upload
  serve_version stable 10.50.1g "20261109 16:10:13"
  serve_installer stable x64 "${WORK}/reupload.sh"
  build --no-smoke
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"SHA-256 MISMATCH"* ]]
  [[ "$stderr" == *"${PIN_X64}"* ]]
  [[ "$stderr" == *"$(sha256_of "${WORK}/reupload.sh")"* ]]
  [ ! -e "${WORK}/stub/buildx-args" ]
  [ ! -e "${CACHE}/installers/10.50.1g" ]
  no_runs_left
}

@test "IBKR moved past the pin: falls forward, checked against IBKR's stamp, built not qualified with a warning" {
  serve_version stable 10.50.1h "20261116 16:02:08"
  serve_installer stable x64 "${WORK}/newer-x64.sh"
  build --no-smoke
  echo "$stderr"
  [ "$status" -eq 0 ]
  last_lines >"${WORK}/last"
  [ "$(sed -n 1p "${WORK}/last")" = "version: 10.50.1h" ]
  [ "$(sed -n 3p "${WORK}/last")" = "qualified_by_project: no" ]
  [ "$(sed -n 4p "${WORK}/last")" = "installer_sha256: ${NEWER_X64}" ]
  [ "$(sed -n 5p "${WORK}/last")" = "ibkr_build_stamp: (.1h) 20261116 16:02:08" ]
  [ "$(buildx_arg IB_GATEWAY_VERSION)" = 10.50.1h ]
  [ "$(buildx_arg IB_GATEWAY_SHA256_X64)" = "${NEWER_X64}" ]
  [ "$(buildx_arg IB_GATEWAY_BUILD_STAMP)" = "(.1h) 20261116 16:02:08" ]
  [ "$(buildx_arg IB_GATEWAY_QUALIFIED)" = no ]
  [ "$(buildx_option -t | tr '\n' ' ')" = "brokersre-ib-gateway:stable brokersre-ib-gateway:10.50.1h " ]
  [[ "$stderr" == *"WARNING"*"not qualified by this project"* ]]
  [[ "$stderr" == *"versions.json pins 10.50.1g"* ]]
  [[ "$stderr" == *"scripts/qualify-paper.sh --image brokersre-ib-gateway:stable --secrets-dir"* ]]
  # version.json was read before and after the download, the installer once.
  [ "$(grep -c '^GET /stable-standalone/version.json$' "${WORK}/requests.log")" -eq 2 ]
  [ "$(installer_requests stable x64)" -eq 1 ]
  grep -qx "ibkr_build_stamp: (.1h) 20261116 16:02:08" "${CACHE}/installers/10.50.1h/x64/${NEWER_X64}/meta"
}

@test "IBKR moved past the pin and the installer's stamp is not what version.json says: exit 1, naming both" {
  make_fake_installer "${WORK}/odd.sh" "IB Gateway 10.50" "(.1h) 20261116 16:02:07" ibgateway-stable-standalone-linux-x64
  serve_version stable 10.50.1h "20261116 16:02:08"
  serve_installer stable x64 "${WORK}/odd.sh"
  build --no-smoke
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"(.1h) 20261116 16:02:08"* ]]
  [[ "$stderr" == *"(.1h) 20261116 16:02:07"* ]]
  [ ! -e "${WORK}/stub/buildx-args" ]
  [ ! -e "${CACHE}/installers/10.50.1h" ]
  no_runs_left
}

@test "version.json changes during the download: one retry, and the build uses the second answer" {
  make_fake_installer "${WORK}/next-x64.sh" "IB Gateway 10.50" "(.1i) 20261117 10:00:00" ibgateway-stable-standalone-linux-x64
  serve_version stable 10.50.1h "20261116 16:02:08" 1
  serve_version stable 10.50.1i "20261117 10:00:00" 2
  serve_installer stable x64 "${WORK}/newer-x64.sh" 1
  serve_installer stable x64 "${WORK}/next-x64.sh" 2
  build --no-smoke
  echo "$stderr"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"changed during the download"* ]]
  [ "$(last_lines | sed -n 1p)" = "version: 10.50.1i" ]
  [ "$(buildx_arg IB_GATEWAY_SHA256_X64)" = "$(sha256_of "${WORK}/next-x64.sh")" ]
  [ "$(installer_requests stable x64)" -eq 2 ]
}

@test "version.json changes again during the retry: exit 1, nothing built" {
  serve_version stable 10.50.1h "20261116 16:02:08" 1
  serve_version stable 10.50.1i "20261117 10:00:00" 2
  serve_version stable 10.50.1i "20261117 10:00:00" 3
  serve_version stable 10.50.1j "20261117 11:00:00" 4
  serve_installer stable x64 "${WORK}/newer-x64.sh"
  build --no-smoke
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"changed during the download"* ]]
  [ "$(installer_requests stable x64)" -eq 2 ]
  [ ! -e "${WORK}/stub/buildx-args" ]
  no_runs_left
}

@test "--strict and IBKR serves another version: exit 4 before any download" {
  serve_version stable 10.50.1h "20261116 16:02:08"
  serve_installer stable x64 "${WORK}/newer-x64.sh"
  build --strict --no-smoke
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"10.50.1h"*"10.50.1g"* ]]
  [ "$(installer_requests stable x64)" -eq 0 ]
  [ ! -e "${WORK}/stub/buildx-args" ]
  no_runs_left
}

@test "--strict and IBKR serves the pin: built, qualified" {
  serve_version stable 10.50.1g "20261109 16:10:13"
  serve_installer stable x64 "${WORK}/pinned-x64.sh"
  build --strict --no-smoke
  [ "$status" -eq 0 ]
  [ "$(last_lines | sed -n 3p)" = "qualified_by_project: yes" ]
}

@test "--installer FILE: version, stamp and channel come from the installer, its SHA-256 is recorded, IBKR is not asked" {
  make_fake_installer "${WORK}/mine.sh" "IB Gateway 10.53" "(.1a) 20261120 09:00:00" ibgateway-latest-standalone-linux-x64
  build --installer "${WORK}/mine.sh" --no-smoke
  echo "$stderr"
  [ "$status" -eq 0 ]
  last_lines >"${WORK}/last"
  [ "$(sed -n 1p "${WORK}/last")" = "version: 10.53.1a" ]
  [ "$(sed -n 2p "${WORK}/last")" = "channel: latest" ]
  [ "$(sed -n 3p "${WORK}/last")" = "qualified_by_project: no" ]
  [ "$(sed -n 4p "${WORK}/last")" = "installer_sha256: $(sha256_of "${WORK}/mine.sh")" ]
  [ "$(sed -n 5p "${WORK}/last")" = "ibkr_build_stamp: (.1a) 20261120 09:00:00" ]
  [ "$(sed -n 6p "${WORK}/last")" = "image: brokersre-ib-gateway:latest" ]
  [ "$(buildx_arg IB_GATEWAY_CHANNEL)" = latest ]
  [ "$(buildx_arg IB_GATEWAY_BUILD_STAMP)" = "(.1a) 20261120 09:00:00" ]
  [ ! -s "${WORK}/requests.log" ]
  [ -f "${CACHE}/installers/10.53.1a/x64/$(sha256_of "${WORK}/mine.sh")/meta" ]
}

@test "--installer with the pinned bytes builds the pin, qualified" {
  build --installer "${WORK}/pinned-x64.sh" --no-smoke
  [ "$status" -eq 0 ]
  [ "$(last_lines | sed -n 1p)" = "version: 10.50.1g" ]
  [ "$(last_lines | sed -n 3p)" = "qualified_by_project: yes" ]
}

@test "--installer for another architecture or another channel than asked: exit 1" {
  build --installer "${WORK}/pinned-arm.sh" --platform linux/amd64 --no-smoke
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"linux-arm"* ]]
  build --installer "${WORK}/pinned-x64.sh" --channel latest --no-smoke
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"stable"* ]]
  [ ! -e "${WORK}/stub/buildx-args" ]
}

@test "--installer that carries no readable stamp: exit 1" {
  printf '#!/bin/sh\nexit 0\n' >"${WORK}/plain.sh"
  build --installer "${WORK}/plain.sh" --no-smoke
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"stamp"* ]]
}

@test "IBKR serves a version already in the cache: no download" {
  serve_version stable 10.50.1h "20261116 16:02:08"
  serve_installer stable x64 "${WORK}/newer-x64.sh"
  build --no-smoke
  [ "$status" -eq 0 ]
  rm -f "${WORK}/stub/buildx-args"
  build --no-smoke
  [ "$status" -eq 0 ]
  [ "$(installer_requests stable x64)" -eq 1 ]
  [ "$(buildx_arg IB_GATEWAY_SHA256_X64)" = "${NEWER_X64}" ]
  [[ "$stderr" == *"cache"* ]]
}

@test "IBKR unreachable, a newer version cached: builds it from the cache, not qualified" {
  serve_version stable 10.50.1h "20261116 16:02:08"
  serve_installer stable x64 "${WORK}/newer-x64.sh"
  build --no-smoke
  [ "$status" -eq 0 ]
  rm -f "${WORK}/stub/buildx-args"
  BROKERSRE_TEST_IBKR_BASE_URL="http://127.0.0.1:1" build --no-smoke
  echo "$stderr"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"unreachable"* ]]
  [ "$(last_lines | sed -n 1p)" = "version: 10.50.1h" ]
  [ "$(last_lines | sed -n 3p)" = "qualified_by_project: no" ]
  [ "$(buildx_arg IB_GATEWAY_SHA256_X64)" = "${NEWER_X64}" ]
  [ "$(buildx_arg IB_GATEWAY_BUILD_STAMP)" = "(.1h) 20261116 16:02:08" ]
}

@test "IBKR unreachable, the pin cached: builds the pin, qualified (also with --strict)" {
  serve_version stable 10.50.1g "20261109 16:10:13"
  serve_installer stable x64 "${WORK}/pinned-x64.sh"
  build --no-smoke
  [ "$status" -eq 0 ]
  BROKERSRE_TEST_IBKR_BASE_URL="http://127.0.0.1:1" build --strict --no-smoke
  [ "$status" -eq 0 ]
  [ "$(last_lines | sed -n 1p)" = "version: 10.50.1g" ]
  [ "$(last_lines | sed -n 3p)" = "qualified_by_project: yes" ]
}

@test "IBKR unreachable and nothing cached: exit 3, nothing built" {
  BROKERSRE_TEST_IBKR_BASE_URL="http://127.0.0.1:1" build --no-smoke
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"unreachable"* ]]
  [ ! -e "${WORK}/stub/buildx-args" ]
}

@test "--strict, IBKR unreachable and only a newer version cached: exit 3" {
  serve_version stable 10.50.1h "20261116 16:02:08"
  serve_installer stable x64 "${WORK}/newer-x64.sh"
  build --no-smoke
  [ "$status" -eq 0 ]
  rm -f "${WORK}/stub/buildx-args"
  BROKERSRE_TEST_IBKR_BASE_URL="http://127.0.0.1:1" build --strict --no-smoke
  [ "$status" -eq 3 ]
  [ ! -e "${WORK}/stub/buildx-args" ]
}

@test "--print-plan resolves and prints the plan without downloading or building" {
  serve_version stable 10.50.1h "20261116 16:02:08"
  serve_installer stable x64 "${WORK}/newer-x64.sh"
  build --print-plan
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"version: 10.50.1h"* ]]
  [[ "$output" == *"pinned_version: 10.50.1g"* ]]
  [[ "$output" == *"pinned: no"* ]]
  [[ "$output" == *"cache_hit: no"* ]]
  [[ "$output" == *"qualified_by_project: no"* ]]
  [[ "$output" == *"image: brokersre-ib-gateway:stable"* ]]
  [ "$(installer_requests stable x64)" -eq 0 ]
  [ ! -e "${WORK}/stub/buildx-args" ]
  [ -z "$(ls -A "${REPO}/downloads")" ]
  [ ! -e "${CACHE}/installers" ]
}

@test "--print-plan after a build of the same version reports the cache hit" {
  serve_version stable 10.50.1g "20261109 16:10:13"
  serve_installer stable x64 "${WORK}/pinned-x64.sh"
  build --no-smoke
  [ "$status" -eq 0 ]
  build --print-plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"pinned: yes"* ]]
  [[ "$output" == *"cache_hit: yes"* ]]
  [[ "$output" == *"installer_sha256: ${PIN_X64}"* ]]
}

@test "a failed image build exits 1, caches nothing and leaves no installer in downloads/" {
  serve_version stable 10.50.1h "20261116 16:02:08"
  serve_installer stable x64 "${WORK}/newer-x64.sh"
  STUB_BUILD_RC=1 build --no-smoke
  [ "$status" -eq 1 ]
  [ ! -e "${CACHE}/installers/10.50.1h" ]
  [ ! -e "${REPO}/downloads/ibgateway-10.50.1h-standalone-linux-x64.sh" ]
  no_runs_left
}

@test "a failed smoke test exits 1 and caches nothing" {
  serve_version stable 10.50.1h "20261116 16:02:08"
  serve_installer stable x64 "${WORK}/newer-x64.sh"
  SMOKE_TIMEOUT=2 build
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"smoke test"* ]]
  grep -q '^run -d --name ibgw-test' "${WORK}/stub/calls"
  [ ! -e "${CACHE}/installers/10.50.1h" ]
}

@test "the smoke test's filter: tests/container/run.sh refuses an unknown --only section (exit 2)" {
  IMAGE=example.test/none run "${REPO}/tests/container/run.sh" --only everything
  [ "$status" -eq 2 ]
  [[ "$output" == *"--only ibc-smoke"* ]]
  [ ! -e "${WORK}/stub/calls" ]
}

@test "--no-smoke skips the smoke test" {
  serve_version stable 10.50.1g "20261109 16:10:13"
  serve_installer stable x64 "${WORK}/pinned-x64.sh"
  build --no-smoke
  [ "$status" -eq 0 ]
  [ -e "${WORK}/stub/buildx-args" ]
  [[ "$(last_lines | sed -n 7p)" == "image_id: sha256:"* ]]
  ! grep -q '^run -d --name ibgw-test' "${WORK}/stub/calls" || false
}

@test "the default platform follows the host: an arm64 host builds linux/arm64 from IBKR's arm installer" {
  serve_version stable 10.50.1g "20261109 16:10:13"
  serve_installer stable arm "${WORK}/pinned-arm.sh"
  STUB_ARCH=aarch64 build --no-smoke
  [ "$status" -eq 0 ]
  [ "$(buildx_option --platform)" = linux/arm64 ]
  [ "$(buildx_arg IB_GATEWAY_SHA256_ARM)" = "${PIN_ARM}" ]
  [ "$(installer_requests stable arm)" -eq 1 ]
  [ -f "${CACHE}/installers/10.50.1g/arm/${PIN_ARM}/meta" ]
}

@test "--tag replaces the default tags; image names it" {
  serve_version stable 10.50.1g "20261109 16:10:13"
  serve_installer stable x64 "${WORK}/pinned-x64.sh"
  build --tag example.test/gw:ci --no-smoke
  [ "$status" -eq 0 ]
  [ "$(buildx_option -t | tr '\n' ' ')" = "example.test/gw:ci " ]
  [ "$(last_lines | sed -n 6p)" = "image: example.test/gw:ci" ]
}

@test "the default cache is \${XDG_CACHE_HOME}/brokersre-ib-gateway" {
  serve_version stable 10.50.1g "20261109 16:10:13"
  serve_installer stable x64 "${WORK}/pinned-x64.sh"
  XDG_CACHE_HOME="${WORK}/xdg" run --separate-stderr "${REPO}/scripts/build-image.sh" --no-smoke
  [ "$status" -eq 0 ]
  [ -f "${WORK}/xdg/brokersre-ib-gateway/installers/10.50.1g/x64/${PIN_X64}/meta" ]
}

@test "without the test override the helper asks IBKR, over HTTPS only" {
  unset BROKERSRE_TEST_IBKR_BASE_URL
  # A stand-in curl records how it was called and fails like a closed network.
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >>"${STUB_DIR}/curl-calls"' 'exit 7' >"${WORK}/bin/curl"
  chmod +x "${WORK}/bin/curl"
  build --no-smoke
  [ "$status" -eq 3 ]
  grep -q -- '--proto =https' "${WORK}/stub/curl-calls"
  grep -q -- '--proto-redir =https' "${WORK}/stub/curl-calls"
  grep -q 'https://download2.interactivebrokers.com/installers/ibgateway/stable-standalone/version.json' "${WORK}/stub/curl-calls"
}

@test "the fake IBKR server serves nothing outside its directory" {
  serve_version stable 10.50.1g "20261109 16:10:13"
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/stable-standalone/version.json")" = 200 ]
  [ "$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/stable-standalone/../../requests.log")" = 404 ]
  [ "$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/../port")" = 404 ]
}

# --- The trust checks, one test per way of weakening them (independent review of #39: of ten
# mutations of the helper, seven passed the suite before these tests).

# cached_installer VERSION: the path of the cached installer file of VERSION (x64), whatever
# the cache's directory layout below the version.
cached_installer() {
  find "${CACHE}/installers/$1" -name "ibgateway-$1-standalone-linux-x64.sh" | head -n 1
}

@test "a cached installer whose bytes no longer match its SHA-256 is skipped and never built" {
  serve_version stable 10.50.1h "20261116 16:02:08"
  serve_installer stable x64 "${WORK}/newer-x64.sh"
  build --no-smoke
  [ "$status" -eq 0 ]
  printf 'tampered' >>"$(cached_installer 10.50.1h)"
  rm -f "${WORK}/stub/buildx-args"
  build --no-smoke
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"no longer matches its recorded SHA-256"* ]]
  [ "$(installer_requests stable x64)" -eq 2 ]
  [ "$(buildx_arg IB_GATEWAY_SHA256_X64)" = "${NEWER_X64}" ]
  # Offline, a tampered copy is no fallback either.
  printf 'tampered' >>"$(cached_installer 10.50.1h)"
  rm -f "${WORK}/stub/buildx-args"
  BROKERSRE_TEST_IBKR_BASE_URL="http://127.0.0.1:1" build --no-smoke
  [ "$status" -eq 3 ]
  [ ! -e "${WORK}/stub/buildx-args" ]
}

@test "a change of buildDateTime alone between the two reads of version.json triggers the retry" {
  make_fake_installer "${WORK}/rebuilt-x64.sh" "IB Gateway 10.50" "(.1h) 20261116 16:02:09" ibgateway-stable-standalone-linux-x64
  serve_version stable 10.50.1h "20261116 16:02:08" 1
  serve_version stable 10.50.1h "20261116 16:02:09" 2
  serve_installer stable x64 "${WORK}/newer-x64.sh" 1
  serve_installer stable x64 "${WORK}/rebuilt-x64.sh" 2
  build --no-smoke
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"changed during the download"* ]]
  [ "$(installer_requests stable x64)" -eq 2 ]
  [ "$(buildx_arg IB_GATEWAY_BUILD_STAMP)" = "(.1h) 20261116 16:02:09" ]
  [ "$(buildx_arg IB_GATEWAY_SHA256_X64)" = "$(sha256_of "${WORK}/rebuilt-x64.sh")" ]
}

@test "a cached version whose build stamp IBKR has changed since is downloaded again, not reused" {
  make_fake_installer "${WORK}/rebuilt-x64.sh" "IB Gateway 10.50" "(.1h) 20261116 16:30:00" ibgateway-stable-standalone-linux-x64
  serve_version stable 10.50.1h "20261116 16:02:08"
  serve_installer stable x64 "${WORK}/newer-x64.sh"
  build --no-smoke
  [ "$status" -eq 0 ]
  serve_version stable 10.50.1h "20261116 16:30:00"
  serve_installer stable x64 "${WORK}/rebuilt-x64.sh"
  rm -f "${WORK}/stub/buildx-args"
  build --no-smoke
  [ "$status" -eq 0 ]
  [ "$(installer_requests stable x64)" -eq 2 ]
  [ "$(buildx_arg IB_GATEWAY_BUILD_STAMP)" = "(.1h) 20261116 16:30:00" ]
  [ "$(buildx_arg IB_GATEWAY_SHA256_X64)" = "$(sha256_of "${WORK}/rebuilt-x64.sh")" ]
}

@test "--installer with the pinned version but other bytes is built not qualified" {
  make_fake_installer "${WORK}/reupload.sh" "IB Gateway 10.50" "(.1g) 20261109 16:10:13" ibgateway-stable-standalone-linux-x64 re-upload
  build --installer "${WORK}/reupload.sh" --no-smoke
  [ "$status" -eq 0 ]
  [ "$(last_lines | sed -n 1p)" = "version: 10.50.1g" ]
  [ "$(last_lines | sed -n 3p)" = "qualified_by_project: no" ]
  [ "$(buildx_arg IB_GATEWAY_QUALIFIED)" = no ]
}

@test "offline, a cached copy of the pinned version with other bytes is not taken for the pin" {
  make_fake_installer "${WORK}/reupload.sh" "IB Gateway 10.50" "(.1g) 20261109 16:10:13" ibgateway-stable-standalone-linux-x64 re-upload
  build --installer "${WORK}/reupload.sh" --no-smoke
  [ "$status" -eq 0 ]
  rm -f "${WORK}/stub/buildx-args"
  BROKERSRE_TEST_IBKR_BASE_URL="http://127.0.0.1:1" build --strict --no-smoke
  [ "$status" -eq 3 ]
  [ ! -e "${WORK}/stub/buildx-args" ]
}

@test "malformed fields in version.json are refused before anything is downloaded or planned" {
  local nl='\n'
  serve_installer stable x64 "${WORK}/newer-x64.sh"
  # A newline in buildVersion would otherwise reach the plan as a line of its own.
  printf 'ibgatewaystable_callback({"buildVersion":"10.50.1h%sbuild_arg: IB_GATEWAY_QUALIFIED=yes","buildDateTime":"20261116 16:02:08"});' "${nl}" \
    >"${WWW}/stable-standalone/version.json"
  build --print-plan
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"not understood"* ]]
  [[ "$output" != *"build_arg:"* ]]
  build --no-smoke
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"not understood"* ]]
  [ "$(installer_requests stable x64)" -eq 0 ]
  [ ! -e "${WORK}/stub/buildx-args" ]
  serve_version stable 10.50.1h "2026-11-16T16:02:08Z"
  build --no-smoke
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"not understood"* ]]
  serve_version stable "10.50.1h/../x" "20261116 16:02:08"
  build --no-smoke
  [ "$status" -eq 1 ]
  [ "$(installer_requests stable x64)" -eq 0 ]
}

@test "an installer download redirected away from HTTPS is refused, also under the test override" {
  serve_version stable 10.50.1h "20261116 16:02:08"
  mkdir -p "${WWW}/elsewhere"
  cp "${WORK}/newer-x64.sh" "${WWW}/elsewhere/ibgateway.sh"
  printf 'http://127.0.0.1:%s/elsewhere/ibgateway.sh\n' "${PORT}" \
    >"${WWW}/stable-standalone/ibgateway-stable-standalone-linux-x64.sh.redirect"
  build --no-smoke
  [ "$status" -eq 1 ]
  ! grep -q '^GET /elsewhere/ibgateway.sh$' "${WORK}/requests.log" || false
  [ ! -e "${WORK}/stub/buildx-args" ]
}

# --- Provenance: a cached installer is reused only from the origin it came from (review of #39).

# use_stub_ibkr: make IBKR's real base URL answer from ${WWW} through a stand-in curl, so that a
# test can run the helper without the override (requests are logged like the fake server's).
use_stub_ibkr() {
  unset BROKERSRE_TEST_IBKR_BASE_URL
  cat >"${WORK}/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Stand-in curl: https://download2.interactivebrokers.com/installers/ibgateway/<path> is ${WWW}/<path>.
out=""
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2" && shift 2 ;;
    --proto | --proto-redir | --connect-timeout | --max-time | --retry | --retry-delay) shift 2 ;;
    https://*) url="$1" && shift ;;
    *) shift ;;
  esac
done
path="${url#https://download2.interactivebrokers.com/installers/ibgateway/}"
[ "${path}" != "${url}" ] || exit 6
printf 'GET /%s\n' "${path}" >>"${WORK}/requests.log"
[ -f "${WWW}/${path}" ] || exit 22
if [ -n "${out}" ]; then cp "${WWW}/${path}" "${out}"; else cat "${WWW}/${path}"; fi
STUB
  sed -i "s|\${WWW}|${WWW}|g; s|\${WORK}|${WORK}|g" "${WORK}/bin/curl"
  chmod +x "${WORK}/bin/curl"
}

# cached_meta VERSION: the meta file of the newest cached entry of VERSION (x64).
cached_meta() {
  find "${CACHE}/installers/$1" -name meta | head -n 1
}

@test "bytes given once with --installer are never reused by a build that IBKR answers" {
  make_fake_installer "${WORK}/thirdparty.sh" "IB Gateway 10.50" "(.1h) 20261116 16:02:08" ibgateway-stable-standalone-linux-x64 not-from-ibkr
  build --installer "${WORK}/thirdparty.sh" --no-smoke
  [ "$status" -eq 0 ]
  serve_version stable 10.50.1h "20261116 16:02:08"
  serve_installer stable x64 "${WORK}/newer-x64.sh"
  rm -f "${WORK}/stub/buildx-args"
  build --no-smoke
  [ "$status" -eq 0 ]
  [ "$(installer_requests stable x64)" -eq 1 ]
  [ "$(buildx_arg IB_GATEWAY_SHA256_X64)" = "${NEWER_X64}" ]
}

@test "a download through the test override is cached as source override, never ibkr" {
  serve_version stable 10.50.1h "20261116 16:02:08"
  serve_installer stable x64 "${WORK}/newer-x64.sh"
  build --no-smoke
  [ "$status" -eq 0 ]
  grep -qx 'source: override' "$(cached_meta 10.50.1h)"
}

@test "an installer cached from the test override is not reused when the helper talks to IBKR" {
  serve_version stable 10.50.1h "20261116 16:02:08"
  serve_installer stable x64 "${WORK}/newer-x64.sh"
  build --no-smoke
  [ "$status" -eq 0 ]
  use_stub_ibkr
  rm -f "${WORK}/stub/buildx-args"
  build --no-smoke
  [ "$status" -eq 0 ]
  [ "$(installer_requests stable x64)" -eq 2 ]
  [[ "$stderr" != *"TEST OVERRIDE"* ]]
  grep -qx 'source: ibkr' "$(cached_meta 10.50.1h)"
}

@test "offline, only an installer that came from the same origin stands in for IBKR's current build" {
  make_fake_installer "${WORK}/thirdparty.sh" "IB Gateway 10.50" "(.1h) 20261116 16:02:08" ibgateway-stable-standalone-linux-x64 not-from-ibkr
  build --installer "${WORK}/thirdparty.sh" --no-smoke
  [ "$status" -eq 0 ]
  rm -f "${WORK}/stub/buildx-args"
  BROKERSRE_TEST_IBKR_BASE_URL="http://127.0.0.1:1" build --no-smoke
  [ "$status" -eq 3 ]
  [ ! -e "${WORK}/stub/buildx-args" ]
}

@test "the image is labelled with where its installer came from: override, installer or ibkr" {
  serve_version stable 10.50.1h "20261116 16:02:08"
  serve_installer stable x64 "${WORK}/newer-x64.sh"
  build --no-smoke
  [ "$status" -eq 0 ]
  [ "$(buildx_arg IB_GATEWAY_INSTALLER_SOURCE)" = override ]
  make_fake_installer "${WORK}/mine.sh" "IB Gateway 10.53" "(.1a) 20261120 09:00:00" ibgateway-latest-standalone-linux-x64
  build --installer "${WORK}/mine.sh" --no-smoke
  [ "$status" -eq 0 ]
  [ "$(buildx_arg IB_GATEWAY_INSTALLER_SOURCE)" = installer ]
  use_stub_ibkr
  build --no-smoke
  [ "$status" -eq 0 ]
  [ "$(buildx_arg IB_GATEWAY_INSTALLER_SOURCE)" = ibkr ]
}

# --- Cache entries are keyed by version and SHA-256 (review of #39).

@test "an --installer copy of the pinned version with other bytes does not replace the cached pin" {
  serve_version stable 10.50.1g "20261109 16:10:13"
  serve_installer stable x64 "${WORK}/pinned-x64.sh"
  build --no-smoke
  [ "$status" -eq 0 ]
  make_fake_installer "${WORK}/reupload.sh" "IB Gateway 10.50" "(.1g) 20261109 16:10:13" ibgateway-stable-standalone-linux-x64 re-upload
  build --installer "${WORK}/reupload.sh" --no-smoke
  [ "$status" -eq 0 ]
  [ "$(last_lines | sed -n 3p)" = "qualified_by_project: no" ]
  rm -f "${WORK}/stub/buildx-args"
  BROKERSRE_TEST_IBKR_BASE_URL="http://127.0.0.1:1" build --strict --no-smoke
  [ "$status" -eq 0 ]
  [ "$(last_lines | sed -n 3p)" = "qualified_by_project: yes" ]
  [ "$(buildx_arg IB_GATEWAY_SHA256_X64)" = "${PIN_X64}" ]
  [ "$(find "${CACHE}/installers/10.50.1g/x64" -name meta | wc -l)" -eq 2 ]
}

@test "the same bytes given again with --installer keep the entry IBKR's download made" {
  serve_version stable 10.50.1h "20261116 16:02:08"
  serve_installer stable x64 "${WORK}/newer-x64.sh"
  use_stub_ibkr
  build --no-smoke
  [ "$status" -eq 0 ]
  build --installer "${WORK}/newer-x64.sh" --no-smoke
  [ "$status" -eq 0 ]
  [ "$(find "${CACHE}/installers/10.50.1h/x64" -name meta | wc -l)" -eq 1 ]
  grep -qx 'source: ibkr' "$(cached_meta 10.50.1h)"
  build --no-smoke
  [ "$status" -eq 0 ]
  [ "$(installer_requests stable x64)" -eq 1 ]
}

# --- The build context's downloads/: the wrapper removes only what it put there (review of #39).

@test "--installer naming the file in downloads/ keeps it after a successful build, and caches it" {
  cp "${WORK}/pinned-x64.sh" "${REPO}/downloads/ibgateway-10.50.1g-standalone-linux-x64.sh"
  build --installer "${REPO}/downloads/ibgateway-10.50.1g-standalone-linux-x64.sh" --no-smoke
  [ "$status" -eq 0 ]
  cmp "${REPO}/downloads/ibgateway-10.50.1g-standalone-linux-x64.sh" "${WORK}/pinned-x64.sh"
  [ -f "${CACHE}/installers/10.50.1g/x64/${PIN_X64}/meta" ]
}

@test "--installer naming the file in downloads/ keeps it after a failed build" {
  cp "${WORK}/pinned-x64.sh" "${REPO}/downloads/ibgateway-10.50.1g-standalone-linux-x64.sh"
  STUB_BUILD_RC=1 build --installer "${REPO}/downloads/ibgateway-10.50.1g-standalone-linux-x64.sh" --no-smoke
  [ "$status" -eq 1 ]
  cmp "${REPO}/downloads/ibgateway-10.50.1g-standalone-linux-x64.sh" "${WORK}/pinned-x64.sh"
}

@test "a file with other bytes at the installer's place in downloads/ is refused and left untouched" {
  printf 'an archived copy of something else\n' >"${REPO}/downloads/ibgateway-10.50.1g-standalone-linux-x64.sh"
  cp "${REPO}/downloads/ibgateway-10.50.1g-standalone-linux-x64.sh" "${WORK}/kept"
  serve_version stable 10.50.1g "20261109 16:10:13"
  serve_installer stable x64 "${WORK}/pinned-x64.sh"
  build --no-smoke
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"downloads/ibgateway-10.50.1g-standalone-linux-x64.sh holds other bytes"* ]]
  # The likely cause and the safe way out are named: a leftover of an interrupted or parallel
  # build, removed only when no other build runs, with the command of the caller's shell and
  # the file's path on the host (the helper sees only its own mount, /downloads).
  [[ "$stderr" == *"leftover of an interrupted build or of a build running in parallel"* ]]
  [[ "$stderr" == *"no other build is running"* ]]
  [[ "$stderr" == *"rm '${REPO}/downloads/ibgateway-10.50.1g-standalone-linux-x64.sh'"* ]]
  [[ "$stderr" == *"build from it with --installer"* ]]
  [[ "$stderr" != *"Remove-Item"* ]]
  cmp "${REPO}/downloads/ibgateway-10.50.1g-standalone-linux-x64.sh" "${WORK}/kept"
  [ ! -e "${WORK}/stub/buildx-args" ]
  no_runs_left
}

@test "for the PowerShell wrapper the refusal names Remove-Item, the Windows path and -Installer" {
  printf 'an archived copy of something else\n' >"${REPO}/downloads/ibgateway-10.50.1g-standalone-linux-x64.sh"
  serve_version stable 10.50.1g "20261109 16:10:13"
  serve_installer stable x64 "${WORK}/pinned-x64.sh"
  local windows_downloads='C:\src\brokersre-ib-gateway\downloads'
  run --separate-stderr env BROKERSRE_HOST_SHELL=powershell BROKERSRE_HOST_DOWNLOADS="${windows_downloads}" \
    bash "${REPO}/scripts/resolve-installer.sh" resolve --arch x64 --versions "${REPO}/versions.json" \
    --cache "${CACHE}" --downloads "${REPO}/downloads"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Remove-Item -LiteralPath '${windows_downloads}\ibgateway-10.50.1g-standalone-linux-x64.sh'"* ]]
  [[ "$stderr" == *"build from it with -Installer"* ]]
  [[ "$stderr" != *"--installer"* ]]
  [[ "$stderr" != *"rm '"* ]]
}

@test "the bash advice quotes a path with a single quote safely: the command removes exactly that file" {
  local downloads="${WORK}/it's a \"repo\" \$HOME/downloads"
  mkdir -p "${downloads}"
  printf 'an archived copy of something else\n' >"${downloads}/ibgateway-10.50.1g-standalone-linux-x64.sh"
  serve_version stable 10.50.1g "20261109 16:10:13"
  serve_installer stable x64 "${WORK}/pinned-x64.sh"
  run --separate-stderr env BROKERSRE_HOST_SHELL=bash BROKERSRE_HOST_DOWNLOADS="${downloads}" \
    bash "${REPO}/scripts/resolve-installer.sh" resolve --arch x64 --versions "${REPO}/versions.json" \
    --cache "${CACHE}" --downloads "${downloads}"
  [ "$status" -eq 1 ]
  local command
  command="$(printf '%s\n' "$stderr" | sed -n 's/^    \(rm .*\)$/\1/p')"
  [ -n "${command}" ]
  bash -c "${command}"
  [ ! -e "${downloads}/ibgateway-10.50.1g-standalone-linux-x64.sh" ]
  [ -d "${downloads}" ]
}

@test "the PowerShell advice doubles every single quote in the path, typographic ones too" {
  printf 'an archived copy of something else\n' >"${REPO}/downloads/ibgateway-10.50.1g-standalone-linux-x64.sh"
  serve_version stable 10.50.1g "20261109 16:10:13"
  serve_installer stable x64 "${WORK}/pinned-x64.sh"
  # PowerShell ends a single-quoted string at ' and at the typographic quotes U+2018/U+2019.
  run --separate-stderr env BROKERSRE_HOST_SHELL=powershell \
    BROKERSRE_HOST_DOWNLOADS="C:\\Users\\o'brien\\Ann$(printf '\342\200\231')s repo\\downloads" \
    bash "${REPO}/scripts/resolve-installer.sh" resolve --arch x64 --versions "${REPO}/versions.json" \
    --cache "${CACHE}" --downloads "${REPO}/downloads"
  [ "$status" -eq 1 ]
  local expected
  expected="Remove-Item -LiteralPath 'C:\\Users\\o''brien\\Ann$(printf '\342\200\231\342\200\231')s repo\\downloads\\ibgateway-10.50.1g-standalone-linux-x64.sh'"
  [[ "$stderr" == *"${expected}"* ]]
}

@test "without a hint from a wrapper the refusal names the file relative to the repository" {
  printf 'an archived copy of something else\n' >"${REPO}/downloads/ibgateway-10.50.1g-standalone-linux-x64.sh"
  serve_version stable 10.50.1g "20261109 16:10:13"
  serve_installer stable x64 "${WORK}/pinned-x64.sh"
  run --separate-stderr bash "${REPO}/scripts/resolve-installer.sh" resolve --arch x64 \
    --versions "${REPO}/versions.json" --cache "${CACHE}" --downloads "${REPO}/downloads"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"downloads/ibgateway-10.50.1g-standalone-linux-x64.sh holds other bytes"* ]]
  [[ "$stderr" == *"remove downloads/ibgateway-10.50.1g-standalone-linux-x64.sh of the repository"* ]]
}

@test "a docker failure outside the contract's codes (125: daemon or mount error) exits 1" {
  serve_version stable 10.50.1g "20261109 16:10:13"
  STUB_RUN_RC=125 build --no-smoke
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"exit 125"* ]]
  STUB_RUN_RC=126 build --print-plan
  [ "$status" -eq 1 ]
}

@test "the installer's stamp is read without decompressing the rest of its archive" {
  make_fake_installer_cut "${WORK}/cut.sh" "IB Gateway 10.53" "(.1a) 20261120 09:00:00" ibgateway-latest-standalone-linux-x64
  # The archive past i4jparams.conf is cut off: a reader that decompresses all of it fails.
  run tar -tzf - < <(tail -c "$(sed -n -E 's/^tail -c ([0-9]+) .*/\1/p' "${WORK}/cut.sh")" "${WORK}/cut.sh")
  [ "$status" -ne 0 ]
  build --installer "${WORK}/cut.sh" --print-plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"version: 10.53.1a"* ]]
  [[ "$output" == *"ibkr_build_stamp: (.1a) 20261120 09:00:00"* ]]
}

@test "an unreachable Docker daemon is named as such, exit 1, with or without --platform" {
  STUB_DAEMON_DOWN=1 build --no-smoke
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"the Docker daemon is not reachable"* ]]
  [[ "$stderr" == *"desktop-linux"* ]]
  [[ "$stderr" != *"architecture"* ]]
  STUB_DAEMON_DOWN=1 build --platform linux/amd64 --no-smoke
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"the Docker daemon is not reachable"* ]]
  ! grep -q -e '^run ' -e '^buildx build' "${WORK}/stub/calls" || false
}

# --- Proxy settings of the caller's shell reach the helper and the build, by name only.

@test "proxy variables set in the shell reach the helper and the build, and their values are never printed" {
  local secret
  secret="pw-$(printf 'SYN%s' THETIC)"
  serve_version stable 10.50.1g "20261109 16:10:13"
  serve_installer stable x64 "${WORK}/pinned-x64.sh"
  export HTTPS_PROXY="http://synthetic:${secret}@proxy.invalid:3128"
  export http_proxy="http://synthetic:${secret}@proxy.invalid:3128"
  export NO_PROXY="127.0.0.1,localhost"
  build --no-smoke
  [ "$status" -eq 0 ]
  # The helper got the values (docker reads them from the caller's environment: -e NAME).
  grep -qx "HTTPS_PROXY=${HTTPS_PROXY}" "${WORK}/stub/helper-env"
  grep -qx "http_proxy=${http_proxy}" "${WORK}/stub/helper-env"
  grep -qx "NO_PROXY=127.0.0.1,localhost" "${WORK}/stub/helper-env"
  ! grep -q '^HTTP_PROXY=' "${WORK}/stub/helper-env" || false
  grep '^run ' "${WORK}/stub/calls" | grep -- '-e HTTPS_PROXY ' >/dev/null
  grep '^run ' "${WORK}/stub/calls" | grep -- '-e http_proxy ' >/dev/null
  grep '^run ' "${WORK}/stub/calls" | grep -- '-e NO_PROXY ' >/dev/null
  ! grep '^run ' "${WORK}/stub/calls" | grep -- '-e HTTP_PROXY ' >/dev/null || false
  # The build got them as build arguments by name (buildx reads the values from the environment).
  [ "$(buildx_option --build-arg | grep -cx -e HTTPS_PROXY -e http_proxy -e NO_PROXY)" -eq 3 ]
  # No value in an argument list, on standard output or on standard error.
  ! grep -q "${secret}" "${WORK}/stub/calls" "${WORK}/stub/buildx-args" || false
  [[ "$output" != *"${secret}"* ]]
  [[ "$stderr" != *"${secret}"* ]]
}

@test "without proxy variables nothing proxy-related is passed" {
  serve_version stable 10.50.1g "20261109 16:10:13"
  serve_installer stable x64 "${WORK}/pinned-x64.sh"
  build --no-smoke
  [ "$status" -eq 0 ]
  ! grep -qi 'proxy' "${WORK}/stub/calls" "${WORK}/stub/buildx-args" || false
}

@test "the Dockerfile declares no proxy variable, so Docker keeps proxy build arguments out of the image" {
  # HTTP_PROXY, HTTPS_PROXY, NO_PROXY (and lower case) are predefined build arguments: usable
  # in RUN, excluded from `docker history` and from the image configuration unless declared.
  ! grep -Ei '^[[:space:]]*(ARG|ENV|LABEL)[[:space:]].*(https?_proxy|no_proxy|all_proxy|ftp_proxy)' "${SRC}/Dockerfile" || false
}

# --- OCI labels of a helper build: created (build time, UTC) and revision (the commit).

@test "a helper build is labelled with its build time (UTC) and revision unknown outside a git work tree" {
  serve_version stable 10.50.1g "20261109 16:10:13"
  serve_installer stable x64 "${WORK}/pinned-x64.sh"
  build --no-smoke
  [ "$status" -eq 0 ]
  [[ "$(buildx_option --label | sed -n 's/^org.opencontainers.image.created=//p')" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  [ "$(buildx_option --label | sed -n 's/^org.opencontainers.image.revision=//p')" = unknown ]
}

@test "a helper build from a git work tree is labelled with its commit" {
  require_command git
  git -C "${REPO}" init -q
  git -C "${REPO}" add -A
  git -C "${REPO}" -c user.email=test@example.invalid -c user.name=test commit -q -m test
  serve_version stable 10.50.1g "20261109 16:10:13"
  serve_installer stable x64 "${WORK}/pinned-x64.sh"
  build --no-smoke
  [ "$status" -eq 0 ]
  [ "$(buildx_option --label | sed -n 's/^org.opencontainers.image.revision=//p')" = "$(git -C "${REPO}" rev-parse HEAD)" ]
}

@test "the image's url label points at the README's build section, not the retired package page" {
  grep -q 'org.opencontainers.image.url="https://github.com/RocketEdge/brokersre-ib-gateway#build-the-image"' "${SRC}/Dockerfile"
  grep -q '^## Build the image$' "${SRC}/README.md"
  ! grep -q 'pkgs/container' "${SRC}/Dockerfile" || false
}

# --- Messages name the host's paths, not the helper container's mounts (/cache, /installer).

@test "the helper names the cache and the installer by the host paths the wrapper passes" {
  local host_cache='D:\Users\someone\cache dir'
  # Offline, nothing cached: the message names the cache.
  BROKERSRE_TEST_IBKR_BASE_URL="http://127.0.0.1:1" BROKERSRE_HOST_CACHE="${host_cache}" \
    run --separate-stderr "${REPO}/scripts/resolve-installer.sh" resolve --arch x64 --versions "${REPO}/versions.json" \
    --cache "${WORK}/mnt-cache" --downloads "${REPO}/downloads" --strict
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"is not in the cache ${host_cache}"* ]]
  [[ "$stderr" != *"${WORK}/mnt-cache"* ]]
  # A cached file that no longer matches is named below the host's cache, in its path style.
  serve_version stable 10.50.1h "20261116 16:02:08"
  serve_installer stable x64 "${WORK}/newer-x64.sh"
  build --no-smoke
  [ "$status" -eq 0 ]
  printf 'tampered' >>"$(find "${CACHE}/installers/10.50.1h" -name '*.sh' | head -n 1)"
  BROKERSRE_HOST_CACHE="${host_cache}" run --separate-stderr "${REPO}/scripts/resolve-installer.sh" resolve --arch x64 \
    --versions "${REPO}/versions.json" --cache "${CACHE}" --downloads "${REPO}/downloads" --print-plan
  local bs='\'
  [[ "$stderr" == *"cached ${host_cache}${bs}installers${bs}10.50.1h${bs}x64${bs}${NEWER_X64}${bs}ibgateway-10.50.1h-standalone-linux-x64.sh no longer matches"* ]]
  # An --installer file is named as the user gave it.
  printf '#!/bin/sh\nexit 0\n' >"${WORK}/plain.sh"
  BROKERSRE_HOST_INSTALLER='.\my installers\plain.sh' run --separate-stderr "${REPO}/scripts/resolve-installer.sh" resolve \
    --arch x64 --versions "${REPO}/versions.json" --cache "${CACHE}" --downloads "${REPO}/downloads" --installer "${WORK}/plain.sh" --print-plan
  [ "$status" -eq 1 ]
  [[ "$stderr" == *'cannot read a build stamp from .\my installers\plain.sh'* ]]
}

@test "the wrapper passes the host's cache directory and installer path to the helper" {
  serve_version stable 10.50.1g "20261109 16:10:13"
  serve_installer stable x64 "${WORK}/pinned-x64.sh"
  build --installer "${WORK}/pinned-x64.sh" --no-smoke
  [ "$status" -eq 0 ]
  grep -qx "BROKERSRE_HOST_CACHE=${CACHE}" "${WORK}/stub/helper-env"
  grep -qx "BROKERSRE_HOST_INSTALLER=${WORK}/pinned-x64.sh" "${WORK}/stub/helper-env"
  XDG_CACHE_HOME="${WORK}/xdg" run --separate-stderr "${REPO}/scripts/build-image.sh" --no-smoke
  [ "$status" -eq 0 ]
  grep -qx "BROKERSRE_HOST_CACHE=${WORK}/xdg/brokersre-ib-gateway" "${WORK}/stub/helper-env"
}

@test "the revision is asked of git in the checkout, without a path argument (Git Bash cannot pass one)" {
  # build-image.sh exports MSYS_NO_PATHCONV=1 for docker's container paths; under Git Bash a
  # POSIX path given to git is then not converted and git cannot open it, so the label said
  # unknown on a real clone (2026-11-17). A stand-in git records how it was called.
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s|%s\n" "$PWD" "$*" >>"${STUB_DIR}/git-calls"' 'echo 0123456789abcdef0123456789abcdef01234567' >"${WORK}/bin/git"
  chmod +x "${WORK}/bin/git"
  serve_version stable 10.50.1g "20261109 16:10:13"
  serve_installer stable x64 "${WORK}/pinned-x64.sh"
  build --no-smoke
  [ "$status" -eq 0 ]
  [ "$(buildx_option --label | sed -n 's/^org.opencontainers.image.revision=//p')" = 0123456789abcdef0123456789abcdef01234567 ]
  [ "$(cut -d'|' -f2 "${WORK}/stub/git-calls")" = "rev-parse HEAD" ]
  [ "$(cut -d'|' -f1 "${WORK}/stub/git-calls")" = "${REPO}" ]
}
