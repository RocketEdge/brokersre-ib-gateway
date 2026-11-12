#!/usr/bin/env bats
# Unit tests for common.sh file_env: a secret file written on Windows (CRLF line ending, UTF-8
# byte-order mark, UTF-16) must either yield the exact secret or stop with a structured error.
#
# The byte sequences are generated here with printf: .gitattributes normalises committed text
# fixtures to LF, which would silently remove the very bytes under test.

setup() {
  : "${BROKERSRE_LIB:?set BROKERSRE_LIB to rootfs/usr/local/lib/brokersre}"
  SECRETS="$(mktemp -d)"
  export TWS_PASSWORD_FILE="${SECRETS}/p"
  unset TWS_PASSWORD
}

teardown() {
  rm -rf "${SECRETS}"
}

# value_hex: run file_env for TWS_PASSWORD and print the resulting value as lowercase hex, so
# invisible bytes (CR, BOM) cannot hide in a string comparison.
value_hex() {
  bash -c "source '${BROKERSRE_LIB}/common.sh'; file_env TWS_PASSWORD \"\$@\"; printf '%s' \"\${TWS_PASSWORD}\" | od -An -v -tx1 | tr -d ' \n'" _ "$@"
}

# hex_of <string>: the expected value in the same encoding as value_hex.
hex_of() {
  printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'
}

# refused: assert that the last run stopped with the secret_unreadable event and printed
# nothing that contains the secret text.
refused() {
  [ "$status" -ne 0 ]
  echo "$output" | tail -1 | jq -e '.event == "secret_unreadable" and .level == "error" and .src == "entrypoint"' >/dev/null
  [[ "$output" != *"hunter2"* ]]
}

@test "a secret without a line ending is used as written" {
  printf 'hunter2hunter2' >"${TWS_PASSWORD_FILE}"
  run value_hex
  [ "$status" -eq 0 ]
  [ "$output" == "$(hex_of 'hunter2hunter2')" ]
}

@test "a trailing LF is removed" {
  printf 'hunter2hunter2\n' >"${TWS_PASSWORD_FILE}"
  run value_hex
  [ "$status" -eq 0 ]
  [ "$output" == "$(hex_of 'hunter2hunter2')" ]
}

@test "a trailing CRLF (Windows editor, Set-Content) is removed" {
  printf 'hunter2hunter2\r\n' >"${TWS_PASSWORD_FILE}"
  run value_hex
  [ "$status" -eq 0 ]
  [ "$output" == "$(hex_of 'hunter2hunter2')" ]
}

@test "several trailing CRLF and LF line endings are removed" {
  printf 'hunter2hunter2\r\n\r\n\n\r\n' >"${TWS_PASSWORD_FILE}"
  run value_hex
  [ "$status" -eq 0 ]
  [ "$output" == "$(hex_of 'hunter2hunter2')" ]
}

@test "a UTF-8 byte-order mark is removed" {
  printf '\xef\xbb\xbfhunter2hunter2' >"${TWS_PASSWORD_FILE}"
  run value_hex
  [ "$status" -eq 0 ]
  [ "$output" == "$(hex_of 'hunter2hunter2')" ]
}

@test "a UTF-8 byte-order mark and a CRLF together are removed" {
  printf '\xef\xbb\xbfhunter2hunter2\r\n' >"${TWS_PASSWORD_FILE}"
  run value_hex
  [ "$status" -eq 0 ]
  [ "$output" == "$(hex_of 'hunter2hunter2')" ]
}

@test "spaces, shell metacharacters and inner bytes of the secret are preserved exactly" {
  printf ' hunter2 $HOME *\\ `x` "q" \x27s\x27 \r\n' >"${TWS_PASSWORD_FILE}"
  run value_hex
  [ "$status" -eq 0 ]
  [ "$output" == "$(printf ' hunter2 $HOME *\\ `x` "q" \x27s\x27 ' | od -An -v -tx1 | tr -d ' \n')" ]
}

@test "a non-ASCII UTF-8 secret is preserved byte for byte" {
  printf 'hunter2-\xc3\xa4\xe2\x82\xac\r\n' >"${TWS_PASSWORD_FILE}"
  run value_hex
  [ "$status" -eq 0 ]
  [ "$output" == "$(printf 'hunter2-\xc3\xa4\xe2\x82\xac' | od -An -v -tx1 | tr -d ' \n')" ]
}

@test "a UTF-16LE file with a byte-order mark (Windows PowerShell 5.1 '>') is refused" {
  printf '\xff\xfeh\x00u\x00n\x00t\x00e\x00r\x002\x00\r\x00\n\x00' >"${TWS_PASSWORD_FILE}"
  run value_hex
  refused
  [[ "$output" == *"UTF-16"* ]]
}

@test "a UTF-16BE file with a byte-order mark is refused" {
  printf '\xfe\xff\x00h\x00u\x00n\x00t\x00e\x00r\x002' >"${TWS_PASSWORD_FILE}"
  run value_hex
  refused
}

@test "a UTF-16 file without a byte-order mark (NUL bytes) is refused" {
  printf 'h\x00u\x00n\x00t\x00e\x00r\x002\x00' >"${TWS_PASSWORD_FILE}"
  run value_hex
  refused
}

@test "an empty secret file is refused" {
  : >"${TWS_PASSWORD_FILE}"
  run value_hex
  refused
  [[ "$output" == *"empty"* ]]
}

@test "a secret file holding only a byte-order mark and line endings is refused as empty" {
  printf '\xef\xbb\xbf\r\n' >"${TWS_PASSWORD_FILE}"
  run value_hex
  refused
  [[ "$output" == *"empty"* ]]
}

@test "an unreadable secret path is refused" {
  export TWS_PASSWORD_FILE="${SECRETS}/does-not-exist"
  run value_hex
  refused
}

@test "the error names the variable, never the file content" {
  printf '\xff\xfeh\x00u\x00n\x00t\x00e\x00r\x002\x00' >"${TWS_PASSWORD_FILE}"
  run value_hex
  [ "$status" -ne 0 ]
  echo "$output" | tail -1 | jq -e '.msg | contains("TWS_PASSWORD_FILE")' >/dev/null
}

@test "a value given directly in the environment is used unchanged" {
  unset TWS_PASSWORD_FILE
  export TWS_PASSWORD='hunter2 direct'
  run value_hex
  [ "$status" -eq 0 ]
  [ "$output" == "$(hex_of 'hunter2 direct')" ]
}

@test "the default applies when neither the variable nor its _FILE is set" {
  unset TWS_PASSWORD_FILE
  run value_hex 'fallback'
  [ "$status" -eq 0 ]
  [ "$output" == "$(hex_of 'fallback')" ]
}

@test "setting both the variable and its _FILE is refused" {
  printf 'hunter2hunter2' >"${TWS_PASSWORD_FILE}"
  export TWS_PASSWORD=x
  run value_hex
  [ "$status" -ne 0 ]
  echo "$output" | tail -1 | jq -e '.event == "config_conflict"' >/dev/null
}

# --- boot id and the needs-human hold (log contract v2) -------------------------------------

@test "new_boot_id exports a 16-hex id and records it for processes started later" {
  export LOG_DIR="$(mktemp -d)"
  mkdir -p "${LOG_DIR}/state"
  run bash -c "source '${BROKERSRE_LIB}/common.sh'; new_boot_id; printf '%s' \"\${BOOT_ID}\"; bash -c 'printf \" %s\" \"\${BOOT_ID}\"'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9a-f]{16}\ [0-9a-f]{16}$ ]]
  [ "$(cat "${LOG_DIR}/state/boot_id")" == "${output%% *}" ]
  rm -rf "${LOG_DIR}"
}

@test "two starts get different boot ids" {
  export LOG_DIR="$(mktemp -d)"
  mkdir -p "${LOG_DIR}/state"
  a="$(bash -c "source '${BROKERSRE_LIB}/common.sh'; new_boot_id; printf '%s' \"\${BOOT_ID}\"")"
  b="$(bash -c "source '${BROKERSRE_LIB}/common.sh'; new_boot_id; printf '%s' \"\${BOOT_ID}\"")"
  [ "${a}" != "${b}" ]
  rm -rf "${LOG_DIR}"
}

@test "current_phase reads the phase file and reports unknown when it is missing" {
  export LOG_DIR="$(mktemp -d)"
  mkdir -p "${LOG_DIR}/state"
  run bash -c "source '${BROKERSRE_LIB}/common.sh'; current_phase"
  [ "$output" == "unknown" ]
  echo needs-human >"${LOG_DIR}/state/phase"
  run bash -c "source '${BROKERSRE_LIB}/common.sh'; current_phase"
  [ "$output" == "needs-human" ]
  rm -rf "${LOG_DIR}"
}
