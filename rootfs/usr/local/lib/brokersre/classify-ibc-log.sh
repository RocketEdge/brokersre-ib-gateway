#!/usr/bin/env bash
# Classify IBC log lines into structured events and the lifecycle phase file.
#
# Purpose: IBC writes human-oriented text (dialog titles, login progress). The BrokerSRE agent
# must react to a handful of events (2FA pending, login completed, existing session, daily
# restart) without ever seeing the raw lines, which can contain the username. This filter reads
# IBC's output on stdin, emits one JSON event per matched line on stdout, and writes the phase
# token to ${LOG_DIR}/state/phase. Unmatched lines produce nothing on stdout (they are already
# captured to ${LOG_DIR}/ibc/ibc.log by tee).
#
# Contract: patterns come from ${IBC_PATTERNS:-/etc/brokersre/ibc-patterns.tsv}
# (event<TAB>regex<TAB>phase<TAB>level). The message of each event is the pattern's event name,
# never the matched line. Exit status is 0 at EOF.
set -u
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/log.sh"

LOG_DIR="${LOG_DIR:-/var/log/ibgateway}"
PATTERNS_FILE="${IBC_PATTERNS:-/etc/brokersre/ibc-patterns.tsv}"
mkdir -p "${LOG_DIR}/state"

events=() regexes=() phases=() levels=()
while IFS=$'\t' read -r event regex phase level; do
  [[ -z "${event}" || "${event}" == \#* ]] && continue
  events+=("${event}")
  regexes+=("${regex}")
  phases+=("${phase}")
  levels+=("${level:-info}")
done <"${PATTERNS_FILE}"

write_phase() {
  printf '%s\n' "$1" >"${LOG_DIR}/state/phase.tmp" && mv -f "${LOG_DIR}/state/phase.tmp" "${LOG_DIR}/state/phase"
}

while IFS= read -r line || [ -n "${line}" ]; do
  for i in "${!events[@]}"; do
    if [[ "${line}" =~ ${regexes[${i}]} ]]; then
      log_event ibc "${levels[${i}]}" "${events[${i}]}" "${events[${i}]}"
      if [ -n "${phases[${i}]}" ]; then
        write_phase "${phases[${i}]}"
      fi
      break
    fi
  done
done
