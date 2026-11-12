#!/usr/bin/env bats
# Unit tests for log.sh (log contract v2): every event goes to stdout AND, as the identical
# line, to ${LOG_DIR}/events/events.jsonl, so a sidecar that only mounts the log volume sees
# the same events as `docker logs`. Each line carries the boot id and a sequence number that
# is monotonic per boot across all processes of the container, so a reader can prove it lost
# nothing.

setup() {
  : "${BROKERSRE_LIB:?set BROKERSRE_LIB to rootfs/usr/local/lib/brokersre}"
  export LOG_DIR="$(mktemp -d)"
  export BOOT_ID="0123456789abcdef"
  unset LOG_MAX_BYTES LOG_KEEP
}

teardown() {
  chmod -R u+w "${LOG_DIR}" 2>/dev/null || true
  rm -rf "${LOG_DIR}"
}

emit() { bash -c "source '${BROKERSRE_LIB}/log.sh'; log_event \"\$@\"" _ "$@"; }

@test "an event keeps the five v1 keys and gains boot_id and seq" {
  run emit entrypoint info container_start "hello world"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.src == "entrypoint" and .level == "info" and .event == "container_start" and .msg == "hello world" and .boot_id == "0123456789abcdef" and .seq == 1' >/dev/null
  echo "$output" | jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$")' >/dev/null
}

@test "the identical line is appended to events/events.jsonl" {
  run emit ibc warn twofa_dialog "twofa_dialog"
  [ "$status" -eq 0 ]
  [ "$(cat "${LOG_DIR}/events/events.jsonl")" == "$output" ]
}

@test "seq increases by one per event within a boot" {
  emit entrypoint info a x >/dev/null
  emit entrypoint info b x >/dev/null
  run emit entrypoint info c x
  echo "$output" | jq -e '.seq == 3' >/dev/null
  [ "$(jq -r .seq "${LOG_DIR}/events/events.jsonl" | tr '\n' ' ')" == "1 2 3 " ]
}

@test "events written by many processes at once get unique, gap-free sequence numbers" {
  for i in $(seq 1 25); do
    emit ibc info "event_${i}" "x" >/dev/null &
  done
  wait
  [ "$(wc -l <"${LOG_DIR}/events/events.jsonl")" == "25" ]
  [ "$(jq -r .seq "${LOG_DIR}/events/events.jsonl" | sort -n | tr '\n' ' ')" == "$(seq 1 25 | tr '\n' ' ')" ]
  # In the file the numbers are also in order: the file order is the sequence order.
  [ "$(jq -r .seq "${LOG_DIR}/events/events.jsonl" | tr '\n' ' ')" == "$(seq 1 25 | tr '\n' ' ')" ]
  jq -e . "${LOG_DIR}/events/events.jsonl" >/dev/null
}

@test "a new boot id restarts the sequence at 1" {
  emit entrypoint info a x >/dev/null
  emit entrypoint info b x >/dev/null
  BOOT_ID="fedcba9876543210" run emit entrypoint info c x
  echo "$output" | jq -e '.seq == 1 and .boot_id == "fedcba9876543210"' >/dev/null
}

@test "without BOOT_ID in the environment the boot id comes from state/boot_id" {
  mkdir -p "${LOG_DIR}/state"
  printf 'aaaabbbbccccdddd\n' >"${LOG_DIR}/state/boot_id"
  unset BOOT_ID
  run emit doctor info doctor_ok "x"
  echo "$output" | jq -e '.boot_id == "aaaabbbbccccdddd" and .seq == 1' >/dev/null
}

@test "an unwritable log directory never costs the stdout line" {
  if [ "$(id -u)" -eq 0 ]; then skip "root ignores directory permissions"; fi
  chmod 0500 "${LOG_DIR}"
  run emit entrypoint error dirs_not_writable "cannot write"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.event == "dirs_not_writable" and .msg == "cannot write" and (has("seq") | not)' >/dev/null
}

@test "with no LOG_DIR at all the event is still printed" {
  unset LOG_DIR BOOT_ID
  run emit entrypoint info container_start "x"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.event == "container_start" and (has("seq") | not) and (has("boot_id") | not)' >/dev/null
}

@test "the events file rotates by size and the sequence continues across the rotation" {
  export LOG_MAX_BYTES=400 LOG_KEEP=2
  for i in $(seq 1 12); do emit entrypoint info "event_${i}" "padding-padding-padding" >/dev/null; done
  [ -f "${LOG_DIR}/events/events.jsonl.1" ]
  [ ! -e "${LOG_DIR}/events/events.jsonl.3" ]
  [ "$(stat -c %s "${LOG_DIR}/events/events.jsonl")" -le 400 ]
  [ "$(tail -1 "${LOG_DIR}/events/events.jsonl" | jq -r .seq)" == "12" ]
  # No event is split or lost at the boundary between the generations that are kept.
  cat $(ls -r "${LOG_DIR}"/events/events.jsonl.[0-9]) "${LOG_DIR}/events/events.jsonl" | jq -e . >/dev/null
}

@test "quotes, backslashes and control characters in a message stay valid JSON" {
  run emit entrypoint info x "$(printf 'a"b\\c\td\ne\001f')"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .msg)" == "$(printf 'a"b\\c\td\ne\001f')" ]
}

# --- structured data on an event (log contract v2) -------------------------------------------

emit_data() { bash -c "source '${BROKERSRE_LIB}/log.sh'; log_event_data \"\$@\"" _ "$@"; }

@test "log_event_data adds a data object and keeps every other key" {
  run emit_data entrypoint info container_start '{"gateway_version":"10.50.1g","n":3}' "starting"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.event == "container_start" and .msg == "starting" and .data.gateway_version == "10.50.1g" and .data.n == 3 and .seq == 1 and .boot_id == "0123456789abcdef"' >/dev/null
  [ "$(cat "${LOG_DIR}/events/events.jsonl")" == "$output" ]
}

@test "data that is not a JSON object is dropped, the event itself is still emitted" {
  run emit_data entrypoint info container_start 'not json' "starting"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.event == "container_start" and (has("data") | not)' >/dev/null
}

@test "json_object builds a flat object from key/value pairs and escapes the values" {
  run bash -c "source '${BROKERSRE_LIB}/log.sh'; json_object a 'x\"y' b 'line1
line2' c ''"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.a == "x\"y" and .b == "line1\nline2" and .c == ""' >/dev/null
}
