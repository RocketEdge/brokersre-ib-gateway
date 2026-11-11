#!/usr/bin/env bash
# Append stdin to a log file, rotating it by size, without ever losing or splitting a line.
#
# Usage: rotating-append.sh <file> [--passthrough] [--state <state-file> <id> <base-bytes>]
#
# Purpose: IBC's output and the mirrored Gateway logs were appended forever (`tee -a`, `>>`),
# so a gateway that runs for months fills its log volume. This filter is the only writer of
# <file>: because it opens the file for every line, it can rename the file between two lines,
# which a `tee` holding an open descriptor cannot do without a copy-and-truncate race.
#
# Contract:
#   - every input line is appended to <file> followed by a newline; a final line without a
#     newline is kept;
#   - before a line would take <file> past LOG_MAX_BYTES (default 10485760 = 10 MiB) the file
#     is renamed to <file>.1 (older generations shift to .2, .3, ...) and only LOG_KEEP
#     (default 3) old generations are kept, so disk use is bounded by about
#     (LOG_KEEP + 1) x LOG_MAX_BYTES; a single line longer than the cap is written whole;
#   - --passthrough also writes each line to stdout (for the classifier behind it);
#   - --state records "<id> <bytes>" in <state-file> (atomically, at most once a second and at
#     end of input), where bytes = <base-bytes> + bytes consumed from stdin. The mirror uses it
#     to resume a source file after a restart instead of copying it again.
#   - an invalid LOG_MAX_BYTES or LOG_KEEP falls back to the default; exit status is 0 at EOF.
# Side effects: creates the file's directory. Lengths are counted in bytes (LC_ALL=C).
set -u
LC_ALL=C

file="${1:?usage: rotating-append.sh <file> [--passthrough] [--state <state-file> <id> <base-bytes>]}"
shift
passthrough=0
state_file="" state_id=""
consumed=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --passthrough)
      passthrough=1
      shift
      ;;
    --state)
      state_file="$2"
      state_id="$3"
      consumed="$4"
      shift 4
      ;;
    *)
      echo "rotating-append.sh: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

max="${LOG_MAX_BYTES:-10485760}"
keep="${LOG_KEEP:-3}"
[[ "${max}" =~ ^[1-9][0-9]*$ ]] || max=10485760
[[ "${keep}" =~ ^[0-9]+$ ]] || keep=3
[[ "${consumed}" =~ ^[0-9]+$ ]] || consumed=0

mkdir -p "$(dirname "${file}")"
size=0
if [ -f "${file}" ]; then size="$(stat -c %s "${file}" 2>/dev/null || echo 0)"; fi

# rotate: shift <file>.N to <file>.N+1 (dropping the oldest) and move <file> to <file>.1.
rotate() {
  local i
  if [ "${keep}" -eq 0 ]; then
    rm -f "${file}"
  else
    rm -f "${file}.${keep}"
    for ((i = keep - 1; i >= 1; i--)); do
      if [ -f "${file}.${i}" ]; then mv -f "${file}.${i}" "${file}.$((i + 1))"; fi
    done
    mv -f "${file}" "${file}.1"
  fi
  size=0
}

# save_state: write "<id> <bytes>" atomically so a reader never sees a half-written record.
save_state() {
  [ -n "${state_file}" ] || return 0
  printf '%s %s\n' "${state_id}" "${consumed}" >"${state_file}.tmp" 2>/dev/null &&
    mv -f "${state_file}.tmp" "${state_file}" 2>/dev/null
  last_saved="${SECONDS}"
}
last_saved=-1
trap 'save_state; exit 0' TERM INT

while IFS= read -r line || [ -n "${line}" ]; do
  bytes=$((${#line} + 1))
  if [ "${size}" -gt 0 ] && [ $((size + bytes)) -gt "${max}" ]; then rotate; fi
  printf '%s\n' "${line}" >>"${file}"
  size=$((size + bytes))
  consumed=$((consumed + bytes))
  if [ "${passthrough}" -eq 1 ]; then printf '%s\n' "${line}"; fi
  if [ -n "${state_file}" ] && [ "${SECONDS}" -ne "${last_saved}" ]; then save_state; fi
done
save_state
