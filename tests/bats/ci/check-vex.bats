#!/usr/bin/env bats
# Unit tests for scripts/check-vex.sh: does the OpenVEX document for IBKR's bundled jars
# (security/vex/ibgateway-vendor-jars.openvex.json, docs/limitations.md L08) say something about
# exactly the jar findings Trivy reports? Runs wherever bash 5 and jq exist:
#   tests/.bats-core/bin/bats tests/bats/ci
#
# The contract under test: a finding without a statement is drift (MISSING), a statement
# without a finding is drift (STALE), both exit 1; a document that breaks the OpenVEX rules or
# this repository's policy (never `fixed`, no digest in the product, a note on every open
# question) and a report that cannot be read are errors (exit 2), never "in sync".
#
# fixtures/trivy/gateway-library.json is a real Trivy 0.76.2 report of this image
# (--pkg-types library --list-all-pkgs, reduced with fixtures/trivy/trim.jq);
# fixtures/vex/in-sync.openvex.json is the VEX document as it was when that report was made.
# Variants are derived from the two with jq inside each test, so the shape stays real.

bats_require_minimum_version 1.5.0 # `run --separate-stderr`

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/check-vex.sh"
  REPO_VEX="${BATS_TEST_DIRNAME}/../../../security/vex/ibgateway-vendor-jars.openvex.json"
  REPORT="${BATS_TEST_DIRNAME}/fixtures/trivy/gateway-library.json"
  VEX="${BATS_TEST_DIRNAME}/fixtures/vex/in-sync.openvex.json"
  FX="${BATS_TEST_DIRNAME}/fixtures/trivy"
  WORK="$(mktemp -d)"
}

teardown() {
  rm -rf "${WORK}"
}

# vex_with FILTER: write a variant of the in-sync document to ${WORK}/vex.json.
vex_with() {
  jq "$1" "${VEX}" > "${WORK}/vex.json"
}

@test "every jar finding has a statement and every statement a finding: in sync" {
  run "$SCRIPT" "$VEX" "$REPORT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"in sync: 25 statements cover 25 jar findings in 1 report(s)"* ]]
}

@test "a finding outside the jars (a Go binary of the base image) is noted, not counted as drift" {
  run "$SCRIPT" "$VEX" "$REPORT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"note: not a jar, outside this document: CVE-2026-97054 pkg:golang/stdlib@v1.27.3 (usr/bin/pebble)"* ]]
}

@test "Trivy reports a jar CVE the document does not mention: MISSING, exit 1" {
  vex_with 'del(.statements[] | select(.vulnerability.name == "CVE-2024-47554"))'
  run "$SCRIPT" "${WORK}/vex.json" "$REPORT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING"*"CVE-2024-47554 pkg:maven/commons-io/commons-io@2.11.0"* ]]
  [[ "$output" == *"drift: 1 missing, 0 stale"* ]]
}

@test "the document mentions a CVE Trivy no longer reports (IBKR shipped a newer jar): STALE, exit 1" {
  jq '(.Results[] | select(.Type == "jar") | .Vulnerabilities) |= map(select(.PkgName != "commons-io:commons-io"))' \
    "$REPORT" > "${WORK}/report.json"
  run "$SCRIPT" "$VEX" "${WORK}/report.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"STALE"*"CVE-2024-47554 pkg:maven/commons-io/commons-io@2.11.0"* ]]
  [[ "$output" == *"drift: 0 missing, 1 stale"* ]]
}

@test "the same CVE in another version of the jar needs a new statement (missing and stale)" {
  jq '(.Results[] | select(.Type == "jar") | .Vulnerabilities[] | select(.VulnerabilityID == "CVE-2024-47554") | .PkgIdentifier.PURL) = "pkg:maven/commons-io/commons-io@2.12.0"' \
    "$REPORT" > "${WORK}/report.json"
  run "$SCRIPT" "$VEX" "${WORK}/report.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING"*"CVE-2024-47554 pkg:maven/commons-io/commons-io@2.12.0"* ]]
  [[ "$output" == *"STALE"*"CVE-2024-47554 pkg:maven/commons-io/commons-io@2.11.0"* ]]
  [[ "$output" == *"drift: 1 missing, 1 stale"* ]]
}

@test "a finding reported under an alias of a statement (a GHSA id) is covered by it" {
  jq '(.Results[] | select(.Type == "jar") | .Vulnerabilities[] | select(.VulnerabilityID == "CVE-2024-47554") | .VulnerabilityID) = "GHSA-78wr-2p64-hpwj"' \
    "$REPORT" > "${WORK}/report.json"
  run "$SCRIPT" "$VEX" "${WORK}/report.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"in sync"* ]]
}

@test "two reports (two channels or platforms): a statement is stale only when neither reports it" {
  jq '(.Results[] | select(.Type == "jar") | .Vulnerabilities) |= map(select(.PkgName != "commons-io:commons-io"))' \
    "$REPORT" > "${WORK}/without-commons-io.json"
  run "$SCRIPT" "$VEX" "${WORK}/without-commons-io.json" "$REPORT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"in sync: 25 statements cover 25 jar findings in 2 report(s)"* ]]
}

@test "the repository's document is valid on its own (no report: rules and policy only)" {
  run "$SCRIPT" "$REPO_VEX"
  [ "$status" -eq 0 ]
  [[ "$output" == *"valid:"*"statements"* ]]
}

@test "status fixed is refused: this image never patches a vendor jar" {
  vex_with '.statements[0].status = "fixed"'
  run "$SCRIPT" "${WORK}/vex.json" "$REPORT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"fixed"* ]]
}

@test "not_affected without a justification label and an impact statement is refused" {
  vex_with '.statements[0].status = "not_affected" | del(.statements[0].status_notes)'
  run "$SCRIPT" "${WORK}/vex.json" "$REPORT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not_affected"* ]]
  vex_with '.statements[0].status = "not_affected" | .statements[0].justification = "because"'
  run "$SCRIPT" "${WORK}/vex.json" "$REPORT"
  [ "$status" -eq 2 ]
}

@test "not_affected with a justification label and an impact statement is accepted and covers the finding" {
  vex_with '.statements[0] |= (.status = "not_affected" | .justification = "vulnerable_code_not_in_execute_path" | .impact_statement = "test text" | del(.status_notes))'
  run "$SCRIPT" "${WORK}/vex.json" "$REPORT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"in sync"* ]]
}

@test "under_investigation without a note on what is unknown is refused" {
  vex_with 'del(.statements[3].status_notes)'
  run "$SCRIPT" "${WORK}/vex.json" "$REPORT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"status_notes"* ]]
}

@test "a product pinned to a digest is refused: it would stop matching with the next build" {
  vex_with '.statements[0].products[0]."@id" = "pkg:oci/brokersre-ib-gateway@sha256%3A693bd6306d94708a87e5b0c43180874f671010a5edf142796eb8f46f51e869ea?repository_url=ghcr.io/rocketedge/brokersre-ib-gateway"'
  run "$SCRIPT" "${WORK}/vex.json" "$REPORT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"digest"* ]]
}

@test "a statement without a jar subcomponent is refused: it would cover the whole image" {
  vex_with 'del(.statements[0].products[0].subcomponents)'
  run "$SCRIPT" "${WORK}/vex.json" "$REPORT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"subcomponents"* ]]
}

@test "two statements for the same CVE and jar are refused" {
  vex_with '.statements += [.statements[0]]'
  run "$SCRIPT" "${WORK}/vex.json" "$REPORT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"more than one statement"* ]]
}

@test "a document without the OpenVEX 0.2.0 context or a required field is refused" {
  for filter in '."@context" = "https://example.invalid/vex"' 'del(."@id")' 'del(.author)' 'del(.timestamp)' 'del(.version)' '.statements = []'; do
    vex_with "$filter"
    run "$SCRIPT" "${WORK}/vex.json" "$REPORT"
    [ "$status" -eq 2 ]
    [[ "$output" != *"in sync"* ]]
  done
}

@test "a report that did not scan the jars (OS packages only) is refused, not read as 'all stale'" {
  run "$SCRIPT" "$VEX" "${FX}/gateway-os-clean.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"did not cover the jars"* ]]
}

@test "a truncated or empty report is refused" {
  head -c 500 "$REPORT" > "${WORK}/truncated.json"
  run "$SCRIPT" "$VEX" "${WORK}/truncated.json"
  [ "$status" -eq 2 ]
  : > "${WORK}/empty.json"
  run "$SCRIPT" "$VEX" "${WORK}/empty.json"
  [ "$status" -eq 2 ]
  [[ "$output" != *"in sync"* ]]
}

@test "a document that is not JSON is refused" {
  head -c 300 "$VEX" > "${WORK}/vex.json"
  run "$SCRIPT" "${WORK}/vex.json" "$REPORT"
  [ "$status" -eq 2 ]
}

@test "a missing document prints the reason; no argument prints usage" {
  run "$SCRIPT" "${WORK}/nope.json" "$REPORT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a readable file"* ]]
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage"* ]]
}

@test "drift is reported on stdout, a refusal on stderr only" {
  vex_with 'del(.statements[] | select(.vulnerability.name == "CVE-2024-47554"))'
  run --separate-stderr "$SCRIPT" "${WORK}/vex.json" "$REPORT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING"* ]]
  run --separate-stderr "$SCRIPT" "${WORK}/nope.json" "$REPORT"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}
