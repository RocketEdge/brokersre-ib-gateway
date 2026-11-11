#!/usr/bin/env bats
# Unit tests for scripts/prefetch-installers.sh: copy archived installers into downloads/ only
# when they match the pinned SHA-256. Candidates are the version's release
# (ibgateway-<channel>@<version>) and, for a version IBKR re-uploaded, the release keyed by the
# pinned x64 hash (ibgateway-<channel>@<version>-<first 12 hex of x64>). A copy that matches no
# pin is dropped so fetch-installer.sh falls back to IBKR's URL instead of failing the build.
# `gh` is replaced by a stub on PATH; nothing reaches GitHub.
#   tests/.bats-core/bin/bats tests/bats/ci

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/prefetch-installers.sh"
  WORK="$(mktemp -d)"
  STUB_BIN="${WORK}/bin"
  ARCHIVES="${WORK}/archives"
  DEST="${WORK}/downloads"
  mkdir -p "${STUB_BIN}" "${ARCHIVES}" "${DEST}"
  # The version's release holds the original bytes and a checksum file.
  ORIG="${ARCHIVES}/ibgateway-stable@10.50.1g"
  mkdir -p "${ORIG}"
  printf 'x64 installer bytes\n' > "${ORIG}/ibgateway-10.50.1g-standalone-linux-x64.sh"
  printf 'arm installer bytes\n' > "${ORIG}/ibgateway-10.50.1g-standalone-linux-arm.sh"
  printf 'checksum file, not an installer\n' > "${ORIG}/ibgateway-10.50.1g-standalone-linux-x64.sh.sha256"
  X64=$(sha256sum "${ORIG}/ibgateway-10.50.1g-standalone-linux-x64.sh" | cut -d' ' -f1)
  ARM=$(sha256sum "${ORIG}/ibgateway-10.50.1g-standalone-linux-arm.sh" | cut -d' ' -f1)
  # gh stub: `gh release download <tag> -R <repo> --pattern '*.sh' --dir <dir>` copies the
  # *.sh files of ${ARCHIVES}/<tag>; a tag without a directory is a missing release (exit 1).
  cat > "${STUB_BIN}/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "${WORK}/gh.calls"
tag="\$3"
dir=""
while [ \$# -gt 0 ]; do case "\$1" in --dir) dir="\$2"; shift 2 ;; *) shift ;; esac; done
if [ ! -d "${ARCHIVES}/\${tag}" ]; then echo "release not found" >&2; exit 1; fi
cp "${ARCHIVES}/\${tag}"/*.sh "\$dir"/
EOF
  chmod +x "${STUB_BIN}/gh"
  export PATH="${STUB_BIN}:${PATH}"
  export GH_TOKEN="test-token-not-a-secret"
}

teardown() {
  rm -rf "${WORK}"
}

@test "matching archive copies land in downloads/" {
  run "$SCRIPT" stable 10.50.1g "$X64" "$ARM" "$DEST"
  [ "$status" -eq 0 ]
  [ -f "${DEST}/ibgateway-10.50.1g-standalone-linux-x64.sh" ]
  [ -f "${DEST}/ibgateway-10.50.1g-standalone-linux-arm.sh" ]
  grep -q "release download ibgateway-stable@10.50.1g -R RocketEdge/brokersre-ib-gateway-archive" "${WORK}/gh.calls"
}

@test "a copy that does not match its pin is dropped, the other is kept" {
  wrong=$(printf '0%.0s' {1..64})
  run "$SCRIPT" stable 10.50.1g "$wrong" "$ARM" "$DEST"
  [ "$status" -eq 0 ]
  [ ! -e "${DEST}/ibgateway-10.50.1g-standalone-linux-x64.sh" ]
  [ -f "${DEST}/ibgateway-10.50.1g-standalone-linux-arm.sh" ]
  [[ "$output" == *"no archived copy matches the pin"* ]]
}

@test "after a re-pin to re-uploaded bytes, the copy comes from the hash-keyed release" {
  NEW="${ARCHIVES}/reupload"
  mkdir -p "${NEW}"
  printf 're-uploaded x64 bytes\n' > "${NEW}/ibgateway-10.50.1g-standalone-linux-x64.sh"
  cp "${ORIG}/ibgateway-10.50.1g-standalone-linux-arm.sh" "${NEW}/"
  new_x64=$(sha256sum "${NEW}/ibgateway-10.50.1g-standalone-linux-x64.sh" | cut -d' ' -f1)
  mv "${NEW}" "${ARCHIVES}/ibgateway-stable@10.50.1g-${new_x64:0:12}"
  run "$SCRIPT" stable 10.50.1g "$new_x64" "$ARM" "$DEST"
  [ "$status" -eq 0 ]
  [ "$(sha256sum "${DEST}/ibgateway-10.50.1g-standalone-linux-x64.sh" | cut -d' ' -f1)" = "$new_x64" ]
  [ "$(sha256sum "${DEST}/ibgateway-10.50.1g-standalone-linux-arm.sh" | cut -d' ' -f1)" = "$ARM" ]
}

@test "without a token it does nothing and succeeds (IBKR's URL is used)" {
  unset GH_TOKEN
  run "$SCRIPT" stable 10.50.1g "$X64" "$ARM" "$DEST"
  [ "$status" -eq 0 ]
  [ ! -e "${WORK}/gh.calls" ]
  [ -z "$(ls -A "${DEST}")" ]
  [[ "$output" == *"no ARCHIVE_READ_TOKEN"* ]]
}

@test "an archive miss is not an error (IBKR's URL is used)" {
  run "$SCRIPT" latest 10.51.1e "$X64" "$ARM" "$DEST"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "${DEST}")" ]
  [[ "$output" == *"no archived copy matches the pin"* ]]
}

@test "nothing but the two pinned installers is left in downloads/" {
  run "$SCRIPT" stable 10.50.1g "$X64" "$ARM" "$DEST"
  [ "$status" -eq 0 ]
  [ "$(ls "${DEST}" | wc -l)" -eq 2 ]
}

@test "unknown channel is refused" {
  run "$SCRIPT" beta 10.50.1g "$X64" "$ARM" "$DEST"
  [ "$status" -eq 2 ]
  [[ "$output" == *"channel"* ]]
}

@test "a missing destination directory is refused" {
  run "$SCRIPT" stable 10.50.1g "$X64" "$ARM" "${WORK}/nope"
  [ "$status" -eq 2 ]
  [[ "$output" == *"destination"* ]]
}
