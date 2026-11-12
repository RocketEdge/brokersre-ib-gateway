#!/usr/bin/env bash
# apply-config.sh [--initial] [--restart-gateway]   (installed to /usr/local/sbin by install.sh)
#
# Purpose   Bring this VM in line with its userData. The template (azure/bicep/vm.bicep) keeps
#           every setting an operator may want to change later in the VM's userData, which
#           can be changed in place and read from the instance metadata service; customData
#           cannot change after the VM was created. After redeploying the template with new
#           values, run this script (az vm run-command invoke ... --scripts
#           "/usr/local/sbin/apply-config.sh"):
#             1. read and validate the userData (nothing is touched when it is invalid);
#             2. render .env, docker-compose.vm.yml and config.json into a staging directory
#                and fetch the pinned commit of the repository;
#             3. decide whether applying would re-create the gateway container (its compose
#                configuration hash changes: image digest, a setting that reaches it, or its
#                definition in the new commit);
#             4. apply: install the staged files, check out the commit, install that commit's
#                scripts, docker compose up (only changed services are re-created).
# Gateway   A re-created gateway container means a restarted IB Gateway: a new IBKR login
#           with second-factor approval. The script therefore SAYS SO and stops (exit 3)
#           unless --restart-gateway is given, and even then refuses (exit 4) while the
#           gateway's phase is 2fa-pending, because a human is approving at that moment.
#           A change that only concerns the shipper is applied without the flag.
# --initial First boot (install.sh): render and check out only; the stack unit starts it.
# Env       IBGW_ROOT (default /opt/ibgateway), IBGW_USERDATA_URL (sovereign clouds, tests).
# Exit      0 applied or nothing to apply; 2 invalid userData; 3 the gateway would restart and
#           --restart-gateway was not given; 4 refused, second factor pending; 5 the userData
#           or the commit could not be fetched. The decisive lines are printed last, because
#           az vm run-command keeps only the end of the output.
set -euo pipefail
umask 022

root="${IBGW_ROOT:-/opt/ibgateway}"
staging="${root}/staging"
userdata_url="${IBGW_USERDATA_URL:-http://169.254.169.254/metadata/instance/compute/userData?api-version=2021-01-01&format=text}"
# The keys of the userData document; vm.bicep writes exactly these (azure/tests/run.sh
# compares the two lists).
required_keys='schemaVersion gatewayImage vectorImage packRepository packCommit instanceLabel hostLabel shipRawLogs tradingMode readOnlyApi timeZone autoRestartTime dcrLogsEndpoint dcrImmutableId keyVaultName'

initial=no
restart_gateway=no
for argument in "$@"; do
  case "${argument}" in
    --initial) initial=yes ;;
    --restart-gateway) restart_gateway=yes ;;
    *)
      echo "apply-config: unknown argument ${argument}" >&2
      exit 64
      ;;
  esac
done

say() { printf 'apply-config: %s\n' "$1"; }

# compose_at <configuration root> <docker compose arguments...>
compose_at() {
  local at="$1"
  shift
  docker compose --project-name ibgw --env-file "${at}/.env" \
    --file "${at}/pack/compose/docker-compose.example.yml" \
    --file "${at}/pack/compose/docker-compose.azure.yml" \
    --file "${at}/docker-compose.vm.yml" \
    --profile azure "$@"
}

rm -rf "${staging}"
mkdir -p "${staging}/pack"

# 1. The userData document.
if ! curl --silent --show-error --fail --retry 5 --retry-delay 2 --max-time 20 \
  --header 'Metadata: true' "${userdata_url}" --output "${staging}/userdata.b64"; then
  say "the instance metadata service did not return the VM's userData; nothing was changed"
  exit 5
fi
if ! base64 --decode "${staging}/userdata.b64" >"${staging}/userdata.json" 2>/dev/null \
  || ! jq --exit-status 'type == "object"' "${staging}/userdata.json" >/dev/null 2>&1; then
  say "the VM's userData is not a JSON object; nothing was changed"
  exit 2
fi
# One line per problem; the patterns keep every value safe to write into the files below
# (no quote, no line break) and refuse what the stack would refuse later.
problems="$(jq --raw-output --arg keys "${required_keys}" '
  # The same rule as azure/vector/entrypoint.sh: a label the redaction would rewrite is refused.
  def good_label: type == "string" and test("^[A-Za-z0-9._-]{1,64}$")
    and (test("((^|[^A-Za-z0-9])([Dd][UuFf]|[UuFf])|[a-z](DU|DF|U|F))[0-9]{5,9}([^A-Za-z0-9]|$)") | not);
  . as $d
  | (($keys | split(" ")) - ($d | keys) | map("\(.) is missing")[]),
    (if ($d.schemaVersion == 1) then empty else "schemaVersion must be 1" end),
    (if ($d.gatewayImage | type == "string" and test("^[a-z0-9./_-]+@sha256:[0-9a-f]{64}$")) then empty else "gatewayImage must be pinned by digest (name@sha256:<64 hex>)" end),
    (if ($d.vectorImage | type == "string" and test("^[a-z0-9./_-]+(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}$")) then empty else "vectorImage must be pinned by digest (name:tag@sha256:<64 hex>)" end),
    (if ($d.packRepository | type == "string" and test("^https://[A-Za-z0-9./_-]+$")) then empty else "packRepository must be an https URL" end),
    (if ($d.packCommit | type == "string" and test("^[0-9a-f]{40}$")) then empty else "packCommit must be a full 40-character commit id" end),
    (if ($d.instanceLabel | good_label) then empty else "instanceLabel must be 1 to 64 letters, digits, dots, underscores or hyphens and must not look like an account id" end),
    (if ($d.hostLabel | good_label) then empty else "hostLabel must be 1 to 64 letters, digits, dots, underscores or hyphens and must not look like an account id" end),
    (if ($d.shipRawLogs | type == "boolean") then empty else "shipRawLogs must be true or false" end),
    (if ($d.tradingMode | IN("paper", "live")) then empty else "tradingMode must be paper or live" end),
    (if ($d.readOnlyApi | IN("yes", "no")) then empty else "readOnlyApi must be yes or no" end),
    (if ($d.timeZone | type == "string" and test("^[A-Za-z0-9_+/-]{1,64}$")) then empty else "timeZone must be an IANA time zone name" end),
    (if ($d.autoRestartTime | type == "string" and test("^[0-9]{1,2}:[0-9]{2}( (AM|PM))?$")) then empty else "autoRestartTime must look like 11:45 PM or 23:45" end),
    (if ($d.dcrLogsEndpoint | type == "string" and test("^https://[A-Za-z0-9.-]+$")) then empty else "dcrLogsEndpoint must be the https logs ingestion endpoint" end),
    (if ($d.dcrImmutableId | type == "string" and test("^dcr-[0-9a-f]{32}$")) then empty else "dcrImmutableId must be dcr- and 32 hex characters" end),
    (if ($d.keyVaultName | type == "string" and test("^[A-Za-z0-9-]{3,24}$")) then empty else "keyVaultName must be a Key Vault name" end)
' "${staging}/userdata.json")"
if [[ -n "${problems}" ]]; then
  say "the VM's userData is not valid; nothing was changed:"
  printf '  %s\n' "${problems}"
  exit 2
fi

# 2. Render into the staging directory.
jq --arg keys "${required_keys}" '. as $d | reduce ($keys | split(" "))[] as $k ({}; .[$k] = $d[$k])' \
  "${staging}/userdata.json" >"${staging}/config.json"
jq --raw-output '
  "# Rendered by apply-config.sh from the VM userData (azure/bicep/vm.bicep). No secret here.",
  "TRADING_MODE=\(.tradingMode)",
  "READ_ONLY_API=\(.readOnlyApi)",
  "TIME_ZONE=\(.timeZone)",
  "AUTO_RESTART_TIME=\(.autoRestartTime)",
  "IBGW_INSTANCE=\(.instanceLabel)",
  "HOST_LABEL=\(.hostLabel)",
  "DCR_LOGS_ENDPOINT=\(.dcrLogsEndpoint)",
  "DCR_IMMUTABLE_ID=\(.dcrImmutableId)",
  "IBGW_REDACT_USERNAME_FILE=\(if .shipRawLogs then "/run/secrets/ib-username" else "" end)",
  "SHIP_RAW_LOGS=no"
' "${staging}/config.json" >"${staging}/.env"
jq --raw-output '
  "# Rendered by apply-config.sh from the VM userData; merged over the reference compose and",
  "# the Azure override of the pinned checkout (ibgw-compose.sh).",
  "services:",
  "  ib-gateway:",
  "    image: \"\(.gatewayImage)\"",
  "  vector:",
  "    image: \"\(.vectorImage)\"",
  "secrets:",
  "  ib-username:",
  "    file: /run/ibgateway-secrets/ib-username",
  "  ib-password:",
  "    file: /run/ibgateway-secrets/ib-password"
' "${staging}/config.json" >"${staging}/docker-compose.vm.yml"

repository="$(jq --raw-output .packRepository "${staging}/config.json")"
commit="$(jq --raw-output .packCommit "${staging}/config.json")"
git -C "${root}/pack" init --quiet
if ! git -C "${root}/pack" cat-file -e "${commit}^{commit}" 2>/dev/null \
  && ! git -C "${root}/pack" fetch --quiet --depth 1 "${repository}" "${commit}"; then
  say "commit ${commit} could not be fetched from ${repository}; nothing was changed"
  exit 5
fi
# The files of that commit that the stack and this host use, without touching the checkout.
git -C "${root}/pack" archive "${commit}" compose azure/vector azure/vm | tar --extract --directory "${staging}/pack"
current_commit="$(git -C "${root}/pack" rev-parse HEAD 2>/dev/null || true)"

# install_staged: put the staged configuration in place and switch the checkout.
install_staged() {
  install -m 0644 "${staging}/config.json" "${root}/config.json"
  install -m 0644 "${staging}/.env" "${root}/.env"
  install -m 0644 "${staging}/docker-compose.vm.yml" "${root}/docker-compose.vm.yml"
  git -C "${root}/pack" checkout --quiet --detach "${commit}"
  # The scripts and units of the commit that is now checked out (this script included).
  "${root}/pack/azure/vm/install.sh" files
  rm -rf "${staging}"
}

if [[ "${initial}" == yes ]]; then
  install_staged
  say "configuration rendered and commit ${commit} checked out; ibgw-stack.service starts the stack"
  exit 0
fi

# 3. What would change?
if [[ "${current_commit}" == "${commit}" ]] \
  && cmp --silent "${staging}/.env" "${root}/.env" \
  && cmp --silent "${staging}/docker-compose.vm.yml" "${root}/docker-compose.vm.yml" \
  && cmp --silent "${staging}/config.json" "${root}/config.json"; then
  rm -rf "${staging}"
  say "nothing to apply: the VM already runs its userData"
  exit 0
fi

gateway_restarts=no
gateway_container="$(docker ps --all --quiet --filter label=com.docker.compose.project=ibgw \
  --filter label=com.docker.compose.service=ib-gateway)"
if [[ -n "${gateway_container}" ]]; then
  # The hash docker compose itself uses to decide whether a service must be re-created.
  running_hash="$(compose_at "${root}" config --hash ib-gateway)"
  staged_hash="$(compose_at "${staging}" config --hash ib-gateway)"
  if [[ "${running_hash}" != "${staged_hash}" ]]; then gateway_restarts=yes; fi
fi

if [[ "${gateway_restarts}" == yes ]]; then
  if [[ "${restart_gateway}" != yes ]]; then
    rm -rf "${staging}"
    say "NOT applied. This change re-creates the gateway container: IB Gateway restarts and"
    say "needs a new IBKR login with second-factor approval. Nothing was changed."
    say "When a human is ready to approve, run: /usr/local/sbin/apply-config.sh --restart-gateway"
    exit 3
  fi
  phase="$(compose_at "${root}" exec -T ib-gateway cat /var/log/ibgateway/state/phase 2>/dev/null || true)"
  if [[ "${phase}" == 2fa-pending ]]; then
    rm -rf "${staging}"
    say "NOT applied. The gateway's phase is 2fa-pending: a second-factor approval is in"
    say "progress. Nothing was changed; run this again after the login completed."
    exit 4
  fi
fi

# 4. Apply.
install_staged
compose_at "${root}" up --detach --remove-orphans 2>&1 | tail -n 20 || {
  say "docker compose up failed; the configuration files are in place, see the lines above"
  exit 1
}
if [[ "${gateway_restarts}" == yes ]]; then
  say "applied. The gateway container was re-created: approve the new IBKR login (second factor)."
else
  say "applied. The gateway container was not touched."
fi
