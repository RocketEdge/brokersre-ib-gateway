#!/usr/bin/env bash
# Structured events for the container (log contract v2, schemas/log-event.v2.schema.json).
#
# Every event is one JSON object on one line:
#   {"ts": "<UTC ISO-8601>", "src": "<component>", "level": "info|warn|error",
#    "event": "<snake_case>", "msg": "<text>", "boot_id": "<16 hex>", "seq": <n>}
# and it is written twice, as the identical line: to stdout (container logging) and to
# ${LOG_DIR}/events/events.jsonl (the shared log volume), so a sidecar that mounts only the
# volume sees exactly what `docker logs` shows. `seq` counts events per `boot_id` across every
# process of the container without gaps, which lets a reader prove that it lost nothing.
# Raw IBC and Gateway output never becomes an event; it goes to files under LOG_DIR, so a
# credential echoed by a dialog cannot leak through an event.
#
# Usage: log_event <src> <level> <event> <msg...>

# json_escape STRING: print STRING escaped for use inside a JSON string value (backslash,
# double quote, and every control character below U+0020).
json_escape() {
  local s="$1" out="" ch esc
  local -i i code
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  # Rare path: any other control character is escaped one character at a time.
  if [[ "${s}" == *[$'\001'-$'\037']* ]]; then
    for ((i = 0; i < ${#s}; i++)); do
      ch="${s:i:1}"
      printf -v code '%d' "'${ch}"
      if ((code > 0 && code < 32)); then
        printf -v esc '\\u%04x' "${code}"
        out+="${esc}"
      else
        out+="${ch}"
      fi
    done
    s="${out}"
  fi
  printf '%s' "${s}"
}

# UTC timestamp with milliseconds from bash's EPOCHREALTIME (no GNU date dependency).
ts_now() {
  local now="${EPOCHREALTIME}" secs micros
  secs="${now%.*}"
  micros="${now#*.}"
  TZ=UTC printf '%(%Y-%m-%dT%H:%M:%S)T.%sZ' "${secs}" "${micros:0:3}"
}

# log_event_persist DIR BOOT BODY: under an exclusive lock, give the event the next sequence
# number of this boot, append it to DIR/events.jsonl (rotating the file by size first) and
# print the same line to stdout.
#
# Contract: returns 0 after the line was written to both places; returns 1 without printing
# when the lock, the append or the counter write failed, so the caller can still print the
# event. The lock makes the counter and the file order agree across processes (the entrypoint,
# the IBC classifier, the sampler and `doctor` all emit events). The timestamp is taken inside
# the lock, so sequence order is also time order.
# Rotation: LOG_MAX_BYTES (default 10485760) and LOG_KEEP (default 3), as for the other logs.
log_event_persist() {
  local dir="$1" boot="$2" body="$3" file="$1/events.jsonl"
  local seq_boot="" seq=0 line max="${LOG_MAX_BYTES:-10485760}" keep="${LOG_KEEP:-3}" size=0 i
  local LC_ALL=C
  [[ "${max}" =~ ^[1-9][0-9]*$ ]] || max=10485760
  [[ "${keep}" =~ ^[0-9]+$ ]] || keep=3
  {
    flock -w 5 9 || return 1
    if [ -r "${dir}/.seq" ]; then read -r seq_boot seq <"${dir}/.seq" || true; fi
    if [ "${seq_boot}" != "${boot}" ] || ! [[ "${seq}" =~ ^[0-9]+$ ]]; then seq=0; fi
    seq=$((seq + 1))
    line="{\"ts\":\"$(ts_now)\",${body},\"boot_id\":\"${boot}\",\"seq\":${seq}}"
    if [ -f "${file}" ]; then size="$(stat -c %s "${file}" 2>/dev/null || echo 0)"; fi
    if [ "${size}" -gt 0 ] && [ $((size + ${#line} + 1)) -gt "${max}" ]; then
      if [ "${keep}" -eq 0 ]; then
        rm -f "${file}"
      else
        rm -f "${file}.${keep}"
        for ((i = keep - 1; i >= 1; i--)); do
          if [ -f "${file}.${i}" ]; then mv -f "${file}.${i}" "${file}.$((i + 1))"; fi
        done
        mv -f "${file}" "${file}.1"
      fi
    fi
    printf '%s\n' "${line}" >>"${file}" 2>/dev/null || return 1
    printf '%s %s\n' "${boot}" "${seq}" >"${dir}/.seq" 2>/dev/null || return 1
    printf '%s\n' "${line}"
  } 9>"${dir}/.lock"
}

# log_event SRC LEVEL EVENT MSG...: emit one event.
#
# The stdout line is never lost: when the log volume cannot be written (not mounted, not
# writable, lock timeout) the event is printed without `seq`, and without `boot_id` when no boot
# id is known. The boot id comes from BOOT_ID (exported by the entrypoint) or, for a process
# started with `docker exec`, from ${LOG_DIR}/state/boot_id.
log_event() {
  local src="$1" level="$2" event="$3"
  shift 3
  local msg="$*" body boot="${BOOT_ID:-}" dir
  body="\"src\":\"$(json_escape "${src}")\",\"level\":\"$(json_escape "${level}")\",\"event\":\"$(json_escape "${event}")\",\"msg\":\"$(json_escape "${msg}")\""
  if [ -n "${LOG_DIR:-}" ]; then
    dir="${LOG_DIR}/events"
    if [ -z "${boot}" ] && [ -r "${LOG_DIR}/state/boot_id" ]; then
      read -r boot <"${LOG_DIR}/state/boot_id" || true
    fi
    if [ -n "${boot}" ] && mkdir -p "${dir}" 2>/dev/null && [ -w "${dir}" ]; then
      if log_event_persist "${dir}" "${boot}" "${body}"; then return 0; fi
    fi
  fi
  printf '{"ts":"%s",%s%s}\n' "$(ts_now)" "${body}" "${boot:+,\"boot_id\":\"${boot}\"}"
}
