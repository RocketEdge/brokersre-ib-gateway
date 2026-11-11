#!/usr/bin/env bats
# Unit tests for scripts/readme-versions.sh: the README's version table is generated from
# versions.json (the only place versions live), and CI fails when the two drift apart. The
# README showed stable 10.50.1f for days after versions.json had moved to 10.50.1g.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/readme-versions.sh"
  WORK="$(mktemp -d)"
  printf '%s\n' \
    '{ "schema_version": 1,' \
    '  "ibc": { "version": "3.24.2", "release_tag": "3.24.2-rocketedge.1", "repo": "RocketEdge/ibc" },' \
    '  "channels": {' \
    '    "stable": { "version": "10.50.1g" },' \
    '    "latest": { "version": "10.51.1e" } } }' >"${WORK}/versions.json"
  printf '%s\n' \
    '# Title' \
    '' \
    'Text before.' \
    '' \
    '<!-- versions:start -->' \
    '| stale | table |' \
    '<!-- versions:end -->' \
    '' \
    'Text after.' >"${WORK}/README.md"
}

teardown() {
  rm -rf "${WORK}"
}

@test "the table between the markers is rewritten from versions.json" {
  run "${SCRIPT}" "${WORK}/README.md" "${WORK}/versions.json"
  [ "$status" -eq 0 ]
  grep -q -F -x '| stable | 10.50.1g | 3.24.2 (RocketEdge/ibc `3.24.2-rocketedge.1`) | `stable`, `10.50`, `10.50.1g` |' "${WORK}/README.md"
  grep -q -F -x '| latest | 10.51.1e | 3.24.2 (RocketEdge/ibc `3.24.2-rocketedge.1`) | `latest`, `10.51`, `10.51.1e` |' "${WORK}/README.md"
  ! grep -q 'stale' "${WORK}/README.md"
}

@test "text outside the markers is untouched" {
  "${SCRIPT}" "${WORK}/README.md" "${WORK}/versions.json"
  [ "$(head -3 "${WORK}/README.md")" == $'# Title\n\nText before.' ]
  [ "$(tail -1 "${WORK}/README.md")" == "Text after." ]
  [ "$(grep -c 'versions:start' "${WORK}/README.md")" == "1" ]
  [ "$(grep -c 'versions:end' "${WORK}/README.md")" == "1" ]
}

@test "rendering twice changes nothing the second time" {
  "${SCRIPT}" "${WORK}/README.md" "${WORK}/versions.json"
  cp "${WORK}/README.md" "${WORK}/first.md"
  "${SCRIPT}" "${WORK}/README.md" "${WORK}/versions.json"
  cmp "${WORK}/README.md" "${WORK}/first.md"
}

@test "--check passes when the README matches versions.json" {
  "${SCRIPT}" "${WORK}/README.md" "${WORK}/versions.json"
  run "${SCRIPT}" --check "${WORK}/README.md" "${WORK}/versions.json"
  [ "$status" -eq 0 ]
}

@test "--check fails, names the fix and changes nothing when the README is stale" {
  cp "${WORK}/README.md" "${WORK}/before.md"
  run "${SCRIPT}" --check "${WORK}/README.md" "${WORK}/versions.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/readme-versions.sh"* ]]
  cmp "${WORK}/README.md" "${WORK}/before.md"
}

@test "a README without the markers is an error, not a silent no-op" {
  printf '# no markers here\n' >"${WORK}/README.md"
  run "${SCRIPT}" "${WORK}/README.md" "${WORK}/versions.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"versions:start"* ]]
}

@test "the repository README is in sync with the repository versions.json" {
  run "${SCRIPT}" --check
  [ "$status" -eq 0 ]
}
