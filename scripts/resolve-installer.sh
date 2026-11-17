#!/usr/bin/env bash
# The build helper's one implementation: decide which IB Gateway installer an image is built
# from, obtain it, verify it and cache it. Runs inside the helper container
# (scripts/build-helper/Dockerfile) started by scripts/build-image.sh and scripts/build-image.ps1,
# so every host does the same thing with the same tools (bash, curl, jq, coreutils, tar, gzip).
#
# Contract:
#   resolve-installer.sh resolve --arch x64|arm --versions FILE --cache DIR --downloads DIR
#                                [--channel stable|latest] [--strict] [--installer FILE]
#                                [--print-plan]
#     Decides, obtains and verifies; writes the installer to DIR(--downloads)/
#     ibgateway-<version>-standalone-linux-<arch>.sh (the build context's downloads/, where the
#     Dockerfile's fetch-installer.sh takes it) and stages it in a run directory under
#     --cache. Prints `key: value` lines on stdout:
#       version, channel, arch, pinned_version, pinned (yes|no), qualified_by_project (yes|no),
#       ibkr_build_stamp, installer_sha256 (or `unknown` in a plan that downloads),
#       source (ibkr|cache|installer), cache_hit (yes|no), ibkr_reachable (yes|no|not-asked),
#       then, unless --print-plan: context_file, run, and one `build_arg: NAME=VALUE` line per
#       Dockerfile build argument.
#     Decision (docs/specs/2026-11-17-private-image-public-recipe.md, ADR 0018):
#       - --installer FILE: the version, build stamp, channel and architecture are read from the
#         installer's own i4jparams.conf (fetch-installer.sh --read-stamp); qualified when the
#         version and SHA-256 equal the pin. IBKR is not asked.
#       - IBKR serves the pinned version: the installer (cached copy or download) must have the
#         pinned SHA-256; qualified.
#       - IBKR serves another version: with --strict exit 4; otherwise a cached copy of that
#         version with the same build stamp, or a download accepted only when version.json is
#         the same before and after it (retried once when it changed) and the installer's own
#         stamp, where readable, equals it; not qualified.
#       - IBKR unreachable: the cached pin (qualified), else, without --strict, the newest
#         cached version of the channel (not qualified), else exit 3.
#     Exit: 0 resolved; 1 download or verification failed; 2 usage; 3 IBKR unreachable and
#     nothing usable cached; 4 --strict and IBKR serves (or the installer is) another version.
#   resolve-installer.sh accept --cache DIR --run ID --image NAME
#     After a successful build: moves the run's installer (if one was staged) into
#     DIR/installers/<version>/<arch>/ with its `meta`, prints the warning for a build the
#     project has not qualified (stderr) and the five summary lines version, channel,
#     qualified_by_project, installer_sha256, ibkr_build_stamp (stdout); removes the run.
#   resolve-installer.sh discard --cache DIR --run ID
#     After a failed build: removes the run (nothing is cached).
#
# Cache layout (DIR): installers/<version>/<arch>/{ibgateway-<version>-standalone-linux-<arch>.sh,
#   meta}; meta holds `key: value` lines version, channel, arch, sha256, ibkr_build_stamp,
#   source, accepted_at (UTC). runs/<id>/ holds a run's plan and staged installer; runs older
#   than a day are removed by the next resolve. A cached file is used only while its SHA-256
#   still equals its meta.
#
# Environment: BROKERSRE_TEST_IBKR_BASE_URL replaces IBKR's base URL. It exists for tests only
#   (a fake server, or a closed port to simulate an unreachable IBKR); every use is announced
#   on stderr. Without it the helper talks to IBKR only, over HTTPS only.
# Side effects: network (IBKR), files under --cache and --downloads; human messages on stderr.
set -euo pipefail

readonly IBKR_BASE_URL="https://download2.interactivebrokers.com/installers/ibgateway"
readonly VERSION_RE='^[0-9]+\.[0-9]+\.[0-9A-Za-z]+$'
readonly DATETIME_RE='^[0-9]{8} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# say MESSAGE...: one human line on stderr.
say() { printf 'resolve-installer: %s\n' "$*" >&2; }

# die CODE MESSAGE...: say MESSAGE and exit with CODE. Never call it inside $(...): the exit
# would end the subshell only.
die() {
  local code="$1"
  shift
  say "$*"
  exit "${code}"
}

usage() {
  sed -n '3,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed -e '/^set -euo/d' -e 's/^# \{0,1\}//' >&2
  exit 2
}

# stamp_of VERSION DATETIME: IBKR's build stamp as the installed Gateway writes it,
# "(.<last part of VERSION>) DATETIME" (10.50.1g, "20261109 16:10:13" -> "(.1g) 20261109 16:10:13").
stamp_of() { printf '(.%s) %s' "${1##*.}" "$2"; }

# sha256_of FILE: lower-case hex SHA-256 of FILE.
sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

# curl_ibkr ARGS...: curl with the protocol policy: HTTPS only (redirects too) unless the test
# override is set, bounded connection time, no progress meter.
curl_ibkr() {
  local proto="=https"
  if [ -n "${BROKERSRE_TEST_IBKR_BASE_URL:-}" ]; then proto="=http,https"; fi
  curl -fsS --proto "${proto}" --proto-redir "${proto}" --connect-timeout 20 "$@"
}

# fetch_version_json: print the channel's version.json body; non-zero when IBKR cannot be
# reached or answers with an error.
fetch_version_json() {
  curl_ibkr --max-time 60 --retry 2 --retry-delay 2 "${base_url}/${channel}-standalone/version.json"
}

# parse_version_json TEXT: set served_version and served_datetime from IBKR's JSONP
# (`ibgateway<channel>_callback({"buildVersion":"10.50.1h","buildDateTime":"20261116 16:02:08"});`);
# non-zero when the text is not that.
parse_version_json() {
  local json
  json="$(printf '%s' "$1" | sed -E 's/^[^(]*\(//; s/\);?[[:space:]]*$//')"
  served_version="$(jq -er '.buildVersion | strings' <<<"${json}" 2>/dev/null)" || return 1
  served_datetime="$(jq -er '.buildDateTime | strings' <<<"${json}" 2>/dev/null)" || return 1
  [[ "${served_version}" =~ ${VERSION_RE} ]] && [[ "${served_datetime}" =~ ${DATETIME_RE} ]]
}

# read_installer_stamp FILE: set inst_version, inst_stamp and inst_media from the installer's
# own i4jparams.conf, found in the gzip tar that install4j appends to the script (its size is
# on the header line `tail -c <N> "$prg_dir/${progname}"`); parsed by fetch-installer.sh
# --read-stamp, the reader the Dockerfile uses after installation. Non-zero when unreadable.
read_installer_stamp() {
  local file="$1" size tmp fields
  # sed reads all of its input: a reader that stops at the first match would kill the writer
  # with SIGPIPE, and under pipefail the pipeline would fail although the line was found.
  size="$(head -c 262144 "${file}" | sed -n -E 's/^tail -c ([0-9]+) .*/\1/p' | sed -n 1p)"
  [ -n "${size}" ] || return 1
  tmp="$(mktemp -d)"
  mkdir -p "${tmp}/.install4j"
  if ! tail -c "${size}" "${file}" | tar -xzOf - i4jparams.conf >"${tmp}/.install4j/i4jparams.conf" 2>/dev/null; then
    rm -rf "${tmp}"
    return 1
  fi
  if ! fields="$(bash "${script_dir}/fetch-installer.sh" --read-stamp "${tmp}" 2>/dev/null)"; then
    rm -rf "${tmp}"
    return 1
  fi
  rm -rf "${tmp}"
  inst_version="$(sed -n 's/^version: //p' <<<"${fields}")"
  inst_stamp="$(sed -n 's/^build_stamp: //p' <<<"${fields}")"
  inst_media="$(sed -n 's/^media: //p' <<<"${fields}")"
}

# meta_get FILE KEY: the value of `KEY: value` in FILE.
meta_get() { sed -n "s/^$2: //p" "$1" | head -n 1; }

# cache_entry VERSION: the cache directory of VERSION for this architecture.
cache_entry() { printf '%s/installers/%s/%s' "${cache}" "$1" "${arch}"; }

# cache_usable DIR [SHA256] [STAMP]: true when DIR holds an installer whose bytes still match
# its meta, and match SHA256 and STAMP when given.
cache_usable() {
  local dir="$1" want_sha="${2:-}" want_stamp="${3:-}" file sha
  [ -f "${dir}/meta" ] || return 1
  file="${dir}/ibgateway-$(meta_get "${dir}/meta" version)-standalone-linux-${arch}.sh"
  [ -f "${file}" ] || return 1
  sha="$(meta_get "${dir}/meta" sha256)"
  if [ -n "${want_sha}" ] && [ "${sha}" != "${want_sha}" ]; then return 1; fi
  if [ -n "${want_stamp}" ] && [ "$(meta_get "${dir}/meta" ibkr_build_stamp)" != "${want_stamp}" ]; then return 1; fi
  if [ "$(sha256_of "${file}")" != "${sha}" ]; then
    say "cached ${file} no longer matches its recorded SHA-256; ignoring it"
    return 1
  fi
}

# cache_newest_of_channel: print the cache directory of the most recently accepted version of
# this channel and architecture, or nothing.
cache_newest_of_channel() {
  local meta best="" best_at="" at
  for meta in "${cache}"/installers/*/"${arch}"/meta; do
    [ -f "${meta}" ] || continue
    [ "$(meta_get "${meta}" channel)" = "${channel}" ] || continue
    at="$(meta_get "${meta}" accepted_at)"
    if [ -z "${best}" ] || [[ "${at}" > "${best_at}" ]]; then
      best="$(dirname "${meta}")"
      best_at="${at}"
    fi
  done
  printf '%s' "${best}"
}

# use_cached DIR: take the build's installer from cache directory DIR.
use_cached() {
  version="$(meta_get "$1/meta" version)"
  build_stamp="$(meta_get "$1/meta" ibkr_build_stamp)"
  installer_sha="$(meta_get "$1/meta" sha256)"
  installer_file="$1/ibgateway-${version}-standalone-linux-${arch}.sh"
  source=cache
  cache_hit=yes
}

# download_installer: download the channel's installer into the run directory; set
# installer_file and installer_sha. Exit 1 when the download fails.
download_installer() {
  local url="${base_url}/${channel}-standalone/ibgateway-${channel}-standalone-linux-${arch}.sh"
  installer_file="${run_dir}/download-${arch}.sh"
  say "downloading ${url}"
  if ! curl_ibkr -L --max-time 1800 --retry 3 --retry-delay 5 -o "${installer_file}" "${url}"; then
    die 1 "the download of ${url} failed"
  fi
  installer_sha="$(sha256_of "${installer_file}")"
  source=ibkr
  cache_hit=no
}

# new_run: create this resolve's run directory under the cache (where downloads land, so the
# accepted file is moved, not copied) and drop runs older than a day.
new_run() {
  mkdir -p "${cache}/runs"
  find "${cache}/runs" -mindepth 1 -maxdepth 1 -type d -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
  run_dir="$(mktemp -d "${cache}/runs/run-XXXXXXXX")"
  run_id="$(basename "${run_dir}")"
}

# resolve_installer_file: the --installer path: everything from the file itself.
resolve_installer_file() {
  local media_channel="" media_arch=""
  [ -r "${installer}" ] || die 2 "cannot read the installer ${installer}"
  read_installer_stamp "${installer}" \
    || die 1 "cannot read a build stamp from ${installer}: not an install4j IB Gateway installer, or a format this helper does not know"
  if [[ "${inst_media}" =~ ^ibgateway-(stable|latest)-standalone-linux-(x64|arm)$ ]]; then
    media_channel="${BASH_REMATCH[1]}"
    media_arch="${BASH_REMATCH[2]}"
  else
    say "the installer names no channel and architecture (mediaName '${inst_media}'); taking channel ${channel:-stable}"
  fi
  if [ -n "${media_arch}" ] && [ "${media_arch}" != "${arch}" ]; then
    die 1 "${installer} is IBKR's linux-${media_arch} installer; this build is for linux-${arch}"
  fi
  if [ -n "${media_channel}" ] && [ -n "${channel}" ] && [ "${media_channel}" != "${channel}" ]; then
    die 1 "${installer} is from IBKR's ${media_channel} channel; --channel asks for ${channel}"
  fi
  channel="${channel:-${media_channel:-stable}}"
  read_pins
  version="${inst_version}"
  build_stamp="${inst_stamp}"
  installer_sha="$(sha256_of "${installer}")"
  installer_file="${installer}"
  source=installer
  cache_hit=no
  ibkr_reachable=not-asked
}

# read_pins: pinned version, build stamp and SHA-256 of this channel and architecture, and the
# other Dockerfile inputs, from versions.json.
read_pins() {
  local q=".channels[\"${channel}\"]"
  pin_version="$(jq -er "${q}.version" "${versions}")" || die 1 "${versions} has no ${channel} version"
  pin_datetime="$(jq -er "${q}.build_datetime" "${versions}")" || die 1 "${versions} has no ${channel} build_datetime"
  pin_sha="$(jq -er "${q}.sha256.${arch}" "${versions}")" || die 1 "${versions} has no ${channel} ${arch} sha256"
  pin_stamp="$(stamp_of "${pin_version}" "${pin_datetime}")"
  ubuntu_digest="$(jq -er '.base.digest' "${versions}")"
  ibc_version="$(jq -er '.ibc.version' "${versions}")"
  ibc_release_tag="$(jq -er '.ibc.release_tag' "${versions}")"
  ibc_sha="$(jq -er '.ibc.sha256' "${versions}")"
}

# resolve_offline REASON EXIT: IBKR could not be used; take the cached pin, else (without
# --strict) the newest cached version of the channel, else exit EXIT.
resolve_offline() {
  local reason="$1" code="$2" dir
  ibkr_reachable=no
  dir="$(cache_entry "${pin_version}")"
  if cache_usable "${dir}" "${pin_sha}"; then
    say "${reason}; building the cached pinned ${pin_version}"
    use_cached "${dir}"
    return
  fi
  if [ "${strict}" = yes ]; then
    die "${code}" "${reason}, and the pinned ${pin_version} (${arch}) is not in the cache ${cache}"
  fi
  dir="$(cache_newest_of_channel)"
  if [ -n "${dir}" ] && cache_usable "${dir}"; then
    say "${reason}; building the cached $(meta_get "${dir}/meta" version), accepted $(meta_get "${dir}/meta" accepted_at)"
    use_cached "${dir}"
    return
  fi
  die "${code}" "${reason}, and no installer of the ${channel} channel (${arch}) is in the cache ${cache}"
}

# resolve_from_ibkr ATTEMPT: one attempt to resolve from IBKR. Sets changed_during_download=yes
# when IBKR's version.json changed during the download (the caller retries once); a flag, not
# a status, so the caller does not run it under `||`, which would switch errexit off inside.
resolve_from_ibkr() {
  local attempt="$1" body after_version after_datetime cached
  if ! body="$(fetch_version_json)"; then
    [ "${attempt}" -eq 1 ] || die 1 "IBKR became unreachable during the retry"
    resolve_offline "IBKR is unreachable (${base_url}/${channel}-standalone/version.json)" 3
    return 0
  fi
  if ! parse_version_json "${body}"; then
    resolve_offline "IBKR's version.json was not understood: '$(printf '%s' "${body}" | head -c 200)'" 1
    return 0
  fi
  ibkr_reachable=yes
  if [ "${served_version}" = "${pin_version}" ]; then
    version="${pin_version}"
    build_stamp="${pin_stamp}"
    cached="$(cache_entry "${pin_version}")"
    if cache_usable "${cached}" "${pin_sha}"; then
      say "IBKR serves the pinned ${pin_version}; using the cached copy"
      use_cached "${cached}"
      return 0
    fi
    installer_sha="unknown"
    source=ibkr
    cache_hit=no
    [ "${print_plan}" = no ] || return 0
    download_installer
    if [ "${installer_sha}" != "${pin_sha}" ]; then
      die 1 "SHA-256 MISMATCH: IBKR's ${channel} channel says ${pin_version}, the pinned version, but the installer differs
  expected ${pin_sha}
  actual   ${installer_sha}
IBKR replaced the installer without a new version label; nothing was built. Report it, or pin
the new bytes in versions.json after checking them."
    fi
    return 0
  fi
  version="${served_version}"
  build_stamp="$(stamp_of "${served_version}" "${served_datetime}")"
  if [ "${strict}" = yes ]; then
    die 4 "--strict: IBKR's ${channel} channel serves ${served_version}; versions.json pins ${pin_version}"
  fi
  cached="$(cache_entry "${served_version}")"
  if cache_usable "${cached}" "" "${build_stamp}"; then
    say "IBKR serves ${served_version} ${served_datetime}; using the cached copy"
    use_cached "${cached}"
    return 0
  fi
  installer_sha="unknown"
  source=ibkr
  cache_hit=no
  [ "${print_plan}" = no ] || return 0
  download_installer
  body="$(fetch_version_json)" || die 1 "IBKR became unreachable right after the download"
  parse_version_json "${body}" || die 1 "IBKR's version.json was not understood after the download"
  after_version="${served_version}"
  after_datetime="${served_datetime}"
  if [ "${after_version}" != "${version}" ] || [ "$(stamp_of "${after_version}" "${after_datetime}")" != "${build_stamp}" ]; then
    say "IBKR's ${channel} channel changed during the download: ${version} ${build_stamp} -> ${after_version} $(stamp_of "${after_version}" "${after_datetime}")"
    rm -f "${installer_file}"
    changed_during_download=yes
    return 0
  fi
  if read_installer_stamp "${installer_file}"; then
    if [ "${inst_stamp}" != "${build_stamp}" ] || [ "${inst_version}" != "${version}" ]; then
      die 1 "the downloaded installer is not the build IBKR announced
  version.json  ${version} ${build_stamp}
  installer     ${inst_version} ${inst_stamp}
nothing was built."
    fi
  else
    say "could not read the build stamp inside the downloaded installer; the Dockerfile checks it after installation"
  fi
  return 0
}

# emit_plan: print the plan lines (and, for a build, the run, the context file and the
# Dockerfile build arguments), and save them in the run directory for `accept`.
emit_plan() {
  local pinned=no qualified=no sha_arg plan
  if [ "${version}" = "${pin_version}" ]; then pinned=yes; fi
  if [ "${pinned}" = yes ] && [ "${installer_sha}" = "${pin_sha}" ]; then qualified=yes; fi
  if [ "${print_plan}" = yes ] && [ "${pinned}" = yes ] && [ "${source}" = ibkr ]; then
    qualified=yes # a download of the pinned version is built only when its SHA-256 matches
  fi
  plan="$(
    printf 'version: %s\nchannel: %s\narch: %s\npinned_version: %s\npinned: %s\n' \
      "${version}" "${channel}" "${arch}" "${pin_version}" "${pinned}"
    printf 'qualified_by_project: %s\nibkr_build_stamp: %s\ninstaller_sha256: %s\n' \
      "${qualified}" "${build_stamp}" "${installer_sha}"
    printf 'source: %s\ncache_hit: %s\nibkr_reachable: %s\n' "${source}" "${cache_hit}" "${ibkr_reachable}"
    if [ "${print_plan}" = no ]; then
      sha_arg=IB_GATEWAY_SHA256_X64
      if [ "${arch}" = arm ]; then sha_arg=IB_GATEWAY_SHA256_ARM; fi
      printf 'run: %s\ncontext_file: downloads/%s\n' "${run_id}" "${context_name}"
      printf 'build_arg: %s=%s\n' \
        UBUNTU_DIGEST "${ubuntu_digest}" \
        IBC_VERSION "${ibc_version}" \
        IBC_RELEASE_TAG "${ibc_release_tag}" \
        IBC_SHA256 "${ibc_sha}" \
        IB_GATEWAY_CHANNEL "${channel}" \
        IB_GATEWAY_VERSION "${version}" \
        "${sha_arg}" "${installer_sha}" \
        IB_GATEWAY_BUILD_STAMP "${build_stamp}" \
        IB_GATEWAY_QUALIFIED "${qualified}"
    fi
  )"
  if [ -n "${run_dir}" ]; then printf '%s\n' "${plan}" >"${run_dir}/plan"; fi
  printf '%s\n' "${plan}"
}

# cmd_resolve ARGS...: the `resolve` subcommand (see the contract).
cmd_resolve() {
  channel="" arch="" versions="" cache="" downloads="" strict=no installer="" print_plan=no
  while [ $# -gt 0 ]; do
    case "$1" in
      --channel) channel="${2:?}" && shift 2 ;;
      --arch) arch="${2:?}" && shift 2 ;;
      --versions) versions="${2:?}" && shift 2 ;;
      --cache) cache="${2:?}" && shift 2 ;;
      --downloads) downloads="${2:?}" && shift 2 ;;
      --installer) installer="${2:?}" && shift 2 ;;
      --strict) strict=yes && shift ;;
      --print-plan) print_plan=yes && shift ;;
      *) usage ;;
    esac
  done
  case "${channel}" in "" | stable | latest) ;; *) usage ;; esac
  case "${arch}" in x64 | arm) ;; *) usage ;; esac
  [ -n "${versions}" ] && [ -n "${cache}" ] && [ -n "${downloads}" ] || usage
  [ -r "${versions}" ] || die 2 "cannot read ${versions}"
  base_url="${BROKERSRE_TEST_IBKR_BASE_URL:-${IBKR_BASE_URL}}"
  if [ -n "${BROKERSRE_TEST_IBKR_BASE_URL:-}" ]; then
    say "TEST OVERRIDE: BROKERSRE_TEST_IBKR_BASE_URL=${base_url} replaces IBKR's download server"
  fi
  run_dir=""
  run_id=""
  if [ "${print_plan}" = no ]; then new_run; fi

  if [ -n "${installer}" ]; then
    resolve_installer_file
    if [ "${strict}" = yes ] && { [ "${version}" != "${pin_version}" ] || [ "${installer_sha}" != "${pin_sha}" ]; }; then
      die 4 "--strict: ${installer} is ${version} (${installer_sha}); versions.json pins ${pin_version} (${pin_sha})"
    fi
    if [ "${print_plan}" = no ]; then
      cp "${installer}" "${run_dir}/download-${arch}.sh"
      installer_file="${run_dir}/download-${arch}.sh"
    fi
  else
    channel="${channel:-stable}"
    read_pins
    local attempt
    for attempt in 1 2; do
      changed_during_download=no
      resolve_from_ibkr "${attempt}"
      [ "${changed_during_download}" = yes ] || break
      [ "${attempt}" -eq 1 ] || die 1 "IBKR's ${channel} channel changed during the download again; nothing was built, try later"
      say "retrying once"
    done
  fi
  [[ "${version}" =~ ${VERSION_RE} ]] || die 1 "refusing the version '${version}' (expected digits.digits.suffix)"

  context_name="ibgateway-${version}-standalone-linux-${arch}.sh"
  if [ "${print_plan}" = no ]; then
    mkdir -p "${downloads}"
    cp "${installer_file}" "${downloads}/.${context_name}.part"
    mv -f "${downloads}/.${context_name}.part" "${downloads}/${context_name}"
    if [ "${source}" = cache ]; then
      : >"${run_dir}/from-cache"
    elif [ "${installer_file}" != "${run_dir}/download-${arch}.sh" ]; then
      mv -f "${installer_file}" "${run_dir}/download-${arch}.sh"
    fi
  fi
  emit_plan
}

# cmd_accept ARGS...: the `accept` subcommand (see the contract).
cmd_accept() {
  local cache="" run="" image="" run_dir plan version channel arch qualified sha stamp pinned_version dest
  while [ $# -gt 0 ]; do
    case "$1" in
      --cache) cache="${2:?}" && shift 2 ;;
      --run) run="${2:?}" && shift 2 ;;
      --image) image="${2:?}" && shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "${cache}" ] && [ -n "${image}" ] && [[ "${run}" =~ ^run-[A-Za-z0-9]+$ ]] || usage
  run_dir="${cache}/runs/${run}"
  plan="${run_dir}/plan"
  [ -f "${plan}" ] || die 1 "no plan for ${run} under ${cache}/runs"
  version="$(meta_get "${plan}" version)"
  channel="$(meta_get "${plan}" channel)"
  arch="$(meta_get "${plan}" arch)"
  qualified="$(meta_get "${plan}" qualified_by_project)"
  sha="$(meta_get "${plan}" installer_sha256)"
  stamp="$(meta_get "${plan}" ibkr_build_stamp)"
  pinned_version="$(meta_get "${plan}" pinned_version)"
  if [ ! -e "${run_dir}/from-cache" ] && [ -f "${run_dir}/download-${arch}.sh" ]; then
    dest="${cache}/installers/${version}/${arch}"
    rm -rf "${dest}"
    mkdir -p "${dest}"
    mv -f "${run_dir}/download-${arch}.sh" "${dest}/ibgateway-${version}-standalone-linux-${arch}.sh"
    printf 'version: %s\nchannel: %s\narch: %s\nsha256: %s\nibkr_build_stamp: %s\nsource: %s\naccepted_at: %s\n' \
      "${version}" "${channel}" "${arch}" "${sha}" "${stamp}" "$(meta_get "${plan}" source)" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${dest}/meta"
    say "cached ${version} (${arch}) in ${dest}"
  fi
  rm -rf "${run_dir}"
  if [ "${qualified}" != yes ]; then
    cat >&2 <<EOF

WARNING: IB Gateway ${version} (${channel}) is not qualified by this project.
  versions.json pins ${pinned_version}; this image holds ${version}, build stamp ${stamp}.
  The installer was checked against IBKR's own build stamp and the offline tests ran, but no
  login has been made with this Gateway build. To qualify it, make one login to a paper
  account of your own (README, "Qualifying an image with a real paper login"):
    scripts/qualify-paper.sh --image ${image} --secrets-dir <dir>

EOF
  fi
  printf 'version: %s\nchannel: %s\nqualified_by_project: %s\ninstaller_sha256: %s\nibkr_build_stamp: %s\n' \
    "${version}" "${channel}" "${qualified}" "${sha}" "${stamp}"
}

# cmd_discard ARGS...: the `discard` subcommand (see the contract).
cmd_discard() {
  local cache="" run=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --cache) cache="${2:?}" && shift 2 ;;
      --run) run="${2:?}" && shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "${cache}" ] && [[ "${run}" =~ ^run-[A-Za-z0-9]+$ ]] || usage
  rm -rf "${cache:?}/runs/${run}"
}

case "${1:-}" in
  resolve) shift && cmd_resolve "$@" ;;
  accept) shift && cmd_accept "$@" ;;
  discard) shift && cmd_discard "$@" ;;
  *) usage ;;
esac
