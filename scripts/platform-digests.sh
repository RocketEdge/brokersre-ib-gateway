#!/usr/bin/env bash
# Name the linux/amd64 and linux/arm64 manifests inside an image index.
#
# Purpose: publish.yml pushes one image index (both platforms) by digest. The two platforms
# hold different software (arm64 runs Ubuntu's OpenJDK where amd64 runs the JRE IBKR bundles),
# so one SBOM cannot describe both: an SBOM is made for each platform and attested to that
# platform's own manifest digest. This script finds the two digests in the index that was
# pushed, and at the same time proves that the index really holds both platforms before it is
# signed and tagged.
#
# Contract:
#   platform-digests.sh <image> <index-digest>
#   image          registry/repository without a tag
#   index-digest   sha256:<64 hex> of the image index
#   stdout         two lines, GITHUB_OUTPUT-ready:
#                    amd64=sha256:<64 hex>
#                    arm64=sha256:<64 hex>
#   exit           0  both digests printed
#                  1  the registry did not answer with that index, or the index does not hold
#                     exactly one linux/amd64 and exactly one linux/arm64 image (nothing is
#                     printed: a publish must stop here, not continue with one platform)
#                  2  bad arguments (the registry was not asked)
#
# Manifests whose platform is unknown/unknown are the build's own attestation manifests
# (BuildKit provenance); they are not images and are ignored.
# Side effects: one read of the registry through `docker buildx imagetools inspect`. Needs
# docker and jq.
set -euo pipefail

usage() {
  echo "usage: platform-digests.sh <image> <sha256:index-digest>" >&2
  exit 2
}

refuse() {
  echo "platform-digests: $1" >&2
  exit 2
}

fail() {
  echo "platform-digests: $1" >&2
  exit 1
}

[ $# -eq 2 ] || usage
image="$1"
index="$2"
[[ "${image}" =~ ^[a-z0-9][a-z0-9.-]*(:[0-9]+)?(/[a-z0-9][a-z0-9._-]*)+$ ]] || refuse "'${image}' is not a registry/repository name without a tag"
[[ "${index}" =~ ^sha256:[0-9a-f]{64}$ ]] || refuse "'${index}' is not sha256:<64 hex digits>"

if ! manifest="$(docker buildx imagetools inspect "${image}@${index}" --format '{{json .Manifest}}')"; then
  fail "the registry did not return ${image}@${index}"
fi

# jq program: prints "amd64=<digest>" and "arm64=<digest>", or fails with the reason. The
# digest check has no anchors on purpose: a negated class also catches a line break.
# shellcheck disable=SC2016  # $index and $arch are jq variables, not shell ones
platform_digests='
  def image($arch):
    [.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest] as $found
    | if ($found | length) != 1
        then error("the index holds " + ($found | length | tostring) + " linux/" + $arch + " images, expected exactly one")
      elif ($found[0] | type) != "string" or ($found[0] | length) != 71 or ($found[0] | startswith("sha256:") | not) or ($found[0][7:] | test("[^0-9a-f]"))
        then error("the linux/" + $arch + " digest is not sha256:<64 hex digits>")
      else $found[0] end;
  if type != "object" then error("not a manifest description")
  elif .digest != $index then error("the answer describes another digest")
  elif (.manifests | type) != "array" then error("not an image index (a single-platform manifest has no list of images)")
  else (image("amd64")) as $amd64 | (image("arm64")) as $arm64 | "amd64=\($amd64)", "arm64=\($arm64)"
  end'

if ! digests="$(jq -r --arg index "${index}" "${platform_digests}" <<<"${manifest}" 2>/dev/null)"; then
  reason="$(jq -r --arg index "${index}" "${platform_digests}" <<<"${manifest}" 2>&1 >/dev/null | tail -n 1 || true)"
  fail "${image}@${index}: ${reason}"
fi
printf '%s\n' "${digests}"
