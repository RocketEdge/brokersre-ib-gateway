#!/usr/bin/env bats
# Unit tests for scripts/check-upgrade.sh: has the channel tag moved past the digest a gateway
# runs? The script only asks and reports; it never pulls, restarts or edits anything.
# `docker` is replaced by a stub on PATH that answers from fixture files and records every
# call; nothing reaches a registry or a Docker daemon.
#   tests/.bats-core/bin/bats tests/bats/ci   (needs jq)

bats_require_minimum_version 1.5.0 # `run --separate-stderr`

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/check-upgrade.sh"
  WORK="$(mktemp -d)"
  FIX="${WORK}/fixtures"
  CALLS="${WORK}/docker.calls"
  mkdir -p "${WORK}/bin" "${FIX}/containers" "${FIX}/images" "${FIX}/registry"
  export FIX CALLS
  REPO="ghcr.io/example/gateway"
  ARCH="sha256:$(printf 'c%.0s' {1..64})"
  ID="sha256:$(printf 'd%.0s' {1..64})"
  CONFIG="sha256:$(printf 'e%.0s' {1..64})"
  # What the registry serves: `stable` is a multi-arch index that lists the manifest ARCH,
  # `latest` a single-platform manifest. A tag's digest is the SHA-256 of exactly these bytes.
  STABLE_DOC='{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"'"${ARCH}"'","size":1022,"platform":{"architecture":"amd64","os":"linux"}}]}'
  LATEST_DOC='{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"'"${CONFIG}"'","size":7},"layers":[]}'
  NEW="sha256:$(printf '%s' "${STABLE_DOC}" | sha256sum | cut -d' ' -f1)"
  OLD="sha256:$(printf '%s' "${LATEST_DOC}" | sha256sum | cut -d' ' -f1)"
  # The stub. Fixture names are the container name, or the image reference with every
  # character outside [A-Za-z0-9.-] replaced by `_`.
  #   inspect --type container ... -- NAME        -> fixtures/containers/NAME (`ref|id|channel`)
  #   image inspect (RepoDigests) -- REF          -> fixtures/images/<key>.repodigests
  #   image inspect (channel label) -- REF        -> fixtures/images/<key>.channel
  #   buildx imagetools inspect --raw REF         -> fixtures/registry/<key> (the manifest's bytes)
  # A missing fixture is the error the real CLI gives; any other subcommand ends with 99.
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >>"${CALLS}"' \
    'key() { printf "%s" "${1//[^A-Za-z0-9.-]/_}"; }' \
    'last="${!#}"' \
    'case "$1 ${2:-} ${3:-}" in' \
    '  "inspect --type container")' \
    '    if [ -f "${FIX}/containers/${last}" ]; then cat "${FIX}/containers/${last}"; exit 0; fi' \
    '    echo "Error response from daemon: No such container: ${last}" >&2; exit 1 ;;' \
    '  "image inspect "*)' \
    '    suffix=channel; if [[ "$*" == *RepoDigests* ]]; then suffix=repodigests; fi' \
    '    if [ -f "${FIX}/images/$(key "${last}").${suffix}" ]; then cat "${FIX}/images/$(key "${last}").${suffix}"; exit 0; fi' \
    '    echo "Error response from daemon: No such image: ${last}" >&2; exit 1 ;;' \
    '  "buildx imagetools inspect")' \
    '    if [ -f "${FIX}/registry-down" ]; then echo "ERROR: failed to do request: dial tcp: lookup registry: no such host" >&2; exit 1; fi' \
    '    if [ -f "${FIX}/registry/$(key "${last}")" ]; then cat "${FIX}/registry/$(key "${last}")"; exit 0; fi' \
    '    echo "ERROR: ${last}: not found" >&2; exit 1 ;;' \
    'esac' \
    'echo "stub docker: unexpected call: $*" >&2' \
    'exit 99' >"${WORK}/bin/docker"
  chmod +x "${WORK}/bin/docker"
  export PATH="${WORK}/bin:${PATH}"
  registry "${REPO}:stable" "${STABLE_DOC}"
  registry "${REPO}:latest" "${LATEST_DOC}"
}

teardown() {
  rm -rf "${WORK}"
}

key() { printf '%s' "${1//[^A-Za-z0-9.-]/_}"; }
# registry REF BYTES: the manifest the registry serves for REF, byte for byte.
registry() { printf '%s' "$2" >"${FIX}/registry/$(key "$1")"; }
# container NAME REF [CHANNEL_LABEL]: a container created from REF, running the image ID.
container() { printf '%s|%s|%s\n' "$2" "${ID}" "${3-stable}" >"${FIX}/containers/$1"; }
# image_digests REF TEXT: the RepoDigests of a local image.
image_digests() { printf '%s\n' "$2" >"${FIX}/images/$(key "$1").repodigests"; }

# doc [JQ OPTIONS] FILTER: the last run printed exactly one line, one JSON document, for which
# FILTER is true.
doc() {
  [ "${#lines[@]}" -eq 1 ]
  [ "$(jq -s 'length' <<<"$output")" -eq 1 ]
  jq -e "$@" <<<"$output" >/dev/null
}

# only_asked: every recorded docker call is one of the three read-only questions.
only_asked() {
  [ -f "${CALLS}" ] || return 0
  ! grep -v -E '^(inspect --type container |image inspect |buildx imagetools inspect )' "${CALLS}"
}

@test "a container on the channel's current digest is up to date (exit 0)" {
  container gw "${REPO}@${NEW}"
  run --separate-stderr "$SCRIPT" --container gw
  [ "$status" -eq 0 ]
  doc '.schema == "brokersre.upgrade-check.v1" and .up_to_date == true and .result == "up-to-date"'
  doc --arg r "${REPO}" --arg d "${NEW}" '.repository == $r and .channel == "stable" and .channel_source == "label" and .running_digest == $d and .registry_digest == $d'
  doc '.checked_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")'
  only_asked
}

@test "a container on an older digest: a newer image is available (exit 10)" {
  container gw "${REPO}@${OLD}"
  run --separate-stderr "$SCRIPT" --container gw
  [ "$status" -eq 10 ]
  doc --arg o "${OLD}" --arg n "${NEW}" '.up_to_date == false and .result == "upgrade-available" and .running_digest == $o and .registry_digest == $n'
  only_asked
}

@test "a container created from a tag is judged by the digest of the image it runs, not by the tag" {
  container gw "${REPO}:stable"
  image_digests "${ID}" "${REPO}@${OLD} "
  run --separate-stderr "$SCRIPT" --container gw
  [ "$status" -eq 10 ]
  doc --arg o "${OLD}" '.up_to_date == false and .running_digest == $o'
  image_digests "${ID}" "other.example/mirror@${OLD} ${REPO}@${NEW} "
  run --separate-stderr "$SCRIPT" --container gw
  [ "$status" -eq 0 ]
  doc --arg n "${NEW}" '.up_to_date == true and .running_digest == $n'
  only_asked
}

@test "a container whose image has no registry digest (built or loaded locally) cannot be judged (exit 2)" {
  container gw "${REPO}:stable"
  image_digests "${ID}" ""
  run --separate-stderr "$SCRIPT" --container gw
  [ "$status" -eq 2 ]
  doc '.up_to_date == null and .result == "undetermined" and (.error | test("no registry digest"))'
  container local "gateway:dev"
  image_digests "${ID}" "gateway@${OLD} "
  run --separate-stderr "$SCRIPT" --container local
  [ "$status" -eq 2 ]
  doc '.up_to_date == null and .result == "undetermined"'
}

@test "a digest of one platform of the current multi-arch image is up to date" {
  container gw "${REPO}@${ARCH}"
  run --separate-stderr "$SCRIPT" --container gw
  [ "$status" -eq 0 ]
  doc --arg a "${ARCH}" --arg n "${NEW}" '.up_to_date == true and .running_digest == $a and .registry_digest == $n'
}

@test "a digest that a single-platform manifest merely mentions (config, layer) is not that image" {
  run --separate-stderr "$SCRIPT" --image "${REPO}@${CONFIG}" --channel latest
  [ "$status" -eq 10 ]
  doc --arg o "${OLD}" '.up_to_date == false and .registry_digest == $o'
}

@test "the registry is asked once, for the tag's manifest in raw form, and nothing is pulled" {
  container gw "${REPO}@${NEW}"
  run --separate-stderr "$SCRIPT" --container gw
  [ "$status" -eq 0 ]
  [ "$(grep -c '^buildx imagetools inspect ' "${CALLS}")" -eq 1 ]
  grep -q -x "buildx imagetools inspect --raw ${REPO}:stable" "${CALLS}"
}

@test "an image reference with a digest is compared with the channel given" {
  run --separate-stderr "$SCRIPT" --image "${REPO}@${NEW}" --channel stable
  [ "$status" -eq 0 ]
  doc '.up_to_date == true and .channel == "stable" and .channel_source == "argument"'
  run --separate-stderr "$SCRIPT" --image "${REPO}@${OLD}" --channel stable
  [ "$status" -eq 10 ]
  doc '.up_to_date == false'
  run --separate-stderr "$SCRIPT" --image "${REPO}:10.50@${OLD}" --channel latest
  [ "$status" -eq 0 ]
  doc --arg r "${REPO}" '.up_to_date == true and .repository == $r and .channel == "latest"'
  only_asked
}

@test "a reference without a digest is refused: a tag proves nothing" {
  for ref in "${REPO}:stable" "${REPO}" "${REPO}@sha256:abc" "${REPO}@md5:$(printf 'a%.0s' {1..32})"; do
    rm -f "${CALLS}"
    run --separate-stderr "$SCRIPT" --image "${ref}" --channel stable
    [ "$status" -eq 2 ]
    doc '.up_to_date == null and .result == "undetermined" and (.error | test("digest"))'
    [ ! -e "${CALLS}" ]
  done
}

@test "the channel of an image reference comes from the local image's label when not given" {
  printf 'latest\n' >"${FIX}/images/$(key "${REPO}@${OLD}").channel"
  run --separate-stderr "$SCRIPT" --image "${REPO}@${OLD}"
  [ "$status" -eq 0 ]
  doc '.up_to_date == true and .channel == "latest" and .channel_source == "label"'
  run --separate-stderr "$SCRIPT" --image "${REPO}@${NEW}"
  [ "$status" -eq 2 ]
  doc '.up_to_date == null and (.error | test("--channel"))'
}

@test "--channel overrides the label, and a label that is no channel is not trusted" {
  container gw "${REPO}@${OLD}"
  run --separate-stderr "$SCRIPT" --container gw --channel latest
  [ "$status" -eq 0 ]
  doc '.channel == "latest" and .channel_source == "argument" and .up_to_date == true'
  container nolabel "${REPO}@${OLD}" ""
  run --separate-stderr "$SCRIPT" --container nolabel
  [ "$status" -eq 2 ]
  doc '.up_to_date == null and (.error | test("--channel"))'
  container oddlabel "${REPO}@${OLD}" 'stable; reboot'
  run --separate-stderr "$SCRIPT" --container oddlabel
  [ "$status" -eq 2 ]
  doc '.up_to_date == null'
  ! grep -q reboot <<<"$output"
}

@test "--repository asks another repository's tag and still compares the digest the container runs" {
  container gw "mirror.example/gateway@${NEW}"
  run --separate-stderr "$SCRIPT" --container gw --repository "${REPO}"
  [ "$status" -eq 0 ]
  doc --arg r "${REPO}" '.repository == $r and .up_to_date == true'
  grep -q -F "${REPO}:stable" "${CALLS}"
  ! grep -q -F "mirror.example/gateway:stable" "${CALLS}"
}

@test "a registry that cannot be reached is 'could not be determined', never 'up to date' (exit 2)" {
  container gw "${REPO}@${NEW}"
  touch "${FIX}/registry-down"
  run --separate-stderr "$SCRIPT" --container gw
  [ "$status" -eq 2 ]
  doc --arg d "${NEW}" '.up_to_date == null and .result == "undetermined" and .registry_digest == null and .running_digest == $d and (.error | test("registry"))'
  [[ "$stderr" == *"check-upgrade:"* ]]
}

@test "a tag the registry does not have, or an answer that is no manifest, is 'could not be determined'" {
  container gw "${REPO}@${NEW}"
  rm "${FIX}/registry/$(key "${REPO}:stable")"
  run --separate-stderr "$SCRIPT" --container gw
  [ "$status" -eq 2 ]
  doc '.up_to_date == null and .registry_digest == null'
  for answer in '' "${NEW}" '<html>proxy login</html>' '{"errors":[{"code":"DENIED"}]}'; do
    registry "${REPO}:stable" "${answer}"
    run --separate-stderr "$SCRIPT" --container gw
    [ "$status" -eq 2 ]
    doc '.up_to_date == null and .registry_digest == null'
    ! grep -q -F 'proxy login' <<<"$output"
  done
}

@test "a container that does not exist is 'could not be determined' (exit 2)" {
  run --separate-stderr "$SCRIPT" --container missing
  [ "$status" -eq 2 ]
  doc '.up_to_date == null and .result == "undetermined" and (.error | test("missing"))'
  ! grep -q 'buildx' "${CALLS}"
}

@test "hostile names and references are refused before docker is called" {
  for name in '; rm -rf /' '$(reboot)' '-v' '--help' 'a b' 'gw`id`' "$(printf 'gw\nx')" '' '../x'; do
    rm -f "${CALLS}"
    run --separate-stderr "$SCRIPT" --container "${name}"
    [ "$status" -eq 2 ]
    doc '.up_to_date == null and .result == "undetermined"'
    [ ! -e "${CALLS}" ]
  done
  for ref in "--help@${NEW}" "${REPO} x@${NEW}" "\$(id)@${NEW}" "${REPO}@${NEW}; id" "-o@${NEW}"; do
    rm -f "${CALLS}"
    run --separate-stderr "$SCRIPT" --image "${ref}" --channel stable
    [ "$status" -eq 2 ]
    doc '.up_to_date == null'
    [ ! -e "${CALLS}" ]
  done
  for channel in 'stable;id' 'beta' '' 'STABLE' '--help'; do
    rm -f "${CALLS}"
    run --separate-stderr "$SCRIPT" --image "${REPO}@${NEW}" --channel "${channel}"
    [ "$status" -eq 2 ]
    [ ! -e "${CALLS}" ]
  done
  for repository in '--help' 'a b' "\$(id)" 'UPPER/case'; do
    rm -f "${CALLS}"
    container gw "${REPO}@${NEW}"
    run --separate-stderr "$SCRIPT" --container gw --repository "${repository}"
    [ "$status" -eq 2 ]
    [ ! -e "${CALLS}" ]
  done
}

@test "a call without a subject, with both, or with an unknown option is a usage error (exit 2)" {
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 2 ]
  doc '.up_to_date == null and .result == "undetermined"'
  [[ "$stderr" == *"usage:"* ]]
  run --separate-stderr "$SCRIPT" --container gw --image "${REPO}@${NEW}"
  [ "$status" -eq 2 ]
  run --separate-stderr "$SCRIPT" --container gw --pull
  [ "$status" -eq 2 ]
  run --separate-stderr "$SCRIPT" --container
  [ "$status" -eq 2 ]
  [ ! -e "${CALLS}" ]
}

@test "the check changes nothing: it only asks docker three read-only questions" {
  container gw "${REPO}:stable"
  image_digests "${ID}" "${REPO}@${OLD} "
  "$SCRIPT" --container gw >/dev/null 2>&1 || true
  "$SCRIPT" --image "${REPO}@${OLD}" --channel stable >/dev/null 2>&1 || true
  "$SCRIPT" --image "${REPO}@${OLD}" >/dev/null 2>&1 || true
  [ "$(wc -l <"${CALLS}")" -ge 5 ]
  only_asked
  ! grep -q -E '(^| )(pull|run|start|stop|restart|rm|kill|exec|compose|tag|push|update|create)( |$)' "${CALLS}"
}

@test "text from docker or the registry never reaches the document unescaped" {
  container gw "${REPO}@${NEW}"
  registry "${REPO}:stable" '"}{"up_to_date":true'
  run --separate-stderr "$SCRIPT" --container gw
  [ "$status" -eq 2 ]
  doc '.up_to_date == null and (keys | index("up_to_date") != null)'
}
