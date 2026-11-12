#!/usr/bin/env bats
# Unit tests for scripts/platform-digests.sh: name the linux/amd64 and linux/arm64 manifests
# inside the image index that publish.yml is about to sign.
# `docker` is replaced by a stub on PATH; nothing reaches a registry. Needs jq.
#   tests/.bats-core/bin/bats tests/bats/ci
#
# The contract under test: one SBOM is made per platform and attested to that platform's own
# manifest, so the two digests must come from the index that was pushed and scanned, and the
# index must hold exactly one image for each of the two platforms. An index with one platform
# missing must stop the publish: it would be tagged as a multi-platform image otherwise.
#
# fixtures/imagetools/index-manifest.json is the real output of
# `docker buildx imagetools inspect <published stable digest> --format '{{json .Manifest}}'`,
# platform-manifest.json the same for one of its platform manifests.

bats_require_minimum_version 1.5.0 # `run --separate-stderr`

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/platform-digests.sh"
  FX="${BATS_TEST_DIRNAME}/fixtures/imagetools"
  WORK="$(mktemp -d)"
  STUB_BIN="${WORK}/bin"
  CALLS="${WORK}/docker.calls"
  mkdir -p "${STUB_BIN}"
  : > "${CALLS}"
  IMAGE="ghcr.io/rocketedge/brokersre-ib-gateway"
  INDEX="sha256:693bd6306d94708a87e5b0c43180874f671010a5edf142796eb8f46f51e869ea"
  AMD64="sha256:6b18da53d94fb9707193f2efe269c8e63048c916216ce9380e4e1f630e67d02d"
  ARM64="sha256:7eafe80738cffa64c3c3fd680e7c5038eddfcc0f8a89fda87d52e0d49317a943"
  cp "${FX}/index-manifest.json" "${WORK}/answer.json"
  # docker stub: records the call and prints ${WORK}/answer.json; fails when ${WORK}/fail exists.
  cat > "${STUB_BIN}/docker" <<EOF
#!/usr/bin/env bash
printf 'docker %s\n' "\$*" >> "${CALLS}"
if [ -f "${WORK}/fail" ]; then echo "unauthorized" >&2; exit 1; fi
cat "${WORK}/answer.json"
EOF
  chmod +x "${STUB_BIN}/docker"
  export PATH="${STUB_BIN}:${PATH}"
}

teardown() {
  rm -rf "${WORK}"
}

# answer FILTER: make the stub answer with a variant of the real index manifest.
answer() {
  jq "$1" "${FX}/index-manifest.json" > "${WORK}/answer.json"
}

@test "an index with both platforms: the two manifest digests, attestation manifests ignored" {
  run "$SCRIPT" "$IMAGE" "$INDEX"
  [ "$status" -eq 0 ]
  [ "$output" = "amd64=${AMD64}"$'\n'"arm64=${ARM64}" ]
  grep -qx "docker buildx imagetools inspect ${IMAGE}@${INDEX} --format {{json .Manifest}}" "${CALLS}"
}

@test "an index without the arm64 image stops the publish" {
  answer 'del(.manifests[] | select(.platform.architecture == "arm64"))'
  run "$SCRIPT" "$IMAGE" "$INDEX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"linux/arm64"* ]]
  [[ "$output" != *"amd64=sha256"* ]]
}

@test "an index without the amd64 image stops the publish" {
  answer 'del(.manifests[] | select(.platform.architecture == "amd64"))'
  run "$SCRIPT" "$IMAGE" "$INDEX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"linux/amd64"* ]]
}

@test "two images for one platform are refused: which one a client gets would be undefined" {
  answer '.manifests += [.manifests[1]]'
  run "$SCRIPT" "$IMAGE" "$INDEX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"linux/arm64"* ]]
}

@test "a single-platform manifest instead of an index stops the publish" {
  cp "${FX}/platform-manifest.json" "${WORK}/answer.json"
  run "$SCRIPT" "$IMAGE" "$AMD64"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not an image index"* ]]
}

@test "an answer about another digest is refused" {
  run "$SCRIPT" "$IMAGE" "sha256:$(printf 'a%.0s' {1..64})"
  [ "$status" -eq 1 ]
  [[ "$output" == *"another digest"* ]]
}

@test "a platform digest that is not sha256:<64 hex> is refused" {
  answer '(.manifests[] | select(.platform.architecture == "arm64") | .digest) = "sha256:abc\narm64=sha256:forged"'
  run --separate-stderr "$SCRIPT" "$IMAGE" "$INDEX"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "the registry refusing, or an answer that is not JSON, stops the publish" {
  touch "${WORK}/fail"
  run "$SCRIPT" "$IMAGE" "$INDEX"
  [ "$status" -eq 1 ]
  rm "${WORK}/fail"
  echo "not json" > "${WORK}/answer.json"
  run --separate-stderr "$SCRIPT" "$IMAGE" "$INDEX"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "bad arguments are refused before docker is called" {
  run "$SCRIPT" "$IMAGE:stable" "$INDEX"
  [ "$status" -eq 2 ]
  run "$SCRIPT" "$IMAGE" "sha256:abc"
  [ "$status" -eq 2 ]
  run "$SCRIPT" "$IMAGE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage"* ]]
  [ ! -s "${CALLS}" ]
}
