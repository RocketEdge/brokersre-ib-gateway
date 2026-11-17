#!/usr/bin/env bats
# Tests that keep the workflows correct for a PRIVATE gateway package (ADR 0018, spec phase 3).
# Needs bash, awk, grep and sed:
#   tests/.bats-core/bin/bats tests/bats/ci
#
# RocketEdge's own image, ghcr.io/rocketedge/brokersre-ib-gateway, is private from phase 4 on:
# an anonymous pull fails, and a pull request from a fork never gets access to it. So:
#   * CI and the sidecar's end-to-end job test an image they built from the commit, under a
#     name no registry serves (nothing can be pulled in its place, not even by accident);
#   * the workflows that do reach the package (publish, the daily scan of rebuild.yml, the
#     paper qualification) log in to ghcr.io with the workflow's token before their first
#     read, in a job whose permissions include packages;
#   * nothing tells the public to pull the image, and nothing sets a package's visibility.
#
# Jobs are read by their text (two-space indentation, one job per `  <name>:` line); their
# steps by workflow-steps.awk, which numbers the steps of the text it is given from 1.
#
# "Must not be there" is written `run ! grep ...`: a bare `! command` that is not the last
# line of a test never fails it (bash exempts negated commands from errexit).

bats_require_minimum_version 1.5.0 # `run !`

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  WF="${ROOT}/.github/workflows"
  LISTER="${BATS_TEST_DIRNAME}/workflow-steps.awk"
  WORK="$(mktemp -d)"
}

teardown() {
  rm -rf "${WORK}"
}

# job FILE NAME: the lines of one job, from the line after `  NAME:` to the next job.
job() {
  awk -v header="  $2:" '$0 == header { inside = 1; next } /^  [A-Za-z0-9_-]+:[ \t]*$/ { inside = 0 } /^[^ #]/ { inside = 0 } inside' "$1"
}

# job_steps FILE NAME: the facts of that job's steps (step number, key, value; tab separated).
job_steps() {
  job "$1" "$2" | awk -f "${LISTER}"
}

# step_where FILE JOB KEY VALUE: the number of the first step of JOB whose KEY equals VALUE.
step_where() {
  job_steps "$1" "$2" | awk -F '\t' -v key="$3" -v want="$4" '$2 == key && $3 == want { print $1; exit }'
}

# login_step FILE JOB: the number of the first step of JOB that logs in to ghcr.io with the
# workflow's own token and runs whatever happened before it (no `if:`).
login_step() {
  job_steps "$1" "$2" | awk -F '\t' '
    $2 == "uses" && $3 ~ /^docker\/login-action@/ { candidate[$1] = 1 }
    $2 == "with.registry" && $3 == "ghcr.io" { registry[$1] = 1 }
    $2 == "with.password" && $3 == "${{ secrets.GITHUB_TOKEN }}" { token[$1] = 1 }
    $2 == "if" { conditional[$1] = 1 }
    END {
      first = 0
      for (n in candidate) {
        if (registry[n] && token[n] && !conditional[n] && (first == 0 || n + 0 < first)) first = n + 0
      }
      if (first > 0) print first
    }'
}

# logs_in_before FILE JOB MARKER_KEY MARKER_VALUE: fail (and say why) unless JOB logs in to
# ghcr.io, unconditionally, before the step whose MARKER_KEY is MARKER_VALUE, and unless the
# job's permissions name packages.
logs_in_before() {
  local file="$1" name="$2" marker login
  marker="$(step_where "${file}" "${name}" "$3" "$4")"
  login="$(login_step "${file}" "${name}")"
  if [ -z "${marker}" ]; then
    echo "$(basename "${file}") ${name}: no step with $3 '$4'"
    return 1
  fi
  if [ -z "${login}" ] || [ "${login}" -ge "${marker}" ]; then
    echo "$(basename "${file}") ${name}: no unconditional ghcr.io login with GITHUB_TOKEN before step ${marker} ($4)"
    return 1
  fi
  if ! job "${file}" "${name}" | grep -q -E '^      packages: (read|write)[ \t]*(#.*)?$'; then
    echo "$(basename "${file}") ${name}: the job's permissions do not name packages"
    return 1
  fi
}

# package_workflows: the workflows that name the gateway package (not the sidecar's).
package_workflows() {
  grep -l -E 'ghcr\\?\.io/rocketedge/brokersre-ib-gateway([^-]|$)' "${WF}"/*.yml | sed 's|.*/||' | sort
}

@test "only publish, rebuild and qualify-paper name RocketEdge's gateway package" {
  [ "$(package_workflows)" = "$(printf '%s\n' publish.yml qualify-paper.yml rebuild.yml)" ]
}

@test "CI tests an image it built, under a name no registry serves, and Trivy reads it from the local daemon" {
  name="$(job "${WF}/ci.yml" build-test | sed -n 's/^      TEST_IMAGE: *//p')"
  [ "${name}" = "brokersre-ib-gateway:stable" ]
  run awk -f "${LISTER}" "${WF}/ci.yml"
  scanners="$(printf '%s\n' "${output}" | awk -F '\t' '$2 == "uses" && $3 ~ /^aquasecurity\/trivy-action@/ { print $1 }')"
  [ "$(printf '%s\n' "${scanners}" | wc -l)" -eq 3 ]
  for n in ${scanners}; do
    [ "$(printf '%s\n' "${output}" | awk -F '\t' -v step="${n}" '$1 == step && $2 == "env.TRIVY_IMAGE_SRC" { print $3 }')" = docker ]
  done
}

@test "the sidecar's end-to-end job builds the gateway image with the build helper, also for forks" {
  text="$(job "${WF}/sidecar.yml" e2e)"
  [ -n "${text}" ]
  [ "$(printf '%s\n' "${text}" | sed -n 's/^      TEST_IMAGE: *//p')" = "brokersre-ib-gateway:stable" ]
  [[ "${text}" == *'scripts/build-image.sh --channel stable --platform linux/amd64 --tag "$TEST_IMAGE"'* ]]
  # No archive pre-fetch and no repository secret: a pull request from a fork runs the job.
  [[ "${text}" != *"prefetch-installers.sh"* ]]
  [[ "${text}" != *"ARCHIVE_READ_TOKEN"* ]]
  [[ "${text}" != *"docker buildx bake"* ]]
  run ! grep -q -E '^    if:' <<<"${text}"
  [[ "${text}" == *'sidecar/tests/e2e/fresh-volumes.sh "$TEST_IMAGE" "$SIDECAR_IMAGE"'* ]]
  [[ "${text}" == *'sidecar/tests/e2e/run.sh "$TEST_IMAGE" "$SIDECAR_IMAGE"'* ]]
}

@test "a change to the build helper starts the sidecar workflow on a push and on a pull request" {
  for event in push pull_request; do
    paths="$(awk -v event="  ${event}:" '$0 == event { inside = 1; next } /^  [a-z_]+:/ || /^[^ ]/ { inside = 0 } inside' "${WF}/sidecar.yml")"
    for input in scripts/build-image.sh scripts/resolve-installer.sh 'scripts/build-helper/**' scripts/fetch-installer.sh tests/container/run.sh; do
      printf '%s\n' "${paths}" | grep -q -x -F "      - ${input}"
    done
  done
}
