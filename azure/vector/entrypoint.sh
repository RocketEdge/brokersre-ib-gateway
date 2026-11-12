#!/bin/sh
# shellcheck shell=sh
# Entrypoint of the Vector shipper container (compose services `vector` and `vector-cert`).
#
# Purpose   Check the operator's settings, render the sink configuration, decide whether raw
#           logs may be shipped, then replace this shell with Vector.
# Usage     /bin/sh /etc/vector/entrypoint.sh [vector arguments...]
#           No argument starts the shipper. Arguments go to Vector unchanged, for example
#           `validate --no-environment` (docker compose run --rm vector validate --no-environment).
# Inputs    AZURE_AUTH                      managed-identity | certificate (required)
#           DCR_LOGS_ENDPOINT               https://<host> of the data collection rule
#           DCR_IMMUTABLE_ID                dcr-<32 hex>
#           AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_CERTIFICATE_PATH   (certificate only)
#           IBGW_REDACT_USERNAME_FILE       optional file whose first line is the IBKR user name
#           SHIP_RAW_LOGS                   optional; "yes" ships raw logs without a user-name file
# Outputs   /var/tmp/vector-config/sinks.yaml (rendered from sinks-<AZURE_AUTH>.yaml) and the
#           empty data directory /var/tmp/vector on first start;
#           VECTOR_CONFIG, IBGW_RAW_MODE and IBGW_REDACT_USERNAME in Vector's environment only.
# Errors    A wrong or missing setting stops the container with exit code 78 (configuration
#           error) and one JSON line on stderr naming the variable; the value of the user-name
#           file is never printed. Raw logs are shipped only when this script could prove one of
#           the two opt-ins; every other state is "off" (fail closed).
# Why       Vector 0.61 no longer interpolates environment variables into its configuration
#           unless started with --dangerously-allow-env-var-interpolation. Rendering four
#           validated values with sed keeps that switch off and gives precise error messages.
set -eu

config_dir=/etc/vector
data_dir=/var/tmp/vector
rendered_dir=/var/tmp/vector-config
rendered="${rendered_dir}/sinks.yaml"

# log <level> <message>: one JSON line on stderr. The message is fixed text plus variable
# NAMES; callers never pass a secret or a user-supplied value.
log() {
  printf '{"timestamp":"%s","level":"%s","target":"entrypoint","message":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >&2
}

# die <message>: report a configuration error and stop with EX_CONFIG.
die() {
  log error "$1"
  exit 78
}

# matches <value> <extended regex>: true when the whole value matches. Used to make sure a
# value is safe to paste into the rendered YAML (no quote, backslash, ampersand or newline).
matches() {
  printf '%s' "$1" | grep -Eqx -- "$2"
}

guid='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'

auth="${AZURE_AUTH:-}"
case "${auth}" in
  managed-identity | certificate) ;;
  *) die "AZURE_AUTH must be managed-identity or certificate" ;;
esac

endpoint="${DCR_LOGS_ENDPOINT:-}"
immutable_id="${DCR_IMMUTABLE_ID:-}"
matches "${endpoint}" 'https://[A-Za-z0-9.-]+(:[0-9]+)?/?' \
  || die "DCR_LOGS_ENDPOINT must be the https:// logs ingestion endpoint of the data collection rule (deployment output logsIngestionEndpoint)"
matches "${immutable_id}" 'dcr-[0-9a-f]{32}' \
  || die "DCR_IMMUTABLE_ID must look like dcr- followed by 32 hex characters (deployment output dcrImmutableId)"

tenant_id="${AZURE_TENANT_ID:-}"
client_id="${AZURE_CLIENT_ID:-}"
certificate_path="${AZURE_CLIENT_CERTIFICATE_PATH:-}"
if [ "${auth}" = certificate ]; then
  matches "${tenant_id}" "${guid}" || die "AZURE_TENANT_ID must be the directory (tenant) id of the Entra application"
  matches "${client_id}" "${guid}" || die "AZURE_CLIENT_ID must be the application (client) id of the Entra application"
  matches "${certificate_path}" '/[A-Za-z0-9._/-]+' || die "AZURE_CLIENT_CERTIFICATE_PATH must be an absolute path"
  [ -f "${certificate_path}" ] && [ -r "${certificate_path}" ] \
    || die "the certificate file named by AZURE_CLIENT_CERTIFICATE_PATH is missing or not readable by uid 1000"
fi

# Raw-log opt-in. Default: off.
IBGW_RAW_MODE=off
unset IBGW_REDACT_USERNAME
if [ -n "${IBGW_REDACT_USERNAME_FILE:-}" ]; then
  [ -f "${IBGW_REDACT_USERNAME_FILE}" ] && [ -r "${IBGW_REDACT_USERNAME_FILE}" ] \
    || die "the file named by IBGW_REDACT_USERNAME_FILE is missing or not readable by uid 1000; raw logs are not shipped without it"
  username=''
  IFS= read -r username <"${IBGW_REDACT_USERNAME_FILE}" || true
  username="$(printf '%s' "${username}" | tr -d '\r')"
  [ -n "${username}" ] \
    || die "the file named by IBGW_REDACT_USERNAME_FILE is empty; raw logs are not shipped without a user name to redact"
  IBGW_RAW_MODE=redacted
  IBGW_REDACT_USERNAME="${username}"
  export IBGW_REDACT_USERNAME
  unset username
  log info "raw logs are shipped; the user name is replaced by [USER] and account ids by their last three characters"
elif [ "${SHIP_RAW_LOGS:-no}" = yes ]; then
  IBGW_RAW_MODE=acknowledged
  log warn "SHIP_RAW_LOGS=yes without IBGW_REDACT_USERNAME_FILE: raw logs are shipped with account ids redacted but the IBKR user name is NOT redacted"
else
  log info "raw logs are not shipped (set IBGW_REDACT_USERNAME_FILE or SHIP_RAW_LOGS=yes to opt in)"
fi
export IBGW_RAW_MODE

# Render the sink configuration into the only writable volume, atomically, private to uid 1000.
# It is kept outside Vector's data directory so it can never collide with a component's state.
umask 077
mkdir -p "${data_dir}" "${rendered_dir}" 2>/dev/null \
  || die "/var/tmp is not writable by uid 1000 (the compose override mounts the vector-data volume there)"
template="${config_dir}/sinks-${auth}.yaml"
[ -r "${template}" ] || die "the sink template for this AZURE_AUTH is missing from /etc/vector"
sed \
  -e "s|__DCR_LOGS_ENDPOINT__|${endpoint}|g" \
  -e "s|__DCR_IMMUTABLE_ID__|${immutable_id}|g" \
  -e "s|__AZURE_TENANT_ID__|${tenant_id}|g" \
  -e "s|__AZURE_CLIENT_ID__|${client_id}|g" \
  -e "s|__AZURE_CLIENT_CERTIFICATE_PATH__|${certificate_path}|g" \
  "${template}" >"${rendered}.tmp" \
  || die "could not write the rendered sink configuration under /var/tmp/vector-config"
mv -f "${rendered}.tmp" "${rendered}"

VECTOR_CONFIG="${config_dir}/vector.yaml,${rendered}"
export VECTOR_CONFIG

exec /usr/local/bin/vector "$@"
