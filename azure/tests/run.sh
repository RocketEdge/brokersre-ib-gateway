#!/usr/bin/env bash
# Offline test suite of the Azure Log Analytics pack (azure/, compose/docker-compose.azure.yml).
#
# Nothing here logs in to Azure, creates a resource or contacts IBKR: Vector runs with
# --network none against fixtures, Bicep is compiled locally, and every helper tool runs from a
# pinned container image so the same command works on the CI runner and on a Windows host.
#
# Usage:   azure/tests/run.sh [group...]
# Groups:  vector      vector validate + the VRL unit tests (vector test), every raw-log mode
#          entrypoint  azure/vector/entrypoint.sh: refusals, rendering, no secret in its output
#          (default: every group, in this order)
# Needs:   docker; az with the Bicep CLI for the bicep group.
# Exit:    0 when every selected test passed. Each test prints PASS/FAIL with its reason.
# Containers and volumes created here are named azpack-*; nothing else is touched.
set -uo pipefail
# Git Bash on Windows rewrites POSIX-looking arguments into Windows paths; keep docker's
# container-side paths literal and convert only host paths explicitly (no-op on Linux).
export MSYS_NO_PATHCONV=1

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "${here}/../.." && pwd)"

# host_path <path>: the path as the Docker daemon must see it in -v (C:/... on Windows).
host_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}
host_repo="$(host_path "${repo}")"

compose_azure="${repo}/compose/docker-compose.azure.yml"
# The image pin lives in exactly one place (the compose override); the tests run that image.
VECTOR_IMAGE="${VECTOR_IMAGE:-$(sed -n 's/^[[:space:]]*image:[[:space:]]*\(timberio\/vector[^[:space:]]*\).*/\1/p' "${compose_azure}" 2>/dev/null | head -n 1)}"

# Canary identifiers: obviously fake, used to prove that redaction works and nothing leaks.
CANARY_USERNAME=CANARY_USER_zq7

failures=0
pass() { echo "PASS  $1"; }
fail() {
  echo "FAIL  $1: $2"
  failures=$((failures + 1))
}
show() { printf '%s\n' "$1" | tail -n 40 | sed 's/^/      /'; }

# check <name> <command...>: PASS when the command exits 0, else FAIL with its last output.
check() {
  local name="$1" out code
  shift
  out="$("$@" 2>&1)"
  code=$?
  if [[ ${code} -eq 0 ]]; then
    pass "${name}"
  else
    fail "${name}" "exit ${code}"
    show "${out}"
  fi
}

# expect_refusal <name> <text> <command...>: PASS when the command exits 78 (configuration
# error) and its output contains <text>.
expect_refusal() {
  local name="$1" text="$2" out code
  shift 2
  out="$("$@" 2>&1)"
  code=$?
  if [[ ${code} -eq 78 && "${out}" == *"${text}"* ]]; then
    pass "${name}"
  else
    fail "${name}" "exit ${code}, expected 78 and a message containing '${text}'"
    show "${out}"
  fi
}

# Throwaway secrets for the tests: a canary user name and a dummy certificate file. They live
# in a temporary directory outside the repository and are removed on exit.
work_dir="$(mktemp -d)"
secrets_dir="${work_dir}/secrets"
mkdir -p "${secrets_dir}"
printf '%s\n' "${CANARY_USERNAME}" >"${secrets_dir}/ib-username"
printf 'dummy-password-not-real\n' >"${secrets_dir}/ib-password"
printf 'not a real certificate\n' >"${secrets_dir}/azure-client-cert.pfx"
: >"${secrets_dir}/empty"
# mktemp -d creates a 0700 directory; uid 1000 inside the container must be able to read it
# (bind mounts keep host permissions on Linux hosts such as the CI runner).
chmod 0755 "${work_dir}" "${secrets_dir}" && chmod 0644 "${secrets_dir}"/*
host_secrets="$(host_path "${secrets_dir}")"

# shellcheck disable=SC2317,SC2329  # invoked through the EXIT trap
cleanup() {
  docker ps -aq --filter "name=^azpack-" 2>/dev/null | while read -r id; do
    docker rm -f "${id}" >/dev/null 2>&1 || true
  done
  docker volume ls -q --filter "name=^azpack-" 2>/dev/null | while read -r volume; do
    docker volume rm "${volume}" >/dev/null 2>&1 || true
  done
  rm -rf "${work_dir}"
}
trap cleanup EXIT

run_id="$$"
valid_env=(
  -e AZURE_AUTH=managed-identity
  -e DCR_LOGS_ENDPOINT=https://example-abcd.eastus-1.ingest.monitor.azure.com
  -e DCR_IMMUTABLE_ID=dcr-00000000000000000000000000000000
  -e IBGW_INSTANCE=test-instance -e HOST_LABEL=test-host
)
cert_env=(
  -e AZURE_AUTH=certificate
  -e AZURE_TENANT_ID=00000000-0000-0000-0000-000000000000
  -e AZURE_CLIENT_ID=11111111-1111-1111-1111-111111111111
  -e AZURE_CLIENT_CERTIFICATE_PATH=/run/secrets/azure-client-cert.pfx
)
rendered=/var/tmp/vector-config/sinks.yaml
unit_config=(/etc/vector/vector.yaml "${rendered}")

# vector_container <docker-args...> -- <command...>: the pinned Vector image with the
# production hardening (uid 1000, read-only root, no capability, no network), azure/vector
# mounted where the compose override mounts it, the throwaway secrets, and a writable /var/tmp.
vector_container() {
  local docker_args=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    docker_args+=("$1")
    shift
  done
  shift
  docker run --rm --name "azpack-unit-${run_id}" --network none --user 1000:1000 --read-only \
    --cap-drop ALL --security-opt no-new-privileges:true \
    --tmpfs /var/tmp:rw,mode=1777 \
    -v "${host_repo}/azure/vector:/etc/vector:ro" \
    -v "${host_secrets}:/run/secrets:ro" \
    "${docker_args[@]}" --entrypoint /bin/sh "${VECTOR_IMAGE}" "$@"
}

# entrypoint <docker-args...> -- <vector-args...>: run Vector the way the compose service does.
entrypoint() {
  local docker_args=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    docker_args+=("$1")
    shift
  done
  shift
  vector_container "${docker_args[@]}" -- /etc/vector/entrypoint.sh "$@"
}

# forced_mode <mode> <username> <test file>: render the configuration through the entrypoint,
# then run the unit tests with IBGW_RAW_MODE / IBGW_REDACT_USERNAME forced to values the
# entrypoint itself never produces (to prove the mapping fails closed on its own).
forced_mode() {
  vector_container "${valid_env[@]}" -e FORCED_MODE="$1" -e FORCED_USERNAME="$2" -e TEST_FILE="$3" -- -c '
    /bin/sh /etc/vector/entrypoint.sh --version >/dev/null 2>&1 || exit 70
    if [ -n "${FORCED_USERNAME}" ]; then export IBGW_REDACT_USERNAME="${FORCED_USERNAME}"; fi
    IBGW_RAW_MODE="${FORCED_MODE}" exec /usr/local/bin/vector test \
      /etc/vector/vector.yaml /var/tmp/vector-config/sinks.yaml "${TEST_FILE}"'
}

group_vector() {
  echo "== vector: validate and unit tests (${VECTOR_IMAGE})"
  if [[ -z "${VECTOR_IMAGE}" ]]; then
    fail "vector image pin" "no timberio/vector image line in ${compose_azure}"
    return
  fi
  check "vector validate (managed identity)" \
    entrypoint "${valid_env[@]}" -- validate --no-environment
  check "vector validate (certificate)" \
    entrypoint "${valid_env[@]}" "${cert_env[@]}" -- validate --no-environment

  check "vector test: events" \
    entrypoint "${valid_env[@]}" -- test "${unit_config[@]}" /etc/vector/tests/events.test.yaml
  check "vector test: metrics" \
    entrypoint "${valid_env[@]}" -- test "${unit_config[@]}" /etc/vector/tests/metrics.test.yaml
  check "vector test: raw logs are not shipped by default" \
    entrypoint "${valid_env[@]}" -- test "${unit_config[@]}" /etc/vector/tests/raw-disabled.test.yaml
  check "vector test: raw logs with user-name redaction (IBGW_REDACT_USERNAME_FILE)" \
    entrypoint "${valid_env[@]}" -e IBGW_REDACT_USERNAME_FILE=/run/secrets/ib-username -- \
    test "${unit_config[@]}" /etc/vector/tests/raw-redacted.test.yaml
  check "vector test: raw logs after SHIP_RAW_LOGS=yes" \
    entrypoint "${valid_env[@]}" -e SHIP_RAW_LOGS=yes -- \
    test "${unit_config[@]}" /etc/vector/tests/raw-acknowledged.test.yaml
  check "vector test: an unknown raw mode ships nothing" \
    forced_mode everything "${CANARY_USERNAME}" /etc/vector/tests/raw-failclosed.test.yaml
  check "vector test: redacted mode without a user name ships nothing" \
    forced_mode redacted "" /etc/vector/tests/raw-failclosed.test.yaml
}

# sinks_without_auth <file>: the sink template without comments and without its auth blocks.
sinks_without_auth() {
  awk '
    /^[[:space:]]*#/ { next }
    /^    auth:[[:space:]]*$/ { in_auth = 1; next }
    in_auth && /^      / { next }
    { in_auth = 0; print }
  ' "$1"
}

group_entrypoint() {
  echo "== entrypoint: refusals, rendering, nothing secret in the output"
  local out

  expect_refusal "refuses a missing AZURE_AUTH" "AZURE_AUTH" \
    entrypoint -e DCR_LOGS_ENDPOINT=https://example.invalid \
    -e DCR_IMMUTABLE_ID=dcr-00000000000000000000000000000000 -- validate --no-environment
  expect_refusal "refuses an http:// endpoint" "DCR_LOGS_ENDPOINT" \
    entrypoint "${valid_env[@]}" -e DCR_LOGS_ENDPOINT=http://example.invalid -- validate --no-environment
  expect_refusal "refuses an endpoint that could break out of the YAML string" "DCR_LOGS_ENDPOINT" \
    entrypoint "${valid_env[@]}" -e 'DCR_LOGS_ENDPOINT=https://example.invalid"|x&y' -- validate --no-environment
  expect_refusal "refuses a missing endpoint" "DCR_LOGS_ENDPOINT" \
    entrypoint -e AZURE_AUTH=managed-identity \
    -e DCR_IMMUTABLE_ID=dcr-00000000000000000000000000000000 -- validate --no-environment
  expect_refusal "refuses a malformed immutable id" "DCR_IMMUTABLE_ID" \
    entrypoint "${valid_env[@]}" -e DCR_IMMUTABLE_ID=dcr-123 -- validate --no-environment
  expect_refusal "certificate: refuses a missing tenant id" "AZURE_TENANT_ID" \
    entrypoint "${valid_env[@]}" "${cert_env[@]}" -e AZURE_TENANT_ID= -- validate --no-environment
  expect_refusal "certificate: refuses a client id that is not a GUID" "AZURE_CLIENT_ID" \
    entrypoint "${valid_env[@]}" "${cert_env[@]}" -e AZURE_CLIENT_ID=my-app -- validate --no-environment
  expect_refusal "certificate: refuses a missing certificate file" "AZURE_CLIENT_CERTIFICATE_PATH" \
    entrypoint "${valid_env[@]}" "${cert_env[@]}" -e AZURE_CLIENT_CERTIFICATE_PATH=/run/secrets/absent.pfx -- validate --no-environment
  expect_refusal "refuses a user-name file that does not exist" "IBGW_REDACT_USERNAME_FILE" \
    entrypoint "${valid_env[@]}" -e IBGW_REDACT_USERNAME_FILE=/run/secrets/absent -- validate --no-environment
  expect_refusal "refuses an empty user-name file" "IBGW_REDACT_USERNAME_FILE" \
    entrypoint "${valid_env[@]}" -e IBGW_REDACT_USERNAME_FILE=/run/secrets/empty -- validate --no-environment

  out="$(docker run --rm --name "azpack-unit-${run_id}" --network none --user 1000:1000 --read-only \
    --cap-drop ALL -v "${host_repo}/azure/vector:/etc/vector:ro" "${valid_env[@]}" \
    --entrypoint /bin/sh "${VECTOR_IMAGE}" /etc/vector/entrypoint.sh validate --no-environment 2>&1)"
  if [[ $? -eq 78 && "${out}" == *"/var/tmp is not writable"* ]]; then
    pass "refuses to start without a writable /var/tmp"
  else
    fail "refuses to start without a writable /var/tmp" "expected exit 78 and a clear message"
    show "${out}"
  fi

  # Comment lines are left out: the template's header mentions the placeholder syntax.
  out="$(vector_container "${valid_env[@]}" "${cert_env[@]}" -- -c "
    /bin/sh /etc/vector/entrypoint.sh --version >/dev/null 2>&1 || exit 70
    grep -v '^[[:space:]]*#' ${rendered}" 2>&1)"
  if [[ "${out}" == *"sinks:"* && "${out}" != *"__"* &&
    "${out}" == *'endpoint: "https://example-abcd.eastus-1.ingest.monitor.azure.com"'* &&
    "${out}" == *'dcr_immutable_id: "dcr-00000000000000000000000000000000"'* &&
    "${out}" == *'azure_tenant_id: "00000000-0000-0000-0000-000000000000"'* &&
    "${out}" == *'azure_client_id: "11111111-1111-1111-1111-111111111111"'* &&
    "${out}" == *'certificate_path: "/run/secrets/azure-client-cert.pfx"'* ]]; then
    pass "renders every placeholder of the certificate template"
  else
    fail "renders every placeholder of the certificate template" "unexpected rendered file"
    show "${out}"
  fi

  out="$(entrypoint "${valid_env[@]}" -e IBGW_REDACT_USERNAME_FILE=/run/secrets/ib-username -- validate --no-environment 2>&1)"
  if [[ $? -eq 0 && "${out,,}" != *"${CANARY_USERNAME,,}"* && "${out}" == *"[USER]"* ]]; then
    pass "never prints the user name it read"
  else
    fail "never prints the user name it read" "user name in the output, or validation failed"
    show "${out//${CANARY_USERNAME}/<CANARY>}"
  fi

  out="$(entrypoint "${valid_env[@]}" -e SHIP_RAW_LOGS=yes -- validate --no-environment 2>&1)"
  if [[ $? -eq 0 && "${out}" == *'"level":"warn"'*"NOT redacted"* ]]; then
    pass "warns when raw logs are shipped without user-name redaction"
  else
    fail "warns when raw logs are shipped without user-name redaction" "no warning"
    show "${out}"
  fi

  out="$(diff <(sinks_without_auth "${repo}/azure/vector/sinks-managed-identity.yaml") \
    <(sinks_without_auth "${repo}/azure/vector/sinks-certificate.yaml") 2>&1)"
  if [[ $? -eq 0 ]]; then
    pass "the two sink templates differ only in their auth blocks"
  else
    fail "the two sink templates differ only in their auth blocks" "they drifted apart"
    show "${out}"
  fi
}

groups=("$@")
if [[ ${#groups[@]} -eq 0 ]]; then groups=(vector entrypoint); fi
for group in "${groups[@]}"; do
  case "${group}" in
    vector) group_vector ;;
    entrypoint) group_entrypoint ;;
    *) fail "group ${group}" "unknown group" ;;
  esac
done

if [[ ${failures} -gt 0 ]]; then
  echo "${failures} test(s) failed"
  exit 1
fi
echo "all tests passed"
