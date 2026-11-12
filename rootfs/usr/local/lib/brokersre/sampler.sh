#!/usr/bin/env bash
# In-container resource sampler: every SAMPLE_INTERVAL_S one JSON line of resource figures in
# ${LOG_DIR}/metrics/metrics.jsonl, and an event when a figure explains an outage.
#
# Purpose: when a gateway goes away, the IBC and Gateway logs rarely say why. The kernel's OOM
# killer, a volume that filled up and a login hidden behind a window nobody sees leave no line
# there. This script reads the container's own cgroup v2 files and /proc (no docker.sock, no
# extra package, no privilege), so the reason is on the shared log volume and in `docker logs`.
#
# Usage:
#   sampler.sh           run the loop until SIGTERM or SIGINT, then exit 0 (the entrypoint starts
#                        it in the background)
#   source sampler.sh    define the functions only; nothing runs (the unit tests do this)
#
# Contract:
#   - every sample is one line appended to ${LOG_DIR}/metrics/metrics.jsonl, keys in this order:
#       always:        ts, src ("metrics"), boot_id, seq, phase
#       when measured: mem_working_set_bytes, mem_limit_bytes, oom_kills, cpu_usage_usec,
#                      cpu_throttled_usec, pids, java_rss_bytes, java_threads, open_fds,
#                      api_close_wait_sockets, disk_free_bytes_logs, disk_free_bytes_settings,
#                      disk_total_bytes_logs, disk_total_bytes_settings
#   - ABSENCE IS NEVER ZERO: a figure whose source is missing, unreadable or not a number is
#     left out of the line. A reader can tell "no socket in CLOSE_WAIT" (0) from "could not
#     look" (no key), and "no memory limit" is no key, not a limit of 0;
#   - seq starts at 1 when the sampler starts and counts every sample taken, written or not, so
#     a gap in seq is a sample that could not be written;
#   - the file is rotated by size like the other logs (LOG_MAX_BYTES, LOG_KEEP), between two
#     lines, by this process alone (it is the only writer);
#   - stdout carries only events (log.sh), never a sample; expected failures print nothing;
#   - events are edge-triggered, one when a condition starts and one when it ends:
#       oom_kill (error)                         the cgroup's OOM-kill counter rose
#       disk_low (warn) / disk_ok (info)         free space of a volume below DISK_MIN_FREE_PCT
#       login_stalled (warn) / login_resumed (info)   phase `login` for more than LOGIN_STALL_S
#       memory_high (warn) / memory_ok (info)    working set above MEM_HIGH_PCT of the limit
#                                                for MEM_HIGH_FOR_S
#     event messages hold numbers, paths and the phase token only;
#   - a missing source, an unwritable volume or a vanished JVM never ends the loop, and nothing
#     here restarts or signals the Gateway: the sampler reports, a human acts.
#
# Environment (an invalid value means the default):
#   SAMPLE_INTERVAL_S   seconds between samples (default 30, at least 1)
#   DISK_MIN_FREE_PCT   disk_low threshold in percent of the volume (default 10; 0 = never)
#   LOGIN_STALL_S       seconds of phase `login` before login_stalled (default 300)
#   MEM_HIGH_PCT        memory_high threshold in percent of the limit (default 85)
#   MEM_HIGH_FOR_S      seconds above the threshold before memory_high (default 600)
#   LOG_MAX_BYTES, LOG_KEEP   rotation of metrics.jsonl (defaults 10485760 and 3)
#   LOG_DIR, TWS_SETTINGS_PATH, BOOT_ID, API_PORT, TRADING_MODE   as set by the image and the
#                       entrypoint
# Test hooks: CGROUP_ROOT (default /sys/fs/cgroup), PROC_ROOT (default /proc),
#   SAMPLER_JAVA_PID (the JVM's pid; set but empty = no JVM), SAMPLER_NOW (epoch seconds used
#   instead of the clock for the two durations).
#
# Side effects of sourcing: LOG_DIR and TWS_SETTINGS_PATH get the image's defaults when they are
# unset, and the sampler's state variables (SAMPLER_*) are initialised.
#
# NOTE: the figures are read when a sample is taken, so a kill that ends the container before
# the next sample is not reported. That is the usual case when the OOM killer takes the Gateway
# JVM: IBC exits, the entrypoint exits and the cgroup with its counter is gone.
# NOTE: every figure is read in a child process. When the container's process limit is used up
# no sample can be taken until a process slot is free again (the samples before show `pids`
# climbing).
# PERF: measured in the image on 2026-11-12: about 27 ms of CPU per sample (some 25 short-lived
# child processes; no tool beyond coreutils and procps), which is about 0.1% of one core at the
# default interval.

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/log.sh"

: "${LOG_DIR:=/var/log/ibgateway}" "${TWS_SETTINGS_PATH:=/home/ibgateway/Jts/settings}"

# is_uint VALUE: true when VALUE is an unsigned decimal integer of at most 18 digits.
#
# Why 18 digits: such a number fits bash's signed 64-bit arithmetic with room to spare, so no
# figure read from a file can overflow or be taken for an octal or negative number later.
is_uint() {
  [[ "$1" =~ ^[0-9]{1,18}$ ]]
}

# uint_or VALUE DEFAULT [MAX]: set REPLY to VALUE in base 10 when VALUE is an unsigned integer
# (and not above MAX when MAX is given), otherwise to DEFAULT.
#
# Used for every setting, so a typo in the environment gives the documented default instead of
# an arithmetic error. Returns its result in REPLY (not on stdout) to avoid a child process.
uint_or() {
  REPLY="$2"
  if is_uint "$1" && { [ -z "${3:-}" ] || [ "$((10#$1))" -le "$3" ]; }; then
    REPLY="$((10#$1))"
  fi
}

# emit_uint VALUE: print VALUE in base 10 followed by a newline when it is an unsigned integer;
# print nothing otherwise. This is the single place where "not a number" becomes "no key".
emit_uint() {
  if is_uint "$1"; then printf '%s\n' "$((10#$1))"; fi
}

# first_line FILE: set REPLY to the first line of FILE, or to the empty string when FILE is
# missing or unreadable. Never fails and never prints (a single-value cgroup file, a state file).
first_line() {
  REPLY=""
  if [ -f "$1" ] && [ -r "$1" ]; then
    IFS= read -r REPLY 2>/dev/null <"$1" || true
  fi
}

# keyed_value FILE KEY: set REPLY to the second field of the first line of FILE whose first
# field is exactly KEY, or to the empty string when there is no such line or FILE cannot be read.
#
# Covers the kernel's flat keyed files: "oom_kill 2" in memory.events, "inactive_file 4096" in
# memory.stat, "VmRSS:   7524 kB" in /proc/<pid>/status (there KEY includes the colon). The key
# is compared whole, so oom_kill never matches oom_group_kill. Never fails and never prints.
keyed_value() {
  local file="$1" key="$2" name value
  local IFS=$' \t\n'
  REPLY=""
  if [ -f "${file}" ] && [ -r "${file}" ]; then
    while read -r name value _; do
      if [ "${name}" = "${key}" ]; then
        REPLY="${value}"
        break
      fi
    done 2>/dev/null <"${file}"
  fi
  return 0
}

# read_mem_working_set: print the container's working-set memory in bytes, or nothing.
#
# Working set = memory.current - inactive_file (memory.stat), floored at 0: the kubelet's
# definition, i.e. the memory the kernel cannot simply drop before it has to kill. Page cache
# that was read once (log files) is inactive_file and would otherwise look like a leak. Both
# figures are required; without inactive_file nothing is printed rather than a wrong number.
read_mem_working_set() {
  local root="${CGROUP_ROOT:-/sys/fs/cgroup}" current inactive working_set
  first_line "${root}/memory.current"
  current="${REPLY}"
  keyed_value "${root}/memory.stat" inactive_file
  inactive="${REPLY}"
  if is_uint "${current}" && is_uint "${inactive}"; then
    working_set=$((10#${current} - 10#${inactive}))
    if [ "${working_set}" -lt 0 ]; then working_set=0; fi
    printf '%s\n' "${working_set}"
  fi
}

# read_mem_limit: print the cgroup's memory limit in bytes (memory.max), or nothing when the
# file holds the literal `max` (no limit) or cannot be read.
read_mem_limit() {
  first_line "${CGROUP_ROOT:-/sys/fs/cgroup}/memory.max"
  emit_uint "${REPLY}"
}

# read_oom_kills: print how many processes of this cgroup the kernel's OOM killer has killed
# since the cgroup was created (the oom_kill line of memory.events), or nothing.
read_oom_kills() {
  keyed_value "${CGROUP_ROOT:-/sys/fs/cgroup}/memory.events" oom_kill
  emit_uint "${REPLY}"
}

# read_cpu_usage_usec: print the CPU time the cgroup has used, in microseconds (usage_usec of
# cpu.stat, a counter since the cgroup was created), or nothing.
read_cpu_usage_usec() {
  keyed_value "${CGROUP_ROOT:-/sys/fs/cgroup}/cpu.stat" usage_usec
  emit_uint "${REPLY}"
}

# read_cpu_throttled_usec: print the time the cgroup was throttled by its CPU quota, in
# microseconds (throttled_usec of cpu.stat, a counter), or nothing; the line exists only when
# the cpu controller is enabled for the cgroup.
read_cpu_throttled_usec() {
  keyed_value "${CGROUP_ROOT:-/sys/fs/cgroup}/cpu.stat" throttled_usec
  emit_uint "${REPLY}"
}

# read_pids: print the number of processes and threads in the cgroup (pids.current), or nothing.
read_pids() {
  first_line "${CGROUP_ROOT:-/sys/fs/cgroup}/pids.current"
  emit_uint "${REPLY}"
}

# find_java_pid: print the pid of the Gateway JVM, or nothing when there is none.
#
# The JVM is the first process named exactly `java` (pgrep -x; IBC starts the Gateway with the
# JRE's `java` binary and the container runs one Gateway). SAMPLER_JAVA_PID, when set, replaces
# the lookup (tests); set to the empty string it means "no JVM".
find_java_pid() {
  local pid=""
  if [ -n "${SAMPLER_JAVA_PID+set}" ]; then
    pid="${SAMPLER_JAVA_PID}"
  else
    pid="$(pgrep -x java 2>/dev/null)" || pid=""
    pid="${pid%%$'\n'*}"
  fi
  emit_uint "${pid}"
}

# read_java_rss_bytes PID: print the resident set size of process PID in bytes (VmRSS of
# /proc/PID/status, which the kernel gives in kB), or nothing when the process is gone.
read_java_rss_bytes() {
  keyed_value "${PROC_ROOT:-/proc}/$1/status" "VmRSS:"
  if is_uint "${REPLY}"; then printf '%s\n' "$((10#${REPLY} * 1024))"; fi
}

# read_java_threads PID: print the number of threads of process PID (Threads of
# /proc/PID/status), or nothing when the process is gone.
read_java_threads() {
  keyed_value "${PROC_ROOT:-/proc}/$1/status" "Threads:"
  emit_uint "${REPLY}"
}

# read_open_fds PID: print the number of open file descriptors of process PID (the entries of
# /proc/PID/fd), or nothing when the directory cannot be listed.
#
# Why the checks: an unreadable or vanished directory lists as "no entries", which must not be
# reported as 0 descriptors. A count of 0 is printed only for a directory that could be listed
# and still exists afterwards. The entries are symbolic links (to sockets and pipes that are
# not files), hence the -L test.
read_open_fds() {
  local dir="${PROC_ROOT:-/proc}/$1/fd"
  local -a entries=()
  if [ -n "$1" ] && [ -d "${dir}" ] && [ -r "${dir}" ] && [ -x "${dir}" ]; then
    entries=("${dir}"/*)
    if [ -e "${entries[0]}" ] || [ -L "${entries[0]}" ]; then
      printf '%s\n' "${#entries[@]}"
    elif [ -d "${dir}" ]; then
      printf '0\n'
    fi
  fi
}

# api_port: set REPLY to the port the Gateway's API listens on, or to the empty string when it
# is not known. API_PORT (exported by the entrypoint) wins when it is a valid port; otherwise
# TRADING_MODE decides (paper 4002, live 4001).
api_port() {
  REPLY=""
  if is_uint "${API_PORT:-}" && [ "$((10#${API_PORT}))" -ge 1 ] && [ "$((10#${API_PORT}))" -le 65535 ]; then
    REPLY="$((10#${API_PORT}))"
    return 0
  fi
  case "${TRADING_MODE:-}" in
    paper) REPLY=4002 ;;
    live) REPLY=4001 ;;
  esac
  return 0
}

# read_api_close_wait: print the number of TCP sockets in state CLOSE_WAIT whose LOCAL port is
# the API port, IPv4 and IPv6 together, or nothing when it cannot be determined.
#
# Why: CLOSE_WAIT means the API client has closed its end and the Gateway has not closed its
# own. A number that keeps growing is the Gateway leaking client connections, which ends in
# refused API connections long before anything is logged.
# Source: /proc/net/tcp and /proc/net/tcp6, one row per socket: "sl local_address rem_address
# st ...", local_address = HEXIP:HEXPORT, st = two hex digits (08 = CLOSE_WAIT). The Gateway's
# listener is usually a dual-stack IPv6 socket, so its connections are in tcp6.
# Nothing is printed when the port is unknown, when tcp cannot be read, or when tcp6 exists but
# cannot be read; a missing tcp6 (IPv6 switched off) is not an error.
# Each table is read in one pass (mapfile): /proc regenerates a table from its start on every
# seek, so a line-by-line `read` would cost quadratic time on a host with many sockets.
read_api_close_wait() {
  local proc="${PROC_ROOT:-/proc}" want file row count=0
  local row_pattern='^[[:space:]]*[0-9]+:[[:space:]]+[0-9A-Fa-f]+:([0-9A-Fa-f]{4})[[:space:]]+[0-9A-Fa-f]+:[0-9A-Fa-f]{4}[[:space:]]+([0-9A-Fa-f]{2})[[:space:]]'
  local -a rows=()
  api_port
  if [ -z "${REPLY}" ]; then return 0; fi
  printf -v want '%04X' "${REPLY}"
  if [ ! -f "${proc}/net/tcp" ] || [ ! -r "${proc}/net/tcp" ]; then return 0; fi
  if [ -e "${proc}/net/tcp6" ] && [ ! -r "${proc}/net/tcp6" ]; then return 0; fi
  for file in "${proc}/net/tcp" "${proc}/net/tcp6"; do
    if [ -f "${file}" ]; then
      rows=()
      mapfile -t rows 2>/dev/null <"${file}" || true
      for row in "${rows[@]}"; do
        if [[ "${row}" =~ ${row_pattern} ]] && [ "${BASH_REMATCH[2]}" = "08" ] && [ "${BASH_REMATCH[1]^^}" = "${want}" ]; then
          count=$((count + 1))
        fi
      done
    fi
  done
  printf '%s\n' "${count}"
}

# read_disk DIRECTORY: print "<free bytes> <total bytes>" of the filesystem that holds
# DIRECTORY, or nothing when df cannot report it.
#
# Free is df's "Available" column: what this unprivileged user can still write, which is what
# matters for the log and settings volumes. df runs under `timeout` so a mount that hangs
# (a network share behind a bind mount) costs five seconds, not the sampler. The figures are
# taken from the numeric columns before the capacity percentage, so a filesystem name with
# spaces (a Windows path) cannot shift them.
read_disk() {
  local directory="$1" out total free
  local columns='[[:space:]]([0-9]{1,15})[[:space:]]+[0-9]+[[:space:]]+([0-9]{1,15})[[:space:]]+[0-9]+%[[:space:]]'
  if [ -z "${directory}" ]; then return 0; fi
  out="$(timeout -k 2 5 df -P -k -- "${directory}" 2>/dev/null)" || return 0
  if [[ "${out##*$'\n'}" =~ ${columns} ]]; then
    total="${BASH_REMATCH[1]}"
    free="${BASH_REMATCH[2]}"
    printf '%s %s\n' "$((10#${free} * 1024))" "$((10#${total} * 1024))"
  fi
}

# read_phase: print the gateway's lifecycle phase from ${LOG_DIR}/state/phase, or `unknown`.
#
# The file holds one token written by the entrypoint and the IBC classifier. Anything that is
# not a single plain token (missing file, empty, other characters) is `unknown`, never a
# healthy-looking value, and it cannot break the JSON line.
read_phase() {
  first_line "${LOG_DIR}/state/phase"
  if [[ "${REPLY}" =~ ^[A-Za-z0-9_-]{1,32}$ ]]; then
    printf '%s\n' "${REPLY}"
  else
    printf 'unknown\n'
  fi
}

# read_boot_id: print the container's boot id: BOOT_ID from the environment, else the content
# of ${LOG_DIR}/state/boot_id, else `unknown` (the key is always present in a sample). The same
# rule as log_event, so samples and events of one start carry the same id.
read_boot_id() {
  local boot="${BOOT_ID:-}"
  if [ -z "${boot}" ]; then
    first_line "${LOG_DIR}/state/boot_id"
    boot="${REPLY}"
  fi
  if [[ "${boot}" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
    printf '%s\n' "${boot}"
  else
    printf 'unknown\n'
  fi
}

# json_add VARIABLE KEY VALUE: append `,"KEY":VALUE` to the string variable named VARIABLE when
# VALUE is not empty; do nothing otherwise. VALUE is a number that a read_* function printed.
# This is how an unmeasured figure stays out of the sample.
json_add() {
  local -n json_target="$1"
  if [ -n "$3" ]; then json_target+=",\"$2\":$3"; fi
}

# sample_once: print one sample as a JSON line (the format in the header of this file).
#
# Inputs: SAMPLER_SEQ (samples taken so far; the line carries SAMPLER_SEQ + 1), the sources
# under CGROUP_ROOT and PROC_ROOT, LOG_DIR, TWS_SETTINGS_PATH and the variables the read_*
# functions use. Output: exactly one line on stdout and status 0. Changes nothing, so it can
# run in a command substitution; the caller (sampler_tick) advances SAMPLER_SEQ.
# Every value comes from a child process (command substitution). When the container's process
# limit is used up those children cannot start and the values come back empty: an optional key
# is then simply left out, but a line without its fixed keys would be worse than no line, so
# nothing is printed and the status is 1.
sample_once() {
  local line ts boot phase java_pid disk_logs disk_settings
  ts="$(ts_now)" || ts=""
  boot="$(read_boot_id)" || boot=""
  phase="$(read_phase)" || phase=""
  if [ -z "${ts}" ] || [ -z "${boot}" ] || [ -z "${phase}" ]; then return 1; fi
  line="{\"ts\":\"${ts}\",\"src\":\"metrics\",\"boot_id\":\"${boot}\""
  line+=",\"seq\":$((${SAMPLER_SEQ:-0} + 1)),\"phase\":\"${phase}\""
  json_add line mem_working_set_bytes "$(read_mem_working_set)"
  json_add line mem_limit_bytes "$(read_mem_limit)"
  json_add line oom_kills "$(read_oom_kills)"
  json_add line cpu_usage_usec "$(read_cpu_usage_usec)"
  json_add line cpu_throttled_usec "$(read_cpu_throttled_usec)"
  json_add line pids "$(read_pids)"
  java_pid="$(find_java_pid)"
  if [ -n "${java_pid}" ]; then
    json_add line java_rss_bytes "$(read_java_rss_bytes "${java_pid}")"
    json_add line java_threads "$(read_java_threads "${java_pid}")"
    json_add line open_fds "$(read_open_fds "${java_pid}")"
  fi
  json_add line api_close_wait_sockets "$(read_api_close_wait)"
  disk_logs="$(read_disk "${LOG_DIR}")"
  disk_settings="$(read_disk "${TWS_SETTINGS_PATH}")"
  json_add line disk_free_bytes_logs "${disk_logs% *}"
  json_add line disk_free_bytes_settings "${disk_settings% *}"
  json_add line disk_total_bytes_logs "${disk_logs#* }"
  json_add line disk_total_bytes_settings "${disk_settings#* }"
  printf '%s}\n' "${line}"
}

# append_sample FILE LINE: append LINE and a newline to FILE, rotating FILE by size first.
#
# Contract: before LINE would take FILE past LOG_MAX_BYTES (default 10485760) FILE is renamed to
# FILE.1, older generations shift to .2, .3, ... and only LOG_KEEP (default 3) are kept; with
# LOG_KEEP=0 FILE is removed instead. A line longer than the cap is written whole. Returns 0
# when the line was written and 1 when the directory or the file cannot be written; it prints
# nothing either way. The same rule as rotating-append.sh and log.sh; done in this process
# because the sampler is the only writer of FILE, so no lock is needed.
append_sample() {
  local file="$1" line="$2" max keep size=0 i
  uint_or "${LOG_MAX_BYTES:-}" 10485760
  max="${REPLY}"
  if [ "${max}" -lt 1 ]; then max=10485760; fi
  uint_or "${LOG_KEEP:-}" 3
  keep="${REPLY}"
  mkdir -p "${file%/*}" 2>/dev/null || return 1
  if [ -f "${file}" ]; then size="$(stat -c %s "${file}" 2>/dev/null)" || size=0; fi
  if ! is_uint "${size}"; then size=0; fi
  if [ "${size}" -gt 0 ] && [ $((size + ${#line} + 1)) -gt "${max}" ]; then
    if [ "${keep}" -eq 0 ]; then
      rm -f "${file}" 2>/dev/null || return 1
    else
      rm -f "${file}.${keep}" 2>/dev/null || return 1
      for ((i = keep - 1; i >= 1; i--)); do
        if [ -f "${file}.${i}" ]; then mv -f "${file}.${i}" "${file}.$((i + 1))" 2>/dev/null || return 1; fi
      done
      mv -f "${file}" "${file}.1" 2>/dev/null || return 1
    fi
  fi
  { printf '%s\n' "${line}" >>"${file}"; } 2>/dev/null || return 1
}

# sampler_init_state: reset everything the sampler remembers between two samples.
#
#   SAMPLER_SEQ                 samples taken since the sampler started
#   SAMPLER_OOM_KILLS           last measured oom_kills (empty: none measured yet)
#   SAMPLER_DISK_LOW[label]     1 while disk_low is open for `logs` or `settings`
#   SAMPLER_LOGIN_SINCE         epoch seconds when the current run of phase `login` was first
#                               seen (empty: the phase is not login)
#   SAMPLER_LOGIN_STALLED       1 after login_stalled, until the phase leaves login
#   SAMPLER_MEM_HIGH_SINCE      epoch seconds when the working set was first seen above the
#                               threshold in the current run (empty: it is not above)
#   SAMPLER_MEM_HIGH_REPORTED   1 after memory_high, until memory_ok
#   SAMPLER_SLEEP_PID           pid of the pause between two samples (empty: not pausing)
# Called when this file is sourced and again by sampler_main, so the functions never meet an
# unset variable under `set -u`.
sampler_init_state() {
  SAMPLER_SEQ=0
  SAMPLER_OOM_KILLS=""
  declare -gA SAMPLER_DISK_LOW=()
  SAMPLER_LOGIN_SINCE=""
  SAMPLER_LOGIN_STALLED=0
  SAMPLER_MEM_HIGH_SINCE=""
  SAMPLER_MEM_HIGH_REPORTED=0
  SAMPLER_SLEEP_PID=""
}

# sample_number LINE KEY: set REPLY to the integer value of KEY in the sample LINE, or to the
# empty string when LINE has no such key. The key is matched with its quotes and colon, so one
# key never matches inside another.
sample_number() {
  local pattern="\"$2\":([0-9]{1,18})[,}]"
  REPLY=""
  if [[ "$1" =~ ${pattern} ]]; then REPLY="${BASH_REMATCH[1]}"; fi
}

# evaluate_oom KILLS LIMIT: emit oom_kill (error) when the OOM-kill counter rose.
#
# KILLS is the sample's oom_kills, LIMIT its mem_limit_bytes; either may be empty. The first
# measured count above zero is reported as "since container start" (the counter is as old as
# the container's cgroup, so those kills happened before the sampler looked); later a rise is
# reported with the difference. An empty KILLS changes nothing: the last measured count stays
# the basis, so a sample that could not be read never hides or invents a kill.
evaluate_oom() {
  local kills="$1" limit="$2" limit_text="memory limit unlimited or not measured"
  if [ -z "${kills}" ]; then return 0; fi
  if [ -n "${limit}" ]; then limit_text="memory limit ${limit} bytes"; fi
  if [ -z "${SAMPLER_OOM_KILLS}" ]; then
    if [ "${kills}" -gt 0 ]; then
      log_event metrics error oom_kill "${kills} OOM kill(s) in this container since container start; ${limit_text}"
    fi
  elif [ "${kills}" -gt "${SAMPLER_OOM_KILLS}" ]; then
    log_event metrics error oom_kill "$((kills - SAMPLER_OOM_KILLS)) OOM kill(s) in this container since the previous sample (${kills} since container start); ${limit_text}"
  fi
  SAMPLER_OOM_KILLS="${kills}"
}

# evaluate_disk LABEL DIRECTORY FREE TOTAL: emit disk_low (warn) when the free space of a
# volume falls below DISK_MIN_FREE_PCT percent of its size, and disk_ok (info) when it is back.
#
# LABEL is `logs` or `settings` (each has its own state), DIRECTORY the path named in the
# message, FREE and TOTAL the sample's bytes (either may be empty). "Below" is strict: exactly
# DISK_MIN_FREE_PCT percent free is not low. Without both figures nothing changes: a volume
# that could not be measured is neither reported low nor declared fine.
evaluate_disk() {
  local label="$1" directory="$2" free="$3" total="$4" min_pct text
  if [ -z "${free}" ] || [ -z "${total}" ] || [ "${total}" -le 0 ]; then return 0; fi
  uint_or "${DISK_MIN_FREE_PCT:-}" 10 100
  min_pct="${REPLY}"
  text="${directory} has ${free} bytes free of ${total} ($((free * 100 / total))%)"
  if ((free * 100 < total * min_pct)); then
    if [ "${SAMPLER_DISK_LOW[${label}]:-0}" -eq 0 ]; then
      SAMPLER_DISK_LOW[${label}]=1
      log_event metrics warn disk_low "${text}, below DISK_MIN_FREE_PCT=${min_pct}"
    fi
  elif [ "${SAMPLER_DISK_LOW[${label}]:-0}" -eq 1 ]; then
    SAMPLER_DISK_LOW[${label}]=0
    log_event metrics info disk_ok "${text}, no longer below DISK_MIN_FREE_PCT=${min_pct}"
  fi
  return 0
}

# evaluate_login PHASE NOW: emit login_stalled (warn) when the phase has been `login` without
# interruption for more than LOGIN_STALL_S seconds, and login_resumed (info) when the phase
# leaves `login` after a stall was reported.
#
# NOW is epoch seconds. The clock starts when the sampler first sees `login` and restarts
# whenever it sees any other phase (2fa-pending included: then a human is being waited for,
# which is not a stall). One login_stalled per stall. Why: a window IBC does not know stops the
# login without a log line; the phase then stays `login` for ever.
evaluate_login() {
  local phase="$1" now="$2" stall_s elapsed
  uint_or "${LOGIN_STALL_S:-}" 300
  stall_s="${REPLY}"
  if [ "${phase}" = "login" ]; then
    if [ -z "${SAMPLER_LOGIN_SINCE}" ]; then SAMPLER_LOGIN_SINCE="${now}"; fi
    elapsed=$((now - SAMPLER_LOGIN_SINCE))
    if [ "${SAMPLER_LOGIN_STALLED}" -eq 0 ] && [ "${elapsed}" -gt "${stall_s}" ]; then
      SAMPLER_LOGIN_STALLED=1
      log_event metrics warn login_stalled "phase has been login for ${elapsed} s; a window that IBC does not handle may be blocking the login (see ibc/ibc.log)"
    fi
    return 0
  fi
  if [ "${SAMPLER_LOGIN_STALLED}" -eq 1 ]; then
    log_event metrics info login_resumed "phase left login after $((now - SAMPLER_LOGIN_SINCE)) s (now ${phase})"
  fi
  SAMPLER_LOGIN_SINCE=""
  SAMPLER_LOGIN_STALLED=0
}

# evaluate_memory WORKING_SET LIMIT NOW: emit memory_high (warn) when the working set has been
# above MEM_HIGH_PCT percent of the limit for MEM_HIGH_FOR_S seconds without interruption, and
# memory_ok (info) when it is no longer above after that was reported.
#
# WORKING_SET and LIMIT are the sample's bytes (either may be empty), NOW epoch seconds.
# "Above" is strict. Without a limit there is nothing to compare with, so nothing ever fires.
# A sample without the figures cannot prove the run continued: the clock restarts, but an
# episode already reported stays open until a measured sample shows it is over.
evaluate_memory() {
  local working_set="$1" limit="$2" now="$3" high_pct hold_s elapsed text
  if [ -z "${working_set}" ] || [ -z "${limit}" ] || [ "${limit}" -le 0 ]; then
    if [ "${SAMPLER_MEM_HIGH_REPORTED}" -eq 0 ]; then SAMPLER_MEM_HIGH_SINCE=""; fi
    return 0
  fi
  uint_or "${MEM_HIGH_PCT:-}" 85 100
  high_pct="${REPLY}"
  uint_or "${MEM_HIGH_FOR_S:-}" 600
  hold_s="${REPLY}"
  text="working set ${working_set} bytes is $((working_set * 100 / limit))% of the ${limit}-byte limit"
  if ((working_set * 100 > limit * high_pct)); then
    if [ -z "${SAMPLER_MEM_HIGH_SINCE}" ]; then SAMPLER_MEM_HIGH_SINCE="${now}"; fi
    elapsed=$((now - SAMPLER_MEM_HIGH_SINCE))
    if [ "${SAMPLER_MEM_HIGH_REPORTED}" -eq 0 ] && [ "${elapsed}" -ge "${hold_s}" ]; then
      SAMPLER_MEM_HIGH_REPORTED=1
      log_event metrics warn memory_high "${text}, above MEM_HIGH_PCT=${high_pct} for ${elapsed} s"
    fi
    return 0
  fi
  if [ "${SAMPLER_MEM_HIGH_REPORTED}" -eq 1 ]; then
    log_event metrics info memory_ok "${text}, no longer above MEM_HIGH_PCT=${high_pct}"
  fi
  SAMPLER_MEM_HIGH_SINCE=""
  SAMPLER_MEM_HIGH_REPORTED=0
}

# evaluate_events LINE: compare the sample LINE (as sample_once printed it) with what the
# sampler remembers and emit the events that follow from it.
#
# Inputs: LINE; the state variables of sampler_init_state, which it updates; the clock, or
# SAMPLER_NOW (epoch seconds) when that is set, so the two durations can be tested without
# waiting. Output: zero or more events through log_event (stdout and events/events.jsonl).
# It works from the line that was written, so an event never disagrees with the sample a
# reader finds next to it.
evaluate_events() {
  local line="$1" now phase="unknown" kills limit working_set free total
  local phase_pattern='"phase":"([^"]*)"'
  uint_or "${SAMPLER_NOW:-}" "${EPOCHSECONDS}"
  now="${REPLY}"
  if [[ "${line}" =~ ${phase_pattern} ]]; then phase="${BASH_REMATCH[1]}"; fi
  sample_number "${line}" oom_kills
  kills="${REPLY}"
  sample_number "${line}" mem_limit_bytes
  limit="${REPLY}"
  sample_number "${line}" mem_working_set_bytes
  working_set="${REPLY}"
  evaluate_oom "${kills}" "${limit}"
  sample_number "${line}" disk_free_bytes_logs
  free="${REPLY}"
  sample_number "${line}" disk_total_bytes_logs
  total="${REPLY}"
  evaluate_disk logs "${LOG_DIR}" "${free}" "${total}"
  sample_number "${line}" disk_free_bytes_settings
  free="${REPLY}"
  sample_number "${line}" disk_total_bytes_settings
  total="${REPLY}"
  evaluate_disk settings "${TWS_SETTINGS_PATH}" "${free}" "${total}"
  evaluate_login "${phase}" "${now}"
  evaluate_memory "${working_set}" "${limit}" "${now}"
}

# sampler_tick: take one sample, append it to ${LOG_DIR}/metrics/metrics.jsonl and emit the
# events that follow from it. One iteration of the loop.
#
# Always returns 0. SAMPLER_SEQ advances even when the line could not be written (the gap in
# seq then shows the loss), and the events are evaluated either way: they also go to stdout,
# which matters most when the volume is full.
sampler_tick() {
  local line
  line="$(sample_once)" || line=""
  SAMPLER_SEQ=$((SAMPLER_SEQ + 1))
  if [[ "${line}" != "{"*"}" ]]; then return 0; fi
  append_sample "${LOG_DIR}/metrics/metrics.jsonl" "${line}" || true
  evaluate_events "${line}"
  return 0
}

# sampler_stop: end the sampler at once with status 0 (the TERM and INT handler). The pause
# between two samples is killed too, so no `sleep` outlives the sampler.
sampler_stop() {
  if [ -n "${SAMPLER_SLEEP_PID}" ]; then kill "${SAMPLER_SLEEP_PID}" 2>/dev/null || true; fi
  exit 0
}

# sampler_main: sample every SAMPLE_INTERVAL_S seconds (default 30) until SIGTERM or SIGINT.
#
# The pause is `sleep` in the background plus `wait`, so the signal handler runs at once
# instead of after the pause. The interval is the pause between two samples; a sample takes a
# few tens of milliseconds, which is the only drift.
sampler_main() {
  local interval
  uint_or "${SAMPLE_INTERVAL_S:-}" 30
  interval="${REPLY}"
  if [ "${interval}" -lt 1 ]; then interval=30; fi
  sampler_init_state
  trap sampler_stop TERM INT
  while true; do
    sampler_tick
    sleep "${interval}" &
    SAMPLER_SLEEP_PID=$!
    wait "${SAMPLER_SLEEP_PID}" 2>/dev/null || true
    SAMPLER_SLEEP_PID=""
  done
}

sampler_init_state

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -u
  sampler_main
fi
