#!/usr/bin/env bash
# check-compose-usernames.sh: prove that no two gateways are about to log in with the same
# IBKR username.
#
# Usage: scripts/check-compose-usernames.sh <secrets-dir>
#   <secrets-dir> is what IBGW_SECRETS_DIR points at (compose/secrets by default). Compared
#   are <secrets-dir>/<instance>/ib-username of every instance directory (the layout of
#   compose/docker-compose.multi.yml) and <secrets-dir>/ib-username (the single-gateway
#   layout of compose/docker-compose.example.yml), reported as "(top level)".
# Exit status: 0 no two instances share a username; 1 at least two do; 2 usage error, no
#   username file found, or a username file that cannot be compared (empty, not UTF-8).
#   A shared username wins over a file that cannot be compared: 1, and both are reported.
#
# Why: IBKR allows one brokerage session per username. Two gateways with the same username
# take the session from each other: the one that loses shows the phase `existing-session`
# and stays logged out. That is cheap to rule out before `docker compose up`.
#
# How: each username is normalised the way the gateway reads a secret file (a UTF-8
# byte-order mark and trailing CR/LF removed), folded to lower case (so that two spellings
# of one login cannot pass as two usernames) and hashed with SHA-256; the hashes are
# compared. Neither a username nor a hash is printed: the output names instance directories
# only. The content is read with bash builtins and reaches the hash tool through a pipe, so
# it never shows in a process list. Password files are not opened.
#
# Bash and sha256sum (coreutils; `shasum -a 256` on macOS). Runs in Git Bash on Windows.
set -uo pipefail
# Byte semantics for the prefix and suffix tests, and ASCII-only case folding.
LC_ALL=C

# usage: print the command-line help.
usage() {
  printf '%s\n' \
    "usage: check-compose-usernames.sh <secrets-dir>" \
    "  Compares <secrets-dir>/<instance>/ib-username of every instance (and <secrets-dir>/ib-username)" \
    "  by SHA-256, without printing a username or a hash." \
    "exit status: 0 all usernames differ, 1 two instances share a username, 2 usage error or a file that cannot be compared"
}

# sha256_of_stdin: print the SHA-256 of standard input as 64 hex characters. Returns 1 when
# the host has neither sha256sum nor shasum.
sha256_of_stdin() {
  local digest
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum)" || return 1
  elif command -v shasum >/dev/null 2>&1; then
    digest="$(shasum -a 256)" || return 1
  else
    return 1
  fi
  printf '%s' "${digest%% *}"
}

# username_digest PATH: set the global `digest` to the SHA-256 of the username in PATH and
# return 0, or set the global `problem` to the reason it cannot be compared and return 1.
#
# The normalisation is the gateway's (read_secret_file): NUL bytes or a UTF-16 byte-order mark
# mean "not UTF-8 text"; a UTF-8 byte-order mark and trailing CR/LF are removed; nothing left
# means "empty". `read -d ''` succeeds only when it meets a NUL byte; when it fails it has read
# the whole file. The content stays in a local variable.
username_digest() {
  local path="$1" content=""
  digest=""
  problem=""
  if [ ! -f "${path}" ] || [ ! -r "${path}" ]; then
    problem="is not a readable file"
    return 1
  fi
  if IFS= read -r -d '' content <"${path}" || [[ "${content}" == $'\xff\xfe'* || "${content}" == $'\xfe\xff'* ]]; then
    problem="is not UTF-8 text (NUL bytes or a UTF-16 byte-order mark: write it as UTF-8 without a byte-order mark)"
    return 1
  fi
  content="${content#$'\xef\xbb\xbf'}"
  while [[ "${content}" == *$'\r' || "${content}" == *$'\n' ]]; do
    content="${content%?}"
  done
  if [ -z "${content}" ]; then
    problem="is empty"
    return 1
  fi
  if ! digest="$(printf '%s' "${content,,}" | sha256_of_stdin)" || [ -z "${digest}" ]; then
    problem="could not be hashed (neither sha256sum nor shasum is installed)"
    return 1
  fi
  return 0
}

# check_directory DIR: compare the username files under DIR and print the verdict. Returns
# the exit status documented in the file header.
check_directory() {
  local dir="${1%/}" path instance digest="" problem=""
  local -a paths=()
  local -A first_holder=()
  local -i compared=0 clashes=0 unusable=0
  if [ ! -d "${dir}" ]; then
    echo "check-compose-usernames: ${dir} is not a directory"
    return 2
  fi
  if [ -e "${dir}/ib-username" ]; then paths+=("${dir}/ib-username"); fi
  for path in "${dir}"/*/ib-username; do
    if [ -e "${path}" ]; then paths+=("${path}"); fi
  done
  if [ "${#paths[@]}" -eq 0 ]; then
    echo "check-compose-usernames: no ib-username file under ${dir} (expected ${dir}/<instance>/ib-username)"
    return 2
  fi
  for path in "${paths[@]}"; do
    instance="(top level)"
    if [ "${path}" != "${dir}/ib-username" ]; then
      instance="${path%/ib-username}"
      instance="${instance##*/}"
    fi
    if ! username_digest "${path}"; then
      echo "cannot compare: ${path} ${problem}"
      unusable+=1
      continue
    fi
    compared+=1
    if [ -n "${first_holder[${digest}]:-}" ]; then
      echo "FAIL: ${first_holder[${digest}]} and ${instance} hold the same IBKR username"
      clashes+=1
    else
      first_holder["${digest}"]="${instance}"
    fi
  done
  if ((clashes > 0)); then
    echo "IBKR allows one session per username: the second gateway to log in takes the session and the other one shows the phase existing-session. Give every gateway its own username."
    return 1
  fi
  if ((unusable > 0)); then return 2; fi
  if ((compared == 1)); then
    echo "ok: 1 instance, nothing to compare"
  else
    echo "ok: ${compared} instances, ${compared} different usernames"
  fi
  return 0
}

# main ARGS...: parse the command line and run the check. Returns the script's exit status.
main() {
  if [ "$#" -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
    usage
    return 0
  fi
  if [ "$#" -ne 1 ]; then
    usage >&2
    return 2
  fi
  check_directory "$1"
}

main "$@"
