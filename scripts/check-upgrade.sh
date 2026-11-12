#!/usr/bin/env bash
# Has the channel tag moved past the image a gateway runs? Asks, reports, changes nothing.
#
# Purpose: consumers pin the image by digest, so a new build never reaches them by itself.
# This script is the question "is there a newer one?" as a command an operator, cron or the
# Task Scheduler can run: it compares the digest a gateway runs with the digest the channel tag
# (`stable` or `latest`, IBKR's channel names) points at in the registry right now.
#
# Usage:
#   check-upgrade.sh --container NAME [--channel stable|latest] [--repository REPO]
#   check-upgrade.sh --image REPO@sha256:<64 hex> [--channel stable|latest] [--repository REPO]
#
#   --container   a container on this Docker host. The digest is the one in the reference it
#                 was created from (`repo@sha256:...`); for a container created from a tag it
#                 is the registry digest Docker recorded for the image the container really
#                 runs, never the tag.
#   --image       an image reference WITH a digest. A reference with only a tag is refused: a
#                 tag says what the registry serves now, not what you run.
#   --channel     the channel tag to compare with. Default: the image's label
#                 com.rocketedge.brokersre.ibkr.channel (for --image this needs the image to be
#                 present on this host).
#   --repository  the repository whose channel tag is asked, when the gateway runs from a
#                 mirror. Default: the repository of the image the gateway runs.
#
# Output: exactly one JSON document on one line on stdout, in every case:
#   {"schema":"brokersre.upgrade-check.v1","checked_at":"<UTC, ISO-8601>",
#    "result":"up-to-date|upgrade-available|undetermined","up_to_date":true|false|null,
#    "repository":"...","channel":"stable|latest","channel_source":"label|argument",
#    "running_digest":"sha256:...","registry_digest":"sha256:...","error":"<only when undetermined>"}
#   A value that is not known is null. Diagnostics go to stderr.
# Exit status:
#   0   up to date: the gateway runs what the channel tag points at
#   10  a different (newer) image is on the channel tag
#   2   could not be determined (bad arguments, no such container, no registry digest for the
#       running image, registry unreachable, an answer that is not a manifest). Never 0: a
#       check that failed must not look like "nothing to do".
#
# What it runs, and nothing else (tests/bats/ci/check-upgrade.bats records every call):
#   docker inspect --type container ...           the container's image reference, id and label
#   docker image inspect ...                      the local image's registry digests or label
#   docker buildx imagetools inspect --raw <repo>:<channel>   the tag's manifest, byte for
#       byte, read from the registry without pulling. The tag's digest is the SHA-256 of those
#       bytes; for a multi-arch image that is the digest of the index, the one a pin by digest
#       uses. Measured with buildx 0.38.1 on 2026-11-12 against three registries: the hash
#       equals the digest buildx prints. The raw form is one registry request; the formatted
#       form (`--format '{{.Manifest.Digest}}'`) also fetches every platform's manifest, which
#       two public registries answered with "429 Too Many Requests" during that measurement.
#       `docker manifest inspect` does not show the digest of an index at all. The registry
#       must be readable with the credentials `docker` already has; the script handles none.
# It never pulls, starts, stops, restarts or edits anything. The one file it writes is a
# temporary copy of that manifest, removed when it ends.
#
# Rules:
#   - "Different" is reported as "upgrade available": channel tags move only forward, through
#     the publish workflow. The script does not judge which of two digests is newer.
#   - A digest that is one platform's manifest of the tag's multi-arch index is up to date. A
#     digest that a single-platform manifest merely mentions (its config, a layer) is not.
#   - Every value that reaches a command line or the document has matched a strict pattern
#     first (container name, repository, digest, channel), so nothing from the arguments, from
#     Docker or from the registry is echoed or executed as it came.
# Needs bash 4+, docker with the buildx plugin, sha256sum (or shasum), grep, mktemp and date;
# no jq.
set -u

program="check-upgrade"
channel_label="com.rocketedge.brokersre.ibkr.channel"

# The patterns everything is checked against before use.
name_pattern='^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$'
repository_pattern='^[a-z0-9]([a-z0-9._-]*[a-z0-9])?(:[0-9]{1,5})?(/[a-z0-9]([a-z0-9._-]*[a-z0-9])?)*$'
digest_pattern='^sha256:[0-9a-f]{64}$'

# The facts of this run; `null` in the document while empty.
repository=""
channel=""
channel_source=""
running_digest=""
registry_digest=""

# json_string VALUE: print VALUE as a JSON string, or `null` when it is empty. Values are
# validated before they get here; the escaping is for the error text.
json_string() {
  local value="$1"
  if [ -z "${value}" ]; then
    printf 'null'
    return 0
  fi
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//[[:cntrl:]]/ }"
  printf '"%s"' "${value}"
}

# emit RESULT UP_TO_DATE [ERROR]: print the one document. UP_TO_DATE is true, false or null.
emit() {
  local result="$1" up_to_date="$2" error="${3:-}" checked_at
  checked_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '{"schema":"brokersre.upgrade-check.v1","checked_at":"%s","result":"%s","up_to_date":%s' "${checked_at}" "${result}" "${up_to_date}"
  printf ',"repository":%s,"channel":%s,"channel_source":%s' "$(json_string "${repository}")" "$(json_string "${channel}")" "$(json_string "${channel_source}")"
  printf ',"running_digest":%s,"registry_digest":%s' "$(json_string "${running_digest}")" "$(json_string "${registry_digest}")"
  if [ -n "${error}" ]; then printf ',"error":%s' "$(json_string "${error}")"; fi
  printf '}\n'
}

# undetermined MESSAGE: the answer is not known. Prints the document with the reason, the
# reason on stderr, and ends with 2.
undetermined() {
  echo "${program}: $1" >&2
  emit undetermined null "$1"
  exit 2
}

usage_error() {
  echo "usage: check-upgrade.sh --container NAME | --image REPO@sha256:DIGEST [--channel stable|latest] [--repository REPO]" >&2
  undetermined "$1"
}

# repository_of REFERENCE: print the repository of an image reference: without the digest and
# without the tag (a colon after the last slash starts a tag; one before it is a port).
repository_of() {
  local reference="${1%%@*}" last
  last="${reference##*/}"
  if [[ "${last}" == *:* ]]; then reference="${reference%:*}"; fi
  printf '%s' "${reference}"
}

# digest_of REFERENCE: print the digest of a reference `...@sha256:<64 hex>`, or nothing.
digest_of() {
  local digest=""
  if [[ "$1" == *@* ]]; then digest="${1##*@}"; fi
  if [[ "${digest}" =~ ${digest_pattern} ]]; then printf '%s' "${digest}"; fi
}

# is_channel VALUE: true for the two channel names.
is_channel() {
  [ "$1" = "stable" ] || [ "$1" = "latest" ]
}

container="" image="" channel_argument="" repository_argument=""
have_channel="no" have_repository="no"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --container)
      if [ "$#" -lt 2 ]; then usage_error "--container needs a name"; fi
      container="$2"
      shift 2
      ;;
    --image)
      if [ "$#" -lt 2 ]; then usage_error "--image needs a reference with a digest"; fi
      image="$2"
      shift 2
      ;;
    --channel)
      if [ "$#" -lt 2 ]; then usage_error "--channel needs stable or latest"; fi
      channel_argument="$2"
      have_channel="yes"
      shift 2
      ;;
    --repository)
      if [ "$#" -lt 2 ]; then usage_error "--repository needs a repository"; fi
      repository_argument="$2"
      have_repository="yes"
      shift 2
      ;;
    *)
      usage_error "unknown argument"
      ;;
  esac
done

if [ -n "${container}" ] && [ -n "${image}" ]; then usage_error "give --container or --image, not both"; fi
if [ -z "${container}" ] && [ -z "${image}" ]; then usage_error "give --container NAME or --image REPO@sha256:DIGEST"; fi
if [ "${have_channel}" = "yes" ] && ! is_channel "${channel_argument}"; then usage_error "--channel must be stable or latest"; fi
if [ "${have_repository}" = "yes" ] && ! [[ "${repository_argument}" =~ ${repository_pattern} ]]; then
  usage_error "--repository is not a repository name"
fi

label=""
if [ -n "${container}" ]; then
  if ! [[ "${container}" =~ ${name_pattern} ]]; then usage_error "--container is not a container name"; fi
  if ! facts="$(docker inspect --type container --format "{{.Config.Image}}|{{.Image}}|{{index .Config.Labels \"${channel_label}\"}}" -- "${container}" 2>/dev/null)"; then
    undetermined "no container named ${container} on this Docker host (or docker cannot be reached)"
  fi
  IFS='|' read -r reference image_id label <<<"${facts}"
  local_repository="$(repository_of "${reference}")"
  if ! [[ "${local_repository}" =~ ${repository_pattern} ]]; then
    undetermined "the container's image reference is not one this script understands"
  fi
  repository="${local_repository}"
  running_digest="$(digest_of "${reference}")"
  if [ -z "${running_digest}" ]; then
    # Created from a tag: the tag proves nothing, the image it runs does. Docker records the
    # registry digests of that image; the one for the same repository is the running digest.
    if ! [[ "${image_id}" =~ ${digest_pattern} ]]; then undetermined "docker did not name the image the container runs"; fi
    recorded="$(docker image inspect --format '{{range .RepoDigests}}{{.}} {{end}}' -- "${image_id}" 2>/dev/null)" || recorded=""
    for entry in ${recorded}; do
      if [ "$(repository_of "${entry}")" = "${local_repository}" ] && [ -n "$(digest_of "${entry}")" ]; then
        running_digest="$(digest_of "${entry}")"
        break
      fi
    done
    if [ -z "${running_digest}" ]; then
      undetermined "the image this container runs has no registry digest for ${local_repository} (built or loaded locally?), so it cannot be compared"
    fi
  fi
else
  local_repository="$(repository_of "${image}")"
  running_digest="$(digest_of "${image}")"
  if [ -z "${running_digest}" ] || ! [[ "${local_repository}" =~ ${repository_pattern} ]]; then
    running_digest=""
    usage_error "--image must be REPO@sha256:<64 hex digits>: a reference without a digest proves nothing about what runs"
  fi
  repository="${local_repository}"
  if [ "${have_channel}" != "yes" ]; then
    label="$(docker image inspect --format "{{index .Config.Labels \"${channel_label}\"}}" -- "${local_repository}@${running_digest}" 2>/dev/null)" || label=""
  fi
fi

if [ "${have_repository}" = "yes" ]; then repository="${repository_argument}"; fi
if [ "${have_channel}" = "yes" ]; then
  channel="${channel_argument}"
  channel_source="argument"
elif is_channel "${label}"; then
  channel="${label}"
  channel_source="label"
else
  undetermined "the image carries no usable channel label (${channel_label}) on this host; give --channel stable or --channel latest"
fi

# The tag's manifest, byte for byte, into a temporary file: its SHA-256 is the tag's digest.
# Nothing is pulled.
manifest="$(mktemp 2>/dev/null)" || undetermined "cannot create a temporary file for the registry answer"
trap 'rm -f "${manifest}"' EXIT
if ! docker buildx imagetools inspect --raw "${repository}:${channel}" >"${manifest}" 2>/dev/null; then
  undetermined "the registry did not answer for ${repository}:${channel} (unreachable, not found, or not readable with docker's credentials)"
fi
# An image manifest or index is a JSON object with a schemaVersion; an error page or an error
# document is not, and its hash would be a digest of nothing.
if ! grep -q '^[[:space:]]*{' "${manifest}" || ! grep -q '"schemaVersion"' "${manifest}"; then
  undetermined "the registry answer for ${repository}:${channel} is not an image manifest"
fi
if command -v sha256sum >/dev/null 2>&1; then
  hash="$(sha256sum <"${manifest}")"
elif command -v shasum >/dev/null 2>&1; then
  hash="$(shasum -a 256 <"${manifest}")"
else
  undetermined "neither sha256sum nor shasum is installed, so the registry answer cannot be hashed"
fi
if ! [[ "sha256:${hash%% *}" =~ ${digest_pattern} ]]; then
  undetermined "the registry answer for ${repository}:${channel} could not be hashed"
fi
registry_digest="sha256:${hash%% *}"

# What counts as "this image": the tag's own digest and, when the tag is a multi-arch index
# (it has a `manifests` list), the digests that list names.
listed=("${registry_digest}")
if grep -q '"manifests"' "${manifest}"; then
  while IFS= read -r entry; do
    listed+=("${entry}")
  done < <(grep -o -E '"digest"[[:space:]]*:[[:space:]]*"sha256:[0-9a-f]{64}"' "${manifest}" | grep -o -E 'sha256:[0-9a-f]{64}')
fi

for candidate in "${listed[@]}"; do
  if [ "${candidate}" = "${running_digest}" ]; then
    emit up-to-date true
    exit 0
  fi
done
emit upgrade-available false
exit 10
