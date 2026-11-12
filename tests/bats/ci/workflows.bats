#!/usr/bin/env bats
# Tests that keep the workflows' security-relevant settings in step. Needs bash and awk:
#   tests/.bats-core/bin/bats tests/bats/ci
#
# Workflows cannot be run from a checkout, and several of their settings are easy to change
# on one side only: the gate flags live in three files, the cron strings in two places, the
# scanner version on every scanner step. Each property below is asserted on the real files
# and, where a regression has a known shape, on a copy with that regression put back in (the
# check must then fail).
#
# The steps are read by workflow-steps.awk (this directory), which relies on the files'
# layout; the first test pins what it finds, so a layout change cannot turn every other test
# into a check of nothing.
#
# "Must not be there" is written `run ! grep ...`: a bare `! command` that is not the last
# line of a test never fails it (bash exempts negated commands from errexit).

bats_require_minimum_version 1.5.0 # `run !`

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  WF="${ROOT}/.github/workflows"
  LISTER="${BATS_TEST_DIRNAME}/workflow-steps.awk"
  WORK="$(mktemp -d)"
  # The Trivy release every scanner step must ask for (invariant 1: every input is pinned).
  TRIVY_VERSION="v0.76.2"
  # Workflows whose scanner steps must carry that version.
  VERSION_PINNED=(ci.yml publish.yml rebuild.yml)
}

teardown() {
  rm -rf "${WORK}"
}

# steps FILE: the facts of every step, tab separated (step number, key, value).
steps() {
  awk -f "${LISTER}" "$1"
}

# scanner_steps FILE: the numbers of the steps that run the scanner action.
scanner_steps() {
  steps "$1" | awk -F '\t' '$2 == "uses" && $3 ~ /^aquasecurity\/trivy-action@/ { print $1 }'
}

# value FILE STEP KEY: the value of one key of one step (empty when the step has no such key).
value() {
  steps "$1" | awk -F '\t' -v step="$2" -v key="$3" '$1 == step && $2 == key { print $3 }'
}

# gate_steps FILE: the scanner steps that can fail the job (exit-code 1).
gate_steps() {
  local n
  for n in $(scanner_steps "$1"); do
    if [ "$(value "$1" "${n}" with.exit-code)" = 1 ]; then echo "${n}"; fi
  done
}

# gate_problems FILE: print what is wrong with the gate steps of FILE; fail when anything is.
# A gate is: OS packages only, CRITICAL and HIGH, fixed findings only; and when it writes SARIF,
# limit-severities-for-sarif, without which the scanner action drops the severity filter.
gate_problems() {
  local file="$1" n key want got bad=0
  for n in $(gate_steps "${file}"); do
    for key in with.severity=CRITICAL,HIGH with.ignore-unfixed=true with.vuln-type=os; do
      want="${key#*=}"
      got="$(value "${file}" "${n}" "${key%%=*}")"
      if [ "${got}" != "${want}" ]; then
        echo "$(basename "${file}") step ${n}: ${key%%=*} is '${got}', expected '${want}'"
        bad=1
      fi
    done
    if [ "$(value "${file}" "${n}" with.format)" = sarif ] \
      && [ "$(value "${file}" "${n}" with.limit-severities-for-sarif)" != true ]; then
      echo "$(basename "${file}") step ${n}: a SARIF gate without limit-severities-for-sarif ignores its severities"
      bad=1
    fi
  done
  return "${bad}"
}

# unpinned_actions FILE: print every `uses` that is not `<action>@<40 hex> # v<version>`.
unpinned_actions() {
  steps "$1" | awk -F '\t' '$2 == "uses" && $3 !~ /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.\/-]+@[0-9a-f]+ # v[0-9]+(\.[0-9]+)*$/ { print $3 }
    $2 == "uses" && $3 ~ /@[0-9a-f]+ # v/ { split($3, part, /[@ ]/); if (length(part[2]) != 40) print $3 }'
}

# pasted_expressions FILE: print every script line that holds a ${{ }} expression.
pasted_expressions() {
  steps "$1" | awk -F '\t' '$2 == "run" && index($3, "${{") > 0 { print "step " $1 ": " $3 }'
}

# cron_schedule FILE / cron_conditions FILE: the cron strings that start the workflow, and
# the ones its job conditions compare github.event.schedule with.
cron_schedule() {
  sed -n -E 's/^ +- cron: *"([^"]*)" *$/\1/p' "$1" | sort
}
cron_conditions() {
  grep -o "github\.event\.schedule == '[^']*'" "$1" | sed -E "s/^[^']*'([^']*)'$/\1/" | sort -u
}

@test "the step lister reads the workflows: the expected scanner steps and gates are found" {
  [ "$(scanner_steps "${WF}/ci.yml" | wc -l)" -eq 3 ]
  [ "$(gate_steps "${WF}/ci.yml" | wc -l)" -eq 1 ]
  [ "$(scanner_steps "${WF}/publish.yml" | wc -l)" -eq 5 ]
  [ "$(gate_steps "${WF}/publish.yml" | wc -l)" -eq 2 ]
  [ "$(scanner_steps "${WF}/rebuild.yml" | wc -l)" -eq 2 ]
  [ "$(gate_steps "${WF}/rebuild.yml" | wc -l)" -eq 0 ]
}

@test "every gate has the same flags: OS packages, CRITICAL and HIGH, fixed findings only" {
  run gate_problems "${WF}/ci.yml"
  [ "$status" -eq 0 ]
  run gate_problems "${WF}/publish.yml"
  [ "$status" -eq 0 ]
}

@test "a gate with one flag changed is caught" {
  sed 's/severity: CRITICAL,HIGH/severity: CRITICAL/' "${WF}/publish.yml" > "${WORK}/publish.yml"
  run gate_problems "${WORK}/publish.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"with.severity"* ]]
  sed 's/ignore-unfixed: true/ignore-unfixed: false/' "${WF}/ci.yml" > "${WORK}/ci.yml"
  run gate_problems "${WORK}/ci.yml"
  [ "$status" -eq 1 ]
  sed 's/vuln-type: os$/vuln-type: os,library/' "${WF}/publish.yml" > "${WORK}/publish.yml"
  run gate_problems "${WORK}/publish.yml"
  [ "$status" -eq 1 ]
}

@test "a SARIF gate without limit-severities-for-sarif is caught (it would fail on any severity)" {
  grep -q 'limit-severities-for-sarif: "true"' "${WF}/ci.yml"
  grep -v 'limit-severities-for-sarif' "${WF}/ci.yml" > "${WORK}/ci.yml"
  run gate_problems "${WORK}/ci.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"limit-severities-for-sarif"* ]]
}

@test "the publish gates read linux/amd64 and linux/arm64 of the pushed digest from the registry" {
  platforms=""
  for n in $(gate_steps "${WF}/publish.yml"); do
    [ "$(value "${WF}/publish.yml" "${n}" env.TRIVY_IMAGE_SRC)" = remote ]
    [ "$(value "${WF}/publish.yml" "${n}" with.format)" = json ]
    [[ "$(value "${WF}/publish.yml" "${n}" with.image-ref)" == *'steps.push.outputs.digest'* ]]
    platforms+="$(value "${WF}/publish.yml" "${n}" env.TRIVY_PLATFORM) "
  done
  [ "${platforms}" = "linux/amd64 linux/arm64 " ]
  # Each gate's report is checked against the platform it was asked for.
  grep -q 'scripts/check-report-arch.sh trivy-os-amd64.json linux/amd64' "${WF}/publish.yml"
  grep -q 'scripts/check-report-arch.sh trivy-os-arm64.json linux/arm64' "${WF}/publish.yml"
}

@test "the daily scan reads both platforms with the gate's flags, and never fails on a finding" {
  platforms=""
  for n in $(scanner_steps "${WF}/rebuild.yml"); do
    [ "$(value "${WF}/rebuild.yml" "${n}" with.severity)" = "CRITICAL,HIGH" ]
    [ "$(value "${WF}/rebuild.yml" "${n}" with.ignore-unfixed)" = true ]
    [ "$(value "${WF}/rebuild.yml" "${n}" with.vuln-type)" = os ]
    [ "$(value "${WF}/rebuild.yml" "${n}" with.format)" = json ]
    [ "$(value "${WF}/rebuild.yml" "${n}" with.exit-code)" = 0 ]
    [ "$(value "${WF}/rebuild.yml" "${n}" env.TRIVY_IMAGE_SRC)" = remote ]
    platforms+="$(value "${WF}/rebuild.yml" "${n}" env.TRIVY_PLATFORM) "
  done
  [ "${platforms}" = "linux/amd64 linux/arm64 " ]
  grep -q 'scripts/check-report-arch.sh os-amd64.json linux/amd64' "${WF}/rebuild.yml"
  grep -q 'scripts/check-report-arch.sh os-arm64.json linux/arm64' "${WF}/rebuild.yml"
}

@test "every scanner step asks for the pinned Trivy version" {
  for name in "${VERSION_PINNED[@]}"; do
    for n in $(scanner_steps "${WF}/${name}"); do
      [ "$(value "${WF}/${name}" "${n}" with.version)" = "${TRIVY_VERSION}" ]
    done
  done
  # A scanner step without the pin is caught.
  grep -v "version: ${TRIVY_VERSION}" "${WF}/rebuild.yml" > "${WORK}/rebuild.yml"
  first="$(scanner_steps "${WORK}/rebuild.yml" | head -n 1)"
  [ -z "$(value "${WORK}/rebuild.yml" "${first}" with.version)" ]
}

@test "a scanner step that is not a gate cannot fail the publish" {
  for n in $(scanner_steps "${WF}/publish.yml"); do
    if [ "$(value "${WF}/publish.yml" "${n}" with.exit-code)" = 1 ]; then continue; fi
    [ "$(value "${WF}/publish.yml" "${n}" continue-on-error)" = true ]
  done
}

@test "every action in publish.yml and rebuild.yml is pinned by commit, with its version as a comment" {
  for name in publish.yml rebuild.yml; do
    [ "$(steps "${WF}/${name}" | awk -F '\t' '$2 == "uses"' | wc -l)" -ge 2 ]
    run unpinned_actions "${WF}/${name}"
    [ -z "$output" ]
  done
}

@test "an action pinned by tag, by a short hash or without the version comment is caught" {
  sed -E 's/(actions\/checkout)@[0-9a-f]{40} # (v[0-9.]+)/\1@\2/' "${WF}/rebuild.yml" > "${WORK}/tag.yml"
  run unpinned_actions "${WORK}/tag.yml"
  [[ "$output" == *"actions/checkout@v"* ]]
  sed -E 's/(actions\/checkout)@([0-9a-f]{7})[0-9a-f]{33} #/\1@\2 #/' "${WF}/rebuild.yml" > "${WORK}/short.yml"
  run unpinned_actions "${WORK}/short.yml"
  [[ "$output" == *"actions/checkout@"* ]]
  sed -E 's/(actions\/checkout@[0-9a-f]{40}) # v[0-9.]+/\1/' "${WF}/rebuild.yml" > "${WORK}/bare.yml"
  run unpinned_actions "${WORK}/bare.yml"
  [[ "$output" == *"actions/checkout@"* ]]
}

@test "no expression is pasted into a script of publish.yml or rebuild.yml" {
  for name in publish.yml rebuild.yml; do
    [ "$(steps "${WF}/${name}" | awk -F '\t' '$2 == "run"' | wc -l)" -ge 5 ]
    run pasted_expressions "${WF}/${name}"
    [ -z "$output" ]
  done
  # The shape of the defect this guards against: the channel pasted into a script.
  sed 's/docker buildx bake "\$CHANNEL"/docker buildx bake ${{ matrix.channel }}/' "${WF}/publish.yml" > "${WORK}/publish.yml"
  run pasted_expressions "${WORK}/publish.yml"
  [[ "$output" == *'${{ matrix.channel }}'* ]]
}

@test "the channel list reaches the plan through the environment and a tested script" {
  plan="$(steps "${WF}/publish.yml" | awk -F '\t' '$2 == "id" && $3 == "plan" { print $1 }')"
  [ -n "${plan}" ]
  [[ "$(value "${WF}/publish.yml" "${plan}" env.RAW)" == *'inputs.channels'* ]]
  steps "${WF}/publish.yml" | awk -F '\t' -v step="${plan}" '$1 == step && $2 == "run"' | grep -q 'scripts/publish-channels.sh "\$RAW"'
  grep -q 'docker buildx bake --print stable latest | scripts/check-bake-tags.sh' "${WF}/publish.yml"
}

@test "publishes are serialised per channel, not per workflow; scans per channel" {
  # A workflow-level group let a one-channel rebuild request replace a pending two-channel run.
  run ! grep -q '^concurrency:' "${WF}/publish.yml"
  grep -q '^      group: publish-\${{ matrix.channel }}$' "${WF}/publish.yml"
  grep -A1 '^      group: publish-\${{ matrix.channel }}$' "${WF}/publish.yml" | grep -q 'cancel-in-progress: false'
  grep -q '^      group: rebuild-scan-\${{ matrix.channel }}$' "${WF}/rebuild.yml"
  grep -A1 '^      group: rebuild-scan-\${{ matrix.channel }}$' "${WF}/rebuild.yml" | grep -q 'cancel-in-progress: false'
}

@test "the publish build reads and writes no build cache" {
  # A cached `apt-get upgrade` layer would make an OS-patch rebuild publish yesterday's packages.
  run ! grep -q -e 'cache-from' -e 'cache-to' "${WF}/publish.yml"
}

@test "the cron strings of rebuild.yml are the same in the schedule and in the job conditions" {
  [ "$(cron_schedule "${WF}/rebuild.yml" | wc -l)" -eq 2 ]
  [ "$(cron_schedule "${WF}/rebuild.yml")" = "$(cron_conditions "${WF}/rebuild.yml")" ]
  # Editing one side only is caught: the job would silently never run.
  sed 's/- cron: "30 5 \* \* \*"/- cron: "45 5 * * *"/' "${WF}/rebuild.yml" > "${WORK}/rebuild.yml"
  [ "$(cron_schedule "${WORK}/rebuild.yml")" != "$(cron_conditions "${WORK}/rebuild.yml")" ]
}

@test "the documented signing identity is anchored to the main branch" {
  # `...publish.yml@` alone would accept a signature made by this workflow file on any branch.
  run ! grep -q "publish.yml@'" "${WF}/publish.yml"
  grep -q 'publish.yml@refs/heads/main\$' "${WF}/publish.yml"
  run ! grep -q "publish.yml@'" "${ROOT}/docs/evidence.md"
  grep -q 'publish.yml@refs/heads/main\$' "${ROOT}/docs/evidence.md"
}
