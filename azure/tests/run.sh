#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # expect() takes its condition single-quoted and evaluates it later; the variables it names look unused
# Offline test suite of the Azure Log Analytics pack (azure/, compose/docker-compose.azure.yml).
#
# Nothing here logs in to Azure, creates a resource or contacts IBKR: Vector runs with
# --network none against fixtures, Bicep is compiled locally, and every helper tool runs from a
# pinned container image so the same command works on the CI runner and on a Windows host.
#
# Usage:   azure/tests/run.sh [group...]
# Groups:  vector      vector validate + the VRL unit tests (vector test), every raw-log mode
#          entrypoint  azure/vector/entrypoint.sh: refusals, rendering, no secret in its output
#          pipeline    the real container on lines of a real gateway run: rotation, checkpoints,
#                      redaction, opt-in, a tightened raw-log mode, old and over-long lines
#          drift       rows Vector emits == DCR stream declarations == table columns (Bicep);
#                      the fixtures have the gateway's real shape; the test doubles keep the
#                      real sinks' durability settings
#          kql         static analysis of every alert, query-pack and workbook query and of
#                      the scenario timelines (azure/kql/scenarios)
#          kql-run     EXECUTES the scenarios in Microsoft's Kusto emulator; skipped unless
#                      KUSTO_EMULATOR_EULA=accept is set (see KUSTO_IMAGE)
#          bicep       az bicep build + lint, parameter files, properties of the compiled
#                      templates (which role for which principal on which scope, network rules)
#          compose     docker compose config of the override; hardening and limits of the services
#          secrets     the VM's host scripts (azure/vm) with fake curl, docker and git
#          lint        shellcheck, shfmt, YAML/JSON parsing, actionlint, line endings
#          (default: every group, in this order)
# Needs:   docker; az with the Bicep CLI (groups drift, kql, bicep); a .NET SDK 10 or newer
#          is used for the kql group when installed, otherwise its container image.
# Env:     AZPACK_KEEP=1 keeps the containers, volumes and files of a run for inspection.
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

# Helper tools, pinned. jq is used from the host when installed (CI runner), else from its image.
JQ_IMAGE="ghcr.io/jqlang/jq:1.8.2"
YQ_IMAGE="mikefarah/yq:4.54.3"
SHELLCHECK_IMAGE="koalaman/shellcheck:v0.11.0"
SHFMT_IMAGE="mvdan/shfmt:v3.14.1"
ACTIONLINT_IMAGE="rhysd/actionlint:1.7.12"
# The .NET SDK (KQL check) and Ubuntu (fetch-secrets test, the VM's OS) follow their release
# line: both are test tools here, not shipped artefacts.
DOTNET_IMAGE="mcr.microsoft.com/dotnet/sdk:10.0"
UBUNTU_IMAGE="ubuntu:26.04"

# Canary identifiers: obviously fake, used to prove that redaction works and nothing leaks.
CANARY_USERNAME=CANARY_USER_zq7
CANARY_ACCOUNT=DU1234567

# jq_cli <jq arguments...>: reads stdin. Programs and JSON arguments are passed as strings,
# never as file paths, so the host binary and the container take the same call.
jq_cli() {
  if command -v jq >/dev/null 2>&1; then jq "$@"; else docker run --rm -i "${JQ_IMAGE}" "$@"; fi
}

# wait_for <seconds> <command...>: poll every half second until the command succeeds.
# Returns 1 when the deadline passes first. Used instead of fixed sleeps.
wait_for() {
  local deadline=$((SECONDS + $1))
  shift
  until "$@" >/dev/null 2>&1; do
    if [[ ${SECONDS} -ge ${deadline} ]]; then return 1; fi
    sleep 0.5
  done
}

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
# The same canary user name in the encodings Windows tools produce, and files that must be
# refused. \357\273\277 is the UTF-8 byte-order mark, \377\376 the UTF-16 one.
printf '\357\273\277%s' "${CANARY_USERNAME}" >"${secrets_dir}/username-bom"
printf '%s\r\n' "${CANARY_USERNAME}" >"${secrets_dir}/username-crlf"
printf '\357\273\277%s\r\n' "${CANARY_USERNAME}" >"${secrets_dir}/username-bom-crlf"
printf '%s\n\r\n\n' "${CANARY_USERNAME}" >"${secrets_dir}/username-blank-lines"
printf '\377\376C\000A\000N\000A\000R\000Y\000\r\000\n\000' >"${secrets_dir}/username-utf16"
printf 'two words\n' >"${secrets_dir}/username-space"
printf 'first\nsecond\n' >"${secrets_dir}/username-two-lines"
printf 'J\303\274rgen\n' >"${secrets_dir}/username-non-ascii"
printf '\357\273\277\r\n' >"${secrets_dir}/username-only-bom"
# mktemp -d creates a 0700 directory; uid 1000 inside the container must be able to read it
# (bind mounts keep host permissions on Linux hosts such as the CI runner).
chmod 0755 "${work_dir}" "${secrets_dir}" && chmod 0644 "${secrets_dir}"/*
host_secrets="$(host_path "${secrets_dir}")"

# shellcheck disable=SC2317,SC2329  # invoked through the EXIT trap
cleanup() {
  # AZPACK_KEEP=1 leaves everything in place for a look at a failing test.
  if [[ -n "${AZPACK_KEEP:-}" ]]; then
    echo "kept for inspection: containers and volumes azpack-*-${run_id}, files in ${work_dir}"
    return
  fi
  # Only what THIS run created: every name ends with the run id, so a parallel run and
  # anything else on the machine are left alone.
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^azpack-.*-${run_id}\$" | while read -r name; do
    docker rm -f "${name}" >/dev/null 2>&1 || true
  done
  docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E "^azpack-.*-${run_id}\$" | while read -r name; do
    docker volume rm "${name}" >/dev/null 2>&1 || true
  done
  docker network ls --format '{{.Name}}' 2>/dev/null | grep -E "^azpack-.*-${run_id}\$" | while read -r name; do
    docker network rm "${name}" >/dev/null 2>&1 || true
  done
  rm -rf "${work_dir}"
}
trap cleanup EXIT

run_id="$$"
# A carriage return, for the line-ending check. Assigned here because $'...' is not expanded
# reliably inside a quoted command substitution by every bash build (Git Bash).
carriage_return=$'\r'
newline=$'\n'
unlabelled_env=(
  -e AZURE_AUTH=managed-identity
  -e DCR_LOGS_ENDPOINT=https://example-abcd.eastus-1.ingest.monitor.azure.com
  -e DCR_IMMUTABLE_ID=dcr-00000000000000000000000000000000
)
valid_env=("${unlabelled_env[@]}" -e IBGW_INSTANCE=test-instance -e HOST_LABEL=test-host)
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
  check "vector test: redaction rules (underscore, glued, escaped, any case; no false positive)" \
    entrypoint "${valid_env[@]}" -e IBGW_REDACT_USERNAME_FILE=/run/secrets/ib-username -- \
    test "${unit_config[@]}" /etc/vector/tests/raw-redaction-rules.test.yaml
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

  # A value with a line break must be refused before it reaches sed: the pattern check looks
  # at lines, so a multi-line value whose LAST line is valid used to pass and its other lines
  # became sed commands that rewrote the rendered sink configuration (raw_out -> raw_file).
  local variable valid baseline
  while IFS='|' read -r variable valid; do
    expect_refusal "refuses a line break in ${variable}" "${variable}" \
      entrypoint "${valid_env[@]}" "${cert_env[@]}" \
      -e "${variable}=injected|g${newline}s|- raw_out|- raw_file|${newline}${valid}" -- validate --no-environment
  done <<'VARIABLES'
DCR_LOGS_ENDPOINT|https://example.invalid
DCR_IMMUTABLE_ID|dcr-00000000000000000000000000000000
AZURE_TENANT_ID|00000000-0000-0000-0000-000000000000
AZURE_CLIENT_ID|11111111-1111-1111-1111-111111111111
AZURE_CLIENT_CERTIFICATE_PATH|/run/secrets/azure-client-cert.pfx
VARIABLES
  expect_refusal "refuses a tab in DCR_IMMUTABLE_ID" "DCR_IMMUTABLE_ID" \
    entrypoint "${valid_env[@]}" -e "DCR_IMMUTABLE_ID=dcr-00000000000000000000000000000000	" -- validate --no-environment
  # With a managed identity the three certificate variables are not used; whatever they hold
  # must not reach the rendering either.
  baseline="$(vector_container "${valid_env[@]}" -- -c "
    /bin/sh /etc/vector/entrypoint.sh --version >/dev/null 2>&1 || exit 70
    cat ${rendered}" 2>&1)"
  out="$(vector_container "${valid_env[@]}" -e 'AZURE_CLIENT_ID=x|g;s|- raw_out|- raw_file|g;s|y' \
    -e 'AZURE_TENANT_ID=x|g;s|- events_out|- raw_file|g;s|y' -e 'AZURE_CLIENT_CERTIFICATE_PATH=x|g;s|block|drop_newest|g;s|y' -- -c "
    /bin/sh /etc/vector/entrypoint.sh --version >/dev/null 2>&1 || exit 70
    cat ${rendered}" 2>&1)"
  expect "managed identity: unused certificate variables cannot change the rendered configuration" \
    '"${out}" == "${baseline}" && "${baseline}" == *"- raw_out"* && "${baseline}" != *"raw_file"*'

  # Row labels. Alert rules tell gateways apart by Instance and Host, so two gateways with the
  # same labels would hide each other's silence; a label must also survive redaction unchanged.
  expect_refusal "refuses to run unlabelled: default instance label and no host label" "IBGW_INSTANCE" \
    entrypoint "${unlabelled_env[@]}" -- validate --no-environment
  expect_refusal "refuses an explicit IBGW_INSTANCE=default without a host label" "HOST_LABEL" \
    entrypoint "${unlabelled_env[@]}" -e IBGW_INSTANCE=default -- validate --no-environment
  check "accepts the default instance label when a host label tells the gateway apart" \
    entrypoint "${unlabelled_env[@]}" -e HOST_LABEL=desk-1 -- validate --no-environment
  check "accepts an instance label without a host label" \
    entrypoint "${unlabelled_env[@]}" -e IBGW_INSTANCE=paper-1 -- validate --no-environment
  expect_refusal "refuses a space in IBGW_INSTANCE" "IBGW_INSTANCE" \
    entrypoint "${unlabelled_env[@]}" -e 'IBGW_INSTANCE=paper 1' -- validate --no-environment
  expect_refusal "refuses an IBGW_INSTANCE longer than 64 characters" "IBGW_INSTANCE" \
    entrypoint "${unlabelled_env[@]}" -e "IBGW_INSTANCE=$(printf 'x%.0s' {1..65})" -- validate --no-environment
  expect_refusal "refuses an IBGW_INSTANCE that looks like an account id" "IBGW_INSTANCE" \
    entrypoint "${unlabelled_env[@]}" -e IBGW_INSTANCE=U1234567 -- validate --no-environment
  expect_refusal "refuses a HOST_LABEL that contains an account id" "HOST_LABEL" \
    entrypoint "${unlabelled_env[@]}" -e IBGW_INSTANCE=paper-1 -e HOST_LABEL=desk_du1234567 -- validate --no-environment
  # The redaction also catches an id glued to a lower-case word; such a label would read
  # desk[ACCT:…567] in the events table and deskDU1234567 in the metrics table.
  expect_refusal "refuses an IBGW_INSTANCE with an account id glued to a word" "IBGW_INSTANCE" \
    entrypoint "${unlabelled_env[@]}" -e IBGW_INSTANCE=deskDU1234567 -- validate --no-environment
  check "accepts a label that only resembles an account id (wolf100234, the redaction leaves it alone)" \
    entrypoint "${unlabelled_env[@]}" -e IBGW_INSTANCE=wolf100234 -- validate --no-environment
  expect_refusal "refuses a line break in HOST_LABEL" "HOST_LABEL" \
    entrypoint "${unlabelled_env[@]}" -e IBGW_INSTANCE=paper-1 -e "HOST_LABEL=desk${newline}x" -- validate --no-environment

  # The user-name file is normalised as the gateway normalises it (a leading UTF-8 byte-order
  # mark and trailing line ends are not part of the name). The proof is positive: the redaction
  # unit tests, which require [USER] in the shipped row, pass with each encoding of the file.
  local variant
  for variant in bom crlf bom-crlf blank-lines; do
    check "user-name file (${variant}): the name is still redacted to [USER]" \
      entrypoint "${valid_env[@]}" -e "IBGW_REDACT_USERNAME_FILE=/run/secrets/username-${variant}" -- \
      test "${unit_config[@]}" /etc/vector/tests/raw-redacted.test.yaml
  done
  for variant in utf16 space two-lines non-ascii only-bom; do
    expect_refusal "user-name file (${variant}) is refused: raw logs are never shipped with a name that cannot match" \
      "IBGW_REDACT_USERNAME_FILE" \
      entrypoint "${valid_env[@]}" -e "IBGW_REDACT_USERNAME_FILE=/run/secrets/username-${variant}" -- validate --no-environment
  done

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

  if out="$(diff <(sinks_without_auth "${repo}/azure/vector/sinks-managed-identity.yaml") \
    <(sinks_without_auth "${repo}/azure/vector/sinks-certificate.yaml") 2>&1)"; then
    pass "the two sink templates differ only in their auth blocks"
  else
    fail "the two sink templates differ only in their auth blocks" "they drifted apart"
    show "${out}"
  fi
}

log_volume="azpack-logs-${run_id}"
helper="azpack-gateway-${run_id}"
capture_file="${work_dir}/capture.jsonl"
events_stream=Custom-IbGwEvents_CL
metrics_stream=Custom-IbGwMetrics_CL
raw_stream=Custom-IBGatewayLogs_CL

# seed_log_volume: a named volume owned by uid 1000 as the gateway image leaves it, and a
# helper container that plays the gateway (the only writer). The fixture files are lines of a
# real gateway run and carry that run's timestamps; rows older than 36 hours are not shipped,
# so the helper works on a private copy (/tmp/fx) in which the date of every `ts` is today's
# (UTC). One line that is not JSON is added to each JSON Lines file.
seed_log_volume() {
  docker volume create "${log_volume}" >/dev/null \
    && docker run --rm --name "azpack-seed-${run_id}" --network none --user 0:0 \
      -v "${log_volume}:/var/log/ibgateway" --entrypoint /bin/sh "${VECTOR_IMAGE}" \
      -c 'chown 1000:1000 /var/log/ibgateway' \
    && docker run -d --name "${helper}" --network none --user 1000:1000 \
      -v "${log_volume}:/var/log/ibgateway" -v "${host_repo}/azure/tests/fixtures:/fx-source:ro" \
      --entrypoint /bin/sh "${VECTOR_IMAGE}" -c 'sleep 1200' >/dev/null \
    && as_gateway '
      cp -r /fx-source /tmp/fx &&
      find /tmp/fx/logvol /tmp/fx/append -type f ! -name "*.log" -exec \
        sed -i "s/\"ts\":\"2026-11-12T/\"ts\":\"$(date -u +%Y-%m-%d)T/" {} + &&
      cp -r /tmp/fx/logvol/. /var/log/ibgateway/ &&
      mkdir -p /var/log/ibgateway/jts &&
      cat /tmp/fx/append/not-json.txt >>/var/log/ibgateway/events/events.jsonl &&
      cat /tmp/fx/append/not-json.txt >>/var/log/ibgateway/metrics/metrics.jsonl'
}

# as_gateway <shell snippet>: write to the log volume the way the gateway does.
as_gateway() { docker exec "${helper}" /bin/sh -c "$1"; }

# start_shipper <container> <data volume> <docker-args...>: the compose service as it runs in
# production (same entrypoint, mounts and hardening, no network), except that the sink template
# is replaced by a test double from fixtures/ so the rows are printed instead of sent to
# Azure: capture-sinks.yaml, or the file named by ${sink_double}.
start_shipper() {
  local name="$1" data="$2"
  shift 2
  docker run -d --name "${name}" --network none --user 1000:1000 --read-only \
    --cap-drop ALL --security-opt no-new-privileges:true \
    -v "${log_volume}:/var/log/ibgateway:ro" \
    -v "${host_repo}/azure/vector:/etc/vector:ro" \
    -v "${host_repo}/azure/tests/fixtures/${sink_double:-capture-sinks.yaml}:/etc/vector/sinks-managed-identity.yaml:ro" \
    -v "${data}:/var/tmp" \
    -v "${host_secrets}:/run/secrets:ro" \
    "${valid_env[@]}" -e VECTOR_LOG_FORMAT=json "$@" \
    --entrypoint /bin/sh "${VECTOR_IMAGE}" /etc/vector/entrypoint.sh >/dev/null
}

# captured <container>: every row the container has printed so far (its stdout only).
captured() { docker logs "$1" 2>/dev/null | grep -F '"capture":' || true; }
# row_count <container> <stream>: number of captured rows of one stream.
row_count() { captured "$1" | grep -cF "\"capture\":\"$2\"" || true; }
has_rows() { [[ "$(row_count "$1" "$2")" -ge "$3" ]]; }

# expect_rows <name> <container> <stream> <count>: wait until <count> rows of the stream were
# captured, then require exactly <count> (more means a duplicate or a line that should have
# been dropped). Counts are cumulative over the life of the container, restarts included.
expect_rows() {
  local name="$1" container="$2" stream="$3" want="$4" got
  wait_for 90 has_rows "${container}" "${stream}" "${want}" || true
  got="$(row_count "${container}" "${stream}")"
  if [[ "${got}" -eq "${want}" ]]; then
    pass "${name}"
  else
    fail "${name}" "captured ${got} rows of ${stream}, expected ${want}"
    docker logs "${container}" 2>&1 | grep -vF '"capture":' | tail -n 15 | cut -c1-400 | sed 's/^/      /'
  fi
}

# expect <name> <condition as a string for [[ ]]>: evaluates the condition in this shell.
expect() {
  if eval "[[ $2 ]]"; then pass "$1"; else fail "$1" "condition not met: $2"; fi
}

group_pipeline() {
  echo "== pipeline: the real container on a fixture log volume (uid 1000, read-only, no network)"
  local a="azpack-ship-a-${run_id}" b="azpack-ship-b-${run_id}" rows output counts
  if ! seed_log_volume; then
    fail "seed the fixture log volume" "docker failed"
    return
  fi

  # Shipper A: raw logs opted in, user name redacted. 5 + 6 real event lines, 3 real samples.
  # VECTOR_LOG=info is Vector's own default; if the entrypoint honoured it, Vector would print
  # the start of every discarded over-long line in its own log (see the long-line test below).
  start_shipper "${a}" "azpack-data-a-${run_id}" -e IBGW_REDACT_USERNAME_FILE=/run/secrets/ib-username -e VECTOR_LOG=info
  expect_rows "ships the gateway's real event lines of the current and the rotated file, drops the malformed one" \
    "${a}" "${events_stream}" 11
  expect_rows "ships the gateway's real metrics samples, drops the malformed one" "${a}" "${metrics_stream}" 3

  as_gateway 'cat /tmp/fx/append/ibc.log >>/var/log/ibgateway/ibc/ibc.log &&
    cp /tmp/fx/append/launcher.log /var/log/ibgateway/jts/launcher.log'
  expect_rows "ships raw lines written after its first start, not the history" "${a}" "${raw_stream}" 6

  # An over-long raw line (300 KB, more than the source's max_line_bytes) that carries the user
  # name and an account id at both ends: it is not shipped, the line after it is, and nothing
  # of it may appear in the shipper's own log (checked on the whole output further down).
  as_gateway "{ printf '%s' 'LONG_LINE_BEGIN ${CANARY_USERNAME} ${CANARY_ACCOUNT} ' &&
    head -c 300000 /dev/zero | tr '\\000' 'x' &&
    printf '%s\\n' ' ${CANARY_USERNAME} ${CANARY_ACCOUNT} LONG_LINE_END' &&
    printf '%s\\n' '2026-11-12 01:06:00 INFO line after the long one'; } >>/var/log/ibgateway/jts/launcher.log"
  expect_rows "skips a raw line longer than the limit and ships the line after it" "${a}" "${raw_stream}" 7
  # The log lines of Vector's file source are switched off (they would print the discarded
  # line), so the counters the shipper prints every minute must say what those lines used to
  # say: how many files are watched, and that a line was discarded.
  if wait_for 90 container_says "${a}" '"error_code":"reading_line_from_file"' \
    && container_says "${a}" '"name":"open_files"'; then
    pass "the shipper's counters report the files it watches and the discarded over-long line"
  else
    fail "the shipper's counters report the files it watches and the discarded over-long line" "no such counter on stdout"
    docker logs "${a}" 2>&1 | grep -vF '"capture":' | grep -F '"name":' | cut -c1-200 | sort -u | tail -n 12 | sed 's/^/      /'
  fi

  # A partial last line: the head of event 12 without a newline, then proof that Vector kept
  # reading (a new metrics sample arrives) while that line was still incomplete.
  as_gateway 'printf %s "$(cat /tmp/fx/append/event-12.head)" >>/var/log/ibgateway/events/events.jsonl &&
    cat /tmp/fx/append/metrics-4.jsonl >>/var/log/ibgateway/metrics/metrics.jsonl'
  expect_rows "keeps shipping while the last events line is incomplete" "${a}" "${metrics_stream}" 4
  expect_rows "does not ship an incomplete last line" "${a}" "${events_stream}" 11
  as_gateway 'cat /tmp/fx/append/event-12.tail >>/var/log/ibgateway/events/events.jsonl'
  expect_rows "ships the line once it is complete" "${a}" "${events_stream}" 12

  # Rotation by rename, as the gateway does it: events.jsonl -> events.jsonl.1, new events.jsonl
  # (the last event of the old boot and the first two of a new one).
  as_gateway 'cd /var/log/ibgateway/events && mv -f events.jsonl events.jsonl.1 &&
    cp /tmp/fx/append/events-after-rotation.jsonl events.jsonl.tmp && mv events.jsonl.tmp events.jsonl'
  expect_rows "follows a rotation: new file shipped, renamed file not shipped again" "${a}" "${events_stream}" 15

  # History is not back-filled: a line whose ts is older than 36 hours (these two carry a fixed
  # date weeks in the past) is dropped, and the shipper says so in its own log. The exact row
  # counts after the restart below prove that neither line was shipped.
  as_gateway 'cat /tmp/fx/append/event-old.jsonl >>/var/log/ibgateway/events/events.jsonl &&
    cat /tmp/fx/append/metrics-old.jsonl >>/var/log/ibgateway/metrics/metrics.jsonl'
  if wait_for 60 container_says "${a}" "dropped an event older than 36 hours" \
    && wait_for 60 container_says "${a}" "dropped a metrics sample older than 36 hours"; then
    pass "an event and a sample older than 36 hours are dropped and the shipper's log says so"
  else
    fail "an event and a sample older than 36 hours are dropped and the shipper's log says so" "no such warning in the shipper's log"
    docker logs "${a}" 2>&1 | grep -vF '"capture":' | tail -n 5 | cut -c1-300 | sed 's/^/      /'
  fi

  # Restart: the checkpoints live on the data volume; a line that was not delivered is read again.
  docker stop -t 70 "${a}" >/dev/null 2>&1
  docker start "${a}" >/dev/null 2>&1
  as_gateway 'cat /tmp/fx/append/event-after-restart.jsonl >>/var/log/ibgateway/events/events.jsonl'
  expect_rows "resumes from its checkpoints after a restart (no duplicate, no loss)" "${a}" "${events_stream}" 16
  expect_rows "does not ship metrics again after a restart" "${a}" "${metrics_stream}" 4
  expect_rows "does not ship raw lines again after a restart" "${a}" "${raw_stream}" 7

  captured "${a}" >"${capture_file}"
  rows="$(cat "${capture_file}")"
  output="$(docker logs "${a}" 2>&1)"
  counts="$(jq_cli -rs '[.[] | select(.capture == "Custom-IbGwEvents_CL") | .row | [.BootId, .Seq]] | [length, (unique | length)] | join(" ")' <"${capture_file}")"
  expect "every event row is shipped exactly once (BootId, Seq)" '"${counts}" == "16 16"'
  counts="$(jq_cli -rs '[.[] | select(.capture == "Custom-IbGwEvents_CL") | .row | select(.Event == "container_start") | .Props.gateway_version] | unique | join(",")' <"${capture_file}")"
  expect "the data object of container_start arrives as Props (gateway_version)" '"${counts}" == "10.50.1g"'
  # shellcheck disable=SC2034  # read by expect through eval
  lowered="${output,,}"
  expect "the user name is neither in a row nor in the shipper's own log" '"${lowered}" != *"${CANARY_USERNAME,,}"*'
  expect "the user name was replaced by [USER]" '"${rows}" == *"[USER]"*'
  expect "no full account id is in a row or in the shipper's own log" '"${output}" != *"${CANARY_ACCOUNT}"*'
  expect "account ids keep their last three characters" '"${rows}" == *"[ACCT:…567]"*'
  expect "the raw history from before the first start is not shipped" '"${rows}" != *"OLD_LINE_MARKER"*'
  expect "nothing of the over-long raw line is in a row or in the shipper's own log" \
    '"${output}" != *"LONG_LINE_"* && "${output}" != *"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"* && "${output}" == *"line after the long one"*'
  counts="$(jq_cli -rs '[.[] | select(.capture == "Custom-IBGatewayLogs_CL") | .row] | [(map(select(.Level == "error" and .Code == 1100)) | length), (map(.FilePath) | unique | join(","))] | join(" ")' <"${capture_file}")"
  expect "raw rows carry the derived level, the code and their file path" \
    '"${counts}" == "1 /var/log/ibgateway/ibc/ibc.log,/var/log/ibgateway/jts/launcher.log"'

  # Shipper B: default settings, its own data volume. Raw lines must not come out. The event
  # appended together with the raw lines proves that B was reading when they were written.
  start_shipper "${b}" "azpack-data-b-${run_id}"
  expect_rows "a shipper with default settings ships the events on the volume" "${b}" "${events_stream}" 11
  as_gateway 'cat /tmp/fx/append/ibc.log >>/var/log/ibgateway/ibc/ibc.log &&
    cat /tmp/fx/append/event-sentinel.jsonl >>/var/log/ibgateway/events/events.jsonl'
  expect_rows "the default shipper keeps shipping events" "${b}" "${events_stream}" 12
  expect_rows "raw logs are not shipped unless the operator opted in" "${b}" "${raw_stream}" 0
  output="$(docker logs "${b}" 2>&1)"
  # shellcheck disable=SC2034  # read by expect through eval
  lowered="${output,,}"
  expect "the default shipper prints no user name" '"${lowered}" != *"${CANARY_USERNAME,,}"*'

  if [[ -z "${AZPACK_KEEP:-}" ]]; then docker rm -f "${a}" "${b}" >/dev/null 2>&1; fi

  # Tightening the raw-log mode. Shipper C maps raw lines under SHIP_RAW_LOGS=yes (the user
  # name stays in them) while its raw sink cannot deliver, then is killed. Whatever starts
  # next on the same data volume with a stricter mode must never ship those rows as they were.
  local c="azpack-ship-c-${run_id}" data_c="azpack-data-c-${run_id}"
  sink_double=blocked-raw-sink.yaml start_shipper "${c}" "${data_c}" -e SHIP_RAW_LOGS=yes
  wait_for 60 container_says "${c}" "Vector has started" || true
  as_gateway 'cat /tmp/fx/append/ibc.log >>/var/log/ibgateway/ibc/ibc.log'
  if wait_for 60 raw_sink_is_failing "${c}"; then
    pass "a shipper whose raw sink cannot deliver holds raw rows mapped under SHIP_RAW_LOGS=yes"
  else
    fail "a shipper whose raw sink cannot deliver holds raw rows mapped under SHIP_RAW_LOGS=yes" "the sink never reported a failed delivery"
    docker logs "${c}" 2>&1 | grep -F azure_raw | tail -n 5 | cut -c1-300 | sed 's/^/      /'
  fi
  docker rm -f "${c}" >/dev/null 2>&1

  start_shipper "${c}" "${data_c}" -e IBGW_REDACT_USERNAME_FILE=/run/secrets/ib-username
  wait_for 60 container_says "${c}" "Vector has started" || true
  as_gateway 'cat /tmp/fx/append/ibc.log >>/var/log/ibgateway/ibc/ibc.log'
  wait_for 60 has_rows "${c}" "${raw_stream}" 3 || true
  rows="$(captured "${c}" | grep -F "\"capture\":\"${raw_stream}\"")"
  # shellcheck disable=SC2034  # read by expect through eval
  lowered="${rows,,}"
  expect "after the mode was tightened to redaction, no raw row carries the user name (old rows included)" \
    '"${rows}" == *"[USER]"* && "${lowered}" != *"${CANARY_USERNAME,,}"*'
  docker rm -f "${c}" >/dev/null 2>&1

  start_shipper "${c}" "${data_c}"
  wait_for 60 container_says "${c}" "Vector has started" || true
  as_gateway 'cat /tmp/fx/append/ibc.log >>/var/log/ibgateway/ibc/ibc.log &&
    cat /tmp/fx/append/event-sentinel.jsonl >>/var/log/ibgateway/events/events.jsonl'
  expect_rows "after raw shipping was switched off the shipper still ships events" "${c}" "${events_stream}" 1
  expect_rows "after raw shipping was switched off, no raw row is shipped (old rows included)" "${c}" "${raw_stream}" 0
  if [[ -z "${AZPACK_KEEP:-}" ]]; then docker rm -f "${c}" >/dev/null 2>&1; fi
}

# container_says <container> <text>: true when the container has printed the text.
container_says() { docker logs "$1" 2>&1 | grep -qF -- "$2"; }
# raw_sink_is_failing <container>: true when the raw sink has reported a delivery it must retry.
raw_sink_is_failing() { docker logs "$1" 2>&1 | grep -F '"component_id":"azure_raw"' | grep -qiE 'retry|error'; }

compiled_main="${work_dir}/main.json"

# compile_main: az bicep build of azure/bicep/main.bicep into ${compiled_main} (offline).
compile_main() {
  az bicep build --file "$(host_path "${repo}/azure/bicep/main.bicep")" --stdout \
    >"${compiled_main}" 2>"${work_dir}/main.build.log"
}

# jq_file <program in azure/tests> <jq arguments...>: run a jq program file on stdin.
jq_file() {
  local program="$1"
  shift
  if command -v jq >/dev/null 2>&1; then
    jq -f "${here}/${program}" "$@"
  else
    # Not mounted at /jq: in this image /jq is the binary itself.
    docker run --rm -i -v "${host_repo}/azure/tests:/programs:ro" "${JQ_IMAGE}" -f "/programs/${program}" "$@"
  fi
}

# drift_problems <declarations json>: the problems schema-drift.jq finds for the captured rows.
drift_problems() {
  { printf '%s\n' "$1" && cat "${capture_file}"; } | jq_file schema-drift.jq -rs
}

# sink_routes <sink template>: "<input transform> <stream name>" for each sink, sorted.
sink_routes() {
  awk '/^      - /{input = $2} /^    stream_name:/{print input, $2}' "$1" | sort
}

# capture_routes: the same pairs as the capture test double declares them.
capture_routes() {
  awk '/^      - /{input = $2}
    /"capture": "/{split($0, part, "\""); print input, part[4]}' \
    "${repo}/azure/tests/fixtures/capture-sinks.yaml" | sort
}

group_drift() {
  echo "== drift: rows Vector emits == DCR stream declarations == table columns"
  local declarations problems mutation expected routes file
  if [[ ! -s "${capture_file}" ]]; then group_pipeline; fi
  if [[ ! -s "${capture_file}" ]]; then
    fail "capture rows from the pipeline" "nothing captured"
    return
  fi
  if ! compile_main; then
    fail "compile azure/bicep/main.bicep" "az bicep build failed"
    show "$(cat "${work_dir}/main.build.log")"
    return
  fi
  declarations="$(jq_file drift-declarations.jq -c <"${compiled_main}")"

  problems="$(drift_problems "${declarations}" 2>&1)"
  if [[ $? -eq 0 && -z "${problems}" ]]; then
    pass "Vector's rows, the DCR streams and the tables declare the same columns and types"
  else
    fail "Vector's rows, the DCR streams and the tables declare the same columns and types" "drift"
    show "${problems}"
  fi

  # The check must notice each kind of defect, otherwise a green result above means nothing.
  while IFS='|' read -r mutation expected; do
    problems="$(drift_problems "$(printf '%s\n' "${declarations}" | jq_file drift-mutate.jq -c --arg name "${mutation}")" 2>&1)"
    if [[ "${problems}" == *"${expected}"* ]]; then
      pass "the drift check notices: ${mutation}"
    else
      fail "the drift check notices: ${mutation}" "expected a problem containing '${expected}'"
      show "${problems}"
    fi
  done <<'MUTATIONS'
column_removed|Vector emits Props but the stream does not declare it
column_added|the stream declares NotEmitted but no captured row carries it
column_retyped|Seq = 1 is not of type string
table_differs|the columns of table IBGatewayLogs_CL differ from the stream declaration
flow_missing|Custom-IbGwMetrics_CL: expected exactly one data flow
MUTATIONS

  # The fixtures themselves must have the shape the gateway writes (they are lines of a real
  # run); a fixture with a key the gateway never emits would make the comparison above a
  # statement about input that does not exist.
  local fx="${repo}/azure/tests/fixtures"
  problems="$({
    cat "${fx}/logvol/events/events.jsonl" "${fx}/logvol/events/events.jsonl.1" \
      "${fx}/append/events-after-rotation.jsonl" "${fx}/append/event-after-restart.jsonl" \
      "${fx}/append/event-sentinel.jsonl" "${fx}/append/event-old.jsonl"
    cat "${fx}/append/event-12.head" "${fx}/append/event-12.tail" | tr -d '\n'
    echo
  } | jq_file fixture-contract.jq -rs --arg kind events 2>&1)"
  if [[ $? -eq 0 && -z "${problems}" ]]; then
    pass "every events fixture line has the shape of the gateway's real events (log contract v2)"
  else
    fail "every events fixture line has the shape of the gateway's real events (log contract v2)" "see below"
    show "${problems}"
  fi
  problems="$(cat "${fx}/logvol/metrics/metrics.jsonl" "${fx}/append/metrics-4.jsonl" "${fx}/append/metrics-old.jsonl" \
    | jq_file fixture-contract.jq -rs --arg kind metrics 2>&1)"
  if [[ $? -eq 0 && -z "${problems}" ]]; then
    pass "every metrics fixture line has the shape of the gateway's real samples"
  else
    fail "every metrics fixture line has the shape of the gateway's real samples" "see below"
    show "${problems}"
  fi
  problems="$(printf '%s\n' '{"ts":"2026-11-12T01:00:00.000Z","src":"ibc","level":"info","event":"login_completed","msg":"x","boot_id":"443d261aecbd4789","seq":1,"code":1100,"phase":"logged-in"}' \
    | jq_file fixture-contract.jq -rs --arg kind events 2>&1)"
  expect "the fixture check refuses keys the gateway does not emit (code, phase on an event)" \
    '"${problems}" == *"key code is not in the event contract"* && "${problems}" == *"key phase is not in the event contract"*'

  routes="$(sink_routes "${repo}/azure/vector/sinks-managed-identity.yaml")"
  expect "the capture test double routes each transform to the stream its real sink uses" \
    '"${routes}" == "$(capture_routes)" && -n "${routes}"'
  expect "every stream a sink writes to is declared by the data collection rule" \
    '"$(printf "%s\n" "${routes}" | cut -d" " -f2 | sort)" == "$(printf "%s\n" "${declarations}" | jq_cli -r ".dcr.streamDeclarations | keys[]" | sort)"'

  # Durability is a property of the sink settings: memory buffers with end-to-end
  # acknowledgements (a file position is saved only after delivery), raw lines dropped instead
  # of blocking. The restart and mode-change tests of the pipeline group run on the test
  # doubles, so the doubles must carry exactly the settings of the real sinks.
  local durability wanted
  wanted="azure_events memory 500 block true${newline}azure_metrics memory 500 block true${newline}azure_raw memory 500 drop_newest true"
  for file in azure/vector/sinks-managed-identity.yaml azure/vector/sinks-certificate.yaml \
    azure/tests/fixtures/capture-sinks.yaml azure/tests/fixtures/blocked-raw-sink.yaml; do
    durability="$(sink_durability <"${repo}/${file}" 2>&1)"
    expect "${file}: memory buffers, end-to-end acknowledgements, raw lines never block" '"${durability}" == "${wanted}"'
  done
  durability="$(sed 's/type: memory/type: disk/' "${repo}/azure/tests/fixtures/capture-sinks.yaml" | sink_durability 2>&1)"
  expect "the durability check notices a test double with other buffer settings" '"${durability}" != "${wanted}" && "${durability}" == *"azure_raw disk"*'
}

# sink_durability: the buffer and acknowledgement settings of every sink of the Vector
# configuration on stdin, one line per sink: "<id> <buffer type> <max events> <when full> <acks>".
sink_durability() {
  docker run --rm -i "${YQ_IMAGE}" \
    '.sinks | to_entries | .[] | [.key, .value.buffer.type, .value.buffer.max_events, .value.buffer.when_full, .value.acknowledgements.enabled] | join(" ")'
}

declarations_file="${work_dir}/declarations.json"

# prepare_declarations: compile main.bicep once and cut out its tables and streams.
prepare_declarations() {
  if [[ -s "${declarations_file}" ]]; then return 0; fi
  compile_main && jq_file drift-declarations.jq -c <"${compiled_main}" >"${declarations_file}"
}

# kql_check <directory with .kql files, relative to the repository>: kql-check.cs against the
# compiled schema. Uses the host's .NET SDK when it can run file-based programs (10 or
# newer), else the SDK container.
kql_check() {
  if command -v dotnet >/dev/null 2>&1 && [[ "$(dotnet --version 2>/dev/null | cut -d. -f1)" -ge 10 ]]; then
    mkdir -p "${work_dir}/kql-check" && cp "${here}/kql-check.cs" "${work_dir}/kql-check/" \
      && (cd "${work_dir}/kql-check" && dotnet run kql-check.cs -- "$(host_path "${declarations_file}")" \
        "$(host_path "${repo}/$1")" "$(host_path "${repo}/azure/workbook/gateway.workbook.json")")
  else
    docker run --rm --name "azpack-kql-${run_id}" -v "${host_repo}:/src:ro" \
      -v "$(host_path "${work_dir}"):/work:ro" "${DOTNET_IMAGE}" sh -c '
        mkdir -p /tmp/kql-check && cp /src/azure/tests/kql-check.cs /tmp/kql-check/ &&
        cd /tmp/kql-check &&
        dotnet run kql-check.cs -- /work/declarations.json "/src/$1" /src/azure/workbook/gateway.workbook.json' sh "$1"
  fi
}

group_kql() {
  echo "== kql: every query against the schema of the compiled template (static analysis)"
  local out code file text kql
  if ! prepare_declarations; then
    fail "compile azure/bicep/main.bicep" "az bicep build failed"
    show "$(cat "${work_dir}/main.build.log")"
    return
  fi
  out="$(kql_check azure/kql 2>&1)"
  code=$?
  if [[ ${code} -eq 0 && "${out}" != *"FAIL  "* && "${out}" == *"PASS  alert-dead-man.kql"* && "${out}" == *"PASS  workbook: "* &&
    "${out}" == *"PASS  scenario: human-needed.twofa-flip.kql"* ]]; then
    pass "alert rules, query pack, workbook and scenario timelines: $(printf '%s\n' "${out}" | grep -c '^PASS  ') queries are valid for the deployed schema"
  else
    fail "alert rules, query pack and workbook are valid KQL" "exit ${code}"
    show "${out}"
  fi

  # The checker must reject each kind of defect, otherwise the result above means nothing.
  out="$(kql_check azure/tests/fixtures/kql-bad 2>&1)"
  code=$?
  expect "the checker fails on the deliberately broken queries" '${code} -eq 1'
  while IFS='|' read -r file text; do
    if printf '%s\n' "${out}" | grep -A 3 -F "FAIL  ${file}" | grep -qF "${text}"; then
      pass "the checker notices: ${file}"
    else
      fail "the checker notices: ${file}" "expected '${text}'"
      show "${out}"
    fi
  done <<'DEFECTS'
alert-missing-condition.kql|an alert query must return the column Condition
alert-no-dimensions.kql|an alert query must declare its dimensions
syntax-error.kql|Missing expression
unknown-column.kql|NoSuchColumn
unknown-table.kql|IbGwNothing_CL
wrong-type.kql|is not defined for the operand types string and timespan
scenario: shadow-unknown-column.kql|IbGwEvents_CL.Phase is not a column of the deployed table
DEFECTS

  # alerts.bicep replaces these two exact lines with the maintenance window.
  for kql in alert-human-needed.kql alert-health.kql; do
    expect "${kql} carries the two maintenance-window lines the Bicep module replaces" \
      '"$(grep -cFx "let maintenance_start = time(00:00:00);" "${repo}/azure/kql/${kql}")" == 1 && "$(grep -cFx "let maintenance_end = time(00:00:00);" "${repo}/azure/kql/${kql}")" == 1'
  done
}

# Microsoft's Kusto emulator, pinned by digest. Running it means accepting its licence terms
# (https://aka.ms/adx.emulator.license), which only the operator can do: group kql-run is
# skipped unless KUSTO_EMULATOR_EULA=accept is set.
KUSTO_IMAGE="mcr.microsoft.com/azuredataexplorer/kustainer-linux@sha256:5c21867936e23d61bb1ba492eb163972d50fc10132cd49a922e601b55ca705cd"

# kusto_post <engine container> <network> <mgmt|query>: POST the JSON request on stdin to the
# emulator's REST API from a helper container on the same internal network; prints the reply.
kusto_post() {
  docker run --rm -i --network "$2" --entrypoint /bin/sh "${VECTOR_IMAGE}" -c '
    cat >/tmp/request.json &&
    wget -q -O - --header "Content-Type: application/json" --post-file /tmp/request.json "http://$0:8080/v1/rest/$1"' "$1" "$3"
}

# group_kql_run: EXECUTES each scenario of azure/kql/scenarios (the timeline followed by its
# alert query) in the emulator and compares the rows with the scenario's "// Expect:" lines.
# This is the only test that evaluates the alert logic; it is opt-in (see KUSTO_IMAGE).
# NOTE: this group was written without ever being run, because the licence had not been
# accepted for this repository. Expect to adjust it on first use (the emulator's start-up
# time, its REST paths and reply shape are taken from Microsoft's documentation, not observed).
group_kql_run() {
  echo "== kql-run: the scenario timelines executed in Microsoft's Kusto emulator"
  if [[ "${KUSTO_EMULATOR_EULA:-}" != accept ]]; then
    echo "SKIP  the alert logic was not executed: the emulator needs its licence accepted (set KUSTO_EMULATOR_EULA=accept)"
    return
  fi
  local network="azpack-kusto-net-${run_id}" engine="azpack-kusto-${run_id}" scenario query expected got reply
  if ! docker network create --internal "${network}" >/dev/null \
    || ! docker run -d --name "${engine}" --network "${network}" -e ACCEPT_EULA=Y -m 4g "${KUSTO_IMAGE}" >/dev/null; then
    fail "start the Kusto emulator" "docker failed"
    return
  fi
  emulator_ready() { printf '%s' '{"csl": ".show cluster"}' | kusto_post "${engine}" "${network}" mgmt | grep -q '"Tables"'; }
  if ! wait_for 180 emulator_ready; then
    fail "start the Kusto emulator" "it did not answer within 180 s"
    docker rm -f "${engine}" >/dev/null 2>&1
    docker network rm "${network}" >/dev/null 2>&1
    return
  fi
  for scenario in "${repo}"/azure/kql/scenarios/*.kql; do
    query="${repo}/azure/kql/$(sed -n 's|^// Query: ||p' "${scenario}" | head -n 1)"
    expected="$(sed -n 's|^// Expect: ||p' "${scenario}" | grep -vF '(no rows)' | sort)"
    reply="$({
      cat "${scenario}"
      echo
      cat "${query}"
    } | jq_cli -Rs '{db: "NetDefaultDB", csl: .}' | kusto_post "${engine}" "${network}" query 2>&1)"
    # The values of the dimension columns of every returned row, in the order Instance, Host, Condition.
    got="$(printf '%s' "${reply}" | jq_cli -r '.Tables[0] as $t | ($t.Columns | map(.ColumnName)) as $names
      | $t.Rows[] | . as $row | [("Instance", "Host", "Condition") | select(. as $n | $names | index($n)) | $row[. as $n | $names | index($n)]] | join("|")' 2>&1 | sort)"
    if [[ "${got}" == "${expected}" ]]; then
      pass "scenario $(basename "${scenario}"): the query returns exactly [${expected//${newline}/, }]"
    else
      fail "scenario $(basename "${scenario}")" "expected [${expected//${newline}/, }], the query returned [${got//${newline}/, }]"
      show "${reply:0:600}"
    fi
  done
  docker rm -f "${engine}" >/dev/null 2>&1
  docker network rm "${network}" >/dev/null 2>&1
}

# bicep_clean <build|lint|build-params> <file relative to the repository>: the command must
# succeed without printing a single warning or error.
bicep_clean() {
  local out code extra=()
  if [[ "$1" != lint ]]; then extra=(--stdout); fi
  out="$(az bicep "$1" --file "$(host_path "${repo}/$2")" "${extra[@]}" 2>&1 >/dev/null)"
  code=$?
  if [[ "$1" == lint ]]; then out="$(az bicep lint --file "$(host_path "${repo}/$2")" 2>&1)"; fi
  if [[ ${code} -ne 0 || "${out}" == *"Warning"* || "${out}" == *"Error"* || "${out}" == *"ERROR"* ]]; then
    printf '%s\n' "${out}"
    return 1
  fi
}

group_bicep() {
  echo "== bicep: build, lint, parameter files, properties of the compiled templates"
  local file out compiled_vm="${work_dir}/vm.json" referenced kql
  for file in azure/bicep/main.bicep azure/bicep/vm.bicep "${repo}"/azure/bicep/modules/*.bicep; do
    file="${file#"${repo}/"}"
    check "az bicep build ${file} (no warning)" bicep_clean build "${file}"
    check "az bicep lint ${file}" bicep_clean lint "${file}"
  done
  check "az bicep build-params azure/bicep/main.bicepparam" bicep_clean build-params azure/bicep/main.bicepparam
  check "az bicep build-params azure/bicep/vm.bicepparam" bicep_clean build-params azure/bicep/vm.bicepparam

  # Every file a template loads exists (a missing one also fails the build above), and no
  # query file is left unreferenced by both the templates and the README.
  referenced="$(grep -rhoE "loadTextContent\('[^']+'\)" "${repo}/azure/bicep" | sed -E "s/.*'([^']+)'.*/\1/" | sed -E 's#^(\.\./)+##' | sort -u)"
  out=""
  while read -r file; do
    if [[ ! -s "${repo}/azure/${file}" ]]; then out+="${file} "; fi
  done <<<"${referenced}"
  expect "every file loaded with loadTextContent exists" '-z "${out}" && "${referenced}" == *"kql/alert-dead-man.kql"*'
  out=""
  for kql in "${repo}"/azure/kql/*.kql; do
    kql="$(basename "${kql}")"
    if [[ "${referenced}" != *"kql/${kql}"* ]] && ! grep -qF "${kql}" "${repo}/azure/README.md" 2>/dev/null; then out+="${kql} "; fi
  done
  expect "every query in azure/kql is used by an alert rule or documented in the README" '-z "${out}"'
  out="$(grep -oE "kql/[a-z0-9-]+\.kql" "${repo}/azure/bicep/modules/query-pack.bicep" | sed 's#^kql/##' | sort | tr '\n' ' ')"
  referenced="$(find "${repo}/azure/kql" -maxdepth 1 -name '*.kql' -exec basename {} \; | sort | tr '\n' ' ')"
  expect "the query pack saves every query file of azure/kql, and nothing else" '-n "${out}" && "${out}" == "${referenced}"'

  if compile_main; then
    out="$(jq_file template-checks.jq -r --arg which main <"${compiled_main}" 2>&1)"
    if [[ $? -eq 0 && -z "${out}" ]]; then
      pass "main.bicep: three self-resolving rules, one role on the rule only, no credential parameter, no foreign id"
    else
      fail "main.bicep keeps its security and shape promises" "see below"
      show "${out}"
    fi
  else
    fail "compile azure/bicep/main.bicep" "az bicep build failed"
  fi
  if az bicep build --file "$(host_path "${repo}/azure/bicep/vm.bicep")" --stdout >"${compiled_vm}" 2>/dev/null; then
    out="$(jq_file template-checks.jq -r --arg which vm <"${compiled_vm}" 2>&1)"
    if [[ $? -eq 0 && -z "${out}" ]]; then
      pass "vm.bicep: no public IP, deny-all inbound, RBAC vault, three roles for your own identities, no secret parameter"
    else
      fail "vm.bicep keeps its security and shape promises" "see below"
      show "${out}"
    fi
    # The checks must be able to fail. A role for somebody else is refused...
    out="$(jq_cli --arg principal "[parameters('somebodyElse')]" \
      '{"type": "Microsoft.Authorization/roleAssignments", "apiVersion": "2022-04-01", "name": "extra", "properties": {"principalId": $principal}} as $extra
        | .resources |= (if type == "array" then . + [$extra] else . + {"extra": $extra} end)' \
      <"${compiled_vm}" | jq_file template-checks.jq -r --arg which vm 2>&1)"
    expect "the template check notices a role assignment for another principal" \
      '"${out}" == *"the role assignments are not the promised ones"*"parameter somebodyElse"*'
    # ...and so is a network rule that lets something in.
    out="$(jq_cli '(.. | objects | select(.name? == "deny-all-inbound") | .properties.access) = "Allow"' <"${compiled_vm}" | jq_file template-checks.jq -r --arg which vm 2>&1)"
    expect "the template check notices an inbound rule that allows" '"${out}" == *"must deny every inbound connection"*'
  else
    fail "compile azure/bicep/vm.bicep" "az bicep build failed"
  fi

  # customData cannot change on an existing VM: the cloud-init file carries no template
  # placeholder, and a change of its content must be deliberate (existing VMs keep the old
  # bootstrap; record the new checksum in azure/cloud-init/gateway.yaml.sha256 with it).
  expect "the cloud-init file contains no template placeholder" \
    '"$(grep -cE "__[A-Z][A-Z_]*[A-Z]__" "${repo}/azure/cloud-init/gateway.yaml")" == 0'
  out="$(sha256sum <"${repo}/azure/cloud-init/gateway.yaml" | cut -d' ' -f1)"
  expect "the cloud-init file is the one whose checksum is recorded (customData of existing VMs cannot change)" \
    '"${out}" == "$(tr -d "[:space:]" <"${repo}/azure/cloud-init/gateway.yaml.sha256")"'
  # The userData document: vm.bicep writes exactly the keys apply-config.sh requires.
  out="$(awk '/^var vmConfig = \{/{inside = 1; next} inside && /^\}/{inside = 0} inside {sub(/:.*/, "", $1); print $1}' "${repo}/azure/bicep/vm.bicep" | sort | tr '\n' ' ')"
  referenced="$(sed -n "s/^required_keys='\(.*\)'$/\1/p" "${repo}/azure/vm/apply-config.sh" | tr ' ' '\n' | sort | tr '\n' ' ')"
  expect "vm.bicep writes exactly the userData keys apply-config.sh requires" '-n "${out}" && "${out}" == "${referenced}"'
  expect "vm.bicep defaults to the Vector image the compose override pins and the tests run" \
    '"$(grep -cF "param vectorImage string = '"'"'${VECTOR_IMAGE}'"'"'" "${repo}/azure/bicep/vm.bicep")" == 1'

  # No tenant, subscription, client or principal id may be committed (public repository).
  out="$(grep -rhoE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' \
    "${repo}/azure" "${repo}/compose/docker-compose.azure.yml" "${repo}/docs/adr" "${repo}/.github/workflows" 2>/dev/null \
    | tr 'A-F' 'a-f' | sort -u \
    | grep -vE '^(3913510d-42f4-4e42-8a64-420c390055eb|4633458b-17de-408a-b874-0445c86b69e6|b86a8fe4-44ce-4948-aee5-eccb2c155cd7|7b0f3c52-5f0e-4c1e-9b1a-0d6c2f1a9e0[12]|0{8}-0{4}-0{4}-0{4}-0{12}|1{8}-1{4}-1{4}-1{4}-1{12})$' | tr '\n' ' ')"
  expect "no GUID other than built-in role ids, workbook parameter ids and all-zero placeholders is committed" '-z "${out}"'
}

group_compose() {
  echo "== compose: the override merges with the reference file and keeps the hardening"
  local project="${work_dir}/project/compose" base both cert none service
  mkdir -p "${project}/secrets"
  cp "${repo}/compose/docker-compose.example.yml" "${repo}/compose/docker-compose.azure.yml" "${project}/"
  cp "${secrets_dir}/ib-username" "${secrets_dir}/ib-password" "${secrets_dir}/azure-client-cert.pfx" "${project}/secrets/"
  compose_json() {
    (cd "${project}" && DCR_LOGS_ENDPOINT=https://example-abcd.eastus-1.ingest.monitor.azure.com \
      DCR_IMMUTABLE_ID=dcr-00000000000000000000000000000000 \
      docker compose --project-name azpack-config "$@" config --format json 2>&1)
  }
  base="$(compose_json -f docker-compose.example.yml)"
  none="$(compose_json -f docker-compose.example.yml -f docker-compose.azure.yml)"
  both="$(compose_json -f docker-compose.example.yml -f docker-compose.azure.yml --profile azure)"
  cert="$(compose_json -f docker-compose.example.yml -f docker-compose.azure.yml --profile azure-cert)"
  expect "docker compose config accepts the override with profile azure" \
    '"$(printf "%s" "${both}" | jq_cli -r ".services | keys | join(\",\")")" == "ib-gateway,vector"'
  expect "profile azure-cert starts the certificate variant with its secret" \
    '"$(printf "%s" "${cert}" | jq_cli -r "[(.services | keys | join(\",\")), (.services[\"vector-cert\"].secrets | map(.source) | join(\",\"))] | join(\" \")")" == "ib-gateway,vector-cert ib-username,azure-client-cert"'
  expect "without a profile no shipper is started" \
    '"$(printf "%s" "${none}" | jq_cli -r ".services | keys | join(\",\")")" == "ib-gateway"'
  # The Vector image is named in two files: the compose override (what this suite runs) and the
  # default of the VM template (what a VM would pull). They must be the same image, or a VM
  # ships with a shipper nobody tested.
  local compose_vector vm_vector
  compose_vector="$(sed -n 's/^[[:space:]]*image:[[:space:]]*\(timberio\/vector[^[:space:]]*\).*/\1/p' "${repo}/compose/docker-compose.azure.yml" | head -n 1)"
  vm_vector="$(sed -n "s/^param vectorImage string = '\(timberio\/vector[^']*\)'.*/\1/p" "${repo}/azure/bicep/vm.bicep" | head -n 1)"
  # shellcheck disable=SC2016  # evaluated by expect
  expect "the VM template's default Vector image is the one the compose override pins" \
    '-n "${compose_vector}" && "${vm_vector}" == "${compose_vector}"'
  expect "the override leaves the gateway service exactly as the reference file defines it" \
    '"$(printf "%s" "${base}" | jq_cli -cS ".services[\"ib-gateway\"]")" == "$(printf "%s" "${both}" | jq_cli -cS ".services[\"ib-gateway\"]")" && "${base}" == *"ib-gateway"*'
  for service in vector vector-cert; do
    if [[ "${service}" == vector ]]; then out="${both}"; else out="${cert}"; fi
    # shellcheck disable=SC2034  # read by expect through eval
    facts="$(printf '%s' "${out}" | jq_cli -r --arg s "${service}" '.services[$s] | [
      (.image | test("^timberio/vector:[0-9.]+-alpine@sha256:[0-9a-f]{64}$")),
      .user == "1000:1000", .read_only == true, .cap_drop == ["ALL"],
      (.security_opt | index("no-new-privileges:true") != null),
      (has("ports") | not), (has("privileged") | not), (has("network_mode") | not),
      ([.volumes[] | select(.source | test("docker.sock"))] | length == 0),
      ([.volumes[] | select(.target != "/var/tmp") | .read_only] | all),
      ([.volumes[] | select(.read_only != true) | .target] == ["/var/tmp"]),
      .restart == "unless-stopped"
    ] | map(tostring) | join(" ")')"
    expect "${service}: digest pin, uid 1000, read-only root, no capability, no port, no docker.sock, one writable volume" \
      '"${facts}" == "true true true true true true true true true true true true"'
    # The shipper shares the host with the gateway: a parsing storm (a log file of megabyte
    # lines) must not take the CPU, the memory or the process table away from it.
    # shellcheck disable=SC2034  # read by expect through eval
    limits="$(printf '%s' "${out}" | jq_cli -r --arg s "${service}" '.services[$s] | [
      ((.cpus // 0) > 0 and (.cpus // 0) <= 1),
      ((.mem_limit // "0" | tonumber) > 0 and (.mem_limit // "0" | tonumber) <= 1073741824),
      ((.pids_limit // 0) > 0 and (.pids_limit // 0) <= 1024)
    ] | map(tostring) | join(" ")')"
    expect "${service}: capped at one CPU, 1 GiB of memory and 1024 processes or less" \
      '"${limits}" == "true true true"'
  done
}

# cloud_init_script <name>: the content of /usr/local/sbin/<name> from the cloud-init file
# (only the first-boot bootstrap lives there; every other host script is a file in azure/vm).
cloud_init_script() {
  docker run --rm -i "${YQ_IMAGE}" ".write_files[] | select(.path == \"/usr/local/sbin/$1\") | .content" \
    <"${repo}/azure/cloud-init/gateway.yaml"
}

# in_ubuntu <name> <test script in azure/tests> <arguments...>: run a test script as root in
# the VM's distribution with azure/ mounted read-only, print its PASS/FAIL lines and count
# its failures. The scripts under test are the real files of azure/vm; only curl, docker and
# git are replaced inside the container.
in_ubuntu() {
  local name="$1" script="$2" out code
  shift 2
  out="$(docker run --rm --name "azpack-${name}-${run_id}" --tmpfs /run \
    -v "${host_repo}/azure:/azure:ro" "${UBUNTU_IMAGE}" bash "/azure/tests/${script}" "$@" 2>&1)"
  code=$?
  printf '%s\n' "${out}" | grep -E '^(PASS|FAIL)  ' || true
  failures=$((failures + $(printf '%s\n' "${out}" | grep -c '^FAIL  ' || true)))
  if [[ ${code} -ne 0 && "${out}" != *"FAIL  "* ]] || [[ "${out}" != *"PASS  "* ]]; then
    fail "${script} ran" "exit ${code}"
    show "${out}"
  fi
}

group_secrets() {
  echo "== secrets: the VM's host scripts (azure/vm) with fake curl, docker and git"
  in_ubuntu secrets fetch-secrets.test.sh /azure/vm/fetch-secrets.sh /azure/tests/fixtures/fake-curl.sh
  in_ubuntu apply apply-config.test.sh /azure/vm /azure/tests/fixtures
}

# unit_setting <unit file> <key>: the values of a key in a systemd unit, space-separated.
unit_setting() { sed -n "s/^$2=//p" "$1" | tr '\n' ' '; }

group_lint() {
  echo "== lint: shell scripts, systemd units, cloud-init, workflow, JSON and YAML files"
  local scripts="${work_dir}/lint" name out stack="${repo}/azure/vm/ibgw-stack.service"
  mkdir -p "${scripts}"
  cloud_init_script ibgw-bootstrap.sh >"${scripts}/ibgw-bootstrap.sh"
  docker run --rm -i "${YQ_IMAGE}" '.write_files[] | select(.path == "/etc/systemd/system/ibgw-bootstrap.service") | .content' \
    <"${repo}/azure/cloud-init/gateway.yaml" >"${scripts}/ibgw-bootstrap.service"
  cp "${repo}/.shellcheckrc" "${scripts}/.shellcheckrc"
  chmod -R a+rX "${scripts}"
  expect "the cloud-init file starts with #cloud-config and carries the bootstrap script and its unit" \
    '"$(head -n 1 "${repo}/azure/cloud-init/gateway.yaml")" == "#cloud-config" && -s "${scripts}/ibgw-bootstrap.sh" && -s "${scripts}/ibgw-bootstrap.service"'
  # A restart of Docker must not restart the gateway: the stack unit may only ORDER itself
  # after docker.service (Wants + After). Requires/BindsTo/PartOf would propagate a restart.
  expect "the stack unit is ordered after Docker but not bound to it (a Docker restart leaves the gateway alone)" \
    '"$(unit_setting "${stack}" Wants)" == *"docker.service"* && "$(unit_setting "${stack}" After)" == *"docker.service"* && -z "$(unit_setting "${stack}" Requires)$(unit_setting "${stack}" BindsTo)$(unit_setting "${stack}" PartOf)"'
  expect "the stack unit fetches the secrets before it starts the stack, and retries with a growing delay" \
    '"$(unit_setting "${stack}" ExecStartPre)" == "/usr/local/sbin/fetch-secrets.sh " && "$(unit_setting "${stack}" ExecStart)" == *"ibgw-compose.sh up"* && "$(unit_setting "${stack}" Restart)" == "on-failure " && -n "$(unit_setting "${stack}" RestartMaxDelaySec)"'
  expect "the first-boot bootstrap is a unit that retries with a growing delay until it succeeded once" \
    '"$(unit_setting "${scripts}/ibgw-bootstrap.service" Restart)" == "on-failure " && -n "$(unit_setting "${scripts}/ibgw-bootstrap.service" RestartMaxDelaySec)" && "$(unit_setting "${scripts}/ibgw-bootstrap.service" ConditionPathExists)" == "!/var/lib/ibgateway/bootstrap.done "'
  out="$(jq_cli -r '."live-restore"' <"${repo}/azure/vm/daemon.json" 2>&1)"
  expect "the Docker daemon keeps containers alive across its own restart (live-restore)" '"${out}" == "true"'
  # cloud-init's own validator, from the distribution the VM runs (needs the package archive).
  check "cloud-init schema: azure/cloud-init/gateway.yaml is valid for Ubuntu's cloud-init" \
    docker run --rm --name "azpack-cloudinit-${run_id}" -v "${host_repo}/azure/cloud-init:/ci:ro" \
    "${UBUNTU_IMAGE}" bash -c '
      export DEBIAN_FRONTEND=noninteractive
      { apt-get update && apt-get install --yes --no-install-recommends cloud-init; } >/dev/null 2>&1 || exit 90
      cloud-init schema --config-file /ci/gateway.yaml'
  check "shellcheck: the bootstrap script embedded in the cloud-init file" \
    docker run --rm -v "$(host_path "${scripts}"):/mnt:ro" -w /mnt "${SHELLCHECK_IMAGE}" ibgw-bootstrap.sh
  check "shellcheck: azure/vm/*.sh, azure/tests/*.sh and the test doubles" \
    docker run --rm -v "${host_repo}:/mnt:ro" -w /mnt "${SHELLCHECK_IMAGE}" -x \
    azure/vm/install.sh azure/vm/apply-config.sh azure/vm/fetch-secrets.sh azure/vm/ibgw-compose.sh \
    azure/tests/run.sh azure/tests/fetch-secrets.test.sh azure/tests/apply-config.test.sh \
    azure/tests/fixtures/fake-curl.sh azure/tests/fixtures/fake-docker.sh azure/tests/fixtures/fake-git.sh
  check "shellcheck: azure/vector/entrypoint.sh as POSIX sh" \
    docker run --rm -v "${host_repo}:/mnt:ro" -w /mnt "${SHELLCHECK_IMAGE}" --shell=sh \
    azure/vector/entrypoint.sh
  check "shfmt: azure shell scripts are formatted like the rest of the repository" \
    docker run --rm -v "${host_repo}:/work:ro" -w /work "${SHFMT_IMAGE}" -i 2 -ci -bn -d \
    azure/vm/install.sh azure/vm/apply-config.sh azure/vm/fetch-secrets.sh azure/vm/ibgw-compose.sh \
    azure/tests/run.sh azure/tests/fetch-secrets.test.sh azure/tests/apply-config.test.sh \
    azure/tests/fixtures/fake-curl.sh azure/tests/fixtures/fake-docker.sh azure/tests/fixtures/fake-git.sh \
    azure/vector/entrypoint.sh
  for name in azure/cloud-init/gateway.yaml azure/vector/vector.yaml azure/vector/sinks-managed-identity.yaml \
    azure/vector/sinks-certificate.yaml compose/docker-compose.azure.yml .github/workflows/azure-pack.yml; do
    out="$(docker run --rm -i "${YQ_IMAGE}" 'tag' <"${repo}/${name}" 2>&1)"
    expect "YAML parses: ${name}" '"${out}" == "!!map"'
  done
  for name in azure/workbook/gateway.workbook.json azure/bicep/bicepconfig.json; do
    out="$(jq_cli -r 'type' <"${repo}/${name}" 2>&1)"
    expect "JSON parses: ${name}" '"${out}" == "object"'
  done
  check "actionlint: .github/workflows/azure-pack.yml" \
    docker run --rm -v "${host_repo}:/repo:ro" -w /repo "${ACTIONLINT_IMAGE}" -color .github/workflows/azure-pack.yml
  # -U: grep on Windows otherwise strips the carriage return before matching.
  out="$(grep -rlIU "${carriage_return}" "${repo}/azure" "${repo}/compose/docker-compose.azure.yml" "${repo}/.github/workflows/azure-pack.yml" 2>/dev/null | tr '\n' ' ')"
  expect "every file of the pack has LF line endings" '-z "${out}"'
  expect "azure/README.md ends with the trademark sentence" \
    '"$(tail -n 2 "${repo}/azure/README.md" | tr "\n" " ")" == *"Interactive Brokers, IBKR, IB Gateway and Trader Workstation are trademarks of Interactive Brokers LLC. This project is not affiliated with, endorsed by or sponsored by Interactive Brokers."*'
}

groups=("$@")
if [[ ${#groups[@]} -eq 0 ]]; then
  groups=(vector entrypoint pipeline drift kql kql-run bicep compose secrets lint)
fi
for group in "${groups[@]}"; do
  case "${group}" in
    vector) group_vector ;;
    entrypoint) group_entrypoint ;;
    pipeline) group_pipeline ;;
    drift) group_drift ;;
    kql) group_kql ;;
    kql-run) group_kql_run ;;
    bicep) group_bicep ;;
    compose) group_compose ;;
    secrets) group_secrets ;;
    lint) group_lint ;;
    *) fail "group ${group}" "unknown group" ;;
  esac
done

if [[ ${failures} -gt 0 ]]; then
  echo "${failures} test(s) failed"
  exit 1
fi
echo "all tests passed"
