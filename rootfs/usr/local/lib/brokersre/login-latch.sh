#!/usr/bin/env bash
# Rejected-login latch: after IBKR has rejected the credentials, do not send them again.
#
# Why: IBC leaves the "Unrecognized Username or Password" dialog open and the container holds
# in phase needs-human, so one start makes one attempt. But every later start (a restart
# policy after a daemon restart, a host reboot, an operator's `up -d`) would make another
# attempt with the same credentials, and IBKR locks an account after repeated failures. The
# latch makes "the credentials were rejected" survive the container.
#
# How: when the classifier sees IBKR's rejection it writes one line to
# ${LOG_DIR}/state/login-rejected:
#     v1 <fingerprint> <UTC time>
# The fingerprint identifies the SOURCE of the credentials at that start, never their content:
#     files:<16 hex>  SHA-256 of the modification times of the secret files (TWS_USERID_FILE,
#                     TWS_PASSWORD_FILE). Rewriting a file changes it; its content plays no part.
#     env             credentials came from plain variables; a change cannot be detected.
#     none, unknown   no credentials, or a secret file that could not be examined.
# Nothing derived from a username or a password is written anywhere (invariant 2).
# At the next start the entrypoint compares: the same fingerprint means the same secret files,
# so IBC is not started at all and the container holds in phase needs-human. A different
# fingerprint (the operator rewrote a secret file) removes the record and the start goes on.
# For `env` credentials only LOGIN_LATCH=clear (once) removes it. A completed login removes it
# too. A record that cannot be read, or one without a usable fingerprint, never holds a start:
# a start is stopped only on positive evidence.
#
# LOGIN_LATCH: on (default) | clear (remove a record at this start, then behave as on) |
#              off (record nothing, hold nothing: the behaviour before this file existed).
# The record lives on the log volume: without a persistent log volume the latch does not
# survive a re-created container.
#
# Requires log.sh (log_event, ts_now). Defines functions only.

# login_latch_file: print the path of the record.
login_latch_file() {
  printf '%s' "${LOG_DIR:-/var/log/ibgateway}/state/login-rejected"
}

# credential_fingerprint: print the fingerprint of the credential source (see the header).
# Reads TWS_USERID_FILE, TWS_PASSWORD_FILE and whether TWS_USERID / TWS_PASSWORD are set; it
# never reads a secret's content. Always returns 0.
credential_fingerprint() {
  local user_file="${TWS_USERID_FILE:-}" pass_file="${TWS_PASSWORD_FILE:-}" stamps="" stamp file
  if [ -n "${user_file}" ] || [ -n "${pass_file}" ]; then
    for file in "${user_file}" "${pass_file}"; do
      [ -n "${file}" ] || continue
      # %y: modification time with nanoseconds and zone, as text.
      if ! stamp="$(stat -c '%y' -- "${file}" 2>/dev/null)" || [ -z "${stamp}" ]; then
        printf 'unknown'
        return 0
      fi
      stamps+="${stamp}"$'\n'
    done
    printf 'files:%s' "$(printf '%s' "${stamps}" | sha256sum | cut -c1-16)"
  elif [ -n "${TWS_USERID:-}" ] || [ -n "${TWS_PASSWORD:-}" ]; then
    printf 'env'
  else
    printf 'none'
  fi
  return 0
}

# login_latch_current: the fingerprint of this start. The entrypoint computes it once, before
# the credentials leave the environment, and exports LOGIN_CRED_FINGERPRINT for the classifier.
login_latch_current() {
  if [ -n "${LOGIN_CRED_FINGERPRINT:-}" ]; then
    printf '%s' "${LOGIN_CRED_FINGERPRINT}"
  else
    credential_fingerprint
  fi
}

# login_latch_set: record that IBKR rejected the credentials of this start. Atomic (temporary
# file and rename). Does nothing with LOGIN_LATCH=off. Returns 0 when recorded, 1 otherwise.
login_latch_set() {
  local file tmp
  [ "${LOGIN_LATCH:-on}" = "off" ] && return 1
  file="$(login_latch_file)"
  tmp="${file}.tmp.${BASHPID}"
  mkdir -p "${file%/*}" 2>/dev/null || true
  if printf 'v1 %s %s\n' "$(login_latch_current)" "$(ts_now)" >"${tmp}" 2>/dev/null && mv -f "${tmp}" "${file}" 2>/dev/null; then
    return 0
  fi
  rm -f "${tmp}" 2>/dev/null
  return 1
}

# login_latch_clear SRC REASON: remove the record. Emits login_latch_cleared (info, source SRC)
# when there was one; says nothing when there was none. Always returns 0.
login_latch_clear() {
  local src="$1" reason="$2" file
  file="$(login_latch_file)"
  [ -e "${file}" ] || return 0
  rm -f "${file}" 2>/dev/null || true
  log_event "${src}" info login_latch_cleared "the record of a rejected login was removed: ${reason}"
  return 0
}

# login_latch_state: print what the record means for this start, changing nothing:
#   off            LOGIN_LATCH=off
#   none           nothing recorded
#   clear          a record exists and LOGIN_LATCH=clear asks for its removal
#   unreadable     a record exists but is not `v1 <fingerprint> <time>`
#   held <time>    the record names this start's credential source: no login may be attempted
#   released       the record names another source (or none that can be compared)
login_latch_state() {
  local file version="" latched="" since="" extra="" current
  file="$(login_latch_file)"
  if [ "${LOGIN_LATCH:-on}" = "off" ]; then
    printf 'off'
    return 0
  fi
  if [ ! -e "${file}" ]; then
    printf 'none'
    return 0
  fi
  if [ "${LOGIN_LATCH:-on}" = "clear" ]; then
    printf 'clear'
    return 0
  fi
  read -r version latched since extra <"${file}" 2>/dev/null || true
  if [ "${version}" != "v1" ] || [ -n "${extra}" ] \
    || ! [[ "${latched}" =~ ^(files:[0-9a-f]{16}|env|none|unknown)$ ]] \
    || ! [[ "${since}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$ ]]; then
    printf 'unreadable'
    return 0
  fi
  current="$(login_latch_current)"
  # Only a source that can be compared holds: the same secret files, or variables both times.
  if [ "${latched}" = "${current}" ] && { [[ "${current}" == files:* ]] || [ "${current}" = "env" ]; }; then
    printf 'held %s' "${since}"
  else
    printf 'released'
  fi
  return 0
}

# login_latch_apply: act on the record at container start (the entrypoint, before IBC).
# Returns 0 when no login may be attempted (LOGIN_LATCH_SINCE is then the time of the
# rejection and the record is kept). Returns 1 otherwise, after removing a record that no
# longer applies and saying why.
# shellcheck disable=SC2034  # LOGIN_LATCH_SINCE is read by entrypoint.sh
login_latch_apply() {
  local state
  state="$(login_latch_state)"
  LOGIN_LATCH_SINCE=""
  case "${state}" in
    held\ *)
      LOGIN_LATCH_SINCE="${state#held }"
      return 0
      ;;
    clear)
      login_latch_clear entrypoint "LOGIN_LATCH=clear is set; remove that setting again, or a rejected login is retried at every start"
      ;;
    released)
      login_latch_clear entrypoint "the credentials changed since IBKR rejected them"
      ;;
    unreadable)
      rm -f "$(login_latch_file)" 2>/dev/null || true
      log_event entrypoint warn login_latch_unreadable "the record of a rejected login could not be read and was removed; the start continues"
      ;;
  esac
  return 1
}
