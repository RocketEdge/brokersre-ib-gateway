#!/usr/bin/env bash
# fetch-secrets.sh: IBKR credentials from Key Vault into tmpfs (installed to /usr/local/sbin
# by install.sh; run by ibgw-stack.service before the compose stack starts).
#
# Purpose   Read the secrets ib-username and ib-password of the Key Vault with the VM's
#           managed identity (instance metadata service) and write them to
#           /run/ibgateway-secrets (tmpfs: gone at power-off, never on a disk).
# Contract  On success both files exist, mode 0400, owner uid 1000 (the gateway's user), in a
#           directory of mode 0500; each file is written to a temporary name and renamed, so
#           a reader never sees half a secret. Exit 0.
#           On any failure nothing is half-written and the exit code is not 0; the systemd
#           unit retries with a growing delay. A secret that is not set yet (404) is the
#           expected state right after deployment.
# Secrecy   Neither the token nor a secret value is ever placed in a command line, an
#           environment variable or the output: curl reads the bearer header from a private
#           file and jq writes the value straight into the file.
# Env       IBGW_KEY_VAULT (default: keyVaultName of /opt/ibgateway/config.json, written by
#           apply-config.sh), IBGW_CONFIG, IBGW_SECRETS_DIR, IBGW_SECRETS_UID; IBGW_IMDS_URL
#           and IBGW_VAULT_SUFFIX exist for sovereign clouds.
# Exit      1 no token, 2 a secret is not set yet, 3 identity refused, 4 vault unreachable,
#           5 a secret is empty, 6 no Key Vault name.
set -euo pipefail
umask 077

config="${IBGW_CONFIG:-/opt/ibgateway/config.json}"
vault="${IBGW_KEY_VAULT:-}"
if [[ -z "${vault}" && -r "${config}" ]]; then vault="$(jq --raw-output '.keyVaultName // empty' "${config}")"; fi
vault_suffix="${IBGW_VAULT_SUFFIX:-vault.azure.net}"
imds_url="${IBGW_IMDS_URL:-http://169.254.169.254/metadata/identity/oauth2/token}"
secrets_dir="${IBGW_SECRETS_DIR:-/run/ibgateway-secrets}"
secrets_uid="${IBGW_SECRETS_UID:-1000}"

log() { printf 'fetch-secrets: %s\n' "$1" >&2; }

if [[ ! "${vault}" =~ ^[A-Za-z0-9-]{3,24}$ ]]; then
  log "no Key Vault name: ${config} is missing or has no keyVaultName (run apply-config.sh)"
  exit 6
fi

work_dir="$(mktemp -d /run/fetch-secrets.XXXXXX)"
cleanup() { rm -rf "${work_dir}"; }
trap cleanup EXIT

# Token for Key Vault from the instance metadata service; kept in a private file.
if ! curl --silent --show-error --fail --retry 5 --retry-delay 2 --max-time 20 \
  --header 'Metadata: true' --get \
  --data-urlencode 'api-version=2018-02-01' \
  --data-urlencode "resource=https://${vault_suffix}" \
  "${imds_url}" --output "${work_dir}/token.json"; then
  log "no token from the instance metadata service (is the VM's managed identity enabled?)"
  exit 1
fi
if ! jq --join-output --exit-status '"header = \"Authorization: Bearer " + .access_token + "\""' \
  "${work_dir}/token.json" >"${work_dir}/auth.curlrc"; then
  log "the instance metadata service returned no access token"
  exit 1
fi

for name in ib-username ib-password; do
  status="$(curl --silent --show-error --retry 3 --retry-delay 2 --max-time 20 \
    --config "${work_dir}/auth.curlrc" \
    --output "${work_dir}/${name}.json" --write-out '%{http_code}' \
    "https://${vault}.${vault_suffix}/secrets/${name}?api-version=7.4")" || status="000"
  case "${status}" in
    200) ;;
    404)
      log "secret ${name} is not set in Key Vault ${vault} yet; set it, this unit retries"
      exit 2
      ;;
    401 | 403)
      log "Key Vault ${vault} refused the VM's identity (HTTP ${status}): it needs Key Vault Secrets User and the subnet must be allowed"
      exit 3
      ;;
    *)
      log "Key Vault ${vault} could not be read (HTTP ${status})"
      exit 4
      ;;
  esac
  if ! jq --join-output --exit-status '.value | select(type == "string" and length > 0)' \
    "${work_dir}/${name}.json" >"${work_dir}/${name}"; then
    log "secret ${name} in Key Vault ${vault} is empty"
    exit 5
  fi
done

install -d -m 0500 -o "${secrets_uid}" -g "${secrets_uid}" "${secrets_dir}"
for name in ib-username ib-password; do
  # Docker creates a DIRECTORY when a bind source is missing; never move a file into it.
  if [[ -d "${secrets_dir}/${name}" ]]; then rmdir "${secrets_dir}/${name}"; fi
  install -m 0400 -o "${secrets_uid}" -g "${secrets_uid}" "${work_dir}/${name}" "${secrets_dir}/.${name}.tmp"
  mv -f -T "${secrets_dir}/.${name}.tmp" "${secrets_dir}/${name}"
done
log "ib-username and ib-password are in ${secrets_dir} (tmpfs)"
