#!/usr/bin/env bash
# Move a channel's tags to the image index that was scanned, then prove every tag resolves to it.
#
# Purpose: publish.yml pushes both platforms of a build by digest only (no tag), scans exactly
# those bytes, signs and attests them, and only then lets tags point at them. This script is
# that last step. Creating a tag from an existing digest copies no layer and builds nothing, so
# what a tag serves afterwards is byte for byte what the scan saw.
#
# Contract:
#   promote-tags.sh <image> <digest> <tag-ref> [<tag-ref> ...]
#   image      registry/repository without a tag, e.g. ghcr.io/rocketedge/brokersre-ib-gateway
#   digest     sha256:<64 hex> of the image index pushed by digest
#   tag-ref    <image>:<tag>, as listed by `docker buildx bake --print <channel>`; a tag given
#              twice is used once (without a rebuild suffix the version tag appears twice)
#   stdout     `promoted <tag-ref> -> <digest>` per tag
#   exit       0  every tag now resolves to <digest>
#              1  the registry refused, or a tag resolves to something else afterwards
#              2  bad arguments (nothing was changed)
#
# Why the check after the create: `imagetools create` with one source keeps the source's
# digest (seen with buildx 0.38.1 against a local registry). If a later buildx re-wrote the
# index, the tag would serve a digest that was never scanned or signed; the publish must stop
# there instead of releasing it.
# Side effects: tags in the registry, through `docker buildx imagetools`. Needs docker and jq.
set -euo pipefail

usage() {
  echo "usage: promote-tags.sh <image> <sha256:digest> <image:tag> [<image:tag> ...]" >&2
  exit 2
}

refuse() {
  echo "promote-tags: $1" >&2
  exit 2
}

[ $# -ge 3 ] || usage
image="$1"
digest="$2"
shift 2

[[ "${image}" =~ ^[a-z0-9][a-z0-9.-]*(:[0-9]+)?(/[a-z0-9][a-z0-9._-]*)+$ ]] || refuse "'${image}' is not a registry/repository name without a tag"
[[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || refuse "'${digest}' is not sha256:<64 hex digits>"

tags=()
declare -A seen=()
for ref in "$@"; do
  # Only this repository: a tag list that names another one is a mistake, never a wish.
  [ "${ref%:*}" = "${image}" ] || refuse "'${ref}' is not a tag of ${image}"
  [[ "${ref##*:}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || refuse "'${ref}' does not end in a valid tag"
  if [ -z "${seen["${ref}"]:-}" ]; then
    seen["${ref}"]=1
    tags+=("${ref}")
  fi
done

create_args=()
for ref in "${tags[@]}"; do create_args+=(-t "${ref}"); done
if ! docker buildx imagetools create "${create_args[@]}" "${image}@${digest}"; then
  echo "promote-tags: the registry refused the tags of ${image}@${digest}; no tag is reported as moved" >&2
  exit 1
fi

failed=0
for ref in "${tags[@]}"; do
  got="$(docker buildx imagetools inspect "${ref}" --format '{{json .Manifest}}' | jq -r '.digest // empty' 2>/dev/null || true)"
  if [ "${got}" = "${digest}" ]; then
    echo "promoted ${ref} -> ${digest}"
  else
    echo "promote-tags: ${ref} resolves to ${got:-nothing readable}, not to the scanned ${digest}" >&2
    failed=1
  fi
done
exit "${failed}"
