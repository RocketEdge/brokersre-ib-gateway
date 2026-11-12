#!/usr/bin/env bats
# Unit tests for scripts/check-compose-usernames.sh: before several gateways are started from
# one secrets directory (compose/docker-compose.multi.yml), prove that no two of them hold the
# same IBKR username. IBKR allows one session per username, so the second gateway to log in
# would end the first one's session. The check compares hashes and never prints a username.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/check-compose-usernames.sh"
  WORK="$(mktemp -d)"
  SECRETS="${WORK}/secrets"
  mkdir -p "${SECRETS}"
  # Obviously fake usernames, assembled at run time.
  USER_A="CANARY_$(printf '%s' user)_a"
  USER_B="CANARY_$(printf '%s' user)_b"
}

teardown() {
  chmod -R u+rwX "${WORK}" 2>/dev/null || true
  rm -rf "${WORK}"
}

# instance NAME USERNAME: create ${SECRETS}/NAME/ib-username (no trailing newline) and a
# password file next to it.
instance() {
  mkdir -p "${SECRETS}/$1"
  printf '%s' "$2" >"${SECRETS}/$1/ib-username"
  printf '%s' "not-a-real-password" >"${SECRETS}/$1/ib-password"
}

# no_username_in_output: neither fake username, in any letter case, appears in $output.
no_username_in_output() {
  ! grep -q -i -F -e "${USER_A}" -e "${USER_B}" <<<"${output}"
}

@test "no argument, two arguments and a missing directory are usage errors (exit 2)" {
  run "${SCRIPT}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: check-compose-usernames.sh"* ]]
  run "${SCRIPT}" "${SECRETS}" extra
  [ "$status" -eq 2 ]
  run "${SCRIPT}" "${WORK}/does-not-exist"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a directory"* ]]
}

@test "--help prints the usage and exits 0" {
  run "${SCRIPT}" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: check-compose-usernames.sh"* ]]
  [[ "$output" == *"exit status"* ]]
}

@test "two instances with different usernames pass" {
  instance live "${USER_A}"
  instance paper "${USER_B}"
  run "${SCRIPT}" "${SECRETS}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok: 2 instances, 2 different usernames"* ]]
  no_username_in_output
}

@test "two instances with the same username fail (exit 1) and both are named" {
  instance live "${USER_A}"
  instance paper "${USER_A}"
  run "${SCRIPT}" "${SECRETS}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL: live and paper hold the same IBKR username"* ]]
  [[ "$output" == *"existing-session"* ]]
}

@test "neither the username nor its hash is ever printed" {
  instance live "${USER_A}"
  instance paper "${USER_A}"
  instance desk "${USER_B}"
  run "${SCRIPT}" "${SECRETS}"
  [ "$status" -eq 1 ]
  no_username_in_output
  ! grep -q -E '[0-9a-f]{32}' <<<"${output}"
}

@test "a trailing newline, CRLF or a UTF-8 byte-order mark does not hide a shared username" {
  instance live "${USER_A}"
  mkdir -p "${SECRETS}/paper" "${SECRETS}/desk-a" "${SECRETS}/desk-b"
  printf '%s\n' "${USER_A}" >"${SECRETS}/paper/ib-username"
  printf '%s\r\n' "${USER_A}" >"${SECRETS}/desk-a/ib-username"
  printf '\xef\xbb\xbf%s' "${USER_A}" >"${SECRETS}/desk-b/ib-username"
  run "${SCRIPT}" "${SECRETS}"
  [ "$status" -eq 1 ]
  [ "$(grep -c '^FAIL: ' <<<"${output}")" -eq 3 ]
  no_username_in_output
}

@test "usernames that differ only in letter case count as the same" {
  instance live "TraderOne"
  instance paper "traderone"
  run "${SCRIPT}" "${SECRETS}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL: live and paper hold the same IBKR username"* ]]
}

@test "a username that is the beginning of another one is a different username" {
  instance live "${USER_A}"
  instance paper "${USER_A}1"
  run "${SCRIPT}" "${SECRETS}"
  [ "$status" -eq 0 ]
}

@test "three instances of which two share a username: the two are named, the third is not" {
  instance desk-a "${USER_A}"
  instance desk-b "${USER_B}"
  instance desk-c "${USER_A}"
  run "${SCRIPT}" "${SECRETS}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL: desk-a and desk-c hold the same IBKR username"* ]]
  [[ "$output" != *"desk-b"* ]]
}

@test "the single-gateway file at the top of the directory is compared too" {
  printf '%s' "${USER_A}" >"${SECRETS}/ib-username"
  instance paper "${USER_A}"
  run "${SCRIPT}" "${SECRETS}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL: (top level) and paper hold the same IBKR username"* ]]
}

@test "one instance alone passes: there is nothing to compare" {
  instance live "${USER_A}"
  run "${SCRIPT}" "${SECRETS}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok: 1 instance, nothing to compare"* ]]
}

@test "a directory without any ib-username file is an error (exit 2), not a pass" {
  mkdir -p "${SECRETS}/live"
  run "${SCRIPT}" "${SECRETS}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no ib-username file"* ]]
}

@test "an empty username file cannot be compared: exit 2 and the file is named" {
  instance live "${USER_A}"
  mkdir -p "${SECRETS}/paper"
  : >"${SECRETS}/paper/ib-username"
  run "${SCRIPT}" "${SECRETS}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"paper/ib-username"* ]]
  [[ "$output" == *"empty"* ]]
  no_username_in_output
}

@test "a UTF-16 username file cannot be compared: exit 2 with the fix" {
  instance live "${USER_A}"
  mkdir -p "${SECRETS}/paper"
  printf '\xff\xfet\0r\0a\0d\0e\0r\0' >"${SECRETS}/paper/ib-username"
  run "${SCRIPT}" "${SECRETS}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"paper/ib-username"* ]]
  [[ "$output" == *"UTF-8"* ]]
}

@test "a shared username is reported even when another file cannot be compared (exit 1 wins)" {
  instance live "${USER_A}"
  instance paper "${USER_A}"
  mkdir -p "${SECRETS}/desk"
  : >"${SECRETS}/desk/ib-username"
  run "${SCRIPT}" "${SECRETS}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL: live and paper hold the same IBKR username"* ]]
  [[ "$output" == *"desk/ib-username"* ]]
}

@test "password files are not compared: the same password in two instances is not a finding" {
  instance live "${USER_A}"
  instance paper "${USER_B}"
  run "${SCRIPT}" "${SECRETS}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"password"* ]]
}
