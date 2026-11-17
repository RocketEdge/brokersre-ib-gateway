#!/usr/bin/env bats
# Tests that keep the workflows correct for a gateway package that is NOT PUBLIC (ADR 0018, spec
# phase 3; private or internal, docs/limitations.md L40). Needs bash, awk, grep and sed:
#   tests/.bats-core/bin/bats tests/bats/ci
#
# RocketEdge's own image, ghcr.io/rocketedge/brokersre-ib-gateway, is not public from phase 4 on:
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
  # The step that receives the token is pinned by commit, with its version as a comment.
  if ! job_steps "${file}" "${name}" | awk -F '\t' -v step="${login}" '$1 == step && $2 == "uses"' \
    | grep -q -E 'docker/login-action@[0-9a-f]{40} # v[0-9]+(\.[0-9]+)*$'; then
    echo "$(basename "${file}") ${name}: the login action is not pinned by commit"
    return 1
  fi
}

# workflow_jobs FILE: the names of the jobs of a workflow, in order.
workflow_jobs() {
  awk '/^jobs:/ { inside = 1; next } /^[^ #]/ { inside = 0 } inside && /^  [A-Za-z0-9_-]+:[ \t]*$/ { name = $1; sub(/:$/, "", name); print name }' "$1"
}

# job_needs FILE JOB: the jobs JOB needs, one per line (`needs: x` or `needs: [x, y]`).
job_needs() {
  job "$1" "$2" | sed -n -E 's/^    needs: *//p' | tr -d '[]' | tr ',' '\n' | sed -E 's/^ +| +$//g' | sed '/^$/d'
}

# gate_problems FILE: print every job of FILE (a publish workflow) that may write packages but
# does not wait for the job private-package, or that has a job condition (`if:`) under which it
# could run after the gate failed; fail when there is one, or when no such job exists at all.
gate_problems() {
  local file="$1" name writers=0 bad=0
  for name in $(workflow_jobs "${file}"); do
    [ "${name}" = private-package ] && continue
    if job "${file}" "${name}" | grep -q -E '^      packages: write'; then
      writers=$((writers + 1))
      if ! job_needs "${file}" "${name}" | grep -q -x private-package; then
        echo "${name} does not wait for private-package"
        bad=1
      fi
      if job "${file}" "${name}" | grep -q -E '^    if:'; then
        echo "${name} has a job condition: it could run after the gate failed"
        bad=1
      fi
    fi
  done
  if [ "${writers}" -eq 0 ]; then
    echo "no job writes packages: the check found nothing to check"
    bad=1
  fi
  return "${bad}"
}

# GATE_STEPS: "<job> <step id>" of every step that runs scripts/check-package-private.sh in
# publish.yml; each must stop its job unless the script exits 0. The second runs inside
# publish, right before the push, in case GitHub applies a visibility change late.
GATE_STEPS=("private-package anonymous" "publish still-private")

# gate_switch_problems FILE: print every way the visibility gate of FILE (a publish workflow)
# is switched off, and fail when there is one:
#   * a gate step that lets an exit other than 0 pass (a case arm that does nothing other than
#     `0) ;;`, fewer than two `exit 1`, `|| true`), or that does not run the script as written;
#   * `continue-on-error` on a gate step, anywhere in the job private-package, or on the job
#     publish (its non-gating Trivy steps keep theirs);
#   * a job condition on publish (it could run after a failed `needs`).
gate_switch_problems() {
  local file="$1" spec gate_job gate_id n script arms bad=0
  if job "${file}" private-package | grep -q -E '^ +continue-on-error:'; then
    echo "private-package has continue-on-error"
    bad=1
  fi
  if job "${file}" publish | grep -q -E '^    (continue-on-error|if):'; then
    echo "publish has a job-level continue-on-error or if"
    bad=1
  fi
  for spec in "${GATE_STEPS[@]}"; do
    gate_job="${spec% *}"
    gate_id="${spec#* }"
    n="$(step_where "${file}" "${gate_job}" id "${gate_id}")"
    if [ -z "${n}" ]; then
      echo "${gate_job}: no step ${gate_id}"
      bad=1
      continue
    fi
    if job_steps "${file}" "${gate_job}" | awk -F '\t' -v step="${n}" '$1 == step && $2 == "continue-on-error"' | grep -q .; then
      echo "${gate_job} ${gate_id}: continue-on-error"
      bad=1
    fi
    script="$(job_steps "${file}" "${gate_job}" | awk -F '\t' -v step="${n}" '$1 == step && $2 == "run" { print $3 }')"
    if ! grep -q -F 'scripts/check-package-private.sh "${IMAGE#ghcr.io/}" visibility-probe || rc=$?' <<<"${script}"; then
      echo "${gate_job} ${gate_id}: does not run the check as written"
      bad=1
    fi
    arms="$(grep -E '^ *[^ #][^)]*\) *;; *$' <<<"${script}" | sed -E 's/^ +//')"
    if [ "${arms}" != "0) ;;" ]; then
      echo "${gate_job} ${gate_id}: passes on '${arms//$'\n'/ | }', expected exit 0 only"
      bad=1
    fi
    if [ "$(grep -c -E '^ *exit 1$' <<<"${script}")" -lt 2 ] || grep -q -F '|| true' <<<"${script}"; then
      echo "${gate_job} ${gate_id}: an exit other than 0 does not stop the job"
      bad=1
    fi
  done
  return "${bad}"
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

# pulling_steps FILE: print every script line of FILE that pulls an image: `docker pull`,
# `docker image pull`, a compose `pull`, or a compose `up`/`run`/`create` with `--pull`
# (an indirect pull through a compose file's default image, the review's mutation M9).
pulling_steps() {
  awk -f "${LISTER}" "$1" | awk -F '\t' '$2 == "run" { print "step " $1 ": " $3 }' \
    | grep -E 'docker (image )?pull |(docker[ -])?compose([^|;&]*)? pull( |$)|(docker[ -])?compose[^|;&]* (up|run|create)[^|;&]*--pull' || true
}

@test "no workflow pulls an image in a script, except the qualification's pull of the digest it was given" {
  for file in "${WF}"/*.yml; do
    found="$(pulling_steps "${file}")"
    if [ "$(basename "${file}")" = qualify-paper.yml ]; then
      [ "${found}" = "$(printf '%s\n' "${found}" | grep -F 'docker pull "${IMAGE}"')" ]
      [ "$(printf '%s\n' "${found}" | grep -c .)" -eq 1 ]
    else
      [ -z "${found}" ] || { echo "$(basename "${file}"): ${found}"; false; }
    fi
  done
  # The shapes are caught: a compose pull with the shipped file's default image, `up --pull`.
  for line in 'docker compose -f compose/docker-compose.example.yml pull' \
    'docker compose -f compose/docker-compose.example.yml up -d --pull always' \
    'docker-compose pull ib-gateway' 'docker pull ghcr.io/rocketedge/brokersre-ib-gateway:stable'; do
    printf '%s\n' 'jobs:' '  x:' '    steps:' "      - run: ${line}" > "${WORK}/pull.yml"
    [ -n "$(pulling_steps "${WORK}/pull.yml")" ] || { echo "not caught: ${line}"; false; }
  done
}

@test "every job that reads the package logs in to ghcr.io with the workflow's token first" {
  run logs_in_before "${WF}/publish.yml" publish id push
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run logs_in_before "${WF}/rebuild.yml" scan-published id published
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run logs_in_before "${WF}/qualify-paper.yml" qualify name "Pull the image"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "a login that is missing, conditional, late or without the permission is caught" {
  # Without any login step.
  awk '/^      - / { skip = ($0 ~ /docker\/login-action@/) } !skip' "${WF}/rebuild.yml" > "${WORK}/missing.yml"
  run logs_in_before "${WORK}/missing.yml" scan-published id published
  [ "$status" -eq 1 ]
  [[ "$output" == *"no unconditional ghcr.io login"* ]]
  # The shape qualify-paper.yml had before: a login only for the attestation (`if:`).
  awk '{ print } /^      - uses: docker\/login-action@/ { print "        if: success() && inputs.attest" }' "${WF}/qualify-paper.yml" > "${WORK}/conditional.yml"
  run logs_in_before "${WORK}/conditional.yml" qualify name "Pull the image"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no unconditional ghcr.io login"* ]]
  # A login after the first read.
  run logs_in_before "${WF}/publish.yml" publish name "The index holds exactly one image per platform (scripts/platform-digests.sh)"
  [ "$status" -eq 0 ]
  run logs_in_before "${WF}/publish.yml" publish uses "docker/setup-buildx-action@f87e5991a6d7451dcb8d9637bfbc97413f497069 # v4.4.1"
  [ "$status" -eq 1 ]
  # A job whose permissions do not name packages.
  sed '/^      packages:/d' "${WF}/rebuild.yml" > "${WORK}/rebuild.yml"
  run logs_in_before "${WORK}/rebuild.yml" scan-published id published
  [ "$status" -eq 1 ]
  [[ "$output" == *"do not name packages"* ]]
}

@test "the paper qualification logs in and pulls before the credential files exist" {
  credentials="$(step_where "${WF}/qualify-paper.yml" qualify name "Write the paper credentials to files")"
  pull="$(step_where "${WF}/qualify-paper.yml" qualify name "Pull the image")"
  login="$(login_step "${WF}/qualify-paper.yml" qualify)"
  [ -n "${credentials}" ] && [ -n "${pull}" ] && [ -n "${login}" ]
  [ "${login}" -lt "${pull}" ]
  [ "${pull}" -lt "${credentials}" ]
  # A tag-pinned login is caught.
  sed -E 's/docker\/login-action@[0-9a-f]{40} # (v[0-9.]+)/docker\/login-action@\1/' "${WF}/qualify-paper.yml" > "${WORK}/tag.yml"
  run logs_in_before "${WORK}/tag.yml" qualify name "Pull the image"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not pinned by commit"* ]]
}

@test "the paper qualification still takes a digest only, from main only, behind its environment" {
  text="$(job "${WF}/qualify-paper.yml" qualify)"
  [[ "${text}" == *'"${IMAGE}" =~ ^ghcr\.io/rocketedge/brokersre-ib-gateway@sha256:[0-9a-f]{64}$'* ]]
  [[ "${text}" == *'if [ "${GITHUB_REF}" != "refs/heads/main" ]; then'* ]]
  printf '%s\n' "${text}" | grep -q -x '    environment: paper-qualification'
  # The digest check is the job's first step: nothing, not even the login, comes before it.
  [ "$(step_where "${WF}/qualify-paper.yml" qualify name "Only from main, only by digest")" -eq 1 ]
  run ! grep -q -E '^  (pull_request|pull_request_target|push|schedule):' "${WF}/qualify-paper.yml"
}

@test "the release notes tell nobody to pull the image and name the way to build it" {
  run awk -f "${LISTER}" "${WF}/publish.yml"
  release="$(printf '%s\n' "${output}" | awk -F '\t' '$2 == "name" && $3 == "Tag and release" { print $1 }')"
  [ -n "${release}" ]
  notes="$(printf '%s\n' "${output}" | awk -F '\t' -v step="${release}" '$1 == step && $2 == "run" { print $3 }')"
  [[ "${notes}" != *"Pin this exact build"* ]]
  # No pull instruction of any kind (the review's mutation M7: `docker pull $IMAGE@$DIGEST`):
  # the only "pull" the notes may contain is "cannot be pulled".
  run ! grep -q -i -E '(docker|podman|nerdctl|crane|oras|skopeo)( image)? (pull|copy|run)|compose[^"]* (pull|up)' <<<"${notes}"
  run ! grep -q -i 'pull' <<<"${notes//cannot be pulled/}"
  # True for a private and an internal package alike (L40): never "private".
  [[ "${notes}" == *"is not public"* ]]
  [[ "${notes}" != *"private"* ]]
  [[ "${notes}" == *"scripts/build-image.sh --channel \$CHANNEL"* ]]
  # The notes still carry the digest RocketEdge pins, and the release is checked for it.
  [[ "${notes}" == *'$IMAGE@$DIGEST'* ]]
  [[ "${notes}" == *'--expect-in-notes "$DIGEST"'* ]]
}

@test "publish.yml proves the package is not public before any job can push the gateway image" {
  text="$(job "${WF}/publish.yml" private-package)"
  [ -n "${text}" ]
  run logs_in_before "${WF}/publish.yml" private-package id probe
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  probe="$(step_where "${WF}/publish.yml" private-package id probe)"
  check="$(step_where "${WF}/publish.yml" private-package id anonymous)"
  [ -n "${check}" ]
  [ "${probe}" -lt "${check}" ]
  facts="$(job_steps "${WF}/publish.yml" private-package)"
  probe_script="$(printf '%s\n' "${facts}" | awk -F '\t' -v step="${probe}" '$1 == step && $2 == "run" { print $3 }')"
  check_script="$(printf '%s\n' "${facts}" | awk -F '\t' -v step="${check}" '$1 == step && $2 == "run" { print $3 }')"
  # The placeholder: FROM scratch and a text file, pushed under its own tag; nothing of IBKR's.
  [[ "${probe_script}" == *"'FROM scratch'"* ]]
  [[ "${probe_script}" == *'docker push "$IMAGE:visibility-probe"'* ]]
  [[ "${probe_script}" != *"bake"* ]]
  [[ "${probe_script}" != *"downloads"* ]]
  [[ "${probe_script}" != *"installer"* ]]
  [[ "${check_script}" == *'scripts/check-package-private.sh "${IMAGE#ghcr.io/}" visibility-probe'* ]]
  run gate_problems "${WF}/publish.yml"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # No other workflow pushes to the gateway package.
  run ! grep -l -E 'docker push|push=true|--push' "${WF}/rebuild.yml" "${WF}/qualify-paper.yml" "${WF}/detect-releases.yml" "${WF}/ci.yml"
}

@test "the visibility gate cannot be switched off: exit 0 only, no continue-on-error, no job condition" {
  run gate_switch_problems "${WF}/publish.yml"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "publish checks the package again immediately before it pushes the gateway image" {
  check="$(step_where "${WF}/publish.yml" publish id still-private)"
  push="$(step_where "${WF}/publish.yml" publish id push)"
  [ -n "${check}" ] && [ -n "${push}" ]
  [ "${check}" -eq $((push - 1)) ]
  # The check is unconditional: no `if:` lets it be skipped.
  [ -z "$(job_steps "${WF}/publish.yml" publish | awk -F '\t' -v step="${check}" '$1 == step && $2 == "if"')" ]
  # Nothing before it in publish pushes to the registry.
  run ! grep -q -E 'docker push|push=true|--push|imagetools create' <<<"$(job_steps "${WF}/publish.yml" publish | awk -F '\t' -v step="${check}" '$1 < step && $2 == "run" { print $3 }')"
}

@test "the review's ways to switch the gate off are caught (G2: exit 3 passes; G3: continue-on-error)" {
  # G2: "inconclusive" passes.
  sed 's/^            0) ;;$/            0 | 3) ;;/' "${WF}/publish.yml" > "${WORK}/g2.yml"
  run ! cmp -s "${WF}/publish.yml" "${WORK}/g2.yml"
  run gate_switch_problems "${WORK}/g2.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"expected exit 0 only"* ]]
  # G3: continue-on-error on the gate step, on the gate job, on publish.
  awk '{ print } /^        id: anonymous$/ { print "        continue-on-error: true" }' "${WF}/publish.yml" > "${WORK}/g3-step.yml"
  run gate_switch_problems "${WORK}/g3-step.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"continue-on-error"* ]]
  awk '{ print } /^  private-package:$/ { print "    continue-on-error: true" }' "${WF}/publish.yml" > "${WORK}/g3-job.yml"
  run gate_switch_problems "${WORK}/g3-job.yml"
  [ "$status" -eq 1 ]
  awk '{ print } /^  publish:$/ { print "    continue-on-error: true" }' "${WF}/publish.yml" > "${WORK}/g3-publish.yml"
  run gate_switch_problems "${WORK}/g3-publish.yml"
  [ "$status" -eq 1 ]
  # The failure arms that stop the job, removed or neutralised.
  sed 's/scripts\/check-package-private.sh "${IMAGE#ghcr.io\/}" visibility-probe || rc=\$?/scripts\/check-package-private.sh "${IMAGE#ghcr.io\/}" visibility-probe || true/' "${WF}/publish.yml" > "${WORK}/true.yml"
  run gate_switch_problems "${WORK}/true.yml"
  [ "$status" -eq 1 ]
}

@test "a publish job that does not wait for the gate, or runs after it failed, is caught" {
  sed 's/^    needs: \[plan, private-package\]$/    needs: plan/' "${WF}/publish.yml" > "${WORK}/publish.yml"
  run gate_problems "${WORK}/publish.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"publish does not wait for private-package"* ]]
  awk '{ print } /^  publish:$/ { print "    if: always()" }' "${WF}/publish.yml" > "${WORK}/always.yml"
  run gate_problems "${WORK}/always.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"publish has a job condition"* ]]
}

@test "no workflow step changes the visibility of a package" {
  # Scripts and inputs of every step (comments are not steps): nothing may make the package
  # public. What sets a visibility: an API field (`-f visibility=public`, `"visibility":`), an
  # option (`--visibility`); the tag `visibility-probe` and words in messages do not.
  pattern='visibility["'"'"']?[[:space:]]*[:=]|--visibility'
  for file in "${WF}"/*.yml; do
    run ! grep -q -i -E "${pattern}" <<<"$(awk -f "${LISTER}" "${file}")"
  done
  # The check reads scripts: a step that sets the visibility is caught.
  printf '%s\n' 'jobs:' '  x:' '    steps:' '      - run: gh api -X PATCH orgs/o/packages/container/p -f visibility=public' > "${WORK}/visible.yml"
  grep -q -i -E "${pattern}" <<<"$(awk -f "${LISTER}" "${WORK}/visible.yml")"
  printf '%s\n' 'jobs:' '  x:' '    steps:' '      - run: echo '"'"'{"visibility": "public"}'"'"' | gh api -X PATCH p --input -' > "${WORK}/json.yml"
  grep -q -i -E "${pattern}" <<<"$(awk -f "${LISTER}" "${WORK}/json.yml")"
}
