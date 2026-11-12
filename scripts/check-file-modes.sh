#!/usr/bin/env bash
# Every tracked shell script carries the execute bit in git.
#
# Usage: git ls-files -s | scripts/check-file-modes.sh
#        scripts/check-file-modes.sh <file holding the output of `git ls-files -s`>
#
# Why: the unit suite runs the scripts from the checked-out tree, so the mode git recorded is
# the mode a Linux runner executes with. A Windows development host records 100644 for a new
# file and still shows it as executable, so a script without the bit passes every local run
# and fails the first Linux run with "Permission denied". The image itself is not affected
# (the Dockerfile sets 0755 on its scripts); the tree is. The listing is read instead of the
# files because the index is the same on every host and the file system is not.
#
# Contract:
#   - input: lines `<mode> <object> <stage><TAB><path>` as `git ls-files -s` prints them;
#   - a shell script is a regular file (mode 100644 or 100755) whose path ends in `.sh`;
#     a symbolic link (120000) is not one;
#   - exit 0: every shell script has mode 100755; prints how many were checked;
#   - exit 1: at least one has not; prints each path with the command that fixes it;
#   - exit 2: usage error, an unreadable file, a line in another format, or a listing without
#     any shell script (an empty or failed `git ls-files` must never pass).
# Side effects: none; reads its input only.
set -euo pipefail

if [ "$#" -gt 1 ]; then
  echo "usage: git ls-files -s | $0   or   $0 <listing file>" >&2
  exit 2
fi
source_file="${1:--}"
if [ "${source_file}" != "-" ] && [ ! -r "${source_file}" ]; then
  echo "check-file-modes: cannot read ${source_file}" >&2
  exit 2
fi

total=0
missing=()
line_number=0
while IFS= read -r line || [ -n "${line}" ]; do
  line_number=$((line_number + 1))
  [ -n "${line}" ] || continue
  # `<mode> <object> <stage>` and the path are separated by one TAB; the path may hold blanks.
  if [[ ! "${line}" =~ ^([0-7]{6})\ [0-9a-f]{40,64}\ [0-3]$'\t'(.+)$ ]]; then
    echo "check-file-modes: line ${line_number} is not in the format of git ls-files -s" >&2
    exit 2
  fi
  mode="${BASH_REMATCH[1]}"
  path="${BASH_REMATCH[2]}"
  case "${path}" in
    *.sh) ;;
    *) continue ;;
  esac
  case "${mode}" in
    100755) total=$((total + 1)) ;;
    100644)
      total=$((total + 1))
      missing+=("${path}")
      ;;
    *) ;; # a symbolic link or a submodule entry is not a script file
  esac
done < <(if [ "${source_file}" = "-" ]; then cat; else cat -- "${source_file}"; fi)

if [ "${total}" -eq 0 ]; then
  echo "check-file-modes: no shell script in the listing; pass the output of git ls-files -s" >&2
  exit 2
fi

noun="shell scripts"
if [ "${total}" -eq 1 ]; then noun="shell script"; fi

if [ "${#missing[@]}" -gt 0 ]; then
  echo "check-file-modes: ${#missing[@]} of ${total} ${noun} lack the execute bit in git:"
  for path in "${missing[@]}"; do
    echo "  ${path}"
    echo "    fix: git update-index --chmod=+x -- '${path}'"
  done
  exit 1
fi
echo "check-file-modes: ${total} ${noun}, all recorded as executable"
