#!/usr/bin/env bash
# Classify IBC log lines into structured events and the lifecycle phase file.
#
# Purpose: IBC writes human-oriented text (dialog titles, login progress). A sidecar or an
# operator must react to a handful of events (second factor pending, login completed, existing
# session, daily restart, a window nobody handles) without ever seeing the raw lines, which can
# contain the username. This filter reads IBC's output on stdin, emits one JSON event per
# recognised line (log.sh: stdout and the events file) and writes the phase token to
# ${LOG_DIR}/state/phase. Other lines produce nothing (they are already in ${LOG_DIR}/ibc/ibc.log).
#
# Contract:
#   - patterns come from ${IBC_PATTERNS:-/etc/brokersre/ibc-patterns.tsv}
#     (event<TAB>regex<TAB>phase<TAB>level); the first matching row wins. The message of each
#     event is fixed text, never the matched line.
#   - unknown_window: a line "detected (dialog|frame) entitled: <title>; event=Opened" that
#     matches no row and whose title matches no line of
#     ${IBC_KNOWN_WINDOWS:-/etc/brokersre/known-windows.txt} raises one `unknown_window` event
#     (warn, no phase change). The title stays in ibc.log only: it is raw Gateway text.
#   - second-factor cap (off by default): when TWOFA_MAX_PROMPTS is a positive number and more
#     than that many `twofa_initiated` events arrive without a `login_completed` between them,
#     the classifier emits `needs_human`, sets the phase `needs-human` and asks IBC to STOP
#     (through ${IBC_CMD:-ibc-cmd.sh}, in the background so IBC's output pipe never waits).
#     The entrypoint keeps the container up in that phase, so a restart policy cannot loop
#     through further logins. This never answers or bypasses a second factor: it only stops
#     asking.
#   - the classifier never moves the phase out of stopping, stopped or exited (write_phase):
#     the event is still emitted, the phase stays with the entrypoint.
#   - rejected-login latch (login-latch.sh): IBKR's rejection (`login_failed_dialog`) is
#     recorded on the log volume so that no later start sends the same credentials again
#     (`login_latch_set`); a completed login removes the record (`login_latch_cleared`).
#   - exit status is 0 at end of input.
set -u
LIB="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=/dev/null
source "${LIB}/log.sh"
# shellcheck source=/dev/null
source "${LIB}/login-latch.sh"
# shellcheck source=/dev/null
source "${LIB}/screenshot.sh"

LOG_DIR="${LOG_DIR:-/var/log/ibgateway}"
PATTERNS_FILE="${IBC_PATTERNS:-/etc/brokersre/ibc-patterns.tsv}"
KNOWN_WINDOWS_FILE="${IBC_KNOWN_WINDOWS:-/etc/brokersre/known-windows.txt}"
IBC_CMD="${IBC_CMD:-${LIB}/ibc-cmd.sh}"
mkdir -p "${LOG_DIR}/state"

max_prompts="${TWOFA_MAX_PROMPTS:-0}"
[[ "${max_prompts}" =~ ^[0-9]+$ ]] || max_prompts=0
prompts=0
held=0

events=() regexes=() phases=() levels=()
while IFS=$'\t' read -r event regex phase level; do
  [[ -z "${event}" || "${event}" == \#* ]] && continue
  events+=("${event}")
  regexes+=("${regex}")
  phases+=("${phase}")
  levels+=("${level:-info}")
done <"${PATTERNS_FILE}"

known_windows=()
if [ -r "${KNOWN_WINDOWS_FILE}" ]; then
  while IFS= read -r known || [ -n "${known}" ]; do
    [[ -z "${known}" || "${known}" == \#* ]] && continue
    known_windows+=("${known}")
  done <"${KNOWN_WINDOWS_FILE}"
fi

# Matches IBC's window report and captures the title; only the Opened report counts, because
# IBC logs Activated and Focused for the same window right after it.
window_opened_re='IBC: detected (dialog|frame) entitled: (.*); event=Opened$'

# write_phase PHASE: the classifier's phase write. Held back while the gateway is ending
# (phase stopping, stopped or exited): from then on the phase belongs to the entrypoint, and
# IBC's last lines ("Login has completed: exiting via ...") must not move it back.
write_phase() {
  phase_write "$1" --unless-ending || true
}

# window_is_known TITLE: true when the title is empty or matches a whole line of the known list.
window_is_known() {
  local title="$1" known
  [ -z "${title}" ] && return 0
  for known in "${known_windows[@]}"; do
    if [[ "${title}" =~ ^(${known})$ ]]; then return 0; fi
  done
  return 1
}

# after_event EVENT: bookkeeping that outlives the line (the second-factor prompt cap, the
# rejected-login latch).
after_event() {
  case "$1" in
    login_completed)
      prompts=0
      # These credentials work: a rejection recorded earlier no longer applies.
      login_latch_clear ibc "a login completed"
      ;;
    login_failed_dialog)
      if login_latch_set; then
        log_event ibc warn login_latch_set "IBKR rejected the credentials; this is recorded, and a later start with the same secret files will not log in until they are corrected"
      fi
      ;;
    twofa_initiated)
      prompts=$((prompts + 1))
      if [ "${max_prompts}" -gt 0 ] && [ "${prompts}" -gt "${max_prompts}" ] && [ "${held}" -eq 0 ]; then
        held=1
        log_event ibc error needs_human "second factor not approved after ${max_prompts} prompts; IBC is being stopped and the container stays up until a person restarts it"
        write_phase needs-human
        "${IBC_CMD}" STOP >/dev/null 2>&1 &
      fi
      ;;
  esac
}

while IFS= read -r line || [ -n "${line}" ]; do
  matched=0
  for i in "${!events[@]}"; do
    if [[ "${line}" =~ ${regexes[${i}]} ]]; then
      matched=1
      log_event ibc "${levels[${i}]}" "${events[${i}]}" "${events[${i}]}"
      # Once a human is needed, later lines of the stopping Gateway must not move the phase.
      if [ -n "${phases[${i}]}" ] && [ "${held}" -eq 0 ]; then
        write_phase "${phases[${i}]}"
      fi
      after_event "${events[${i}]}"
      break
    fi
  done
  # Without a list of known windows every window would look unknown, so nothing is reported.
  if [ "${matched}" -eq 0 ] && [ "${#known_windows[@]}" -gt 0 ] && [[ "${line}" =~ ${window_opened_re} ]]; then
    if ! window_is_known "${BASH_REMATCH[2]}"; then
      log_event ibc warn unknown_window "IBC reported a window it has no handler for; it may block the login or a restart (title in ibc/ibc.log)"
      # What the window says is on the screen: keep a picture of it (only with SCREENSHOTS=yes).
      # Beside this loop, not in it: IBC's output pipe must never wait for the log volume.
      (screenshot_save unknown_window) &
    fi
  fi
done
