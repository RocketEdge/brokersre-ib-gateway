#!/usr/bin/env bash
# Run the bats unit suite INSIDE the built image, so the scripts are exercised with the exact
# bash, coreutils, envsubst and jq they ship with. bats-core is mounted from the host (the image
# has no curl or git by design).
#
# Usage: tests/bats/run-in-image.sh <image> [bats-core dir]
set -euo pipefail
# Git Bash on Windows rewrites POSIX-looking arguments into Windows paths; keep docker's
# container-side paths literal and convert only the host path explicitly.
export MSYS_NO_PATHCONV=1
image="${1:?image reference}"
bats_dir="${2:-tests/.bats-core}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
if [ ! -x "${repo}/${bats_dir}/bin/bats" ]; then
  echo "bats-core not found at ${bats_dir}; clone it: git clone --depth 1 -b v1.14.0 https://github.com/bats-core/bats-core ${bats_dir}" >&2
  exit 2
fi
host_repo="${repo}"
if command -v cygpath >/dev/null 2>&1; then host_repo="$(cygpath -m "${repo}")"; fi
docker run --rm \
  -v "${host_repo}:/code:ro" \
  -w /code \
  -e BROKERSRE_LIB=/code/rootfs/usr/local/lib/brokersre \
  --entrypoint bash \
  "${image}" \
  -c "/code/${bats_dir}/bin/bats --print-output-on-failure /code/tests/bats/unit"
