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
#     UNKNOWN_WINDOW_GRACE_S seconds (default 10; whole seconds, at most six digits; anything
#     else is the default). When IBC reports "event=Closed" for that title within the wait,
#     nothing is said: IBC or the Gateway dealt with the window (the paper-account "Warning"
#     that IBC accepts is gone 0.3 s after it opens). A window still open when the wait ends
#     raises one `unknown_window` event (warn, no phase change): that is the window a person
#     must look at. UNKNOWN_WINDOW_GRACE_S=0 reports every such window the moment it opens.
#     The title stays in ibc.log only: it is raw Gateway text.
#     What ends a wait without a report: the window's "Closed" line; a new IBC (its version
#     line: the Gateway process was started again, and the windows of the old one are gone
#     without a "Closed" line); the end of IBC's output.
#     Time is the kernel's uptime, not the wall clock: a clock step neither hurries nor delays
#     a report (bash's SECONDS is the fallback only where /proc/uptime cannot be read at
#     start). A window is never reported before the wait is over, and it is reported only
#     when no further line of IBC is already waiting to be read: after a pause of this
#     process, of the container or of the host, the line that closes the window may be in the
#     pipe already. A stream of lines postpones a report by at most one second.
#     Limits: IBC names a window by its title only. Of several open windows with one title the
#     one that opened LAST counts as the one that closed, so a window that stays open keeps
#     its place and is reported on time. A window whose title changes while it is open is
#     reported although it closed (the start-up frame does that, which is why its titles are on
#     the list). No more than 32 windows wait at a time; a further one is not followed.
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
# Lines are bytes here. In a UTF-8 locale bash can drop bytes when the time limit of a read
# ends inside a multibyte character.
export LC_ALL=C
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

# How long an unknown window may stay open before it is reported, in hundredths of a second;
# 0 reports it at once. 10# keeps a value such as 08 decimal (bash would read it as a broken
# octal number).
grace="${UNKNOWN_WINDOW_GRACE_S:-10}"
[[ "${grace}" =~ ^[0-9]{1,6}$ ]] || grace=10
grace_cs=$((10#${grace} * 100))
# Unknown windows that are open and not yet reported, oldest first: the title, and the time
# (clock_now) at which the window is due to be reported. Kept in step by index.
waiting_titles=()
waiting_due=()
# No more windows than this wait at a time: every line of IBC's output walks the list, and
# IBC's output pipe must never wait for the classifier. A further window is not followed; the
# ones that wait already are still reported, which is what brings a person to the screen.
max_waiting=32
# A due window is reported only when no line of IBC is waiting to be read, but lines are read
# first for no longer than this many hundredths of a second: a stream of lines cannot hide a
# window. Counted from the first time a report was put off, not from the due time: after a
# pause of the process the window is long overdue, and the line that closes it is exactly what
# is waiting.
max_defer_cs=100
defer_since_cs=-1

events=() regexes=() phases=() levels=()
while IFS=$'\t' read -r event regex phase level; do
  [[ -z "${event}" || "${event}" == \#* ]] && continue
  events+=("${event}")
  regexes+=("${regex}")
  phases+=("${phase}")
  levels+=("${level:-info}")
done <"${PATTERNS_FILE}"

# The list of known windows: the regular expression of each line, and the kind of window it
# is limited to ("frame" for a line that starts with "frame:", nothing for both kinds).
known_windows=()
known_kinds=()
if [ -r "${KNOWN_WINDOWS_FILE}" ]; then
  while IFS= read -r known || [ -n "${known}" ]; do
    [[ -z "${known}" || "${known}" == \#* ]] && continue
    if [[ "${known}" == frame:* ]]; then
      known_windows+=("${known#frame:}")
      known_kinds+=("frame")
    else
      known_windows+=("${known}")
      known_kinds+=("")
    fi
  done <"${KNOWN_WINDOWS_FILE}"
fi

# Matches IBC's window report and captures the kind and the title; only the Opened report
# counts, because IBC logs Activated and Focused for the same window right after it.
window_opened_re='IBC: detected (dialog|frame) entitled: (.*); event=Opened$'
# The report that ends a window's life. Lost focus and Deactivated, which IBC logs before it,
# do not: a window that only lost the focus is still on the screen.
window_closed_re='IBC: detected (dialog|frame) entitled: (.*); event=Closed$'

# Where the time comes from: the kernel's uptime, which a step of the wall clock does not
# move. Decided once, so that two sources are never mixed; bash's SECONDS (wall clock, whole
# seconds) is the fallback only where /proc/uptime cannot be read at start.
clock_source=seconds
if { read -r probe _ </proc/uptime; } 2>/dev/null && [[ "${probe}" =~ ^[0-9]+\.[0-9][0-9]$ ]]; then
  clock_source=uptime
fi
now_cs=0

# clock_now: put the time into ${now_cs}, in hundredths of a second. A read of /proc/uptime
# that fails once keeps the last value (time then stands still for that call, which can only
# delay a report, never bring it forward), instead of switching to the other clock. It
# overwrites BASH_REMATCH: a caller takes what it needs from a match before calling it.
clock_now() {
  local up=""
  if [ "${clock_source}" = seconds ]; then
    now_cs=$((SECONDS * 100))
  elif { read -r up _ </proc/uptime; } 2>/dev/null && [[ "${up}" =~ ^([0-9]+)\.([0-9][0-9])$ ]]; then
    now_cs=$((10#${BASH_REMATCH[1]} * 100 + 10#${BASH_REMATCH[2]}))
  fi
}

# write_phase PHASE: the classifier's phase write. Held back while the gateway is ending
# (phase stopping, stopped or exited): from then on the phase belongs to the entrypoint, and
# IBC's last lines ("Login has completed: exiting via ...") must not move it back.
write_phase() {
  phase_write "$1" --unless-ending || true
}

# window_is_known KIND TITLE: true when the title is empty or matches a whole line of the
# known list that applies to this kind of window (dialog or frame).
window_is_known() {
  local kind="$1" title="$2" i
  [ -z "${title}" ] && return 0
  for i in "${!known_windows[@]}"; do
    if [ -n "${known_kinds[${i}]}" ] && [ "${known_kinds[${i}]}" != "${kind}" ]; then continue; fi
    if [[ "${title}" =~ ^(${known_windows[${i}]})$ ]]; then return 0; fi
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
# Otherwise it waits, and is due once it has been open for the whole grace period.
window_opened() {
  if [ "${grace_cs}" -eq 0 ]; then
    report_unknown_window
    return 0
  fi
  if [ "${#waiting_titles[@]}" -ge "${max_waiting}" ]; then return 0; fi
  clock_now
  waiting_titles+=("$1")
  waiting_due+=("$((now_cs + grace_cs))")
}

# window_closed TITLE: a window of this title is gone. Of several that wait under one title
# the NEWEST is taken off the list: IBC answers a window within a fraction of a second, so the
# one that just opened is the likely one, and a window that stays open keeps its due time
# whatever opens and closes after it. A title nobody waits for changes nothing. The titles
# are compared as text (quoted), never as a pattern.
window_closed() {
  local indexes=("${!waiting_titles[@]}") k i
  for ((k = ${#indexes[@]} - 1; k >= 0; k--)); do
    i="${indexes[${k}]}"
    if [ "${waiting_titles[${i}]}" == "$1" ]; then
      unset "waiting_titles[${i}]" "waiting_due[${i}]"
      return 0
    fi
  done
  return 0
}

# forget_windows: stop waiting for every window. Called when a new IBC announces itself: the
# Gateway process was started again (daily restart, a restart after a second-factor timeout),
# its windows went with it, and no "Closed" line was written for them.
forget_windows() {
  waiting_titles=()
  waiting_due=()
}

# report_due_windows: report each waiting window whose grace period is over, and stop
# waiting for it.
report_due_windows() {
  local i
  [ "${#waiting_due[@]}" -eq 0 ] && return 0
  clock_now
  for i in "${!waiting_due[@]}"; do
    if [ "${now_cs}" -ge "${waiting_due[${i}]}" ]; then
      unset "waiting_titles[${i}]" "waiting_due[${i}]"
      report_unknown_window
    fi
  done
}

# set_wait: put into ${wait_s} the seconds (with hundredths) until the next waiting window is
# due, or nothing when no window waits. With nothing to wait for, the read of the next line
# blocks without a time limit, exactly as it did before windows could wait. Never 0: with a
# time limit of 0 `read` reads nothing and only says whether input is waiting, and the loop
# below would take its answer for the end of the input.
set_wait() {
  local i left=-1
  wait_s=""
  [ "${#waiting_due[@]}" -eq 0 ] && return 0
  clock_now
  for i in "${!waiting_due[@]}"; do
    if [ "${left}" -lt 0 ] || [ "$((waiting_due[i] - now_cs))" -lt "${left}" ]; then
      left=$((waiting_due[i] - now_cs))
      [ "${left}" -lt 1 ] && left=1
    fi
  done
  printf -v wait_s '%d.%02d' "$((left / 100))" "$((left % 100))"
}

# input_waiting: true when a line of IBC, or the end of its output, can be read at once.
input_waiting() {
  read -r -t 0
}

# set_overdue: put into ${overdue_cs} how long, in hundredths of a second, the window that
# became due first has been due; -1 when no waiting window is due yet.
set_overdue() {
  local i
  overdue_cs=-1
  [ "${#waiting_due[@]}" -eq 0 ] && return 0
  clock_now
  for i in "${!waiting_due[@]}"; do
    if [ "${now_cs}" -ge "${waiting_due[${i}]}" ] && [ "$((now_cs - waiting_due[i]))" -gt "${overdue_cs}" ]; then
      overdue_cs=$((now_cs - waiting_due[i]))
    fi
  done
}

# after_event EVENT: bookkeeping that outlives the line (the windows of a Gateway process
# that was replaced, the second-factor prompt cap, the rejected-login latch).
after_event() {
  case "$1" in
    ibc_version)
      forget_windows
      ;;
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
  local line="$1" matched=0 i kind title
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
      kind="${BASH_REMATCH[1]}"
      title="${BASH_REMATCH[2]}"
      window_is_known "${kind}" "${title}" || window_opened "${title}"
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
  else
    line="${partial}${line}"
    partial=""
    # End of input: a last line without a line end is still a line.
    if [ "${read_status}" -ne 0 ] && [ -z "${line}" ]; then break; fi
    classify_line "${line}"
    if [ "${read_status}" -ne 0 ]; then break; fi
  fi
  # A due window is reported only when IBC has nothing more to say right now: a line that is
  # already in the pipe may be the one that closes it. max_defer_cs bounds the postponing.
  set_overdue
  if [ "${overdue_cs}" -lt 0 ]; then
    defer_since_cs=-1
  elif ! input_waiting; then
    defer_since_cs=-1
    report_due_windows
  elif [ "${defer_since_cs}" -lt 0 ]; then
    defer_since_cs="${now_cs}"
  elif [ "$((now_cs - defer_since_cs))" -ge "${max_defer_cs}" ]; then
    defer_since_cs=-1
    report_due_windows
  fi
done
