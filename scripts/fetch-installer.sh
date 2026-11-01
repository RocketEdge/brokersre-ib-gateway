#!/usr/bin/env bash
# Build-time only (runs inside the Dockerfile's setup stage).
#
# Purpose: obtain the IB Gateway installer for IB_GATEWAY_VERSION/TARGETARCH and prove its
# SHA-256 matches the pin passed in as a build argument.
#
# Contract:
#   $1                      destination path for the verified installer
#   IB_GATEWAY_VERSION      e.g. 10.50.1f
#   IB_GATEWAY_CHANNEL      stable | latest (selects IBKR's unversioned URL)
#   IB_GATEWAY_SHA256_X64 / IB_GATEWAY_SHA256_ARM   expected digests
#   IB_GATEWAY_URL_BASE     https://download2.interactivebrokers.com/installers/ibgateway
#   TARGETARCH              amd64 | arm64 (set by BuildKit)
#
# Order of preference: a pre-fetched file under /tmp/downloads (CI drops the private-archive
# copy there when IBKR's channel URL already serves a newer build), then IBKR's URL. Either
# way the digest must match or the build fails: no checksum, no image.
set -euo pipefail

dest="${1:?destination path required}"
case "${TARGETARCH:?TARGETARCH not set}" in
  amd64)
    arch=x64
    expected="${IB_GATEWAY_SHA256_X64:?}"
    ;;
  arm64)
    arch=arm
    expected="${IB_GATEWAY_SHA256_ARM:?}"
    ;;
  *)
    echo "unsupported TARGETARCH '${TARGETARCH}'" >&2
    exit 1
    ;;
esac

file="ibgateway-${IB_GATEWAY_VERSION:?}-standalone-linux-${arch}.sh"
prefetched="/tmp/downloads/${file}"
url="${IB_GATEWAY_URL_BASE:?}/${IB_GATEWAY_CHANNEL:?}-standalone/ibgateway-${IB_GATEWAY_CHANNEL}-standalone-linux-${arch}.sh"

verify() {
  echo "${expected}  ${dest}" | sha256sum -c - >/dev/null
}

if [ -f "${prefetched}" ]; then
  echo "fetch-installer: using pre-fetched ${file}"
  cp "${prefetched}" "${dest}"
  if verify; then
    echo "fetch-installer: sha256 ok (pre-fetched)"
    exit 0
  fi
  echo "fetch-installer: pre-fetched installer does not match the pinned sha256" >&2
  exit 1
fi

echo "fetch-installer: downloading ${url}"
curl -fsSL --retry 3 --retry-delay 5 "${url}" -o "${dest}"
if verify; then
  echo "fetch-installer: sha256 ok (${expected})"
  exit 0
fi
actual="$(sha256sum "${dest}" | cut -d' ' -f1)"
cat >&2 <<EOF
fetch-installer: SHA-256 MISMATCH for ${file}
  expected ${expected}
  actual   ${actual}
IBKR's unversioned ${IB_GATEWAY_CHANNEL} URL no longer serves ${IB_GATEWAY_VERSION}. Either bump
versions.json (detect-releases.yml does this) or place the archived installer under downloads/.
EOF
exit 1
