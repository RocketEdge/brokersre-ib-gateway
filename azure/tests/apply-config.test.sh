#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # expect() takes its condition single-quoted and evaluates it later; the variables it names look unused
# Tests of azure/vm/apply-config.sh, run by azure/tests/run.sh as root inside an Ubuntu
# container: the real script with real jq, base64, tar and sha256sum; only the three
# boundaries are replaced: curl (the instance metadata service), docker and git
# (fixtures/fake-curl.sh, fake-docker.sh, fake-git.sh).
#
# Usage:  apply-config.test.sh <directory of azure/vm> <directory of the fixtures>
# Exit:   0 when every test passed. Each test prints PASS/FAIL with its reason.
set -uo pipefail

vm_dir="$1"
fixtures="$2"
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
install -m 0755 "${fixtures}/fake-curl.sh" /usr/local/bin/curl
install -m 0755 "${fixtures}/fake-docker.sh" /usr/local/bin/docker
install -m 0755 "${fixtures}/fake-git.sh" /usr/local/bin/git

export IBGW_ROOT=/tmp/ibgw
export FAKE_PACKS=/tmp/packs FAKE_GIT_STATE=/tmp/git-state FAKE_DOCKER_LOG=/tmp/docker.log
export FAKE_CURL_LOG=/tmp/curl.log FAKE_SCENARIO=ok FAKE_USERDATA_FILE=/tmp/userdata.json
export INSTALL_LOG=/tmp/install.log
commit_one=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
commit_two=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
commit_three=cccccccccccccccccccccccccccccccccccccccc
gateway_one="ghcr.io/rocketedge/brokersre-ib-gateway@sha256:$(printf '1%.0s' {1..64})"
gateway_two="ghcr.io/rocketedge/brokersre-ib-gateway@sha256:$(printf '2%.0s' {1..64})"
vector_one="timberio/vector:0.61.0-alpine@sha256:$(printf '3%.0s' {1..64})"
vector_two="timberio/vector:0.62.0-alpine@sha256:$(printf '4%.0s' {1..64})"

# make_pack <commit> <text of the reference compose file>: one commit of the "remote".
make_pack() {
  mkdir -p "${FAKE_PACKS}/$1/compose" "${FAKE_PACKS}/$1/azure/vector" "${FAKE_PACKS}/$1/azure/vm"
  printf '%s\n' "$2" >"${FAKE_PACKS}/$1/compose/docker-compose.example.yml"
  printf 'services: {}\n' >"${FAKE_PACKS}/$1/compose/docker-compose.azure.yml"
  printf 'data_dir: /var/tmp/vector\n' >"${FAKE_PACKS}/$1/azure/vector/vector.yaml"
  # Stands in for install.sh of that commit: records that its files were installed.
  printf '#!/usr/bin/env bash\necho "install %s $*" >>"${INSTALL_LOG}"\n' "$1" >"${FAKE_PACKS}/$1/azure/vm/install.sh"
  chmod 0755 "${FAKE_PACKS}/$1/azure/vm/install.sh"
}
make_pack "${commit_one}" 'services: {ib-gateway: {image: placeholder}}'
make_pack "${commit_two}" 'services: {ib-gateway: {image: placeholder}}'
make_pack "${commit_three}" 'services: {ib-gateway: {image: placeholder, stop_grace_period: 90s}}'

# user_data <jq filter>: write the VM's userData, the base document changed by the filter.
user_data() {
  jq --null-input --arg gateway "${gateway_one}" --arg vector "${vector_one}" --arg commit "${commit_one}" '{
    schemaVersion: 1, gatewayImage: $gateway, vectorImage: $vector,
    packRepository: "https://github.com/RocketEdge/brokersre-ib-gateway.git", packCommit: $commit,
    instanceLabel: "paper-1", hostLabel: "ibgw-vm", shipRawLogs: false, tradingMode: "paper",
    readOnlyApi: "yes", timeZone: "America/New_York", autoRestartTime: "11:45 PM",
    dcrLogsEndpoint: "https://ibgw-dcr-abcd.eastus-1.ingest.monitor.azure.com",
    dcrImmutableId: "dcr-00000000000000000000000000000000", keyVaultName: "kv-ibgw-test"
  } | '"$1" >"${FAKE_USERDATA_FILE}"
}

output=""
status=0
# apply <arguments...>: run the script, keep its output and exit status, start a fresh call log.
apply() {
  : >"${FAKE_DOCKER_LOG}"
  output="$(bash "${vm_dir}/apply-config.sh" "$@" 2>&1)"
  status=$?
}
# expect <name> <condition as a string for [[ ]]>
expect() {
  if eval "[[ $2 ]]"; then pass "$1"; else fail "$1" "condition not met: $2 (status ${status}, output: ${output})"; fi
}
stack_started() { grep -q ' up ' "${FAKE_DOCKER_LOG}"; }
overlay="${IBGW_ROOT}/docker-compose.vm.yml"

user_data '.'
apply --initial
expect "first boot: the configuration is rendered and the pack checked out, the stack is not touched" \
  '${status} -eq 0 && "$(cat "${FAKE_GIT_STATE}/head")" == "${commit_one}" && -s "${IBGW_ROOT}/.env" && -s "${overlay}"'
expect "first boot: docker compose up is left to the stack unit" '! -s "${FAKE_DOCKER_LOG}" || "$(grep -c " up " "${FAKE_DOCKER_LOG}")" == 0'
expect "the env file carries the settings, no secret" \
  '"$(sort "${IBGW_ROOT}/.env" | grep -v "^#" | tr "\n" " ")" == "AUTO_RESTART_TIME=11:45 PM DCR_IMMUTABLE_ID=dcr-00000000000000000000000000000000 DCR_LOGS_ENDPOINT=https://ibgw-dcr-abcd.eastus-1.ingest.monitor.azure.com HOST_LABEL=ibgw-vm IBGW_INSTANCE=paper-1 IBGW_REDACT_USERNAME_FILE= READ_ONLY_API=yes SHIP_RAW_LOGS=no TIME_ZONE=America/New_York TRADING_MODE=paper "'
expect "the overlay pins both images by digest and points the secrets at tmpfs" \
  '"$(grep -c "${gateway_one}" "${overlay}")" == 1 && "$(grep -c "${vector_one}" "${overlay}")" == 1 && "$(grep -c "/run/ibgateway-secrets/ib-" "${overlay}")" == 2'
expect "the Key Vault name is kept for fetch-secrets.sh" '"$(jq -r .keyVaultName "${IBGW_ROOT}/config.json")" == "kv-ibgw-test"'
expect "the scripts of the checked-out commit are installed" '"$(cat "${INSTALL_LOG}")" == "install ${commit_one} files"'

export FAKE_GATEWAY_EXISTS=1
apply
expect "nothing changed: nothing is applied" '${status} -eq 0 && "${output}" == *"nothing to apply"*'
expect "nothing changed: the stack is not touched" '"$(grep -c " up " "${FAKE_DOCKER_LOG}")" == 0'

user_data '.vectorImage = "'"${vector_two}"'" | .shipRawLogs = true'
apply
expect "a change that only concerns the shipper is applied without asking" '${status} -eq 0 && "$(grep -c " up " "${FAKE_DOCKER_LOG}")" == 1'
expect "the raw-log switch reaches the env file" '"$(grep -c "^IBGW_REDACT_USERNAME_FILE=/run/secrets/ib-username$" "${IBGW_ROOT}/.env")" == 1 && "$(grep -c "${vector_two}" "${overlay}")" == 1'
expect "a shipper-only change does not announce a gateway restart" '"${output}" != *"IBKR login"*'

user_data '.vectorImage = "'"${vector_two}"'" | .shipRawLogs = true | .gatewayImage = "'"${gateway_two}"'"'
apply
expect "a change that re-creates the gateway stops and says so" '${status} -eq 3 && "${output}" == *"new IBKR login"* && "${output}" == *"--restart-gateway"*'
expect "and changes nothing" '"$(grep -c "${gateway_one}" "${overlay}")" == 1 && "$(grep -c " up " "${FAKE_DOCKER_LOG}")" == 0'

export FAKE_PHASE=2fa-pending
apply --restart-gateway
expect "even with --restart-gateway it refuses while a second factor is pending" '${status} -eq 4 && "${output}" == *"2fa-pending"*'
expect "and changes nothing then either" '"$(grep -c "${gateway_one}" "${overlay}")" == 1 && "$(grep -c " up " "${FAKE_DOCKER_LOG}")" == 0'

export FAKE_PHASE=logged-in
apply --restart-gateway
expect "with --restart-gateway and no pending second factor the gateway change is applied" \
  '${status} -eq 0 && "$(grep -c "${gateway_two}" "${overlay}")" == 1 && "$(grep -c " up " "${FAKE_DOCKER_LOG}")" == 1 && "${output}" == *"new IBKR login"*'

user_data '.vectorImage = "'"${vector_two}"'" | .shipRawLogs = true | .gatewayImage = "ghcr.io/rocketedge/brokersre-ib-gateway:stable"'
apply --restart-gateway
expect "an image that is not pinned by digest is refused and names the field" '${status} -eq 2 && "${output}" == *"gatewayImage"*'
expect "and the running configuration stays" '"$(grep -c "${gateway_two}" "${overlay}")" == 1 && "$(grep -c " up " "${FAKE_DOCKER_LOG}")" == 0'

user_data '.vectorImage = "'"${vector_two}"'" | .shipRawLogs = true | .gatewayImage = "'"${gateway_two}"'" | .instanceLabel = "U1234567"'
apply --restart-gateway
expect "an instance label that looks like an account id is refused" '${status} -eq 2 && "${output}" == *"instanceLabel"*'

user_data '.vectorImage = "'"${vector_two}"'" | .shipRawLogs = true | .gatewayImage = "'"${gateway_two}"'" | .instanceLabel = "deskDU1234567"'
apply --restart-gateway
expect "an instance label with an account id glued to a word is refused (the redaction would change it)" '${status} -eq 2 && "${output}" == *"instanceLabel"*'

user_data '.vectorImage = "'"${vector_two}"'" | .shipRawLogs = true | .gatewayImage = "'"${gateway_two}"'" | .packCommit = "'"${commit_two}"'"'
apply
expect "a new pack commit that leaves the gateway definition alone is applied without asking" \
  '${status} -eq 0 && "$(cat "${FAKE_GIT_STATE}/head")" == "${commit_two}" && "$(tail -n 1 "${INSTALL_LOG}")" == "install ${commit_two} files"'

user_data '.vectorImage = "'"${vector_two}"'" | .shipRawLogs = true | .gatewayImage = "'"${gateway_two}"'" | .packCommit = "'"${commit_three}"'"'
apply
expect "a new pack commit that changes the gateway definition needs --restart-gateway" \
  '${status} -eq 3 && "$(cat "${FAKE_GIT_STATE}/head")" == "${commit_two}"'
apply --restart-gateway
expect "and is applied with it" '${status} -eq 0 && "$(cat "${FAKE_GIT_STATE}/head")" == "${commit_three}"'

user_data '.vectorImage = "'"${vector_two}"'" | .shipRawLogs = true | .gatewayImage = "'"${gateway_two}"'" | .packCommit = "dddddddddddddddddddddddddddddddddddddddd"'
apply --restart-gateway
expect "a commit the repository does not have fails and leaves the checkout alone" '${status} -eq 5 && "$(cat "${FAKE_GIT_STATE}/head")" == "${commit_three}"'

export FAKE_GATEWAY_EXISTS=0
user_data '.vectorImage = "'"${vector_two}"'" | .shipRawLogs = true | .gatewayImage = "'"${gateway_one}"'" | .packCommit = "'"${commit_three}"'"'
apply
expect "without a gateway container there is nothing to restart: the change is applied" '${status} -eq 0 && "$(grep -c "${gateway_one}" "${overlay}")" == 1'

FAKE_SCENARIO=no-identity apply
expect "an unreachable metadata service fails without touching anything" '${status} -eq 5 && "$(grep -c "${gateway_one}" "${overlay}")" == 1'

if [[ ${failures} -gt 0 ]]; then
  echo "${failures} test(s) failed"
  exit 1
fi
