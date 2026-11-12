#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # expect() takes its condition single-quoted and evaluates it later; the variables it names look unused
# Tests of azure/vm/fetch-secrets.sh, run by azure/tests/run.sh as root inside an Ubuntu
# container: the real script, real jq, install and mv; only curl is replaced by
# fixtures/fake-curl.sh (the HTTP boundary).
#
# Usage:  fetch-secrets.test.sh <path of fetch-secrets.sh> <path of fake-curl.sh>
# Exit:   0 when every test passed. Each test prints PASS/FAIL with its reason.
# Every user name, password and token in here is a canary, not a real credential.
set -uo pipefail

script="$1"
fake_curl="$2"
failures=0
pass() { echo "PASS  $1"; }
fail() {
  echo "FAIL  $1: $2"
  failures=$((failures + 1))
}

export DEBIAN_FRONTEND=noninteractive
if ! command -v jq >/dev/null 2>&1; then
  if ! { apt-get update && apt-get install --yes --no-install-recommends jq; } >/dev/null 2>&1; then
    echo "FAIL  install jq in the test container: apt-get failed"
    exit 1
  fi
fi
install -m 0755 "${fake_curl}" /usr/local/bin/curl

export IBGW_KEY_VAULT=kv-test
export IBGW_SECRETS_DIR=/run/ibgateway-secrets
export FAKE_CURL_LOG=/tmp/fake-curl.log
expected_password='hunter2"hunter2\tail $x'
output=""
status=0

# run_script <scenario>: runs the script, keeps its combined output and exit status.
run_script() {
  : >"${FAKE_CURL_LOG}"
  output="$(FAKE_SCENARIO="$1" bash "${script}" 2>&1)"
  status=$?
}

# expect <name> <condition as a string for [[ ]]>
expect() {
  if eval "[[ $2 ]]"; then pass "$1"; else fail "$1" "condition not met: $2 (status ${status}, output: ${output})"; fi
}

run_script ok
expect "both secrets are fetched" '${status} -eq 0'
expect "the user name is written exactly, without a newline" '"$(cat "${IBGW_SECRETS_DIR}/ib-username")" == "CANARY_USER_zq7" && "$(wc -c <"${IBGW_SECRETS_DIR}/ib-username")" -eq 15'
expect "a password with quotes, a backslash and a dollar sign survives unchanged" '"$(cat "${IBGW_SECRETS_DIR}/ib-password")" == "${expected_password}"'
expect "the files are 0400 and owned by uid 1000" '"$(stat -c "%a %u %g" "${IBGW_SECRETS_DIR}/ib-username" "${IBGW_SECRETS_DIR}/ib-password" | sort -u)" == "400 1000 1000"'
expect "the directory is 0500 and owned by uid 1000" '"$(stat -c "%a %u %g" "${IBGW_SECRETS_DIR}")" == "500 1000 1000"'
expect "no temporary file is left next to the secrets" '"$(find "${IBGW_SECRETS_DIR}" -mindepth 1 | sort | tr "\n" " ")" == "${IBGW_SECRETS_DIR}/ib-password ${IBGW_SECRETS_DIR}/ib-username "'
expect "no working directory is left in /run" '-z "$(find /run -maxdepth 1 -name "fetch-secrets.*")"'
expect "the output shows neither the token nor a secret value" '"${output}" != *CANARY_TOKEN* && "${output}" != *CANARY_USER* && "${output}" != *hunter2*'
arguments="$(cat "${FAKE_CURL_LOG}")"
expect "neither the token nor a secret value is ever on a command line" '"${arguments}" != *CANARY_TOKEN* && "${arguments}" != *CANARY_USER* && "${arguments}" != *hunter2*'
expect "the secrets are requested from the configured vault" '"${arguments}" == *"https://kv-test.vault.azure.net/secrets/ib-username?api-version=7.4"*'

run_script ok
expect "a second run succeeds and leaves the same files" '${status} -eq 0 && "$(cat "${IBGW_SECRETS_DIR}/ib-username")" == "CANARY_USER_zq7"'

# Docker creates a directory when a bind source is missing; the script must replace it.
rm -f "${IBGW_SECRETS_DIR}/ib-username" && mkdir "${IBGW_SECRETS_DIR}/ib-username"
run_script ok
expect "a directory left by Docker at a secret path is replaced by the file" '${status} -eq 0 && -f "${IBGW_SECRETS_DIR}/ib-username" && "$(cat "${IBGW_SECRETS_DIR}/ib-username")" == "CANARY_USER_zq7"'

rm -rf "${IBGW_SECRETS_DIR}"
run_script missing-password
expect "a secret that is not set yet stops with exit 2 and names the secret" '${status} -eq 2 && "${output}" == *"ib-password is not set"*'
expect "nothing is written when one secret is missing" '! -e "${IBGW_SECRETS_DIR}"'

run_script forbidden
expect "a refused identity stops with exit 3" '${status} -eq 3 && "${output}" == *"Key Vault Secrets User"*'

run_script no-identity
expect "no managed identity stops with exit 1" '${status} -eq 1 && "${output}" == *"instance metadata service"*'

run_script empty-username
expect "an empty secret stops with exit 5 and writes nothing" '${status} -eq 5 && ! -e "${IBGW_SECRETS_DIR}"'

# On the VM the vault name is not in the environment: it comes from the configuration that
# apply-config.sh renders from the VM's userData.
unset IBGW_KEY_VAULT
export IBGW_CONFIG=/tmp/ibgw-config.json
printf '{"keyVaultName":"kv-from-config"}\n' >"${IBGW_CONFIG}"
run_script ok
arguments="$(cat "${FAKE_CURL_LOG}")"
expect "without IBGW_KEY_VAULT the vault name comes from config.json" \
  '${status} -eq 0 && "${arguments}" == *"https://kv-from-config.vault.azure.net/secrets/ib-password?api-version=7.4"*'

rm -rf "${IBGW_SECRETS_DIR}" "${IBGW_CONFIG}"
run_script ok
expect "without any vault name it stops with exit 6 before asking for a token" \
  '${status} -eq 6 && ! -s "${FAKE_CURL_LOG}" && ! -e "${IBGW_SECRETS_DIR}"'

printf '{"keyVaultName":"not a vault; name"}\n' >"${IBGW_CONFIG}"
run_script ok
expect "a configured value that is not a vault name is refused with exit 6" \
  '${status} -eq 6 && ! -s "${FAKE_CURL_LOG}" && ! -e "${IBGW_SECRETS_DIR}"'

if [[ ${failures} -gt 0 ]]; then
  echo "${failures} test(s) failed"
  exit 1
fi
