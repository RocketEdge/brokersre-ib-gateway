#!/usr/bin/env bash
# Copy a pinned IB Gateway version's installers from the private archive into downloads/,
# keeping only copies whose SHA-256 matches the pin.
#
# Purpose: IBKR's channel URL serves only its newest build, so a pinned version that IBKR has
# moved past can only be built from the archive (RocketEdge/brokersre-ib-gateway-archive, release
# `ibgateway-<channel>@<version>`, written by detect-releases.yml). fetch-installer.sh fails the
# build when a pre-fetched file does not match the pin, so a stale archive copy (IBKR re-uploaded
# the version) is dropped here and the build falls back to IBKR's URL.
#
# Contract:
#   prefetch-installers.sh <channel> <version> <sha256_x64> <sha256_arm> <dest_dir>
#   GH_TOKEN       ARCHIVE_READ_TOKEN (contents: read on the archive repository); when empty the
#                  script does nothing and exits 0, leaving the build on IBKR's URL
#   dest_dir       existing directory (the build context's downloads/)
#   result         dest_dir holds ibgateway-<version>-standalone-linux-{x64,arm}.sh for every
#                  architecture whose archive copy matches its pin, and nothing else from the
#                  archive; an archive miss is reported and is not an error
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
dest="$5"
case "${channel}" in
  stable | latest) ;;
  *)
    echo "prefetch-installers: unknown channel '${channel}' (expected stable or latest)"
    exit 2
    ;;
esac

if [ -z "${GH_TOKEN:-}" ]; then
  echo "prefetch-installers: no ARCHIVE_READ_TOKEN; relying on IBKR's channel URL"
  exit 0
fi

staging="$(mktemp -d)"
trap 'rm -rf "${staging}"' EXIT
tag="ibgateway-${channel}@${version}"
if ! gh release download "${tag}" -R "${archive_repo}" --pattern '*.sh' --dir "${staging}"; then
  echo "prefetch-installers: archive miss for ${tag}; relying on IBKR's channel URL"
  exit 0
fi

for arch in x64 arm; do
  if [ "${arch}" = x64 ]; then expected="${3,,}"; else expected="${4,,}"; fi
  file="ibgateway-${version}-standalone-linux-${arch}.sh"
  if [ ! -f "${staging}/${file}" ]; then
    echo "prefetch-installers: ${file} not in ${tag}; relying on IBKR's channel URL"
    continue
  fi
  actual="$(sha256sum "${staging}/${file}" | cut -d' ' -f1)"
  if [ "${actual}" = "${expected}" ]; then
    cp "${staging}/${file}" "${dest}/${file}"
    echo "prefetch-installers: ${file} from ${tag} (sha256 ok)"
  else
    echo "prefetch-installers: archived ${file} does not match the pin (${actual}); dropped, relying on IBKR's channel URL"
  fi
done
