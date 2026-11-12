#!/usr/bin/env bats
# Unit tests for rotating-append.sh (size-capped log writer) and tail-gateway-logs.sh (mirror
# of the Gateway's own logs). A long-running gateway must not fill its log volume, rotation
# must not lose a line, and a container restart must not copy the same lines twice.

setup() {
  : "${BROKERSRE_LIB:?set BROKERSRE_LIB to rootfs/usr/local/lib/brokersre}"
  WORK="$(mktemp -d)"
  LOG="${WORK}/out.log"
  unset LOG_MAX_BYTES LOG_KEEP
}

teardown() {
  # Stop any mirror started by a test (and any tail it left behind: every such process has the
  # scratch path in its arguments), then remove the scratch directory.
  if [ -n "${MIRROR_PID:-}" ]; then
    pkill -P "${MIRROR_PID}" 2>/dev/null || true
    kill "${MIRROR_PID}" 2>/dev/null || true
  fi
  pkill -f "${WORK}/settings" 2>/dev/null || true
  rm -rf "${WORK}"
}

# start_mirror: run tail-gateway-logs.sh in the background against the scratch directories.
# Output is discarded and bats' own descriptor 3 is closed, otherwise bats waits for the
# background process before it reports the test.
start_mirror() {
  TWS_SETTINGS_PATH="${WORK}/settings" LOG_DIR="${WORK}/logs" MIRROR_INTERVAL_S=1 \
    "${BROKERSRE_LIB}/tail-gateway-logs.sh" >/dev/null 2>&1 3>&- &
  MIRROR_PID=$!
}

# wait_until <seconds> <command...>: poll instead of sleeping a fixed time.
wait_until() {
  local deadline=$((SECONDS + $1))
  shift
  until "$@" 2>/dev/null; do
    if ((SECONDS >= deadline)); then return 1; fi
    sleep 0.2
  done
}

lines_in() { wc -l <"$1"; }

@test "lines are appended to the file and passed through when asked" {
  run bash -c "printf 'one\ntwo\n' | '${BROKERSRE_LIB}/rotating-append.sh' '${LOG}' --passthrough"
  [ "$status" -eq 0 ]
  [ "$output" == $'one\ntwo' ]
  [ "$(cat "${LOG}")" == $'one\ntwo' ]
}

@test "without --passthrough nothing is written to stdout" {
  run bash -c "printf 'one\n' | '${BROKERSRE_LIB}/rotating-append.sh' '${LOG}'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "${LOG}")" == "one" ]
}

@test "an existing file is appended to, never truncated" {
  printf 'old\n' >"${LOG}"
  printf 'new\n' | "${BROKERSRE_LIB}/rotating-append.sh" "${LOG}"
  [ "$(cat "${LOG}")" == $'old\nnew' ]
}

@test "a final line without a newline is kept" {
  printf 'one\ntwo' | "${BROKERSRE_LIB}/rotating-append.sh" "${LOG}"
  [ "$(cat "${LOG}")" == $'one\ntwo' ]
}

@test "the file rotates at LOG_MAX_BYTES and no line is lost or split" {
  # 40 lines of 10 bytes each with a 100-byte cap: generations hold whole lines only.
  for i in $(seq -w 1 40); do printf 'line-%s--\n' "${i}"; done >"${WORK}/in.txt"
  LOG_MAX_BYTES=100 LOG_KEEP=9 "${BROKERSRE_LIB}/rotating-append.sh" "${LOG}" <"${WORK}/in.txt"
  [ -f "${LOG}.1" ]
  for f in "${LOG}" "${LOG}".[0-9]; do
    [ "$(stat -c %s "${f}")" -le 100 ]
  done
  # Oldest generation first: .3 .2 .1 then the live file reproduce the input exactly.
  cat $(ls -r "${LOG}".[0-9]) "${LOG}" >"${WORK}/joined.txt"
  cmp "${WORK}/in.txt" "${WORK}/joined.txt"
}

@test "only LOG_KEEP old generations are kept, so disk use is bounded" {
  for i in $(seq -w 1 200); do printf 'line-%s-\n' "${i}"; done |
    LOG_MAX_BYTES=100 LOG_KEEP=2 "${BROKERSRE_LIB}/rotating-append.sh" "${LOG}"
  [ -f "${LOG}.1" ]
  [ -f "${LOG}.2" ]
  [ ! -e "${LOG}.3" ]
  # The newest lines are the ones that survive.
  tail -1 "${LOG}" | grep -q -x 'line-200-'
}

@test "a single line longer than the cap is written whole, not dropped" {
  long="$(printf 'x%.0s' $(seq 1 300))"
  printf 'a\n%s\nb\n' "${long}" | LOG_MAX_BYTES=100 LOG_KEEP=5 "${BROKERSRE_LIB}/rotating-append.sh" "${LOG}"
  cat "${LOG}".[0-9] "${LOG}" | grep -q -x "${long}"
}

@test "an invalid LOG_MAX_BYTES falls back to the default instead of rotating every line" {
  printf 'one\ntwo\n' | LOG_MAX_BYTES=banana "${BROKERSRE_LIB}/rotating-append.sh" "${LOG}"
  [ "$(cat "${LOG}")" == $'one\ntwo' ]
  [ ! -e "${LOG}.1" ]
}

@test "the mirror copies the Gateway launcher log into the log volume" {
  mkdir -p "${WORK}/settings" "${WORK}/logs"
  printf 'l1\nl2\nl3\n' >"${WORK}/settings/launcher.log"
  start_mirror
  wait_until 10 bash -c "[ \"\$(wc -l <'${WORK}/logs/jts/launcher.log')\" = 3 ]"
  printf 'l4\n' >>"${WORK}/settings/launcher.log"
  wait_until 10 bash -c "[ \"\$(wc -l <'${WORK}/logs/jts/launcher.log')\" = 4 ]"
  [ "$(cat "${WORK}/logs/jts/launcher.log")" == $'l1\nl2\nl3\nl4' ]
}

@test "a restart of the mirror continues where it stopped instead of copying everything again" {
  mkdir -p "${WORK}/settings" "${WORK}/logs"
  printf 'l1\nl2\nl3\n' >"${WORK}/settings/launcher.log"
  start_mirror
  wait_until 10 bash -c "[ \"\$(wc -l <'${WORK}/logs/jts/launcher.log')\" = 3 ]"
  # Stop it the way the entrypoint does (SIGTERM), as on a container stop.
  kill "${MIRROR_PID}"
  wait "${MIRROR_PID}" 2>/dev/null || true
  MIRROR_PID=""
  printf 'l4\nl5\n' >>"${WORK}/settings/launcher.log"
  start_mirror
  wait_until 10 bash -c "[ \"\$(wc -l <'${WORK}/logs/jts/launcher.log')\" -ge 5 ]"
  sleep 1
  [ "$(cat "${WORK}/logs/jts/launcher.log")" == $'l1\nl2\nl3\nl4\nl5' ]
}

@test "a launcher log replaced by a new file (Gateway restart) is mirrored from its start" {
  mkdir -p "${WORK}/settings" "${WORK}/logs"
  printf 'old1\nold2\n' >"${WORK}/settings/launcher.log"
  start_mirror
  wait_until 10 bash -c "[ \"\$(wc -l <'${WORK}/logs/jts/launcher.log')\" = 2 ]"
  printf 'new1\n' >"${WORK}/settings/launcher.log.next"
  mv -f "${WORK}/settings/launcher.log.next" "${WORK}/settings/launcher.log"
  wait_until 10 bash -c "[ \"\$(wc -l <'${WORK}/logs/jts/launcher.log')\" = 3 ]"
  [ "$(cat "${WORK}/logs/jts/launcher.log")" == $'old1\nold2\nnew1' ]
}
