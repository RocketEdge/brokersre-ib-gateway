#!/usr/bin/env bash
# Mirror the Gateway's own log files from the settings volume into ${LOG_DIR}/jts so the agent
# can read them without mounting the settings volume (which holds the auto-restart session
# token). IB Gateway writes launcher.log and a dated ibgateway.*.log; the dated file changes at
# the daily restart, so the newest matching file is re-selected every 30 s.
# File names are the ones observed with IB Gateway 10.x; VERIFY in Phase 0.
set -u
SETTINGS="${TWS_SETTINGS_PATH:-/home/ibgateway/Jts/settings}"
OUT="${LOG_DIR:-/var/log/ibgateway}/jts"
mkdir -p "${OUT}"

tail_pid=""
current=""
while true; do
  newest="$(find "${SETTINGS}" -maxdepth 1 -type f -name 'ibgateway.*.log' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)"
  if [ -n "${newest}" ] && [ "${newest}" != "${current}" ]; then
    [ -n "${tail_pid}" ] && kill "${tail_pid}" 2>/dev/null
    current="${newest}"
    tail -n +1 -F "${current}" >>"${OUT}/ibgateway.current.log" 2>/dev/null &
    tail_pid=$!
  fi
  if [ -f "${SETTINGS}/launcher.log" ] && [ -z "${launcher_pid:-}" ]; then
    tail -n +1 -F "${SETTINGS}/launcher.log" >>"${OUT}/launcher.log" 2>/dev/null &
    launcher_pid=$!
  fi
  sleep 30
done
