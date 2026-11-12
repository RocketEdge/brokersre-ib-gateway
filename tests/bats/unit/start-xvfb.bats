#!/usr/bin/env bats
# Unit tests for start-xvfb.sh. The virtual screen is started exactly as it always was unless
# the operator asked for screenshots (SCREENSHOTS=yes): only then does Xvfb keep its
# framebuffer in a file, which is what screenshot.sh copies.

setup() {
  : "${BROKERSRE_LIB:?set BROKERSRE_LIB to rootfs/usr/local/lib/brokersre}"
  WORK="$(mktemp -d)"
  export LOG_DIR="${WORK}/logs" RUN_DIR="${WORK}/run" DISPLAY=":77" BOOT_ID="0123456789abcdef"
  mkdir -p "${LOG_DIR}" "${RUN_DIR}" "${WORK}/bin"
  export ARGS="${WORK}/xvfb.args"
  # A stand-in for Xvfb: records its arguments, then stays alive like the real one.
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >"${ARGS}"' 'sleep 600 &' 'wait' >"${WORK}/bin/Xvfb"
  chmod +x "${WORK}/bin/Xvfb"
  export PATH="${WORK}/bin:${PATH}"
  unset SCREENSHOTS
}

teardown() {
  pkill -f "${WORK}/bin/Xvfb" 2>/dev/null || true
  chmod -R u+rwx "${WORK}" 2>/dev/null || true
  rm -rf "${WORK}"
}

# start: run start_xvfb with the socket wait replaced (there is no real X server here) and
# print the events; the stand-in's arguments are in ${ARGS}.
start() {
  bash -uc "source '${BROKERSRE_LIB}/common.sh'; source '${BROKERSRE_LIB}/start-xvfb.sh'
    wait_for_unix_socket() { return 0; }
    start_xvfb
    for _ in \$(seq 1 50); do [ -s '${ARGS}' ] && break; sleep 0.1; done
    kill \"\${XVFB_PID}\" 2>/dev/null || true" 3>&-
}

@test "without SCREENSHOTS the virtual screen is started exactly as before" {
  run start
  [ "$status" -eq 0 ]
  [ "$(cat "${ARGS}")" == ":77 -ac -nolisten tcp -screen 0 1024x768x16" ]
  [ ! -e "${RUN_DIR}/xvfb" ]
  echo "$output" | jq -s -e 'map(.event) == ["xvfb_started"]' >/dev/null
}

@test "SCREENSHOTS=yes keeps the framebuffer in a private directory under the run directory" {
  SCREENSHOTS=yes run start
  [ "$status" -eq 0 ]
  [ "$(cat "${ARGS}")" == ":77 -ac -nolisten tcp -screen 0 1024x768x16 -fbdir ${RUN_DIR}/xvfb" ]
  [ -d "${RUN_DIR}/xvfb" ]
  [ "$(stat -c %a "${RUN_DIR}/xvfb")" == "700" ]
}

@test "any other value of SCREENSHOTS means off" {
  SCREENSHOTS=true run start
  [ "$(cat "${ARGS}")" == ":77 -ac -nolisten tcp -screen 0 1024x768x16" ]
}

@test "a framebuffer directory that cannot be created does not cost the virtual screen" {
  : >"${RUN_DIR}/xvfb"
  SCREENSHOTS=yes run start
  [ "$status" -eq 0 ]
  [ "$(cat "${ARGS}")" == ":77 -ac -nolisten tcp -screen 0 1024x768x16" ]
  echo "$output" | jq -s -e 'map(.event) == ["screenshots_unavailable", "xvfb_started"]' >/dev/null
  echo "$output" | jq -s -e '.[0].level == "warn" and .[0].src == "xvfb"' >/dev/null
}
