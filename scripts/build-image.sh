#!/usr/bin/env bash
# Build the IB Gateway image from this repository, robust against IBKR replacing its installers.
#
# Usage:
#   scripts/build-image.sh [--channel stable|latest] [--strict] [--installer FILE]
#                          [--platform linux/amd64|linux/arm64] [--tag NAME] [--no-smoke]
#                          [--cache-dir DIR] [--print-plan] [--help]
#
#   --channel     IBKR channel to build (default stable; with --installer, the installer's own)
#   --strict      build only the version pinned in versions.json; exit 4 when IBKR serves another
#   --installer   build from this installer file instead of IBKR's download (its version is read
#                 from its build stamp; its SHA-256 is recorded)
#   --platform    image platform (default: the Docker host's architecture)
#   --tag         image name; may be given more than once; replaces the default tags
#                 brokersre-ib-gateway:<channel> and brokersre-ib-gateway:<version>
#   --no-smoke    skip the offline IBC smoke test after the build
#   --cache-dir   installer cache (default ${XDG_CACHE_HOME:-$HOME/.cache}/brokersre-ib-gateway)
#   --print-plan  resolve and print what would be built (version, pinned or not, cache hit);
#                 download nothing, build nothing
#
# What it does: (1) builds the small helper image scripts/build-helper (Docker CLI image pinned
# by digest, plus bash, curl, jq); (2) runs scripts/resolve-installer.sh in it, which decides
# the installer (pinned version and SHA-256, or IBKR's newer build checked against IBKR's own
# build stamp, or --installer), downloads or takes it from the cache, and puts it in the build
# context's downloads/; (3) runs `docker buildx build --load` with the resolved build arguments
# (the Dockerfile checks the installed stamp again); (4) runs the IBC smoke test
# (tests/container/run.sh --only ibc-smoke, offline); (5) records the installer in the cache
# and prints the summary. A build IBKR moved past the pin is labelled
# com.rocketedge.brokersre.qualified=no and a warning says how to qualify it.
#
# Output: progress and warnings on stderr; on success the last seven lines of stdout are
#   version, channel, qualified_by_project, installer_sha256, ibkr_build_stamp, image, image_id
#   as `key: value` (with --print-plan: the plan's `key: value` lines). qualified_by_project:
#   yes means the version and the installer's SHA-256 equal the pin in versions.json, which
#   passed the project's offline CI; a paper login is a separate qualification
#   (scripts/qualify-paper.sh), and a stable pin can move without a person (ADR 0018).
# Exit codes: 0 built (and smoke-tested unless --no-smoke); 1 download, verification, build or
#   smoke test failed; 2 usage; 3 IBKR unreachable and no usable cached installer; 4 --strict
#   and IBKR serves (or the installer is) a version other than the pin.
# Host requirements: bash (3.2 or later) and Docker with buildx. Nothing else: resolving,
#   downloading and verifying run in the helper container.
# Environment: BROKERSRE_TEST_IBKR_BASE_URL (tests only) replaces IBKR's download server; it is
#   passed to the helper, which announces it. SMOKE_TIMEOUT is passed to the smoke test.
# Side effects: Docker images (helper, gateway), the installer cache, a file in downloads/ for
#   the duration of the build.
#
# Interface contract: docs/specs/2026-11-17-private-image-public-recipe.md; decision: ADR 0018.
set -euo pipefail
# Git Bash rewrites arguments that look like POSIX paths; container paths stay literal and
# host paths are converted explicitly (host_path).
export MSYS_NO_PATHCONV=1

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper_image="brokersre-ib-gateway-build-helper:local"
default_repository="brokersre-ib-gateway"

# usage: print the command-line interface.
usage() {
  cat <<'EOF'
usage: scripts/build-image.sh [--channel stable|latest] [--strict] [--installer FILE]
                              [--platform linux/amd64|linux/arm64] [--tag NAME] [--no-smoke]
                              [--cache-dir DIR] [--print-plan] [--help]

  --channel     IBKR channel (default stable; with --installer, the installer's own)
  --strict      build only the version pinned in versions.json (exit 4 otherwise)
  --installer   build from this installer file; its version comes from its build stamp
  --platform    image platform (default: the Docker host's architecture)
  --tag         image name, repeatable; replaces brokersre-ib-gateway:<channel> and :<version>
  --no-smoke    skip the offline IBC smoke test
  --cache-dir   installer cache (default ${XDG_CACHE_HOME:-$HOME/.cache}/brokersre-ib-gateway)
  --print-plan  print what would be built (version, pinned or not, cache hit); no download, no build

Exit codes: 0 built, 1 download/verification/build/smoke test failed, 2 usage,
3 IBKR unreachable and no usable cached installer, 4 --strict and IBKR serves another version.

qualified_by_project: yes means the version and the installer's SHA-256 equal the pin in
versions.json, which passed the project's offline CI; a paper login is a separate
qualification (scripts/qualify-paper.sh). A stable pin can move without a person
(STABLE_AUTOMERGE, ADR 0018).
EOF
}

# die_usage MESSAGE: a usage error (exit 2).
die_usage() {
  printf 'build-image: %s\n' "$1" >&2
  usage >&2
  exit 2
}

# say MESSAGE...: one progress line on stderr.
say() { printf 'build-image: %s\n' "$*" >&2; }

# host_path PATH: PATH as the Docker CLI on this host understands it (C:/... under Git Bash).
host_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

channel=""
strict=no
installer=""
platform=""
tags=()
smoke=yes
cache_dir=""
print_plan=no
while [ $# -gt 0 ]; do
  case "$1" in
    --channel | --installer | --platform | --tag | --cache-dir)
      [ $# -ge 2 ] && [ -n "$2" ] || die_usage "$1 needs a value"
      case "$1" in
        --channel) channel="$2" ;;
        --installer) installer="$2" ;;
        --platform) platform="$2" ;;
        --tag) tags+=("$2") ;;
        --cache-dir) cache_dir="$2" ;;
      esac
      shift 2
      ;;
    --strict) strict=yes && shift ;;
    --no-smoke) smoke=no && shift ;;
    --print-plan) print_plan=yes && shift ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die_usage "unknown option '$1'" ;;
  esac
done
case "${channel}" in "" | stable | latest) ;; *) die_usage "--channel must be stable or latest" ;; esac
case "${platform}" in "" | linux/amd64 | linux/arm64) ;; *) die_usage "--platform must be linux/amd64 or linux/arm64" ;; esac
if [ -n "${installer}" ]; then
  [ -f "${installer}" ] && [ -r "${installer}" ] || die_usage "--installer: cannot read '${installer}'"
  installer_dir="$(cd "$(dirname "${installer}")" && pwd)"
  installer_name="$(basename "${installer}")"
fi

command -v docker >/dev/null 2>&1 || {
  say "Docker is required (Docker Desktop, or Docker Engine 23 or later with buildx)"
  exit 1
}
docker buildx version >/dev/null 2>&1 || {
  say "docker buildx is required (Docker Desktop, or Docker Engine 23 or later with the buildx plugin)"
  exit 1
}
# The daemon, before anything asks it a question: without this check a stopped Docker Desktop
# surfaced as an empty architecture, or (with --platform) as a failed helper build. Docker's
# own error is not repeated: it can name DOCKER_HOST, which may hold a user name.
server_version="$(docker version --format '{{.Server.Version}}' 2>/dev/null)" || server_version=""
if [ -z "${server_version}" ]; then
  context="$(docker context show 2>/dev/null)" || context="unknown"
  say "the Docker daemon is not reachable (Docker context '${context}'$([ -n "${DOCKER_HOST:-}" ] && printf ', DOCKER_HOST is set')): start Docker Desktop and wait until its engine runs (Windows, macOS), or start the daemon (Linux: sudo systemctl start docker); check the Docker context and DOCKER_HOST"
  exit 1
fi
if [ -z "${platform}" ]; then
  host_arch="$(docker info --format '{{.Architecture}}')"
  case "${host_arch}" in
    x86_64 | amd64) platform=linux/amd64 ;;
    aarch64 | arm64) platform=linux/arm64 ;;
    *)
      say "the Docker host's architecture '${host_arch}' is not supported; pass --platform"
      exit 1
      ;;
  esac
fi
arch=x64
if [ "${platform}" = linux/arm64 ]; then arch=arm; fi
if [ -z "${cache_dir}" ]; then cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/brokersre-ib-gateway"; fi
# Created here, so that Docker does not create it (as root, on Linux) for the bind mount.
mkdir -p "${cache_dir}" "${repo_root}/downloads"

# `buildx build --load`, not `docker build`: with a docker-container default builder (what
# docker/setup-buildx-action installs) a plain build leaves the image in the build cache only.
if ! docker buildx build --load -q -t "${helper_image}" "$(host_path "${repo_root}/scripts/build-helper")" >/dev/null; then
  say "could not build the helper image from scripts/build-helper"
  exit 1
fi

# The proxy variables of the caller's environment, by name. Docker takes their values from this
# process's environment (`-e NAME`, `--build-arg NAME`), so a value, which may hold a password,
# is never in an argument list or in the output. They are predefined build arguments: usable in
# RUN steps, kept out of `docker history` and the image configuration (the Dockerfile declares
# none). A proxy in Docker's config.json still applies when none of these is set.
proxy_names=""
for proxy_name in HTTPS_PROXY HTTP_PROXY NO_PROXY https_proxy http_proxy no_proxy; do
  if [ -n "${!proxy_name:-}" ]; then proxy_names="${proxy_names} ${proxy_name}"; fi
done

# helper ARGS...: run scripts/resolve-installer.sh ARGS in the helper container, with the cache,
# the repository (read-only), downloads/ and the --installer directory mounted. On Linux it
# runs as the calling user, so that the cache and downloads/ stay the user's. It is told that
# the caller is bash and where downloads/ is on this host, so that its advice names the
# caller's command and path (BROKERSRE_HOST_SHELL, BROKERSRE_HOST_DOWNLOADS).
helper() {
  set -- -v "$(host_path "${cache_dir}"):/cache" -v "$(host_path "${repo_root}"):/repo:ro" \
    -v "$(host_path "${repo_root}/downloads"):/downloads" -e BROKERSRE_TEST_IBKR_BASE_URL \
    -e BROKERSRE_HOST_SHELL=bash -e "BROKERSRE_HOST_DOWNLOADS=$(host_path "${repo_root}/downloads")" \
    "${helper_image}" bash /repo/scripts/resolve-installer.sh "$@"
  # The helper's messages name the cache and the --installer file as the user knows them
  # (BROKERSRE_HOST_CACHE, BROKERSRE_HOST_INSTALLER), not by its mounts /cache and /installer.
  set -- -e "BROKERSRE_HOST_CACHE=${cache_dir}" "$@"
  if [ -n "${installer}" ]; then
    set -- -v "$(host_path "${installer_dir}"):/installer:ro" -e "BROKERSRE_HOST_INSTALLER=${installer}" "$@"
  fi
  for proxy_name in ${proxy_names}; do set -- -e "${proxy_name}" "$@"; done
  if [ "$(uname -s)" = Linux ]; then set -- --user "$(id -u):$(id -g)" "$@"; fi
  docker run --rm "$@"
}

set -- resolve --arch "${arch}" --versions /repo/versions.json --cache /cache --downloads /downloads
if [ -n "${channel}" ]; then set -- "$@" --channel "${channel}"; fi
if [ "${strict}" = yes ]; then set -- "$@" --strict; fi
if [ -n "${installer}" ]; then set -- "$@" --installer "/installer/${installer_name}"; fi
if [ "${print_plan}" = yes ]; then set -- "$@" --print-plan; fi
rc=0
plan="$(helper "$@")" || rc=$?
case "${rc}" in
  0) ;;
  1 | 2 | 3 | 4) exit "${rc}" ;; # the helper said why on stderr
  *)
    # Not the helper's answer: docker itself failed (125 daemon or mount error, 126/127 the
    # command could not run). The contract has no such code; it is a failed build.
    say "the helper container did not run (docker exit ${rc})"
    exit 1
    ;;
esac

# value KEY: the value of the plan line `KEY: value`.
value() { printf '%s\n' "${plan}" | sed -n "s/^$1: //p" | sed -n 1p; }
version="$(value version)"
channel="$(value channel)"
run_id="$(value run)"
context_file="$(value context_file)"
if [ "${#tags[@]}" -eq 0 ]; then tags=("${default_repository}:${channel}" "${default_repository}:${version}"); fi
image="${tags[0]}"

if [ "${print_plan}" = yes ]; then
  printf '%s\n' "${plan}"
  printf 'platform: %s\nimage: %s\n' "${platform}" "${image}"
  exit 0
fi

# discard: forget the run (nothing is cached) after a failed build or smoke test.
discard() {
  helper discard --cache /cache --run "${run_id}" >/dev/null 2>&1 || true
}
context_path="${repo_root}/${context_file}"
# remove_context_installer: remove the installer this run put into downloads/ (and only that:
# a file that was there before, the user's, is never removed).
# shellcheck disable=SC2329  # invoked through the EXIT trap
remove_context_installer() {
  if [ "$(value context_owned)" = yes ]; then rm -f "${context_path}"; fi
}
trap remove_context_installer EXIT

set -- buildx build --platform "${platform}" --load
for tag in "${tags[@]}"; do set -- "$@" -t "${tag}"; done
while IFS= read -r line; do
  case "${line}" in "build_arg: "*) set -- "$@" --build-arg "${line#build_arg: }" ;; esac
done <<EOF
${plan}
EOF
for proxy_name in ${proxy_names}; do set -- "$@" --build-arg "${proxy_name}"; done
# The build's own OCI labels (the bake path sets the same through bake-env.sh): the build time
# in UTC, to the second, and the commit of this checkout, or unknown when it is not a git work
# tree (a downloaded archive). Without them the image showed the Ubuntu base image's `created`
# and no revision. They change the image id from build to build, which a rebuild did anyway
# (README, "Pinning and reproducing a build"): same Gateway and IBC, not the same image id.
# Asked in the checkout, with no path argument: MSYS_NO_PATHCONV=1 (above) keeps Git Bash from
# converting a POSIX path for git, which then cannot open it (the label said unknown).
build_revision="$(cd "${repo_root}" && git rev-parse HEAD 2>/dev/null)" || build_revision=""
case "${build_revision}" in "" | *[!0-9a-f]*) build_revision=unknown ;; esac
set -- "$@" --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --label "org.opencontainers.image.revision=${build_revision}"
set -- "$@" -f "$(host_path "${repo_root}/Dockerfile")" "$(host_path "${repo_root}")"
say "building ${image}: IB Gateway ${version} (${channel}) for ${platform}"
if ! docker "$@" >&2; then
  discard
  say "the image build failed; nothing was cached"
  exit 1
fi
remove_context_installer

if [ "${smoke}" = yes ]; then
  say "smoke test: IMAGE=${image} tests/container/run.sh --only ibc-smoke (offline)"
  if ! IMAGE="${image}" "${repo_root}/tests/container/run.sh" --only ibc-smoke >&2; then
    discard
    say "the IBC smoke test failed for ${image}; nothing was cached"
    exit 1
  fi
fi

rc=0
summary="$(helper accept --cache /cache --run "${run_id}" --image "${image}")" || rc=$?
if [ "${rc}" -ne 0 ]; then
  say "the image was built, but the helper could not record it (exit ${rc})"
  exit 1
fi
image_id="$(docker image inspect --format '{{.Id}}' "${image}")"
printf '%s\n' "${summary}"
printf 'image: %s\nimage_id: %s\n' "${image}" "${image_id}"
