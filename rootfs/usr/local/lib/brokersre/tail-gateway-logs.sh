#!/usr/bin/env bash
# Mirror the Gateway's own log files from the settings volume into ${LOG_DIR}/jts so a sidecar
# can read them without mounting the settings volume (which holds the auto-restart session
# token). IB Gateway writes launcher.log and a dated ibgateway.*.log; the dated file changes at
# the daily restart, so the newest matching file is re-selected every MIRROR_INTERVAL_S.
# launcher.log is REAL (seen with IB Gateway 10.50.1g); the ibgateway.*.log name is from IB
# Gateway 10.x documentation and still unverified (docs/limitations.md L03).
#
# Contract:
#   - ${LOG_DIR}/jts/launcher.log and ${LOG_DIR}/jts/ibgateway.current.log receive every line
#     of their source exactly once per source file, through rotating-append.sh (size-capped);
#   - a restart of this script (container restart) resumes each source after the last byte
#     already mirrored: the position is kept in ${LOG_DIR}/jts/.mirror/<name>.state as
#     "<device:inode> <bytes>". A source that is a different file (new inode) or shorter than
#     the recorded position is mirrored from its start;
#   - a source replaced while the mirror runs is picked up within MIRROR_INTERVAL_S (default 30).
# At-least-once: a crash between an append and the state write can repeat the last second of
# lines after a restart; lines are never skipped.
set -u
BROKERSRE_LIB="${BROKERSRE_LIB:-$(dirname "${BASH_SOURCE[0]}")}"
SETTINGS="${TWS_SETTINGS_PATH:-/home/ibgateway/Jts/settings}"
OUT="${LOG_DIR:-/var/log/ibgateway}/jts"
INTERVAL="${MIRROR_INTERVAL_S:-30}"
STATE_DIR="${OUT}/.mirror"
mkdir -p "${OUT}" "${STATE_DIR}"

# Per mirror name: the pids of the tail and of its writer, and the identity of the source.
declare -A tail_pid=() writer_pid=() mirror_id=()

# identity <file>: "<device>:<inode>", the same for a file that only grew, different for a
# file that was replaced. Empty when the file does not exist.
identity() { stat -c '%d:%i' "$1" 2>/dev/null || true; }

# stop_mirror <name>: end the tail first (the writer then drains what is left in the pipe,
# reaches end of input and records its position), then wait for the writer.
stop_mirror() {
  local name="$1"
  if [ -n "${tail_pid[${name}]:-}" ]; then kill "${tail_pid[${name}]}" 2>/dev/null || true; fi
  if [ -n "${writer_pid[${name}]:-}" ]; then wait "${writer_pid[${name}]}" 2>/dev/null || true; fi
  tail_pid[${name}]=""
  writer_pid[${name}]=""
  mirror_id[${name}]=""
}

# follow <name> <source> <destination>: (re)start the mirror of <source> when it is a different
# file than the one being followed, resuming from the recorded position when that position
# belongs to this very file.
follow() {
  local name="$1" src="$2" dst="$3" id skip=0 saved_id="" saved_bytes=0 size fifo
  id="$(identity "${src}")"
  [ -n "${id}" ] || return 0
  if [ "${mirror_id[${name}]:-}" = "${id}" ] && kill -0 "${tail_pid[${name}]:-0}" 2>/dev/null; then
    return 0
  fi
  stop_mirror "${name}"
  if [ -r "${STATE_DIR}/${name}.state" ]; then
    read -r saved_id saved_bytes <"${STATE_DIR}/${name}.state" || true
  fi
  size="$(stat -c %s "${src}" 2>/dev/null || echo 0)"
  if [ "${saved_id}" = "${id}" ] && [[ "${saved_bytes}" =~ ^[0-9]+$ ]] && [ "${saved_bytes}" -le "${size}" ]; then
    skip="${saved_bytes}"
  fi
  # A named pipe (instead of `tail | writer`) gives this script both pids, so it can stop the
  # tail and let the writer finish cleanly. It lives in the tmpfs run directory: a log volume
  # that is a bind mount from a Windows host cannot hold a named pipe.
  fifo="${RUN_DIR:-/tmp}/mirror-${name}.fifo"
  rm -f "${fifo}"
  mkfifo "${fifo}"
  "${BROKERSRE_LIB}/rotating-append.sh" "${dst}" --state "${STATE_DIR}/${name}.state" "${id}" "${skip}" <"${fifo}" &
  writer_pid[${name}]=$!
  # --follow=descriptor: keep reading this very file even after its name is given to a new
  # file; the loop below notices the new identity and starts a fresh mirror for it.
  tail -c "+$((skip + 1))" --follow=descriptor "${src}" >"${fifo}" 2>/dev/null &
  tail_pid[${name}]=$!
  mirror_id[${name}]="${id}"
}

# shellcheck disable=SC2317,SC2329  # invoked through the TERM/INT trap
shutdown() {
  local name
  for name in "${!tail_pid[@]}"; do stop_mirror "${name}"; done
  exit 0
}
trap shutdown TERM INT

while true; do
  newest="$(find "${SETTINGS}" -maxdepth 1 -type f -name 'ibgateway.*.log' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)"
  if [ -n "${newest}" ]; then follow gateway "${newest}" "${OUT}/ibgateway.current.log"; fi
  follow launcher "${SETTINGS}/launcher.log" "${OUT}/launcher.log"
  # `sleep` in the background plus `wait` lets the TERM trap run at once instead of after the
  # sleep ends.
  sleep "${INTERVAL}" &
  wait $! 2>/dev/null || true
done
