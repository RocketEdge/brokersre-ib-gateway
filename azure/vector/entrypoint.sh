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
#           IBGW_INSTANCE, HOST_LABEL       row labels (letters, digits, . _ -; at most 64);
#                                           at least one must name this gateway: the default
#                                           instance label without a host label is refused
#           IBGW_REDACT_USERNAME_FILE       optional file holding the IBKR user name: one line of
#                                           printable ASCII; a UTF-8 byte-order mark and line
#                                           ends are ignored, as the gateway ignores them
#           SHIP_RAW_LOGS                   optional; "yes" ships raw logs without a user-name file
# Outputs   /var/tmp/vector-config/sinks.yaml (rendered from sinks-<AZURE_AUTH>.yaml) and the
#           empty data directory /var/tmp/vector on first start;
#           VECTOR_CONFIG, VECTOR_LOG, IBGW_RAW_MODE and IBGW_REDACT_USERNAME in Vector's
#           environment only.
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

# matches <value> <extended regex>: true when the value is ONE line without any control
# character and that line matches the pattern as a whole. Every value that is pasted into the
# rendered YAML goes through here. The control-character test comes first on purpose: grep
# matches line by line, so a multi-line value whose last line is valid would pass the pattern
# alone, and its other lines would reach sed as commands.
matches() {
  case "$1" in
    *[[:cntrl:]]*) return 1 ;;
  esac
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

# Only validated values are ever handed to sed: with a managed identity the three certificate
# variables are not used and therefore not read at all.
tenant_id=''
client_id=''
certificate_path=''
if [ "${auth}" = certificate ]; then
  tenant_id="${AZURE_TENANT_ID:-}"
  client_id="${AZURE_CLIENT_ID:-}"
  certificate_path="${AZURE_CLIENT_CERTIFICATE_PATH:-}"
  matches "${tenant_id}" "${guid}" || die "AZURE_TENANT_ID must be the directory (tenant) id of the Entra application"
  matches "${client_id}" "${guid}" || die "AZURE_CLIENT_ID must be the application (client) id of the Entra application"
  matches "${certificate_path}" '/[A-Za-z0-9._/-]+' || die "AZURE_CLIENT_CERTIFICATE_PATH must be an absolute path"
  [ -f "${certificate_path}" ] && [ -r "${certificate_path}" ] \
    || die "the certificate file named by AZURE_CLIENT_CERTIFICATE_PATH is missing or not readable by uid 1000"
fi

# Row labels. Every row carries Instance and Host, and the alert rules tell gateways apart by
# them: two gateways with the same pair would hide each other's silence from the dead-man rule.
# A label must also survive redaction unchanged (redact.vrl rewrites every string of an event
# row, the labels included, but not the metrics rows: a rewritten label would differ between
# the two tables). So a label that the redaction would touch is refused: prefix DU, DF, U or F
# and 5 to 9 digits, in any case as a word of its own, or in upper case glued to a lower-case
# letter. Keep the two patterns in step with rules 1 and 2 of redact.vrl.
label='[A-Za-z0-9._-]{1,64}'
account_like='((^|[^A-Za-z0-9])([Dd][UuFf]|[UuFf])|[a-z](DU|DF|U|F))[0-9]{5,9}([^A-Za-z0-9]|$)'
IBGW_INSTANCE="${IBGW_INSTANCE:-default}"
HOST_LABEL="${HOST_LABEL:-}"
matches "${IBGW_INSTANCE}" "${label}" \
  || die "IBGW_INSTANCE must be 1 to 64 letters, digits, dots, underscores or hyphens"
if [ -n "${HOST_LABEL}" ]; then
  matches "${HOST_LABEL}" "${label}" \
    || die "HOST_LABEL must be empty or 1 to 64 letters, digits, dots, underscores or hyphens"
fi
if printf '%s' "${IBGW_INSTANCE}" | grep -Eq -- "${account_like}"; then
  die "IBGW_INSTANCE looks like an IBKR account id; choose a label that is not one (for example paper-1)"
fi
if printf '%s' "${HOST_LABEL}" | grep -Eq -- "${account_like}"; then
  die "HOST_LABEL looks like an IBKR account id; choose a label that is not one"
fi
if [ "${IBGW_INSTANCE}" = default ] && [ -z "${HOST_LABEL}" ]; then
  die "this gateway has no label of its own: set IBGW_INSTANCE to a name that is unique in the workspace (for example paper-1), or set HOST_LABEL; IBGW_INSTANCE=default alone cannot be told apart from another gateway"
fi
export IBGW_INSTANCE HOST_LABEL

# Raw-log opt-in. Default: off.
IBGW_RAW_MODE=off
unset IBGW_REDACT_USERNAME
if [ -n "${IBGW_REDACT_USERNAME_FILE:-}" ]; then
  [ -f "${IBGW_REDACT_USERNAME_FILE}" ] && [ -r "${IBGW_REDACT_USERNAME_FILE}" ] \
    || die "the file named by IBGW_REDACT_USERNAME_FILE is missing or not readable by uid 1000; raw logs are not shipped without it"
  # Normalise the file exactly as the gateway does when it reads the same secret (a leading
  # UTF-8 byte-order mark and every trailing CR/LF are not part of the name), working on the
  # bytes as hex so that no locale or shell quoting can change them. A name that would not
  # match what IBC prints must stop the container: shipping raw logs with a "redaction" that
  # silently matches nothing is the one outcome this file exists to prevent.
  [ "$(wc -c <"${IBGW_REDACT_USERNAME_FILE}")" -le 512 ] \
    || die "the file named by IBGW_REDACT_USERNAME_FILE is larger than 512 bytes; it must hold the IBKR user name only"
  name_hex="$(od -An -v -tx1 "${IBGW_REDACT_USERNAME_FILE}" | tr -d ' \n')"
  name_hex="${name_hex#efbbbf}"
  while :; do
    case "${name_hex}" in
      *0d | *0a) name_hex="${name_hex%??}" ;;
      *) break ;;
    esac
  done
  [ -n "${name_hex}" ] \
    || die "the file named by IBGW_REDACT_USERNAME_FILE is empty; raw logs are not shipped without a user name to redact"
  # Every remaining byte must be printable ASCII without a space (0x21 to 0x7e): a NUL byte
  # means UTF-16 (Windows PowerShell '>' or Out-File), a line break means more than one line.
  printf '%s' "${name_hex}" | grep -Eqx '(2[1-9a-f]|[3-6][0-9a-f]|7[0-9a-e])+' \
    || die "the file named by IBGW_REDACT_USERNAME_FILE must hold one line of printable ASCII without spaces, written as UTF-8 (not UTF-16, no second line); raw logs are not shipped with a user name that cannot be matched"
  unset name_hex
  # The checks above proved that the file is the name plus, at most, a byte-order mark and line
  # ends, so keeping the printable ASCII bytes yields exactly the normalised name.
  IBGW_REDACT_USERNAME="$(LC_ALL=C tr -cd '!-~' <"${IBGW_REDACT_USERNAME_FILE}")"
  export IBGW_REDACT_USERNAME
  IBGW_RAW_MODE=redacted
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

# Vector's own log must never show a line of the gateway. Its file source logs the START OF A
# LINE it discards for being longer than max_line_bytes (field truncated_bytes; up to 256 KiB
# of raw text with the user name and full account ids), whatever the raw-log mode is. Vector's
# log filter works per target, so the messages of that one module are switched off; "info" is
# Vector's default level for everything else. An operator-supplied VECTOR_LOG is overridden on
# purpose (its default value would switch the messages back on). What those messages said is
# still visible without content: vector.yaml prints the counters open_files and
# component_errors_total (error_code reading_line_from_file) every minute.
VECTOR_LOG='info,vector::internal_events::file::source=off'
export VECTOR_LOG

exec /usr/local/bin/vector "$@"
