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
#     ${IBC_KNOWN_WINDOWS:-/etc/brokersre/known-windows.txt} starts a wait of
#     UNKNOWN_WINDOW_GRACE_S seconds (default 10, whole seconds; anything else is the default).
#     When IBC reports "event=Closed" for that title within the wait, nothing is said: IBC or
#     the Gateway dealt with the window (the paper-account "Warning" that IBC accepts is gone
#     0.3 s after it opens). A window still open when the wait ends raises one
#     `unknown_window` event (warn, no phase change): that is the window a person must look
#     at. UNKNOWN_WINDOW_GRACE_S=0 reports every such window the moment it opens. The title
#     stays in ibc.log only: it is raw Gateway text.
#     Limits: IBC names a window by its title only, so of two open windows with one title the
#     one that opened first counts as the one that closed; a window whose title changes while
#     it is open is reported although it closed (the start-up frame does that, which is why
#     its titles are on the list). The wait ends with IBC's output: a window that went down
#     with IBC is not reported.
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

# Seconds an unknown window may stay open before it is reported; 0 reports it at once.
# 10# keeps a value such as 08 decimal (bash would read it as a broken octal number).
grace="${UNKNOWN_WINDOW_GRACE_S:-10}"
[[ "${grace}" =~ ^[0-9]{1,6}$ ]] || grace=10
grace=$((10#${grace}))
# Unknown windows that are open, oldest first: the title, and either the value of SECONDS at
# which the window is due to be reported or the word "reported". Kept in step by index.
waiting_titles=()
waiting_due=()
# More open unknown windows than this are not followed: every line of IBC's output walks the
# list, and IBC's output pipe must never wait for the classifier.
max_waiting=32

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
# The report that ends a window's life (IBC logs Lost focus and Deactivated before it).
window_closed_re='IBC: detected (dialog|frame) entitled: (.*); event=Closed$'

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

# report_unknown_window: the event, and a picture of what the window says (only with
# SCREENSHOTS=yes). The picture is taken beside this loop, not in it: IBC's output pipe must
# never wait for the log volume.
report_unknown_window() {
  log_event ibc warn unknown_window "IBC reported a window it has no handler for; it may block the login or a restart (title in ibc/ibc.log)"
  (screenshot_save unknown_window) &
}

# window_opened TITLE: an unknown window opened. Without a grace period it is reported now.
# Otherwise it joins the waiting list and is due once it has been open for the whole grace
# period (SECONDS counts whole seconds, so one more is added: never early, at most 2 s late).
window_opened() {
  local first
  if [ "${grace}" -eq 0 ]; then
    report_unknown_window
    return 0
  fi
  if [ "${#waiting_titles[@]}" -ge "${max_waiting}" ]; then
    first=("${!waiting_titles[@]}")
    unset "waiting_titles[${first[0]}]" "waiting_due[${first[0]}]"
  fi
  waiting_titles+=("$1")
  waiting_due+=("$((SECONDS + grace + 1))")
}

# window_closed TITLE: the window of this title that has been open longest is gone, whether
# it was reported or not. A title nobody waits for changes nothing.
window_closed() {
  local i
  for i in "${!waiting_titles[@]}"; do
    if [ "${waiting_titles[${i}]}" == "$1" ]; then
      unset "waiting_titles[${i}]" "waiting_due[${i}]"
      return 0
    fi
  done
  return 0
}

# report_due_windows: report each waiting window whose grace period is over. It stays on the
# list as "reported" until IBC says it closed, so that a second window with the same title is
# not mistaken for it.
report_due_windows() {
  local i
  for i in "${!waiting_due[@]}"; do
    if [ "${waiting_due[${i}]}" != reported ] && [ "${SECONDS}" -ge "${waiting_due[${i}]}" ]; then
      waiting_due[i]=reported
      report_unknown_window
    fi
  done
}

# set_wait: put into ${wait_s} the seconds until the next waiting window is due (at least 1),
# or nothing when no window waits. With nothing to wait for, the read of the next line blocks
# without a time limit, exactly as it did before windows could wait.
set_wait() {
  local i left
  wait_s=""
  for i in "${!waiting_due[@]}"; do
    [ "${waiting_due[${i}]}" == reported ] && continue
    left=$((waiting_due[i] - SECONDS))
    [ "${left}" -lt 1 ] && left=1
    if [ -z "${wait_s}" ] || [ "${left}" -lt "${wait_s}" ]; then wait_s="${left}"; fi
  done
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

# classify_line LINE: one line of IBC's output. The first matching row of the pattern table
# becomes an event (and a phase); a window report that matches no row starts or ends the wait
# for an unknown window.
classify_line() {
  local line="$1" matched=0 i title
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
  if [ "${matched}" -eq 0 ] && [ "${#known_windows[@]}" -gt 0 ]; then
    if [[ "${line}" =~ ${window_opened_re} ]]; then
      title="${BASH_REMATCH[2]}"
      window_is_known "${title}" || window_opened "${title}"
    elif [[ "${line}" =~ ${window_closed_re} ]]; then
      window_closed "${BASH_REMATCH[2]}"
    fi
  fi
}

# The read has a time limit only while a window waits. When the limit ends the read, bash
# hands over what has arrived of an unfinished line: it is kept and put in front of the rest,
# so a line is never classified in two halves.
partial=""
while :; do
  set_wait
  if [ -n "${wait_s}" ]; then
    IFS= read -r -t "${wait_s}" line
  else
    IFS= read -r line
  fi
  read_status=$?
  if [ "${read_status}" -gt 128 ]; then
    partial+="${line}"
    report_due_windows
    continue
  fi
  line="${partial}${line}"
  partial=""
  # End of input: a last line without a line end is still a line.
  if [ "${read_status}" -ne 0 ] && [ -z "${line}" ]; then break; fi
  classify_line "${line}"
  report_due_windows
  if [ "${read_status}" -ne 0 ]; then break; fi
done
