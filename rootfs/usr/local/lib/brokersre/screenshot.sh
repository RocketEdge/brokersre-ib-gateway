#!/usr/bin/env bash
# A picture of the Gateway's virtual screen, kept on the log volume.
#
# Why: when a window that IBC does not handle blocks the login, the log says only that a
# window opened (its title stays in ibc/ibc.log). What the window says, and which button it
# offers, is on the screen. This file saves that screen at the two moments the image knows
# something is stuck (`unknown_window`, `login_stalled`) and on request.
#
# How, without a new package: with SCREENSHOTS=yes start-xvfb.sh starts Xvfb with `-fbdir`,
# and Xvfb then keeps its framebuffer in ${RUN_DIR}/xvfb/Xvfb_screen0, an image in XWD format
# (readable by GIMP, ImageMagick and xwud). A screenshot is a copy of that file.
#
# Opt-in (SCREENSHOTS=yes, default no): the screen can show the username in the login window
# and account information after a login. The copies are private files (0600) under
# ${LOG_DIR}/screens/ and are never printed or shipped by this image; whoever mounts the log
# volume can read them.
#
# Contract:
#   - file name: <UTC time as YYYYMMDDTHHMMSSZ>-<reason>.xwd; the reason is cut down to
#     lower-case letters, digits, underscore and hyphen (it never carries a window title);
#   - at most one screenshot per SCREENSHOT_MIN_INTERVAL_S seconds (default 60; 0 = no limit),
#     so a burst of windows cannot fill the volume; the newest SCREENSHOT_KEEP (default 5)
#     are kept, older ones are removed;
#   - event `screenshot_saved` (info, source xvfb; data: file, reason, bytes) per saved file;
#     `screenshot_failed` (warn) when the copy could not be written;
#   - nothing is saved, and nothing is said, when screenshots are off or Xvfb runs without the
#     framebuffer file; screenshot_save never fails its caller.
#   - a copy of a screen that is being redrawn can show a half-drawn window; that is accepted.
#
# As a command: `screenshot.sh [reason]` takes one screenshot now (reason `manual`); exit 0
# when taken or skipped by the interval, 1 when screenshots are switched off.
# Requires log.sh (log_event, log_event_data, json_object) when sourced; sources it itself
# when executed. SCREENSHOT_NOW (epoch seconds) replaces the clock in tests.

# screenshots_enabled: true when the operator switched screenshots on.
screenshots_enabled() {
  [ "${SCREENSHOTS:-no}" = "yes" ]
}

# screenshot_framebuffer: print the path of the file Xvfb keeps its framebuffer in.
screenshot_framebuffer() {
  printf '%s' "${RUN_DIR:-/run/brokersre}/xvfb/Xvfb_screen0"
}

# screenshot_number VALUE DEFAULT: print VALUE when it is a plain non-negative integer, else
# DEFAULT. A mistyped setting must not turn into "keep none" or "no limit".
screenshot_number() {
  if [[ "${1:-}" =~ ^[0-9]+$ ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

# screenshot_save [REASON]: save the screen to ${LOG_DIR}/screens/ (see the header).
# Always returns 0.
screenshot_save() {
  local reason="${1:-}" framebuffer dir name tmp now last="" keep interval size
  local -a kept
  screenshots_enabled || return 0
  framebuffer="$(screenshot_framebuffer)"
  [ -s "${framebuffer}" ] || return 0
  reason="${reason//[^a-z0-9_-]/}"
  reason="${reason:0:32}"
  [ -n "${reason}" ] || reason="manual"
  keep="$(screenshot_number "${SCREENSHOT_KEEP:-}" 5)"
  # Keeping none would delete the screenshot just taken; the bound itself is not optional.
  [ "${keep}" -ge 1 ] || keep=5
  interval="$(screenshot_number "${SCREENSHOT_MIN_INTERVAL_S:-}" 60)"
  now="$(screenshot_number "${SCREENSHOT_NOW:-}" "")"
  if [ -z "${now}" ]; then printf -v now '%(%s)T' -1; fi
  dir="${LOG_DIR:-/var/log/ibgateway}/screens"
  if ! mkdir -p "${dir}" 2>/dev/null || ! chmod 0700 "${dir}" 2>/dev/null; then
    log_event xvfb warn screenshot_failed "the screenshot directory on the log volume cannot be created or written"
    return 0
  fi
  if [ -r "${dir}/.last" ]; then read -r last <"${dir}/.last" || true; fi
  if [[ "${last}" =~ ^[0-9]+$ ]] && ((now - last < interval)); then
    return 0
  fi
  name="$(TZ=UTC printf '%(%Y%m%dT%H%M%SZ)T' "${now}")-${reason}.xwd"
  tmp="${dir}/.${name}.tmp.${BASHPID}"
  if ! (umask 077 && cp -- "${framebuffer}" "${tmp}") 2>/dev/null || ! mv -f "${tmp}" "${dir}/${name}" 2>/dev/null; then
    rm -f "${tmp}" 2>/dev/null
    log_event xvfb warn screenshot_failed "a screenshot could not be written to the log volume"
    return 0
  fi
  printf '%s\n' "${now}" >"${dir}/.last" 2>/dev/null || true
  size="$(stat -c %s "${dir}/${name}" 2>/dev/null || echo 0)"
  # The names start with the time, so name order is age order: drop all but the newest.
  mapfile -t kept < <(find "${dir}" -maxdepth 1 -name '*.xwd' -printf '%f\n' 2>/dev/null | sort)
  if [ "${#kept[@]}" -gt "${keep}" ]; then
    local old
    for old in "${kept[@]:0:${#kept[@]}-keep}"; do rm -f "${dir}/${old}" 2>/dev/null || true; done
  fi
  log_event_data xvfb info screenshot_saved \
    "$(json_object file "screens/${name}" reason "${reason}" bytes "${size}")" \
    "a screenshot of the Gateway's screen was saved to screens/${name} on the log volume (XWD format)"
  return 0
}

# Executed (not sourced): take one screenshot now.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  # shellcheck source=/dev/null
  source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/log.sh"
  if ! screenshots_enabled; then
    echo "screenshots are switched off: start the container with SCREENSHOTS=yes (the screen can show the username, so it is opt-in)" >&2
    exit 1
  fi
  # Someone asked for this one: the interval that protects the volume from a burst of
  # windows does not apply.
  SCREENSHOT_MIN_INTERVAL_S=0 screenshot_save "${1:-manual}"
fi
