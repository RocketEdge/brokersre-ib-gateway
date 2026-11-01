#!/usr/bin/env bash
# Prints `export VAR=value` lines for docker-bake.hcl from versions.json, so the JSON stays the
# single source of truth. Usage: eval "$(scripts/bake-env.sh)"; optional $1 = path to versions.json.
set -euo pipefail

versions="${1:-$(dirname "$0")/../versions.json}"
command -v jq >/dev/null || {
  echo "jq is required" >&2
  exit 1
}

q() { jq -r "$1" "${versions}"; }
minor() { echo "$1" | cut -d. -f1,2; }

stable_version="$(q '.channels.stable.version')"
latest_version="$(q '.channels.latest.version')"

cat <<EOF
export UBUNTU_DIGEST='$(q '.base.digest')'
export IBC_VERSION='$(q '.ibc.version')'
export IBC_RELEASE_TAG='$(q '.ibc.release_tag')'
export IBC_SHA256='$(q '.ibc.sha256')'
export STABLE_VERSION='${stable_version}'
export STABLE_MINOR='$(minor "${stable_version}")'
export STABLE_SHA256_X64='$(q '.channels.stable.sha256.x64')'
export STABLE_SHA256_ARM='$(q '.channels.stable.sha256.arm')'
export LATEST_VERSION='${latest_version}'
export LATEST_MINOR='$(minor "${latest_version}")'
export LATEST_SHA256_X64='$(q '.channels.latest.sha256.x64')'
export LATEST_SHA256_ARM='$(q '.channels.latest.sha256.arm')'
export SOURCE_REVISION='$(git -C "$(dirname "${versions}")" rev-parse HEAD 2>/dev/null || echo unknown)'
export CREATED='$(date -u +%Y-%m-%dT%H:%M:%SZ)'
EOF
