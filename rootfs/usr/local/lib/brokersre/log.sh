#!/usr/bin/env bash
# Structured stdout for the container (log contract v1, schemas/log-event.v1.schema.json).
#
# Every line the container writes to stdout is one JSON object:
#   {"ts": "<UTC ISO-8601>", "src": "<component>", "level": "info|warn|error", "event": "<snake_case>", "msg": "<text>"}
# Raw IBC and Gateway output never reaches stdout; it goes to files under LOG_DIR, so a
# credential echoed by a dialog can never leak through container logging.
#
# Usage: log_event <src> <level> <event> <msg...>

json_escape() {
  # Escape backslashes, double quotes and control characters for a JSON string value.
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "${s}"
}

# UTC timestamp with milliseconds from bash's EPOCHREALTIME (no GNU date dependency).
ts_now() {
  local now="${EPOCHREALTIME}" secs micros
  secs="${now%.*}"
  micros="${now#*.}"
  TZ=UTC printf '%(%Y-%m-%dT%H:%M:%S)T.%sZ' "${secs}" "${micros:0:3}"
}

log_event() {
  local src="$1" level="$2" event="$3"
  shift 3
  local msg="$*"
  printf '{"ts":"%s","src":"%s","level":"%s","event":"%s","msg":"%s"}\n' \
    "$(ts_now)" \
    "$(json_escape "${src}")" "$(json_escape "${level}")" "$(json_escape "${event}")" "$(json_escape "${msg}")"
}
