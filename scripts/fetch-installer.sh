#!/usr/bin/env bash
# Build-time only (runs inside the Dockerfile's setup stage); the stamp reader also runs in the
# build helper (scripts/resolve-installer.sh), so the two read an installer's identity the same
# way.
#
# Purpose: obtain the IB Gateway installer for IB_GATEWAY_VERSION/TARGETARCH and prove its
# SHA-256 matches the build argument; after installation, prove that the installed Gateway is
# the build the image is labelled with.
#
# Contract:
#   fetch-installer.sh <dest>
#     $1                      destination path for the verified installer
#     IB_GATEWAY_VERSION      e.g. 10.50.1f
#     IB_GATEWAY_CHANNEL      stable | latest (selects IBKR's unversioned URL)
#     IB_GATEWAY_SHA256_X64 / IB_GATEWAY_SHA256_ARM   expected digests
#     IB_GATEWAY_URL_BASE     https://download2.interactivebrokers.com/installers/ibgateway
#     TARGETARCH              amd64 | arm64 (set by BuildKit)
#     Order of preference: a pre-fetched file under /tmp/downloads (the build helper, or CI from
#     the private archive, puts it there), then IBKR's URL. Either way the digest must match or
#     the build fails: no checksum, no image.
#   fetch-installer.sh --read-stamp <install dir>
#     Prints three lines read from <install dir>/.install4j/i4jparams.conf, which install4j
#     writes at installation (and which the installer carries in its own archive):
#       version: <number of applicationName>.<suffix of applicationVersion>   e.g. 10.50.1h
#       build_stamp: <applicationVersion as written>   e.g. (.1h) 20261116 16:02:08
#       media: <mediaName>   e.g. ibgateway-stable-standalone-linux-x64 (may be empty)
#     Exit 1 when the file is missing or no version can be derived from it.
#   fetch-installer.sh --check-stamp <install dir>
#     When IB_GATEWAY_BUILD_STAMP is set, the installed build stamp must equal it and the
#     installed version must equal IB_GATEWAY_VERSION; otherwise exit 1 naming expected and
#     actual. When it is unset or empty the check is skipped (exit 0, said on stdout).
#
# Why the stamp: IBKR publishes no checksum, but it publishes the version a channel serves
# (version.json: buildVersion, buildDateTime) and the installed Gateway records the same facts
# as applicationVersion "(.<suffix>) <buildDateTime>" (10.50.1g: "(.1g) 20261109 16:10:13",
# equal to versions.json). A build that IBKR moved past the pin is accepted only when the
# installed stamp equals what IBKR announced (ADR 0018).
set -euo pipefail

# read_stamp INSTALL_DIR: print the three `key: value` lines of --read-stamp; exit 1 with a
# message on stderr when the stamp is missing or names no version.
read_stamp() {
  local conf="$1/.install4j/i4jparams.conf" name app_version media number suffix
  if [ ! -f "${conf}" ]; then
    echo "fetch-installer: no build stamp: ${conf} does not exist" >&2
    return 1
  fi
  # The attributes sit on install4j's one-line <general .../> element; take the first of each.
  name="$(sed -n 's/.*applicationName="\([^"]*\)".*/\1/p' "${conf}" | head -n 1)"
  app_version="$(sed -n 's/.*applicationVersion="\([^"]*\)".*/\1/p' "${conf}" | head -n 1)"
  media="$(sed -n 's/.*mediaName="\([^"]*\)".*/\1/p' "${conf}" | head -n 1)"
  number="${name##* }"
  suffix=""
  if [[ "${app_version}" =~ ^\((\.[0-9A-Za-z]+)\)\  ]]; then
    suffix="${BASH_REMATCH[1]}"
  fi
  if ! [[ "${number}" =~ ^[0-9]+\.[0-9]+$ ]] || [ -z "${suffix}" ]; then
    echo "fetch-installer: cannot derive a version from ${conf} (applicationName '${name}', applicationVersion '${app_version}')" >&2
    return 1
  fi
  printf 'version: %s\nbuild_stamp: %s\nmedia: %s\n' "${number}${suffix}" "${app_version}" "${media}"
}

# check_stamp INSTALL_DIR: compare the installed stamp and version with IB_GATEWAY_BUILD_STAMP
# and IB_GATEWAY_VERSION; exit 1 naming both values on a difference.
check_stamp() {
  local expected_stamp="${IB_GATEWAY_BUILD_STAMP:-}" fields actual_version actual_stamp
  if [ -z "${expected_stamp}" ]; then
    echo "fetch-installer: no IB_GATEWAY_BUILD_STAMP; build stamp not checked"
    return 0
  fi
  fields="$(read_stamp "$1")" || return 1
  actual_version="$(sed -n 's/^version: //p' <<<"${fields}")"
  actual_stamp="$(sed -n 's/^build_stamp: //p' <<<"${fields}")"
  if [ "${actual_stamp}" != "${expected_stamp}" ]; then
    cat >&2 <<EOF
fetch-installer: BUILD STAMP MISMATCH in $1
  expected ${expected_stamp}
  actual   ${actual_stamp}
The installed IB Gateway is not the build IBKR announced (or versions.json pins).
EOF
    return 1
  fi
  if [ "${actual_version}" != "${IB_GATEWAY_VERSION:?IB_GATEWAY_VERSION not set}" ]; then
    cat >&2 <<EOF
fetch-installer: VERSION MISMATCH in $1
  expected ${IB_GATEWAY_VERSION}
  actual   ${actual_version}
EOF
    return 1
  fi
  echo "fetch-installer: build stamp ok (${actual_stamp}, IB Gateway ${actual_version})"
}

case "${1:-}" in
  --read-stamp)
    read_stamp "${2:?install directory required}"
    exit
    ;;
  --check-stamp)
    check_stamp "${2:?install directory required}"
    exit
    ;;
esac

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
IBKR's unversioned ${IB_GATEWAY_CHANNEL} URL no longer serves ${IB_GATEWAY_VERSION}. Build with
scripts/build-image.sh (it follows IBKR's channel and verifies IBKR's build stamp), bump
versions.json (detect-releases.yml does this) or place the archived installer under downloads/.
EOF
exit 1
