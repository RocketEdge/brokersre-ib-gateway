#!/usr/bin/env bash
# Render IBC's config.ini and the Gateway's jts.ini from templates and the environment.
#
# Purpose: turn the documented environment variables (docs/env-vars.md) into the two files IBC
# and IB Gateway read, with the credentials present only in the tmpfs-resident config.ini.
#
# Contract (sourced by entrypoint.sh after common.sh):
#   render_config
#     - CUSTOM_CONFIG=yes: use ${RUN_DIR}/config.ini supplied by the operator (mounted), render nothing.
#     - otherwise: file_env TWS_USERID / TWS_PASSWORD / VNC_SERVER_PASSWORD, envsubst the IBC
#       template into ${RUN_DIR}/config.ini (mode 0600), write jts.ini into TWS_SETTINGS_PATH only
#       when absent (so the Gateway's own later edits survive), then unset every secret.
#   Exported for later stages: VNC_SERVER_PASSWORD is unset after start-vnc reads it, see start-vnc.sh.
#
# Why envsubst with an explicit variable list: an unlisted ${...} in the template (or a
# password containing a dollar sign) must never be expanded.

IBC_TEMPLATE="${IBC_TEMPLATE:-/etc/brokersre/ibc.config.ini.tmpl}"
JTS_TEMPLATE="${JTS_TEMPLATE:-/etc/brokersre/jts.ini.tmpl}"
IBC_INI="${RUN_DIR}/config.ini"
# shellcheck disable=SC2016  # literal $NAMES are the envsubst allow-list; bash must not expand them
IBC_VARS='$TWS_USERID $TWS_PASSWORD $TWOFA_DEVICE $RELOGIN_AFTER_TWOFA_TIMEOUT $TWOFA_EXIT_INTERVAL $TRADING_MODE $EXISTING_SESSION_DETECTED_ACTION $TWS_MASTER_CLIENT_ID $READ_ONLY_API $BYPASS_WARNING $AUTO_LOGOFF_TIME $AUTO_RESTART_TIME $TWS_ACCEPT_INCOMING $ALLOW_BLIND_TRADING $SAVE_TWS_SETTINGS $IBC_COMMAND_SERVER_PORT $IBC_SUPPRESS_INFO_MESSAGES'
# shellcheck disable=SC2016
JTS_VARS='$TIME_ZONE'

# properties_escape VALUE: print VALUE in java.util.Properties escaping, as pure ASCII.
#
# Why: IBC loads config.ini with Properties.load(InputStream). That parser decodes the bytes as
# ISO-8859-1, treats a backslash as the escape character and drops leading whitespace of a
# value, so a credential written verbatim is silently altered when it contains a backslash, a
# non-ASCII character or a leading space, and IBC then types a wrong password. Repeated wrong
# passwords can lock an IBKR account, hence the exact escaping:
#   backslash -> \\ ; a leading space -> "\ " ; tab, LF, CR -> \t \n \r ;
#   every other character outside printable ASCII -> \uXXXX (UTF-16 code units, so a code
#   point above U+FFFF becomes a surrogate pair).
# Contract: VALUE is UTF-8 text; the output contains only bytes 0x20-0x7E and round-trips
# through Properties.load to VALUE. Uses bash builtins only (the secret never reaches `ps`).
properties_escape() {
  # Character (not byte) indexing for the loop below; C.UTF-8 is built into glibc.
  local LC_ALL=C.UTF-8
  local value="$1" out="" ch esc
  local -i code i high low
  for ((i = 0; i < ${#value}; i++)); do
    ch="${value:i:1}"
    printf -v code '%d' "'${ch}"
    # A byte that is not valid UTF-8 comes back as a (possibly negative) byte value.
    if ((code < 0)); then code=$((code + 256)); fi
    if ((code == 92)); then
      out+='\\'
    elif ((code == 32 && i == 0)); then
      out+='\ '
    elif ((code == 9)); then
      out+='\t'
    elif ((code == 10)); then
      out+='\n'
    elif ((code == 13)); then
      out+='\r'
    elif ((code >= 32 && code <= 126)); then
      out+="${ch}"
    elif ((code > 65535)); then
      high=$((55296 + ((code - 65536) >> 10)))
      low=$((56320 + ((code - 65536) & 1023)))
      printf -v esc '\\u%04x\\u%04x' "${high}" "${low}"
      out+="${esc}"
    else
      printf -v esc '\\u%04x' "${code}"
      out+="${esc}"
    fi
  done
  printf '%s' "${out}"
}

render_config() {
  mkdir -p "${RUN_DIR}" "${TWS_SETTINGS_PATH}"
  if [ "${CUSTOM_CONFIG:-no}" = "yes" ]; then
    if [ ! -r "${IBC_INI}" ]; then
      log_event entrypoint error config_missing "CUSTOM_CONFIG=yes but ${IBC_INI} is not readable"
      exit 1
    fi
    log_event entrypoint info config_custom "using operator-supplied ${IBC_INI}"
  else
    file_env TWS_USERID
    file_env TWS_PASSWORD
    if [ -z "${TWS_USERID:-}" ] || [ -z "${TWS_PASSWORD:-}" ]; then
      log_event entrypoint error config_missing "TWS_USERID and TWS_PASSWORD (or their _FILE variants) are required"
      exit 1
    fi
    : "${TWOFA_DEVICE:=}" "${TWS_MASTER_CLIENT_ID:=}" "${AUTO_LOGOFF_TIME:=}" "${AUTO_RESTART_TIME:=}" "${SAVE_TWS_SETTINGS:=}"
    export TWOFA_DEVICE TWS_MASTER_CLIENT_ID AUTO_LOGOFF_TIME AUTO_RESTART_TIME SAVE_TWS_SETTINGS
    umask 077
    # The two free-text values are escaped for IBC's .properties parser; only this one command
    # sees the escaped copies.
    TWS_USERID="$(properties_escape "${TWS_USERID}")" TWS_PASSWORD="$(properties_escape "${TWS_PASSWORD}")" \
      envsubst "${IBC_VARS}" <"${IBC_TEMPLATE}" >"${IBC_INI}.tmp"
    mv -f "${IBC_INI}.tmp" "${IBC_INI}"
    chmod 0600 "${IBC_INI}"
    umask 022
    log_event entrypoint info config_rendered "IBC config rendered to ${IBC_INI} (mode 0600)"
    unset_secret TWS_PASSWORD
    unset_secret TWS_USERID
  fi

  if [ ! -f "${TWS_SETTINGS_PATH}/jts.ini" ]; then
    envsubst "${JTS_VARS}" <"${JTS_TEMPLATE}" >"${TWS_SETTINGS_PATH}/jts.ini"
    log_event entrypoint info jts_ini_written "jts.ini created in ${TWS_SETTINGS_PATH} (TimeZone=${TIME_ZONE})"
  else
    log_event entrypoint info jts_ini_kept "jts.ini already present in ${TWS_SETTINGS_PATH}; not overwritten"
  fi
}
