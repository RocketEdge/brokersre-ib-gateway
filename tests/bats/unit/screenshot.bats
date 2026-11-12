#!/usr/bin/env bats
# Unit tests for screenshot.sh: a picture of the Gateway's virtual screen, kept on the log
# volume, for the moment when a window nobody handles blocks the login. The image has no
# screenshot tool and gets none: Xvfb itself can keep its framebuffer in a file (XWD format),
# and a screenshot is a copy of that file. Opt-in (SCREENSHOTS=yes): the screen can show the
# username, so nothing is written unless the operator asked for it.

setup() {
  : "${BROKERSRE_LIB:?set BROKERSRE_LIB to rootfs/usr/local/lib/brokersre}"
  WORK="$(mktemp -d)"
  export LOG_DIR="${WORK}/logs" RUN_DIR="${WORK}/run" BOOT_ID="0123456789abcdef"
  mkdir -p "${LOG_DIR}" "${RUN_DIR}/xvfb"
  FB="${RUN_DIR}/xvfb/Xvfb_screen0"
  # Not a real image: 4 KiB of known bytes are enough to prove a byte-exact copy.
  head -c 4096 /dev/urandom >"${FB}"
  SCREENS="${LOG_DIR}/screens"
  EVENTS="${LOG_DIR}/events/events.jsonl"
  unset SCREENSHOTS SCREENSHOT_KEEP SCREENSHOT_MIN_INTERVAL_S SCREENSHOT_NOW
}

teardown() {
  chmod -R u+rwx "${WORK}" 2>/dev/null || true
  rm -rf "${WORK}"
}

# shot ARGS...: call one function of screenshot.sh in a fresh shell with nounset.
shot() {
  bash -uc "source '${BROKERSRE_LIB}/log.sh'; source '${BROKERSRE_LIB}/screenshot.sh'; \"\$@\"" _ "$@"
}

# files: the screenshots on the volume, oldest first, one name per line.
files() {
  if [ -d "${SCREENS}" ]; then find "${SCREENS}" -maxdepth 1 -name '*.xwd' -printf '%f\n' | sort; fi
}

@test "off by default: nothing is saved and nothing is said" {
  run shot screenshot_save unknown_window
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$(files)" ]
}

@test "SCREENSHOTS=yes saves the framebuffer byte for byte, private, under a timestamped name" {
  SCREENSHOTS=yes SCREENSHOT_NOW=1794441600 run shot screenshot_save unknown_window
  [ "$status" -eq 0 ]
  [ "$(files)" == "20261112T000000Z-unknown_window.xwd" ]
  cmp "${FB}" "${SCREENS}/20261112T000000Z-unknown_window.xwd"
  [ "$(stat -c %a "${SCREENS}/20261112T000000Z-unknown_window.xwd")" == "600" ]
  [ "$(stat -c %a "${SCREENS}")" == "700" ]
  [ -z "$(find "${SCREENS}" -name '*.tmp*')" ]
}

@test "the saved screenshot is announced with its file, reason and size, and nothing else" {
  SCREENSHOTS=yes SCREENSHOT_NOW=1794441600 run shot screenshot_save login_stalled
  [ "${#lines[@]}" -eq 1 ]
  echo "${lines[0]}" | jq -e '.event == "screenshot_saved" and .src == "xvfb" and .level == "info"' >/dev/null
  echo "${lines[0]}" | jq -e '.data.file == "screens/20261112T000000Z-login_stalled.xwd" and .data.reason == "login_stalled" and .data.bytes == "4096"' >/dev/null
}

@test "without a framebuffer file (Xvfb runs without one) nothing is saved and nothing is said" {
  rm -f "${FB}"
  SCREENSHOTS=yes run shot screenshot_save unknown_window
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$(files)" ]
}

@test "the reason reaches the file name only as letters, digits, underscore and hyphen" {
  SCREENSHOTS=yes SCREENSHOT_NOW=1794441600 run shot screenshot_save '../../etc/Passwd x;$(id)'
  [ "$status" -eq 0 ]
  [ "$(files)" == "20261112T000000Z-etcasswdxid.xwd" ]
  # Nothing was written outside the screens directory.
  [ "$(find "${WORK}" -name '*.xwd' | wc -l)" == "1" ]
  SCREENSHOTS=yes SCREENSHOT_NOW=1794445200 run shot screenshot_save ''
  [ "$(files | tail -n 1)" == "20261112T010000Z-manual.xwd" ]
}

@test "a second screenshot within SCREENSHOT_MIN_INTERVAL_S is skipped without a word" {
  SCREENSHOTS=yes SCREENSHOT_NOW=1000 shot screenshot_save unknown_window >/dev/null
  SCREENSHOTS=yes SCREENSHOT_NOW=1059 run shot screenshot_save unknown_window
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(files | wc -l)" == "1" ]
  SCREENSHOTS=yes SCREENSHOT_NOW=1060 run shot screenshot_save unknown_window
  [ "$(files | wc -l)" == "2" ]
  # The interval can be set; 0 means every call saves.
  SCREENSHOTS=yes SCREENSHOT_MIN_INTERVAL_S=0 SCREENSHOT_NOW=1061 run shot screenshot_save unknown_window
  [ "$(files | wc -l)" == "3" ]
}

@test "only the newest SCREENSHOT_KEEP screenshots are kept" {
  for now in 1000 2000 3000 4000; do
    SCREENSHOTS=yes SCREENSHOT_KEEP=2 SCREENSHOT_NOW="${now}" shot screenshot_save unknown_window >/dev/null
  done
  [ "$(files | wc -l)" == "2" ]
  [ "$(files | head -n 1)" == "19700101T005000Z-unknown_window.xwd" ]
  [ "$(files | tail -n 1)" == "19700101T010640Z-unknown_window.xwd" ]
}

@test "a bad SCREENSHOT_KEEP or interval falls back to the default instead of deleting everything" {
  for now in 1000 2000 3000; do
    SCREENSHOTS=yes SCREENSHOT_KEEP=none SCREENSHOT_MIN_INTERVAL_S=soon SCREENSHOT_NOW="${now}" shot screenshot_save unknown_window >/dev/null
  done
  [ "$(files | wc -l)" == "3" ]
}

@test "a screens directory that cannot be written is reported and never fails the caller" {
  : >"${SCREENS}"
  SCREENSHOTS=yes run shot screenshot_save unknown_window
  [ "$status" -eq 0 ]
  echo "${lines[0]}" | jq -e '.event == "screenshot_failed" and .level == "warn" and .src == "xvfb"' >/dev/null
}

@test "screenshot.sh as a command takes one screenshot now" {
  SCREENSHOTS=yes SCREENSHOT_NOW=1794441600 run "${BROKERSRE_LIB}/screenshot.sh"
  [ "$status" -eq 0 ]
  [ "$(files)" == "20261112T000000Z-manual.xwd" ]
  SCREENSHOTS=yes SCREENSHOT_NOW=1794445200 run "${BROKERSRE_LIB}/screenshot.sh" before_restart
  [ "$(files | tail -n 1)" == "20261112T010000Z-before_restart.xwd" ]
}

@test "as a command with SCREENSHOTS off it says how to switch them on and changes nothing" {
  run "${BROKERSRE_LIB}/screenshot.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SCREENSHOTS=yes"* ]]
  [ -z "$(files)" ]
}

# --- the two moments a screenshot is taken by itself -----------------------------------------

@test "classifier: a window IBC has no handler for is photographed" {
  export SCREENSHOTS=yes SCREENSHOT_NOW=1794441600
  printf '%s\n' '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Hunter2 Promo Offer 12345; event=Opened' \
    | IBC_PATTERNS="${BATS_TEST_DIRNAME}/../../../rootfs/etc/brokersre/ibc-patterns.tsv" \
      IBC_KNOWN_WINDOWS="${BATS_TEST_DIRNAME}/../../../rootfs/etc/brokersre/known-windows.txt" \
      "${BROKERSRE_LIB}/classify-ibc-log.sh" >/dev/null
  # The copy runs beside the classifier, which must never wait for a volume: poll for it.
  for _ in $(seq 1 50); do
    if [ -n "$(files)" ] && grep -q '"event":"screenshot_saved"' "${EVENTS}" 2>/dev/null; then break; fi
    sleep 0.1
  done
  [ "$(files)" == "20261112T000000Z-unknown_window.xwd" ]
  jq -e 'select(.event == "screenshot_saved") | .data.reason == "unknown_window"' "${EVENTS}" >/dev/null
  # The window title never reaches the file name or the event.
  ! grep -q -i 'promo' "${EVENTS}" || false
}

@test "classifier: with SCREENSHOTS off an unknown window is an event only" {
  printf '%s\n' '2026-11-11 23:23:04:155 IBC: detected dialog entitled: Hunter2 Promo Offer 12345; event=Opened' \
    | IBC_PATTERNS="${BATS_TEST_DIRNAME}/../../../rootfs/etc/brokersre/ibc-patterns.tsv" \
      IBC_KNOWN_WINDOWS="${BATS_TEST_DIRNAME}/../../../rootfs/etc/brokersre/known-windows.txt" \
      "${BROKERSRE_LIB}/classify-ibc-log.sh" >/dev/null
  sleep 0.5
  [ -z "$(files)" ]
  [ "$(jq -r .event "${EVENTS}" | tr '\n' ' ')" == "unknown_window " ]
}
