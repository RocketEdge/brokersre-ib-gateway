#!/usr/bin/env bats
# Unit tests for sampler.sh, the in-container resource sampler (metrics/metrics.jsonl on the
# shared log volume). The sampler is what tells an operator WHY a gateway went away: the kernel
# killed a process for memory, a volume filled up, or the login is stuck behind a window nobody
# sees. Two rules are tested throughout: a value that could not be measured is left out of the
# sample (it is never written as 0), and a condition is reported once when it starts and once
# when it clears, not on every sample.
#
# Every source is a fixture tree built under mktemp (CGROUP_ROOT, PROC_ROOT), the clock is the
# SAMPLER_NOW hook and the JVM is the SAMPLER_JAVA_PID hook, so nothing waits and nothing depends
# on the machine. The last tests run against the real /sys/fs/cgroup and /proc of the image.

setup() {
  : "${BROKERSRE_LIB:?set BROKERSRE_LIB to rootfs/usr/local/lib/brokersre}"
  WORK="$(mktemp -d)"
  export LOG_DIR="${WORK}/logs" TWS_SETTINGS_PATH="${WORK}/settings"
  export CGROUP_ROOT="${WORK}/cgroup" PROC_ROOT="${WORK}/proc"
  export BOOT_ID="0123456789abcdef" TRADING_MODE="paper" SAMPLER_JAVA_PID="4242"
  unset API_PORT LOG_MAX_BYTES LOG_KEEP SAMPLE_INTERVAL_S DISK_MIN_FREE_PCT LOGIN_STALL_S \
    MEM_HIGH_PCT MEM_HIGH_FOR_S SAMPLER_NOW
  METRICS="${LOG_DIR}/metrics/metrics.jsonl"
  EVENTS="${LOG_DIR}/events/events.jsonl"
  SAMPLER_PID="" WATCHDOG_PID="" FAKE_JVM_PID=""
  mkdir -p "${LOG_DIR}/state" "${TWS_SETTINGS_PATH}"
  printf 'logged-in\n' >"${LOG_DIR}/state/phase"
  make_cgroup
  make_proc
  # The sampler runs with `set -u` when it is executed; the functions are tested the same way.
  set -u
  source "${BROKERSRE_LIB}/sampler.sh"
  sampler_init_state
}

teardown() {
  local pid children child
  for pid in "${SAMPLER_PID:-}" "${WATCHDOG_PID:-}" "${FAKE_JVM_PID:-}"; do
    if [ -n "${pid}" ]; then
      # SIGKILL, and wait, before the scratch directory goes: a sampler stopped with SIGTERM
      # takes a last sample, which would write into the directory while it is being removed.
      children="$(pgrep -P "${pid}" || true)"
      kill -KILL "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
      for child in ${children}; do kill "${child}" 2>/dev/null || true; done
    fi
  done
  chmod -R u+rwx "${WORK}" 2>/dev/null || true
  rm -rf "${WORK}"
}

# make_cgroup: a cgroup v2 directory with the files the sampler reads, in the kernel's format.
# The neighbours of every key (inactive_anon, oom, oom_group_kill, user_usec) carry different
# numbers, so a parser that matches a prefix or the wrong line gives a wrong value.
make_cgroup() {
  mkdir -p "${CGROUP_ROOT}"
  printf '1000000\n' >"${CGROUP_ROOT}/memory.current"
  printf 'anon 600000\nfile 300000\ninactive_anon 111\nactive_anon 222\ninactive_file 250000\nactive_file 50000\n' \
    >"${CGROUP_ROOT}/memory.stat"
  printf '2000000\n' >"${CGROUP_ROOT}/memory.max"
  printf 'low 0\nhigh 0\nmax 5\noom 7\noom_kill 2\noom_group_kill 9\n' >"${CGROUP_ROOT}/memory.events"
  printf 'usage_usec 47930\nuser_usec 17429\nsystem_usec 30501\nnice_usec 0\nnr_periods 12\nnr_throttled 3\nthrottled_usec 1234\nnr_bursts 0\nburst_usec 0\n' \
    >"${CGROUP_ROOT}/cpu.stat"
  printf '57\n' >"${CGROUP_ROOT}/pids.current"
}

# tcp_row SL LOCAL REMOTE STATE: one socket row as /proc/net/tcp and /proc/net/tcp6 print it
# (the state is the fourth column, two hex digits; 08 is CLOSE_WAIT, 01 ESTABLISHED, 0A LISTEN).
tcp_row() {
  printf '%4d: %s %s %s 00000000:00000000 00:00000000 00000000  1000        0 %d 1 0000000000000000 20 4 30 10 -1\n' \
    "$1" "$2" "$3" "$4" "$((22360 + $1))"
}

# make_proc: /proc of a container whose JVM is pid 4242 (512000 kB resident, 63 threads, five
# open descriptors) and whose socket tables hold, for API port 4002 (hex 0FA2): two IPv4 and
# one IPv6 socket in CLOSE_WAIT, next to rows that must not be counted (a listener, an
# established connection, CLOSE_WAIT on the IBC command port 7462 = 1D26, CLOSE_WAIT where 4002
# is the REMOTE port, and CLOSE_WAIT on the live port 4001 = 0FA1).
make_proc() {
  local jvm="${PROC_ROOT}/4242" v4="0100007F" v6="0000000000000000FFFF00000100007F"
  mkdir -p "${jvm}/fd" "${PROC_ROOT}/net"
  printf 'Name:\tjava\nUmask:\t0022\nState:\tS (sleeping)\nTgid:\t4242\nPid:\t4242\nPPid:\t1\nVmPeak:\t 3456789 kB\nVmSize:\t 3400000 kB\nVmHWM:\t  520000 kB\nVmRSS:\t  512000 kB\nRssAnon:\t  480000 kB\nThreads:\t63\nSigQ:\t0/31400\n' \
    >"${jvm}/status"
  touch "${jvm}/fd/0" "${jvm}/fd/1" "${jvm}/fd/2" "${jvm}/fd/3" "${jvm}/fd/4"
  {
    printf '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n'
    tcp_row 0 "${v4}:0FA2" "00000000:0000" 0A
    tcp_row 1 "${v4}:0FA2" "${v4}:D431" 08
    tcp_row 2 "${v4}:0FA2" "${v4}:D432" 01
    tcp_row 3 "${v4}:1D26" "${v4}:D433" 08
    tcp_row 4 "${v4}:D434" "${v4}:0FA2" 08
    tcp_row 5 "${v4}:0FA2" "${v4}:D435" 08
  } >"${PROC_ROOT}/net/tcp"
  {
    printf '  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n'
    tcp_row 0 "00000000000000000000000000000000:0FA2" "00000000000000000000000000000000:0000" 0A
    tcp_row 1 "${v6}:0FA2" "${v6}:E0F2" 08
    tcp_row 2 "${v6}:0FA1" "${v6}:E0F3" 08
  } >"${PROC_ROOT}/net/tcp6"
}

# lacks KEY...: true when the sample in $output has none of the keys.
lacks() {
  local key
  for key in "$@"; do
    jq -e --arg k "${key}" 'has($k) | not' <<<"${output}" >/dev/null || return 1
  done
}

# sample_line [phase=TOKEN] [KEY=NUMBER...]: a metrics line with the five fixed keys and the
# given measurements, as input for evaluate_events.
sample_line() {
  local phase="logged-in" pair body=""
  for pair in "$@"; do
    case "${pair}" in
      phase=*) phase="${pair#phase=}" ;;
      *) body+=",\"${pair%%=*}\":${pair#*=}" ;;
    esac
  done
  printf '{"ts":"2026-11-12T00:00:00.000Z","src":"metrics","boot_id":"%s","seq":1,"phase":"%s"%s}\n' \
    "${BOOT_ID}" "${phase}" "${body}"
}

# observe NOW [phase=TOKEN] [KEY=NUMBER...]: let the sampler evaluate one sample at the injected
# time NOW (epoch seconds). Runs in the test's shell, so the sampler's state carries over to the
# next call exactly as it does between two iterations of the loop.
observe() {
  SAMPLER_NOW="$1"
  shift
  evaluate_events "$(sample_line "$@")" >/dev/null
}

# events: the names of all events emitted so far, in order, each followed by a space.
events() {
  if [ -f "${EVENTS}" ]; then jq -r .event "${EVENTS}" | tr '\n' ' '; fi
}

# event_field EVENT FIELD: FIELD of every EVENT emitted so far, one per line.
event_field() {
  jq -r --arg e "$1" --arg f "$2" 'select(.event == $e) | .[$f]' "${EVENTS}"
}

# wait_until <seconds> <command...>: poll instead of sleeping a fixed time.
wait_until() {
  local deadline=$((SECONDS + $1))
  shift
  until "$@" >/dev/null 2>&1; do
    if ((SECONDS >= deadline)); then return 1; fi
    sleep 0.1
  done
}

# start_sampler: run the sampler the way the entrypoint does, as a background process. Output
# is discarded and bats' descriptor 3 is closed, otherwise bats waits for it.
start_sampler() {
  "${BROKERSRE_LIB}/sampler.sh" >/dev/null 2>&1 3>&- &
  SAMPLER_PID=$!
}

# stop_sampler: send SIGTERM and wait; STOP_STATUS is the sampler's exit status and STOP_MS the
# time it took to end. A watchdog kills a sampler that ignores the signal, so such a bug fails
# the test (status 137) instead of hanging it.
stop_sampler() {
  local started="${EPOCHREALTIME/[.,]/}" ended
  (sleep 10 && kill -KILL "${SAMPLER_PID}") >/dev/null 2>&1 3>&- &
  WATCHDOG_PID=$!
  kill -TERM "${SAMPLER_PID}"
  STOP_STATUS=0
  wait "${SAMPLER_PID}" || STOP_STATUS=$?
  ended="${EPOCHREALTIME/[.,]/}"
  STOP_MS=$(((ended - started) / 1000))
  SAMPLER_PID=""
}

# start_fake_jvm: run a process whose name is `java`. The kernel names a process after the file
# it executes, so a script called java is what `pgrep -x java` finds.
start_fake_jvm() {
  printf '#!/bin/bash\nsleep 60\nexit 0\n' >"${WORK}/java"
  chmod +x "${WORK}/java"
  "${WORK}/java" >/dev/null 2>&1 3>&- &
  FAKE_JVM_PID=$!
  wait_until 10 pgrep -x java
}

metrics_lines() { wc -l <"${METRICS}"; }

# wait_for_pause: wait until the running sampler has taken a sample and sleeps until the next.
wait_for_pause() {
  wait_until 20 pgrep -P "${SAMPLER_PID}" -x sleep
}

# set_oom_kills N: rewrite the cgroup's memory.events with oom_kill N, as the kernel would
# after its OOM killer took a process.
set_oom_kills() {
  printf 'low 0\nhigh 0\nmax 5\noom 7\noom_kill %s\noom_group_kill 9\n' "$1" >"${CGROUP_ROOT}/memory.events"
}

# fake_df SECONDS: put a `df` in front of the real one that records every call in
# ${WORK}/df-calls and takes SECONDS longer. df is the one source that can be slow (a mount
# that hangs), so the tests make it slow and count its calls.
fake_df() {
  local real_df
  real_df="$(command -v df)"
  mkdir -p "${WORK}/bin"
  printf '#!/bin/bash\necho call >>"%s"\nsleep %s\nexec "%s" "$@"\n' "${WORK}/df-calls" "$1" "${real_df}" \
    >"${WORK}/bin/df"
  chmod +x "${WORK}/bin/df"
  export PATH="${WORK}/bin:${PATH}"
}

df_calls() { wc -l <"${WORK}/df-calls"; }

# --- the sample line ---------------------------------------------------------------------

@test "a sample carries every value of the fixture" {
  run sample_once
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$(jq -c 'del(.ts) | with_entries(select(.key | startswith("disk_") | not))' <<<"${output}")" == '{"src":"metrics","boot_id":"0123456789abcdef","seq":1,"phase":"logged-in","mem_working_set_bytes":750000,"mem_limit_bytes":2000000,"oom_kills":2,"cpu_usage_usec":47930,"cpu_throttled_usec":1234,"pids":57,"java_rss_bytes":524288000,"java_threads":63,"open_fds":5,"api_close_wait_sockets":3}' ]
}

@test "the keys come in the order of the contract and ts is UTC with milliseconds" {
  run sample_once
  [ "$(jq -c 'keys_unsorted' <<<"${output}")" == '["ts","src","boot_id","seq","phase","mem_working_set_bytes","mem_limit_bytes","oom_kills","cpu_usage_usec","cpu_throttled_usec","pids","java_rss_bytes","java_threads","open_fds","api_close_wait_sockets","disk_free_bytes_logs","disk_free_bytes_settings","disk_total_bytes_logs","disk_total_bytes_settings"]' ]
  jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$")' <<<"${output}" >/dev/null
}

@test "disk keys are the free and total bytes df reports for the log and settings directories" {
  run sample_once
  set -- $(df -P -k "${LOG_DIR}" | tail -1)
  jq -e --argjson total "$(($2 * 1024))" '
    .disk_total_bytes_logs == $total and .disk_total_bytes_settings == $total
    and .disk_free_bytes_logs > 0 and .disk_free_bytes_logs <= $total
    and .disk_free_bytes_settings > 0 and .disk_free_bytes_settings <= $total' <<<"${output}" >/dev/null
}

@test "seq is one more than the number of samples already taken" {
  SAMPLER_SEQ=41 run sample_once
  jq -e '.seq == 42' <<<"${output}" >/dev/null
}

@test "the phase is the token in state/phase" {
  printf '2fa-pending\n' >"${LOG_DIR}/state/phase"
  run sample_once
  jq -e '.phase == "2fa-pending"' <<<"${output}" >/dev/null
}

@test "a missing phase file gives phase unknown" {
  rm -f "${LOG_DIR}/state/phase"
  run sample_once
  [ "$status" -eq 0 ]
  jq -e '.phase == "unknown"' <<<"${output}" >/dev/null
}

@test "a phase file that does not hold one plain token gives phase unknown and valid JSON" {
  printf 'log"in\\ now\n' >"${LOG_DIR}/state/phase"
  run sample_once
  jq -e '.phase == "unknown"' <<<"${output}" >/dev/null
}

@test "without BOOT_ID in the environment the boot id comes from state/boot_id" {
  printf 'aaaabbbbccccdddd\n' >"${LOG_DIR}/state/boot_id"
  unset BOOT_ID
  run sample_once
  jq -e '.boot_id == "aaaabbbbccccdddd"' <<<"${output}" >/dev/null
}

@test "with no boot id anywhere the key is still present, as unknown" {
  unset BOOT_ID
  run sample_once
  jq -e '.boot_id == "unknown"' <<<"${output}" >/dev/null
}

# --- absence is never zero ---------------------------------------------------------------

@test "when nothing can be measured only ts, src, boot_id, seq and phase are written" {
  export CGROUP_ROOT="${WORK}/none" PROC_ROOT="${WORK}/none" LOG_DIR="${WORK}/none" TWS_SETTINGS_PATH="${WORK}/none"
  SAMPLER_JAVA_PID=""
  run sample_once
  [ "$status" -eq 0 ]
  [ "$(jq -c 'del(.ts)' <<<"${output}")" == '{"src":"metrics","boot_id":"0123456789abcdef","seq":1,"phase":"unknown"}' ]
}

@test "a memory limit of max (no limit) leaves mem_limit_bytes out" {
  printf 'max\n' >"${CGROUP_ROOT}/memory.max"
  run sample_once
  lacks mem_limit_bytes
  jq -e '.mem_working_set_bytes == 750000' <<<"${output}" >/dev/null
}

@test "the working set is left out when memory.current is missing" {
  rm "${CGROUP_ROOT}/memory.current"
  run sample_once
  lacks mem_working_set_bytes
  jq -e '.mem_limit_bytes == 2000000 and .oom_kills == 2' <<<"${output}" >/dev/null
}

@test "the working set is left out when memory.stat has no inactive_file line" {
  printf 'anon 600000\nfile 300000\n' >"${CGROUP_ROOT}/memory.stat"
  run sample_once
  lacks mem_working_set_bytes
}

@test "the working set never goes below zero" {
  printf 'anon 0\ninactive_file 1000001\n' >"${CGROUP_ROOT}/memory.stat"
  run sample_once
  jq -e '.mem_working_set_bytes == 0' <<<"${output}" >/dev/null
}

@test "oom_kills is left out when memory.events has no oom_kill line" {
  printf 'low 0\nhigh 0\nmax 5\noom 7\n' >"${CGROUP_ROOT}/memory.events"
  run sample_once
  lacks oom_kills
}

@test "a cpu.stat without throttling figures gives the usage and leaves cpu_throttled_usec out" {
  printf 'usage_usec 47930\nuser_usec 17429\nsystem_usec 30501\n' >"${CGROUP_ROOT}/cpu.stat"
  run sample_once
  lacks cpu_throttled_usec
  jq -e '.cpu_usage_usec == 47930' <<<"${output}" >/dev/null
}

@test "missing cgroup files leave their keys out and keep the others" {
  rm "${CGROUP_ROOT}/memory.max" "${CGROUP_ROOT}/memory.events" "${CGROUP_ROOT}/cpu.stat" "${CGROUP_ROOT}/pids.current"
  run sample_once
  [ "$status" -eq 0 ]
  lacks mem_limit_bytes oom_kills cpu_usage_usec cpu_throttled_usec pids
  jq -e '.mem_working_set_bytes == 750000 and .java_threads == 63' <<<"${output}" >/dev/null
}

@test "a value that is not a number is never written" {
  printf 'garbage\n' >"${CGROUP_ROOT}/pids.current"
  printf 'usage_usec -5\nthrottled_usec 12x\n' >"${CGROUP_ROOT}/cpu.stat"
  run sample_once
  lacks pids cpu_usage_usec cpu_throttled_usec
  jq -e '.oom_kills == 2' <<<"${output}" >/dev/null
}

@test "unreadable sources leave their keys out instead of reporting zero, without any error text" {
  if [ "$(id -u)" -eq 0 ]; then skip "root reads everything"; fi
  chmod 000 "${CGROUP_ROOT}/pids.current" "${CGROUP_ROOT}/memory.events" "${PROC_ROOT}/4242/fd" \
    "${PROC_ROOT}/4242/status" "${PROC_ROOT}/net/tcp"
  run sample_once
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  lacks pids oom_kills open_fds java_rss_bytes java_threads api_close_wait_sockets
  jq -e '.cpu_usage_usec == 47930' <<<"${output}" >/dev/null
}

@test "without a JVM the three JVM keys are left out" {
  SAMPLER_JAVA_PID=""
  run sample_once
  lacks java_rss_bytes java_threads open_fds
  jq -e '.pids == 57' <<<"${output}" >/dev/null
}

@test "a JVM that ended between two samples leaves its keys out" {
  rm -rf "${PROC_ROOT}/4242"
  run sample_once
  [ "$status" -eq 0 ]
  lacks java_rss_bytes java_threads open_fds
}

@test "a JVM without any open descriptor is a measured zero" {
  rm "${PROC_ROOT}/4242/fd"/*
  run sample_once
  jq -e '.open_fds == 0' <<<"${output}" >/dev/null
}

@test "a sample whose fixed keys cannot be produced is not printed at all" {
  # What a process limit that is used up looks like: the child that formats the time cannot run.
  ts_now() { return 1; }
  run sample_once
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "a directory that df cannot report leaves its two disk keys out and keeps the other pair" {
  export TWS_SETTINGS_PATH="${WORK}/no-such-directory"
  run sample_once
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  lacks disk_free_bytes_settings disk_total_bytes_settings
  jq -e '.disk_free_bytes_logs > 0 and .disk_total_bytes_logs > 0' <<<"${output}" >/dev/null
}

# --- sockets in CLOSE_WAIT on the API port --------------------------------------------------

@test "CLOSE_WAIT sockets are counted on the local API port only, IPv4 and IPv6 together" {
  run read_api_close_wait
  [ "$output" == "3" ]
}

@test "IPv4 alone: other states, other local ports and the API port as remote port are not counted" {
  rm "${PROC_ROOT}/net/tcp6"
  run read_api_close_wait
  [ "$output" == "2" ]
}

@test "IPv6 alone: the socket of the live port is not counted in paper mode" {
  printf '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n' >"${PROC_ROOT}/net/tcp"
  run read_api_close_wait
  [ "$output" == "1" ]
}

@test "live mode counts on port 4001" {
  TRADING_MODE=live run read_api_close_wait
  [ "$output" == "1" ]
}

@test "API_PORT overrides the port derived from TRADING_MODE" {
  API_PORT=7462 run read_api_close_wait
  [ "$output" == "1" ]
}

@test "readable socket tables without a matching socket are a measured zero" {
  API_PORT=4999 run sample_once
  jq -e '.api_close_wait_sockets == 0' <<<"${output}" >/dev/null
}

@test "missing socket tables leave api_close_wait_sockets out" {
  rm "${PROC_ROOT}/net/tcp" "${PROC_ROOT}/net/tcp6"
  run sample_once
  lacks api_close_wait_sockets
}

@test "an unreadable IPv6 table leaves the key out rather than giving half a count" {
  if [ "$(id -u)" -eq 0 ]; then skip "root reads everything"; fi
  chmod 000 "${PROC_ROOT}/net/tcp6"
  run sample_once
  [ "${#lines[@]}" -eq 1 ]
  lacks api_close_wait_sockets
}

@test "an unknown API port leaves api_close_wait_sockets out" {
  TRADING_MODE=both run sample_once
  lacks api_close_wait_sockets
}

# --- the metrics file -----------------------------------------------------------------------

@test "each tick appends one line to metrics/metrics.jsonl and seq counts from 1" {
  sampler_tick >/dev/null
  sampler_tick >/dev/null
  sampler_tick >/dev/null
  [ "$(metrics_lines)" -eq 3 ]
  [ "$(jq -r .seq "${METRICS}" | tr '\n' ' ')" == "1 2 3 " ]
  jq -e '.src == "metrics" and .pids == 57' "${METRICS}" >/dev/null
}

@test "metrics.jsonl rotates at LOG_MAX_BYTES, keeps LOG_KEEP generations and never splits a line" {
  export LOG_MAX_BYTES=1200 LOG_KEEP=2
  for _ in 1 2 3 4 5 6 7 8 9; do sampler_tick >/dev/null; done
  [ -f "${METRICS}.1" ]
  [ -f "${METRICS}.2" ]
  [ ! -e "${METRICS}.3" ]
  for f in "${METRICS}" "${METRICS}.1" "${METRICS}.2"; do
    [ "$(stat -c %s "${f}")" -le 1200 ]
  done
  # Oldest generation first: what is kept is whole lines that continue each other up to seq 9.
  cat "${METRICS}.2" "${METRICS}.1" "${METRICS}" >"${WORK}/joined"
  jq -e . "${WORK}/joined" >/dev/null
  kept="$(wc -l <"${WORK}/joined")"
  [ "${kept}" -ge 3 ]
  [ "$(jq -r .seq "${WORK}/joined" | tr '\n' ' ')" == "$(seq $((10 - kept)) 9 | tr '\n' ' ')" ]
}

@test "LOG_KEEP=0 keeps no old generation" {
  export LOG_MAX_BYTES=100 LOG_KEEP=0
  for _ in 1 2 3; do sampler_tick >/dev/null; done
  [ ! -e "${METRICS}.1" ]
  [ "$(jq -r .seq "${METRICS}")" == "3" ]
}

@test "an invalid LOG_MAX_BYTES falls back to the default instead of rotating every line" {
  export LOG_MAX_BYTES=banana
  for _ in 1 2 3; do sampler_tick >/dev/null; done
  [ "$(metrics_lines)" -eq 3 ]
  [ ! -e "${METRICS}.1" ]
}

@test "a sample that could not be produced is skipped and the gap shows in seq" {
  ts_now() { return 1; }
  sampler_tick >/dev/null
  [ ! -e "${METRICS}" ]
  [ "$(events)" == "" ]
  source "${BROKERSRE_LIB}/log.sh"
  sampler_tick >/dev/null
  [ "$(jq -r .seq "${METRICS}")" == "2" ]
}

@test "an unwritable log volume costs the sample but not the sampler, and the gap shows in seq" {
  if [ "$(id -u)" -eq 0 ]; then skip "root ignores directory permissions"; fi
  mkdir -p "${LOG_DIR}/metrics"
  chmod 0500 "${LOG_DIR}/metrics"
  sampler_tick >/dev/null 2>"${WORK}/stderr"
  [ ! -e "${METRICS}" ]
  [ ! -s "${WORK}/stderr" ]
  chmod 0700 "${LOG_DIR}/metrics"
  sampler_tick >/dev/null
  [ "$(jq -r .seq "${METRICS}")" == "2" ]
}

# --- oom_kill -------------------------------------------------------------------------------

@test "oom_kill fires on the first sample when the counter is already above zero" {
  observe 1000 oom_kills=2 mem_limit_bytes=2000000
  [ "$(events)" == "oom_kill " ]
  [ "$(event_field oom_kill level)" == "error" ]
  [ "$(event_field oom_kill src)" == "metrics" ]
  [ "$(event_field oom_kill msg)" == "2 OOM kill(s) in this container since container start; memory limit 2000000 bytes" ]
}

@test "oom_kill fires when the counter rises, once per rise" {
  observe 1000 oom_kills=0 mem_limit_bytes=2000000
  [ "$(events)" == "" ]
  observe 1030 oom_kills=1 mem_limit_bytes=2000000
  observe 1060 oom_kills=1 mem_limit_bytes=2000000
  [ "$(events)" == "oom_kill " ]
  [ "$(event_field oom_kill msg)" == "1 OOM kill(s) in this container since the previous sample (1 since container start); memory limit 2000000 bytes" ]
  observe 1090 oom_kills=3 mem_limit_bytes=2000000
  [ "$(events)" == "oom_kill oom_kill " ]
  [ "$(event_field oom_kill msg | tail -1)" == "2 OOM kill(s) in this container since the previous sample (3 since container start); memory limit 2000000 bytes" ]
}

@test "a sample without oom_kills fires nothing and keeps the last measured count" {
  observe 1000 oom_kills=2
  observe 1030
  observe 1060 oom_kills=2
  [ "$(events)" == "oom_kill " ]
}

@test "the oom_kill message says so when no memory limit is known" {
  observe 1000 oom_kills=1
  [ "$(event_field oom_kill msg)" == "1 OOM kill(s) in this container since container start; memory limit unlimited or not measured" ]
}

# --- disk_low / disk_ok ---------------------------------------------------------------------

@test "disk_low fires once when free space falls below DISK_MIN_FREE_PCT and disk_ok once when it clears" {
  observe 1000 disk_free_bytes_logs=20000 disk_total_bytes_logs=100000
  [ "$(events)" == "" ]
  observe 1030 disk_free_bytes_logs=9999 disk_total_bytes_logs=100000
  observe 1060 disk_free_bytes_logs=5000 disk_total_bytes_logs=100000
  [ "$(events)" == "disk_low " ]
  [ "$(event_field disk_low level)" == "warn" ]
  [ "$(event_field disk_low msg)" == "${LOG_DIR} has 9999 bytes free of 100000 (9%), below DISK_MIN_FREE_PCT=10" ]
  observe 1090 disk_free_bytes_logs=30000 disk_total_bytes_logs=100000
  observe 1120 disk_free_bytes_logs=30000 disk_total_bytes_logs=100000
  [ "$(events)" == "disk_low disk_ok " ]
  [ "$(event_field disk_ok level)" == "info" ]
  [ "$(event_field disk_ok msg)" == "${LOG_DIR} has 30000 bytes free of 100000 (30%), no longer below DISK_MIN_FREE_PCT=10" ]
}

@test "free space of exactly DISK_MIN_FREE_PCT is not low" {
  observe 1000 disk_free_bytes_logs=10000 disk_total_bytes_logs=100000
  [ "$(events)" == "" ]
}

@test "the two filesystems are watched independently" {
  observe 1000 disk_free_bytes_logs=50000 disk_total_bytes_logs=100000 disk_free_bytes_settings=100 disk_total_bytes_settings=100000
  [ "$(events)" == "disk_low " ]
  [ "$(event_field disk_low msg)" == "${TWS_SETTINGS_PATH} has 100 bytes free of 100000 (0%), below DISK_MIN_FREE_PCT=10" ]
  observe 1030 disk_free_bytes_logs=50 disk_total_bytes_logs=100000 disk_free_bytes_settings=100 disk_total_bytes_settings=100000
  [ "$(events)" == "disk_low disk_low " ]
  observe 1060 disk_free_bytes_logs=50 disk_total_bytes_logs=100000 disk_free_bytes_settings=90000 disk_total_bytes_settings=100000
  [ "$(events)" == "disk_low disk_low disk_ok " ]
  [ "$(event_field disk_ok msg)" == "${TWS_SETTINGS_PATH} has 90000 bytes free of 100000 (90%), no longer below DISK_MIN_FREE_PCT=10" ]
}

@test "a sample without disk figures neither clears nor repeats disk_low" {
  observe 1000 disk_free_bytes_logs=100 disk_total_bytes_logs=100000
  observe 1030
  observe 1060 disk_free_bytes_logs=100 disk_total_bytes_logs=100000
  [ "$(events)" == "disk_low " ]
}

@test "DISK_MIN_FREE_PCT moves the threshold and an invalid value means the default" {
  DISK_MIN_FREE_PCT=50
  observe 1000 disk_free_bytes_logs=40000 disk_total_bytes_logs=100000
  [ "$(events)" == "disk_low " ]
  DISK_MIN_FREE_PCT=banana
  observe 1030 disk_free_bytes_logs=40000 disk_total_bytes_logs=100000
  [ "$(events)" == "disk_low disk_ok " ]
}

# --- login_stalled / login_resumed ----------------------------------------------------------

@test "a stalled login is photographed when SCREENSHOTS=yes, and only then" {
  export RUN_DIR="${WORK}/run" SCREENSHOT_NOW=1794441600
  mkdir -p "${RUN_DIR}/xvfb"
  head -c 2048 /dev/urandom >"${RUN_DIR}/xvfb/Xvfb_screen0"
  observe 1000 phase=login
  observe 1301 phase=login
  [ "$(events)" == "login_stalled " ]
  [ ! -d "${LOG_DIR}/screens" ]
  observe 1400 phase=logged-in
  export SCREENSHOTS=yes
  observe 2000 phase=login
  observe 2301 phase=login
  [ "$(events)" == "login_stalled login_resumed login_stalled screenshot_saved " ]
  cmp "${RUN_DIR}/xvfb/Xvfb_screen0" "${LOG_DIR}/screens/20261112T000000Z-login_stalled.xwd"
}

@test "login_stalled fires once after more than LOGIN_STALL_S of login and login_resumed when it ends" {
  observe 1000 phase=login
  observe 1300 phase=login
  [ "$(events)" == "" ]
  observe 1301 phase=login
  observe 1400 phase=login
  [ "$(events)" == "login_stalled " ]
  [ "$(event_field login_stalled level)" == "warn" ]
  [ "$(event_field login_stalled msg)" == "phase has been login for 301 s; a window that IBC does not handle may be blocking the login (see ibc/ibc.log)" ]
  observe 1500 phase=logged-in
  observe 1530 phase=logged-in
  [ "$(events)" == "login_stalled login_resumed " ]
  [ "$(event_field login_resumed level)" == "info" ]
  [ "$(event_field login_resumed msg)" == "phase left login after 500 s (now logged-in)" ]
}

@test "any other phase in between restarts the login clock" {
  observe 1000 phase=login
  observe 1200 phase=2fa-pending
  observe 1250 phase=login
  observe 1450 phase=login
  [ "$(events)" == "" ]
  observe 1551 phase=login
  [ "$(events)" == "login_stalled " ]
  [ "$(event_field login_stalled msg)" == "phase has been login for 301 s; a window that IBC does not handle may be blocking the login (see ibc/ibc.log)" ]
}

@test "a login that completes in time fires nothing" {
  observe 1000 phase=login
  observe 1100 phase=logged-in
  [ "$(events)" == "" ]
}

@test "a second stall after a resumed login is reported again" {
  LOGIN_STALL_S=60
  observe 1000 phase=login
  observe 1061 phase=login
  observe 1100 phase=restarting
  observe 1200 phase=login
  observe 1260 phase=login
  [ "$(events)" == "login_stalled login_resumed " ]
  observe 1261 phase=login
  [ "$(events)" == "login_stalled login_resumed login_stalled " ]
}

# --- memory_high / memory_ok ----------------------------------------------------------------

@test "memory_high fires once after MEM_HIGH_FOR_S above MEM_HIGH_PCT and memory_ok when it clears" {
  observe 1000 mem_working_set_bytes=1800000 mem_limit_bytes=2000000
  observe 1599 mem_working_set_bytes=1800000 mem_limit_bytes=2000000
  [ "$(events)" == "" ]
  observe 1600 mem_working_set_bytes=1900000 mem_limit_bytes=2000000
  observe 1700 mem_working_set_bytes=1900000 mem_limit_bytes=2000000
  [ "$(events)" == "memory_high " ]
  [ "$(event_field memory_high level)" == "warn" ]
  [ "$(event_field memory_high msg)" == "working set 1900000 bytes is 95% of the 2000000-byte limit, above MEM_HIGH_PCT=85 for 600 s" ]
  observe 1800 mem_working_set_bytes=1000000 mem_limit_bytes=2000000
  observe 1830 mem_working_set_bytes=1000000 mem_limit_bytes=2000000
  [ "$(events)" == "memory_high memory_ok " ]
  [ "$(event_field memory_ok level)" == "info" ]
  [ "$(event_field memory_ok msg)" == "working set 1000000 bytes is 50% of the 2000000-byte limit, no longer above MEM_HIGH_PCT=85" ]
}

@test "a dip below the threshold restarts the memory clock" {
  observe 1000 mem_working_set_bytes=1800000 mem_limit_bytes=2000000
  observe 1300 mem_working_set_bytes=1000000 mem_limit_bytes=2000000
  observe 1400 mem_working_set_bytes=1800000 mem_limit_bytes=2000000
  observe 1900 mem_working_set_bytes=1800000 mem_limit_bytes=2000000
  [ "$(events)" == "" ]
  observe 2000 mem_working_set_bytes=1800000 mem_limit_bytes=2000000
  [ "$(events)" == "memory_high " ]
}

@test "a sample without memory figures restarts the memory clock" {
  observe 1000 mem_working_set_bytes=1800000 mem_limit_bytes=2000000
  observe 1300
  observe 1400 mem_working_set_bytes=1800000 mem_limit_bytes=2000000
  observe 1900 mem_working_set_bytes=1800000 mem_limit_bytes=2000000
  [ "$(events)" == "" ]
  observe 2000 mem_working_set_bytes=1800000 mem_limit_bytes=2000000
  [ "$(events)" == "memory_high " ]
}

@test "a sample without memory figures neither clears nor repeats memory_high" {
  MEM_HIGH_FOR_S=0
  observe 1000 mem_working_set_bytes=1800000 mem_limit_bytes=2000000
  observe 1030
  observe 1060 mem_working_set_bytes=1800000 mem_limit_bytes=2000000
  [ "$(events)" == "memory_high " ]
  observe 1090 mem_working_set_bytes=1000000 mem_limit_bytes=2000000
  [ "$(events)" == "memory_high memory_ok " ]
}

@test "without a memory limit memory_high never fires" {
  observe 1000 mem_working_set_bytes=1800000
  observe 9000 mem_working_set_bytes=1800000
  [ "$(events)" == "" ]
}

@test "a working set of exactly MEM_HIGH_PCT is not high" {
  observe 1000 mem_working_set_bytes=1700000 mem_limit_bytes=2000000
  observe 9000 mem_working_set_bytes=1700000 mem_limit_bytes=2000000
  [ "$(events)" == "" ]
}

@test "MEM_HIGH_PCT and MEM_HIGH_FOR_S move the threshold and the duration" {
  MEM_HIGH_PCT=50 MEM_HIGH_FOR_S=60
  observe 1000 mem_working_set_bytes=1100000 mem_limit_bytes=2000000
  observe 1060 mem_working_set_bytes=1100000 mem_limit_bytes=2000000
  [ "$(events)" == "memory_high " ]
  [ "$(event_field memory_high msg)" == "working set 1100000 bytes is 55% of the 2000000-byte limit, above MEM_HIGH_PCT=50 for 60 s" ]
}

# --- the tick: sample, file and events together ---------------------------------------------

@test "a tick turns what it sampled into events, on stdout and in events.jsonl alike" {
  sampler_tick >"${WORK}/stdout"
  [ "$(events)" == "oom_kill " ]
  [ "$(event_field oom_kill boot_id)" == "0123456789abcdef" ]
  cmp "${WORK}/stdout" "${EVENTS}"
  printf 'low 0\nhigh 0\nmax 5\noom 7\noom_kill 3\noom_group_kill 9\n' >"${CGROUP_ROOT}/memory.events"
  sampler_tick >/dev/null
  sampler_tick >/dev/null
  [ "$(events)" == "oom_kill oom_kill " ]
}

@test "ticks follow the phase file: a login that stays stuck is reported with the injected clock" {
  printf 'low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\noom_group_kill 0\n' >"${CGROUP_ROOT}/memory.events"
  printf 'login\n' >"${LOG_DIR}/state/phase"
  SAMPLER_NOW=5000 sampler_tick >/dev/null
  SAMPLER_NOW=5300 sampler_tick >/dev/null
  [ "$(events)" == "" ]
  SAMPLER_NOW=5330 sampler_tick >/dev/null
  [ "$(events)" == "login_stalled " ]
  printf 'logged-in\n' >"${LOG_DIR}/state/phase"
  SAMPLER_NOW=5360 sampler_tick >/dev/null
  [ "$(events)" == "login_stalled login_resumed " ]
  [ "$(jq -r .phase "${METRICS}" | tr '\n' ' ')" == "login login login logged-in " ]
}

# --- the loop -------------------------------------------------------------------------------

@test "the loop writes a sample every SAMPLE_INTERVAL_S and stops within 2 s of SIGTERM" {
  export SAMPLE_INTERVAL_S=1
  start_sampler
  wait_until 20 bash -c "[ \"\$(wc -l <'${METRICS}')\" -ge 2 ]"
  stop_sampler
  [ "${STOP_STATUS}" -eq 0 ]
  [ "${STOP_MS}" -le 2000 ]
  [ "$(jq -r .seq "${METRICS}" | head -2 | tr '\n' ' ')" == "1 2 " ]
  jq -e '.boot_id == "0123456789abcdef" and .mem_working_set_bytes == 750000' "${METRICS}" >/dev/null
}

@test "SIGTERM interrupts the pause between samples and leaves no sleep behind" {
  export SAMPLE_INTERVAL_S=47
  start_sampler
  wait_until 20 pgrep -P "${SAMPLER_PID}" -x sleep
  [ "$(metrics_lines)" -eq 1 ]
  stop_sampler
  [ "${STOP_STATUS}" -eq 0 ]
  [ "${STOP_MS}" -le 2000 ]
  run pgrep -f '^sleep 47$'
  [ "$status" -eq 1 ]
}

@test "an invalid SAMPLE_INTERVAL_S falls back to 30 s instead of spinning" {
  export SAMPLE_INTERVAL_S=0
  start_sampler
  wait_until 20 pgrep -P "${SAMPLER_PID}" -x sleep
  pgrep -P "${SAMPLER_PID}" -f '^sleep 30$' >/dev/null
  [ "$(metrics_lines)" -eq 1 ]
}

# --- the last sample: what a stop request leaves behind -------------------------------------

@test "SIGTERM during the pause gives one last sample that continues seq, then exit 0 within 2 s" {
  export SAMPLE_INTERVAL_S=47
  start_sampler
  wait_for_pause
  [ "$(metrics_lines)" -eq 1 ]
  stop_sampler
  [ "${STOP_STATUS}" -eq 0 ]
  [ "${STOP_MS}" -le 2000 ]
  jq -e . "${METRICS}" >/dev/null
  [ "$(jq -r .seq "${METRICS}" | tr '\n' ' ')" == "1 2 " ]
}

@test "the last sample has every figure except the disk figures" {
  export SAMPLE_INTERVAL_S=47
  start_sampler
  wait_for_pause
  stop_sampler
  head -1 "${METRICS}" | jq -e 'has("disk_free_bytes_logs") and has("disk_total_bytes_settings")' >/dev/null
  [ "$(tail -1 "${METRICS}" | jq -c 'del(.ts)')" == '{"src":"metrics","boot_id":"0123456789abcdef","seq":2,"phase":"logged-in","mem_working_set_bytes":750000,"mem_limit_bytes":2000000,"oom_kills":2,"cpu_usage_usec":47930,"cpu_throttled_usec":1234,"pids":57,"java_rss_bytes":524288000,"java_threads":63,"open_fds":5,"api_close_wait_sockets":3}' ]
}

@test "the last sample never runs df, so a mount that hangs cannot delay the stop" {
  fake_df 0
  export SAMPLE_INTERVAL_S=47
  start_sampler
  wait_for_pause
  [ "$(df_calls)" -eq 2 ]
  stop_sampler
  [ "${STOP_STATUS}" -eq 0 ]
  [ "$(metrics_lines)" -eq 2 ]
  [ "$(df_calls)" -eq 2 ]
}

@test "an OOM kill the loop has not sampled yet is reported by the last sample" {
  set_oom_kills 0
  export SAMPLE_INTERVAL_S=47
  start_sampler
  wait_for_pause
  [ "$(events)" == "" ]
  set_oom_kills 1
  stop_sampler
  [ "${STOP_STATUS}" -eq 0 ]
  [ "${STOP_MS}" -le 5000 ]
  [ "$(events)" == "oom_kill " ]
  [ "$(event_field oom_kill level)" == "error" ]
  [ "$(event_field oom_kill msg)" == "1 OOM kill(s) in this container since the previous sample (1 since container start); memory limit 2000000 bytes" ]
  [ "$(jq -r .oom_kills "${METRICS}" | tr '\n' ' ')" == "0 1 " ]
}

@test "the last sample reports kills since container start when no sample could count them before" {
  rm "${CGROUP_ROOT}/memory.events"
  export SAMPLE_INTERVAL_S=47
  start_sampler
  wait_for_pause
  set_oom_kills 2
  stop_sampler
  [ "${STOP_STATUS}" -eq 0 ]
  [ "$(events)" == "oom_kill " ]
  [ "$(event_field oom_kill msg)" == "2 OOM kill(s) in this container since container start; memory limit 2000000 bytes" ]
}

@test "two SIGTERMs in a row give one last sample, not two" {
  export SAMPLE_INTERVAL_S=47
  start_sampler
  wait_for_pause
  kill -TERM "${SAMPLER_PID}"
  stop_sampler
  [ "${STOP_STATUS}" -eq 0 ]
  [ "$(jq -r .seq "${METRICS}" | tr '\n' ' ')" == "1 2 " ]
  [ "$(events)" == "oom_kill " ]
}

@test "SIGTERM during a sample lets that sample finish, then takes the last one: none is entered twice" {
  fake_df 1
  export SAMPLE_INTERVAL_S=47
  start_sampler
  wait_until 20 pgrep -f "${WORK}/bin/df"
  [ ! -e "${METRICS}" ]
  stop_sampler
  [ "${STOP_STATUS}" -eq 0 ]
  [ "${STOP_MS}" -le 5000 ]
  jq -e . "${METRICS}" >/dev/null
  [ "$(jq -r .seq "${METRICS}" | tr '\n' ' ')" == "1 2 " ]
  [ "$(jq -c 'has("disk_free_bytes_logs")' "${METRICS}" | tr '\n' ' ')" == "true false " ]
  [ "$(events)" == "oom_kill " ]
  [ "$(df_calls)" -eq 2 ]
}

# --- the real kernel interfaces of the image ------------------------------------------------

@test "against the real cgroup and /proc a sample is well-formed and has plausible positive numbers" {
  if [ ! -r /sys/fs/cgroup/memory.current ]; then skip "no cgroup v2 memory controller here"; fi
  unset CGROUP_ROOT PROC_ROOT
  SAMPLER_JAVA_PID="$$"
  run sample_once
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  jq -e '
    (keys - ["ts","src","boot_id","seq","phase","mem_working_set_bytes","mem_limit_bytes","oom_kills","cpu_usage_usec","cpu_throttled_usec","pids","java_rss_bytes","java_threads","open_fds","api_close_wait_sockets","disk_free_bytes_logs","disk_free_bytes_settings","disk_total_bytes_logs","disk_total_bytes_settings"]) == []
    and ([to_entries[] | select(.key | IN("ts","src","boot_id","phase") | not) | .value | (type == "number" and . >= 0 and . == floor)] | all)
    and .src == "metrics" and .seq == 1 and .phase == "logged-in"
    and .mem_working_set_bytes > 0 and .pids >= 1 and .cpu_usage_usec > 0 and .oom_kills >= 0
    and .java_rss_bytes >= 1048576 and .java_threads >= 1 and .open_fds >= 3
    and .api_close_wait_sockets == 0
    and .disk_free_bytes_logs > 0 and .disk_total_bytes_logs >= .disk_free_bytes_logs' <<<"${output}" >/dev/null
}

@test "the JVM is found by its process name and read from the real /proc" {
  unset PROC_ROOT SAMPLER_JAVA_PID
  run sample_once
  lacks java_rss_bytes java_threads open_fds
  start_fake_jvm
  run sample_once
  jq -e '.java_rss_bytes > 0 and .java_threads == 1 and .open_fds >= 3' <<<"${output}" >/dev/null
}

@test "SAMPLER_JAVA_PID set to nothing means no JVM, whatever is running" {
  unset PROC_ROOT
  start_fake_jvm
  SAMPLER_JAVA_PID=""
  run sample_once
  lacks java_rss_bytes java_threads open_fds
}
