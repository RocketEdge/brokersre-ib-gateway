#!/usr/bin/env bash
# Prints `export VAR=value` lines for docker-bake.hcl from versions.json, so the JSON stays the
# single source of truth. Usage: eval "$(scripts/bake-env.sh)"; optional $1 = path to versions.json.
#
# <CHANNEL>_BUILD_STAMP is IBKR's build stamp of the pinned version, "(.<last part of the
# version>) <build_datetime>" (10.50.1g -> "(.1g) 20261109 16:10:13"): the Dockerfile fails a
# build whose installed Gateway carries another stamp (fetch-installer.sh --check-stamp). A
# channel without build_datetime is refused, so a bake build never skips that check silently.
set -euo pipefail

versions="${1:-$(dirname "$0")/../versions.json}"
command -v jq >/dev/null || {
  echo "jq is required" >&2
  exit 1
}

q() { jq -r "$1" "${versions}"; }
minor() { echo "$1" | cut -d. -f1,2; }
# build_stamp CHANNEL: the pinned build stamp of CHANNEL; exit 1 when build_datetime is missing.
build_stamp() {
  local version datetime
  version="$(q ".channels.$1.version")"
  datetime="$(jq -er ".channels.$1.build_datetime | strings" "${versions}")" || {
    echo "bake-env: versions.json has no build_datetime for the $1 channel" >&2
    exit 1
  }
  printf '(.%s) %s' "${version##*.}" "${datetime}"
}

stable_version="$(q '.channels.stable.version')"
latest_version="$(q '.channels.latest.version')"
stable_stamp="$(build_stamp stable)"
latest_stamp="$(build_stamp latest)"

cat <<EOF
export UBUNTU_DIGEST='$(q '.base.digest')'
export IBC_VERSION='$(q '.ibc.version')'
export IBC_RELEASE_TAG='$(q '.ibc.release_tag')'
export IBC_SHA256='$(q '.ibc.sha256')'
export STABLE_VERSION='${stable_version}'
export STABLE_MINOR='$(minor "${stable_version}")'
export STABLE_SHA256_X64='$(q '.channels.stable.sha256.x64')'
export STABLE_SHA256_ARM='$(q '.channels.stable.sha256.arm')'
export STABLE_BUILD_STAMP='${stable_stamp}'
export LATEST_VERSION='${latest_version}'
export LATEST_MINOR='$(minor "${latest_version}")'
export LATEST_SHA256_X64='$(q '.channels.latest.sha256.x64')'
export LATEST_SHA256_ARM='$(q '.channels.latest.sha256.arm')'
export LATEST_BUILD_STAMP='${latest_stamp}'
export SOURCE_REVISION='$(git -C "$(dirname "${versions}")" rev-parse HEAD 2>/dev/null || echo unknown)'
export CREATED='$(date -u +%Y-%m-%dT%H:%M:%SZ)'
EOF
