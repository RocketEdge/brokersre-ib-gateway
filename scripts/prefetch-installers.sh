#!/usr/bin/env bash
# Copy a pinned IB Gateway version's installers from the private archive into downloads/,
# keeping only copies whose SHA-256 matches the pin.
#
# Purpose: IBKR's channel URL serves only its newest build, so a pinned version that IBKR has
# moved past can only be built from the archive (RocketEdge/brokersre-ib-gateway-archive, written
# by detect-releases.yml). fetch-installer.sh fails the build when a pre-fetched file does not
# match the pin, so a copy that matches no pin is dropped here and the build falls back to IBKR's
# URL.
#
# Contract:
#   prefetch-installers.sh <channel> <version> <sha256_x64> <sha256_arm> <dest_dir>
#   GH_TOKEN       ARCHIVE_READ_TOKEN (contents: read on the archive repository); when empty the
#                  script does nothing and exits 0, leaving the build on IBKR's URL. A bad or
#                  expired token looks like an archive miss (gh fails either way).
#   candidates     release `ibgateway-<channel>@<version>` (a new version, as first archived) and
#                  `ibgateway-<channel>@<version>-<first 8 hex of sha256_x64><first 8 hex of
#                  sha256_arm>` (bytes IBKR re-uploaded under the same version, archived by
#                  detect-releases.yml; keyed by both hashes so an arm-only re-upload has its own
#                  release); for each
#                  architecture the first candidate copy whose SHA-256 equals the pin is used
#   dest_dir       existing directory (the build context's downloads/)
#   result         dest_dir holds ibgateway-<version>-standalone-linux-{x64,arm}.sh for every
#                  architecture with a matching copy, and nothing else from the archive; misses
#                  are reported and are not an error
#   exit           0, or 2 on bad arguments
# Side effects: network (gh release download), files in a temporary directory and dest_dir.
set -euo pipefail

archive_repo="RocketEdge/brokersre-ib-gateway-archive"

[ $# -eq 5 ] || {
  echo "usage: prefetch-installers.sh <stable|latest> <version> <sha256_x64> <sha256_arm> <dest_dir>"
  exit 2
}
channel="$1"
version="$2"
pin_x64="${3,,}"
pin_arm="${4,,}"
dest="$5"
case "${channel}" in
  stable | latest) ;;
  *)
    echo "prefetch-installers: unknown channel '${channel}' (expected stable or latest)"
    exit 2
    ;;
esac
[ -d "${dest}" ] || {
  echo "prefetch-installers: destination '${dest}' is not a directory"
  exit 2
}

if [ -z "${GH_TOKEN:-}" ]; then
  echo "prefetch-installers: no ARCHIVE_READ_TOKEN; relying on IBKR's channel URL"
  exit 0
fi

staging="$(mktemp -d)"
trap 'rm -rf "${staging}"' EXIT
tags=("ibgateway-${channel}@${version}" "ibgateway-${channel}@${version}-${pin_x64:0:8}${pin_arm:0:8}")
for i in "${!tags[@]}"; do
  mkdir -p "${staging}/${i}"
  if ! gh release download "${tags[${i}]}" -R "${archive_repo}" --pattern '*.sh' --dir "${staging}/${i}" 2>/dev/null; then
    echo "prefetch-installers: no archive release ${tags[${i}]}"
  fi
done

for arch in x64 arm; do
  if [ "${arch}" = x64 ]; then expected="${pin_x64}"; else expected="${pin_arm}"; fi
  file="ibgateway-${version}-standalone-linux-${arch}.sh"
  found=""
  for i in "${!tags[@]}"; do
    candidate="${staging}/${i}/${file}"
    if [ -f "${candidate}" ] && [ "$(sha256sum "${candidate}" | cut -d' ' -f1)" = "${expected}" ]; then
      found="${candidate}"
      echo "prefetch-installers: ${file} from ${tags[${i}]} (sha256 ok)"
      break
    fi
  done
  if [ -n "${found}" ]; then
    cp "${found}" "${dest}/${file}"
  else
    echo "prefetch-installers: no archived copy matches the pin for ${file}; relying on IBKR's channel URL"
  fi
done
