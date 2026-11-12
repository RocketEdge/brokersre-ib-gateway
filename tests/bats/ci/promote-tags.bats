#!/usr/bin/env bats
# Unit tests for scripts/promote-tags.sh: move the tags of a channel to the image index that
# was scanned, and prove that every tag then resolves to exactly that digest.
# `docker` is replaced by a stub on PATH; nothing reaches a registry.
#   tests/.bats-core/bin/bats tests/bats/ci
#
# The contract under test: publish.yml pushes an image by digest only, scans both platforms of
# that digest, and only then calls this script. Tags may move only inside the image's own
# repository and only to the scanned digest; a tag that resolves to anything else afterwards
# fails the publish.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/promote-tags.sh"
  WORK="$(mktemp -d)"
  STUB_BIN="${WORK}/bin"
  CALLS="${WORK}/docker.calls"
  mkdir -p "${STUB_BIN}" "${WORK}/resolves"
  : > "${CALLS}"
  IMAGE="ghcr.io/example/gateway"
  DIGEST="sha256:$(printf 'a%.0s' {1..64})"
  OTHER="sha256:$(printf 'b%.0s' {1..64})"
  # docker stub: every call is appended to ${CALLS} as `docker <arguments>`.
  #   buildx imagetools create ...   fails when ${WORK}/fail-create exists
  #   buildx imagetools inspect REF  prints the manifest descriptor as JSON; the digest is
  #                                  ${DIGEST} unless ${WORK}/resolves/<tag> names another one;
  #                                  prints text that is not JSON when ${WORK}/garbage exists
  cat > "${STUB_BIN}/docker" <<EOF
#!/usr/bin/env bash
printf 'docker %s\n' "\$*" >> "${CALLS}"
case "\$1 \$2 \$3" in
  "buildx imagetools create")
    if [ -f "${WORK}/fail-create" ]; then echo "denied" >&2; exit 1; fi
    ;;
  "buildx imagetools inspect")
    if [ -f "${WORK}/garbage" ]; then echo "not json"; exit 0; fi
    tag="\${4##*:}"
    digest="${DIGEST}"
    if [ -f "${WORK}/resolves/\${tag}" ]; then digest="\$(cat "${WORK}/resolves/\${tag}")"; fi
    printf '{"mediaType":"application/vnd.oci.image.index.v1+json","digest":"%s","size":1607}\n' "\${digest}"
    ;;
esac
exit 0
EOF
  chmod +x "${STUB_BIN}/docker"
  export PATH="${STUB_BIN}:${PATH}"
}

teardown() {
  rm -rf "${WORK}"
}

@test "every tag is created from the scanned digest in one call and then verified" {
  run "$SCRIPT" "$IMAGE" "$DIGEST" "$IMAGE:10.50.1g-r20261201" "$IMAGE:10.50.1g" "$IMAGE:10.50" "$IMAGE:stable"
  [ "$status" -eq 0 ]
  grep -qx "docker buildx imagetools create -t $IMAGE:10.50.1g-r20261201 -t $IMAGE:10.50.1g -t $IMAGE:10.50 -t $IMAGE:stable $IMAGE@$DIGEST" "${CALLS}"
  [ "$(grep -c '^docker buildx imagetools inspect ' "${CALLS}")" -eq 4 ]
  [[ "$output" == *"promoted $IMAGE:stable -> $DIGEST"* ]]
}

@test "a tag listed twice (no rebuild suffix: the version tag appears twice) is created once" {
  run "$SCRIPT" "$IMAGE" "$DIGEST" "$IMAGE:10.50.1g" "$IMAGE:10.50.1g" "$IMAGE:stable"
  [ "$status" -eq 0 ]
  grep -qx "docker buildx imagetools create -t $IMAGE:10.50.1g -t $IMAGE:stable $IMAGE@$DIGEST" "${CALLS}"
}

@test "a tag that resolves to another digest afterwards fails the publish and is named" {
  echo "$OTHER" > "${WORK}/resolves/stable"
  run "$SCRIPT" "$IMAGE" "$DIGEST" "$IMAGE:10.50.1g" "$IMAGE:stable"
  [ "$status" -eq 1 ]
  [[ "$output" == *"$IMAGE:stable resolves to $OTHER"* ]]
}

@test "the registry refusing the tags fails the publish and nothing is reported as promoted" {
  touch "${WORK}/fail-create"
  run "$SCRIPT" "$IMAGE" "$DIGEST" "$IMAGE:stable"
  [ "$status" -eq 1 ]
  [[ "$output" != *"promoted"* ]]
  ! grep -q '^docker buildx imagetools inspect ' "${CALLS}"
}

@test "an answer that is not a manifest descriptor fails the publish" {
  touch "${WORK}/garbage"
  run "$SCRIPT" "$IMAGE" "$DIGEST" "$IMAGE:stable"
  [ "$status" -eq 1 ]
  [[ "$output" != *"promoted"* ]]
}

@test "a tag in another repository is refused before docker is called" {
  run "$SCRIPT" "$IMAGE" "$DIGEST" "$IMAGE:stable" "ghcr.io/example/other:stable"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ghcr.io/example/other:stable"* ]]
  [ ! -s "${CALLS}" ]
}

@test "a digest that is not sha256:<64 hex>, a tagged image name and a missing tag list are refused" {
  run "$SCRIPT" "$IMAGE" "sha256:abc" "$IMAGE:stable"
  [ "$status" -eq 2 ]
  run "$SCRIPT" "$IMAGE:stable" "$DIGEST" "$IMAGE:stable"
  [ "$status" -eq 2 ]
  run "$SCRIPT" "$IMAGE" "$DIGEST" "$IMAGE:bad tag"
  [ "$status" -eq 2 ]
  run "$SCRIPT" "$IMAGE" "$DIGEST"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage"* ]]
  [ ! -s "${CALLS}" ]
}
