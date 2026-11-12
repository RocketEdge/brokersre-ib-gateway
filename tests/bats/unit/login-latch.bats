#!/usr/bin/env bats
# Unit tests for login-latch.sh: after IBKR rejects the credentials, no later start of the
# gateway may send the same credentials again. A restart policy, a host reboot or an operator's
# `up -d` would otherwise repeat the rejected login until IBKR locks the account. The latch is
# keyed on the identity of the credential source (the modification times of the secret files),
# never on its content: nothing derived from a password is written anywhere.

setup() {
  : "${BROKERSRE_LIB:?set BROKERSRE_LIB to rootfs/usr/local/lib/brokersre}"
  export LOG_DIR="$(mktemp -d)"
  mkdir -p "${LOG_DIR}/state"
  export BOOT_ID="0123456789abcdef"
  SECRETS="$(mktemp -d)"
  printf 'canaryuser' >"${SECRETS}/ib-username"
  printf 'CANARY_PASSWORD_hunter2hunter2' >"${SECRETS}/ib-password"
  touch -d '2026-11-10 08:00:00.123456789' "${SECRETS}/ib-username"
  touch -d '2026-11-10 08:00:01.987654321' "${SECRETS}/ib-password"
  export TWS_USERID_FILE="${SECRETS}/ib-username" TWS_PASSWORD_FILE="${SECRETS}/ib-password"
  unset TWS_USERID TWS_PASSWORD LOGIN_LATCH LOGIN_CRED_FINGERPRINT
  LATCH="${LOG_DIR}/state/login-rejected"
}

teardown() {
  rm -rf "${LOG_DIR}" "${SECRETS}"
}

# latch FUNCTION ARGS...: call one function of login-latch.sh in a fresh shell.
latch() {
  bash -uc "source '${BROKERSRE_LIB}/log.sh'; source '${BROKERSRE_LIB}/login-latch.sh'; \"\$@\"" _ "$@"
}

# reject: record a rejection for the credentials the environment names right now.
reject() {
  latch login_latch_set
}

# --- the fingerprint -------------------------------------------------------------------------

@test "the fingerprint of file credentials is a short token that holds nothing of their content" {
  run latch credential_fingerprint
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^files:[0-9a-f]{16}$ ]]
  [[ "$output" != *canary* ]]
  [[ "$output" != *hunter2* ]]
}

@test "the fingerprint is stable while the secret files are untouched" {
  first="$(latch credential_fingerprint)"
  second="$(latch credential_fingerprint)"
  [ "${first}" == "${second}" ]
}

@test "rewriting the password file changes the fingerprint" {
  before="$(latch credential_fingerprint)"
  printf 'CANARY_PASSWORD_corrected' >"${SECRETS}/ib-password"
  after="$(latch credential_fingerprint)"
  [ "${before}" != "${after}" ]
}

@test "rewriting the username file changes the fingerprint" {
  before="$(latch credential_fingerprint)"
  touch -d '2026-11-12 09:00:00' "${SECRETS}/ib-username"
  after="$(latch credential_fingerprint)"
  [ "${before}" != "${after}" ]
}

@test "the fingerprint depends on the modification time only, not on the content" {
  before="$(latch credential_fingerprint)"
  printf 'another password of another length' >"${SECRETS}/ib-password"
  touch -d '2026-11-10 08:00:01.987654321' "${SECRETS}/ib-password"
  after="$(latch credential_fingerprint)"
  [ "${before}" == "${after}" ]
}

@test "credentials from plain variables have the fingerprint env (a change cannot be seen)" {
  unset TWS_USERID_FILE TWS_PASSWORD_FILE
  TWS_USERID=canaryuser TWS_PASSWORD=CANARY_PASSWORD_hunter2hunter2 run latch credential_fingerprint
  [ "$output" == "env" ]
}

@test "no credentials at all give the fingerprint none, a missing secret file gives unknown" {
  unset TWS_USERID_FILE TWS_PASSWORD_FILE
  run latch credential_fingerprint
  [ "$output" == "none" ]
  TWS_PASSWORD_FILE="${SECRETS}/absent" run latch credential_fingerprint
  [ "$output" == "unknown" ]
}

# --- recording a rejection -------------------------------------------------------------------

@test "a rejection is recorded as one line: version, fingerprint, time; nothing of the secrets" {
  run reject
  [ "$status" -eq 0 ]
  [ "$(wc -l <"${LATCH}")" == "1" ]
  grep -Eq '^v1 files:[0-9a-f]{16} [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$' "${LATCH}"
  ! grep -q -i -e canary -e hunter2 "${LATCH}" || false
  [ -z "$(find "${LOG_DIR}/state" -name 'login-rejected.tmp*')" ]
}

@test "LOGIN_LATCH=off records nothing and says so with its status" {
  LOGIN_LATCH=off run reject
  # 1 means "not recorded": the classifier announces a latch only when one was written.
  [ "$status" -eq 1 ]
  [ ! -e "${LATCH}" ]
}

# --- the state at the next start --------------------------------------------------------------

@test "without a recorded rejection the state is none" {
  run latch login_latch_state
  [ "$output" == "none" ]
}

@test "after a rejection the same secret files are held, with the time of the rejection" {
  reject
  run latch login_latch_state
  [[ "$output" =~ ^held\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$ ]]
}

@test "after a rejection a rewritten secret file is released" {
  reject
  printf 'CANARY_PASSWORD_corrected' >"${SECRETS}/ib-password"
  run latch login_latch_state
  [ "$output" == "released" ]
}

@test "variable credentials stay held until someone clears the latch" {
  unset TWS_USERID_FILE TWS_PASSWORD_FILE
  export TWS_USERID=canaryuser TWS_PASSWORD=CANARY_PASSWORD_hunter2hunter2
  reject
  TWS_PASSWORD=CANARY_PASSWORD_corrected run latch login_latch_state
  [[ "$output" == held\ * ]]
  LOGIN_LATCH=clear run latch login_latch_state
  [ "$output" == "clear" ]
}

@test "switching from variables to secret files releases the latch" {
  saved_user="${TWS_USERID_FILE}" saved_pass="${TWS_PASSWORD_FILE}"
  unset TWS_USERID_FILE TWS_PASSWORD_FILE
  TWS_USERID=canaryuser TWS_PASSWORD=x reject
  TWS_USERID_FILE="${saved_user}" TWS_PASSWORD_FILE="${saved_pass}" run latch login_latch_state
  [ "$output" == "released" ]
}

@test "LOGIN_LATCH=off ignores a recorded rejection, LOGIN_LATCH=clear asks for its removal" {
  reject
  LOGIN_LATCH=off run latch login_latch_state
  [ "$output" == "off" ]
  LOGIN_LATCH=clear run latch login_latch_state
  [ "$output" == "clear" ]
  LOGIN_LATCH=clear run bash -uc "rm -f '${LATCH}'; source '${BROKERSRE_LIB}/log.sh'; source '${BROKERSRE_LIB}/login-latch.sh'; login_latch_state"
  [ "$output" == "none" ]
}

@test "a record that cannot be read is not evidence: the state is unreadable, never held" {
  for content in '' 'garbage' 'v2 files:0123456789abcdef 2026-11-12T00:00:00.000Z' 'v1 files:0123456789abcdef' 'v1  2026-11-12T00:00:00.000Z' 'v1 files:0123456789abcdef $(id)'; do
    printf '%s\n' "${content}" >"${LATCH}"
    run latch login_latch_state
    [ "$output" == "unreadable" ] || {
      echo "content '${content}' gave '${output}'"
      return 1
    }
  done
}

@test "a rejection recorded without a usable fingerprint never holds a start" {
  printf 'v1 unknown 2026-11-12T00:00:00.000Z\n' >"${LATCH}"
  TWS_PASSWORD_FILE="${SECRETS}/absent" run latch login_latch_state
  [ "$output" == "released" ]
  printf 'v1 none 2026-11-12T00:00:00.000Z\n' >"${LATCH}"
  unset TWS_USERID_FILE TWS_PASSWORD_FILE
  run latch login_latch_state
  [ "$output" == "released" ]
}

# --- acting on the state at container start ----------------------------------------------------

# apply: run login_latch_apply; print `rc=<status> since=<LOGIN_LATCH_SINCE>` after its events.
apply() {
  bash -uc "source '${BROKERSRE_LIB}/log.sh'; source '${BROKERSRE_LIB}/login-latch.sh'; rc=0; login_latch_apply || rc=\$?; echo \"rc=\${rc} since=\${LOGIN_LATCH_SINCE:-}\""
}

@test "apply: a held latch says so (status 0), keeps the record and reports when IBKR refused" {
  reject
  run apply
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" =~ ^rc=0\ since=[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
  [ -e "${LATCH}" ]
}

@test "apply: changed secret files remove the record and say why" {
  reject
  touch -d '2026-11-12 09:30:00' "${SECRETS}/ib-password"
  run apply
  [ "${lines[-1]}" == "rc=1 since=" ]
  echo "${lines[0]}" | jq -e '.event == "login_latch_cleared" and .level == "info" and .src == "entrypoint"' >/dev/null
  [ ! -e "${LATCH}" ]
}

@test "apply: LOGIN_LATCH=clear removes the record and reminds to remove the setting" {
  reject
  LOGIN_LATCH=clear run apply
  [ "${lines[-1]}" == "rc=1 since=" ]
  echo "${lines[0]}" | jq -e '.event == "login_latch_cleared" and (.msg | contains("LOGIN_LATCH"))' >/dev/null
  [ ! -e "${LATCH}" ]
}

@test "apply: an unreadable record is removed with a warning and the start goes on" {
  echo garbage >"${LATCH}"
  run apply
  [ "${lines[-1]}" == "rc=1 since=" ]
  echo "${lines[0]}" | jq -e '.event == "login_latch_unreadable" and .level == "warn"' >/dev/null
  [ ! -e "${LATCH}" ]
}

@test "apply: nothing recorded, nothing said" {
  run apply
  [ "$output" == "rc=1 since=" ]
}

@test "apply: LOGIN_LATCH=off leaves a record alone and goes on" {
  reject
  LOGIN_LATCH=off run apply
  [ "$output" == "rc=1 since=" ]
  [ -e "${LATCH}" ]
}

@test "clearing a latch that does not exist says nothing; clearing one says why" {
  run latch login_latch_clear ibc "a login completed"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  reject
  run latch login_latch_clear ibc "a login completed"
  echo "$output" | jq -e '.event == "login_latch_cleared" and .src == "ibc" and (.msg | contains("a login completed"))' >/dev/null
  [ ! -e "${LATCH}" ]
}

# --- the classifier sets and clears the latch ---------------------------------------------------

classify_lines() {
  printf '%s\n' "$@" | IBC_PATTERNS="${BATS_TEST_DIRNAME}/../../../rootfs/etc/brokersre/ibc-patterns.tsv" \
    IBC_KNOWN_WINDOWS="${BATS_TEST_DIRNAME}/../../../rootfs/etc/brokersre/known-windows.txt" \
    "${BROKERSRE_LIB}/classify-ibc-log.sh"
}

@test "classifier: IBKR's rejection dialog records the latch for the start's fingerprint" {
  export LOGIN_CRED_FINGERPRINT="files:00112233aabbccdd"
  run classify_lines '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Unrecognized Username or Password; event=Opened'
  [ "$status" -eq 0 ]
  echo "$output" | jq -s -e 'map(.event) == ["login_failed_dialog", "login_latch_set"]' >/dev/null
  echo "$output" | jq -s -e '.[1].level == "warn" and .[1].src == "ibc"' >/dev/null
  grep -q '^v1 files:00112233aabbccdd ' "${LATCH}"
  [ "$(cat "${LOG_DIR}/state/phase")" == "needs-human" ]
}

@test "classifier: the real rejected login (10.50.1g) records the latch exactly once" {
  export LOGIN_CRED_FINGERPRINT="files:00112233aabbccdd"
  run bash -c "IBC_PATTERNS='${BATS_TEST_DIRNAME}/../../../rootfs/etc/brokersre/ibc-patterns.tsv' IBC_KNOWN_WINDOWS='${BATS_TEST_DIRNAME}/../../../rootfs/etc/brokersre/known-windows.txt' '${BROKERSRE_LIB}/classify-ibc-log.sh' <'${BATS_TEST_DIRNAME}/../../fixtures/ibc-real-failed-login.log' | jq -r .event"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep -c '^login_latch_set$')" == "1" ]
  [ -e "${LATCH}" ]
}

@test "classifier: a completed login removes a recorded rejection" {
  reject
  run classify_lines '2026-11-11 23:25:00:000 IBC: Login has completed'
  echo "$output" | jq -s -e 'map(.event) == ["login_completed", "login_latch_cleared"]' >/dev/null
  [ ! -e "${LATCH}" ]
}

@test "classifier: a completed login with nothing recorded adds no event" {
  run classify_lines '2026-11-11 23:25:00:000 IBC: Login has completed'
  echo "$output" | jq -s -e 'map(.event) == ["login_completed"]' >/dev/null
}

@test "classifier: LOGIN_LATCH=off records nothing and says nothing about a latch" {
  export LOGIN_LATCH=off
  run classify_lines '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Unrecognized Username or Password; event=Opened'
  echo "$output" | jq -s -e 'map(.event) == ["login_failed_dialog"]' >/dev/null
  [ ! -e "${LATCH}" ]
}
