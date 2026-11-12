#!/usr/bin/env bats
# Unit tests for scripts/rebuild-decision.sh: does the published image of a channel need an
# OS-patch rebuild? Runs wherever bash 5 and jq exist (CI lint job, or inside the image):
#   tests/.bats-core/bin/bats tests/bats/ci
#
# The contract under test: a rebuild is requested only for a CRITICAL or HIGH finding in OS
# packages that has a fixed version (the same predicate as the Trivy gate of ci.yml and
# publish.yml); findings a rebuild cannot fix (no fixed version, or IBKR's bundled jars,
# docs/limitations.md L08) never request one; a report that cannot be read is an error (exit 2),
# never "nothing to do".
#
# The fixtures are real Trivy 0.76.2 reports, reduced with fixtures/trivy/trim.jq
# (fixtures/trivy/README.md says how each one was produced).

bats_require_minimum_version 1.5.0 # `run --separate-stderr`

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/rebuild-decision.sh"
  FX="${BATS_TEST_DIRNAME}/fixtures/trivy"
  WORK="$(mktemp -d)"
}

teardown() {
  rm -rf "${WORK}"
}

@test "no finding in OS packages: nothing to do" {
  run "$SCRIPT" stable "${FX}/gateway-os-clean.json"
  [ "$status" -eq 0 ]
  [ "$output" = $'action=none\ncves=' ]
}

@test "only CRITICAL/HIGH findings without a fixed version: a rebuild would change nothing" {
  run "$SCRIPT" stable "${FX}/debian-os-unfixable-only.json"
  [ "$status" -eq 0 ]
  [ "$output" = $'action=none\ncves=' ]
}

@test "one fixable HIGH finding: rebuild, and the CVE is named" {
  run "$SCRIPT" stable "${FX}/debian-os-one-fixable-high.json"
  [ "$status" -eq 0 ]
  [ "$output" = $'action=rebuild\ncves=CVE-2026-109518' ]
}

@test "CRITICAL and HIGH mixed with unfixable, MEDIUM and LOW: only fixable CRITICAL/HIGH, each once, sorted" {
  # The fixture holds CVE-2023-4911 and CVE-2026-109518 twice (two packages each), one fixable
  # CRITICAL, an unfixable CRITICAL and HIGH, and a fixable MEDIUM and LOW.
  run "$SCRIPT" latest "${FX}/debian-os-mix.json"
  [ "$status" -eq 0 ]
  [ "$output" = $'action=rebuild\ncves=CVE-2023-4911,CVE-2026-109518,CVE-2026-33845' ]
}

@test "the script's own filter equals Trivy's gate flags on the same image" {
  # debian-os-gate.json was written by Trivy with --severity CRITICAL,HIGH --ignore-unfixed,
  # debian-os-full.json by the same scan without those flags (365 findings).
  run "$SCRIPT" stable "${FX}/debian-os-gate.json"
  [ "$status" -eq 0 ]
  from_gate="$output"
  run "$SCRIPT" stable "${FX}/debian-os-full.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$from_gate" ]
  [[ "$output" == $'action=rebuild\ncves=CVE-2023-31484,'* ]]
  ids="${output#*cves=}"
  [ "$(tr ',' '\n' <<<"$ids" | wc -l)" -eq 35 ]
}

@test "fixable findings only in IBKR's bundled jars: no rebuild (an OS rebuild cannot fix them)" {
  run "$SCRIPT" stable "${FX}/gateway-os-clean-jars-vulnerable.json"
  [ "$status" -eq 0 ]
  [ "$output" = $'action=none\ncves=' ]
}

@test "two reports (both platforms of one image): a finding in either one requests the rebuild" {
  run "$SCRIPT" stable "${FX}/gateway-os-clean.json" "${FX}/debian-os-one-fixable-high.json"
  [ "$status" -eq 0 ]
  [ "$output" = $'action=rebuild\ncves=CVE-2026-109518' ]
}

@test "two reports naming the same CVE: it is listed once" {
  run "$SCRIPT" stable "${FX}/debian-os-mix.json" "${FX}/debian-os-one-fixable-high.json"
  [ "$status" -eq 0 ]
  [ "$output" = $'action=rebuild\ncves=CVE-2023-4911,CVE-2026-109518,CVE-2026-33845' ]
}

@test "a report without an OS-package result is refused: absence of a scan is not a clean scan" {
  # gateway-library.json comes from `--pkg-types library`: it says nothing about OS packages.
  run "$SCRIPT" stable "${FX}/gateway-library.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"OS package"* ]]
}

@test "truncated JSON is refused, never read as nothing to do" {
  head -c 600 "${FX}/debian-os-gate.json" > "${WORK}/truncated.json"
  run "$SCRIPT" stable "${WORK}/truncated.json"
  [ "$status" -eq 2 ]
  [[ "$output" != *"action="* ]]
}

@test "an empty report is refused" {
  : > "${WORK}/empty.json"
  run "$SCRIPT" stable "${WORK}/empty.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"empty"* ]]
  [[ "$output" != *"action="* ]]
}

@test "a report holding only white space is refused" {
  printf '\n  \n' > "${WORK}/blank.json"
  run "$SCRIPT" stable "${WORK}/blank.json"
  [ "$status" -eq 2 ]
  [[ "$output" != *"action="* ]]
}

@test "valid JSON that is not a Trivy report is refused" {
  for body in '{}' '[]' 'null' '{"SchemaVersion":2}' '{"SchemaVersion":1,"ArtifactType":"container_image","Results":[]}'; do
    printf '%s\n' "$body" > "${WORK}/other.json"
    run "$SCRIPT" stable "${WORK}/other.json"
    [ "$status" -eq 2 ]
    [[ "$output" != *"action="* ]]
  done
}

@test "a missing report file is refused" {
  run "$SCRIPT" stable "${WORK}/does-not-exist.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a readable file"* ]]
}

@test "one unusable report among good ones: no decision at all" {
  : > "${WORK}/empty.json"
  run --separate-stderr "$SCRIPT" stable "${FX}/debian-os-one-fixable-high.json" "${WORK}/empty.json"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "a finding whose id could forge an output line is refused" {
  # The id reaches GITHUB_OUTPUT and an issue: a line break in it would inject `action=none`.
  jq '.Results[0].Vulnerabilities[0].VulnerabilityID = "CVE-2026-1\naction=none"' \
    "${FX}/debian-os-one-fixable-high.json" > "${WORK}/forged.json"
  run --separate-stderr "$SCRIPT" stable "${WORK}/forged.json"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"unexpected vulnerability id"* ]]
}

@test "unknown channel is refused" {
  run "$SCRIPT" beta "${FX}/gateway-os-clean.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"channel"* ]]
}

@test "wrong number of arguments prints usage" {
  run "$SCRIPT" stable
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage"* ]]
}

@test "a refusal goes to stderr only, so it can never reach GITHUB_OUTPUT" {
  run --separate-stderr "$SCRIPT" beta "${FX}/gateway-os-clean.json"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"channel"* ]]
}
