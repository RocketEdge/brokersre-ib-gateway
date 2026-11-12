#!/usr/bin/env bats
# Unit tests for scripts/check-file-modes.sh: every tracked shell script carries the execute
# bit in git.
# Runs wherever bash 5 exists:
#   tests/.bats-core/bin/bats tests/bats/ci
#
# The contract under test: the unit suite runs the scripts from the checked-out tree, so the
# mode git recorded is the mode a Linux runner executes with. A development host on Windows
# records 100644 for a new file and shows it as executable anyway, so a script without the bit
# passes every local run and fails the first Linux one with "Permission denied". The check
# reads `git ls-files -s` (from a file or stdin), which is the same on every host.

bats_require_minimum_version 1.5.0 # `run --separate-stderr`

setup() {
  REPO="${BATS_TEST_DIRNAME}/../../.."
  SCRIPT="${REPO}/scripts/check-file-modes.sh"
  WORK="$(mktemp -d)"
  SHA="9411b6d766b3b18e883a58628c380edec36a3787"
}

teardown() {
  rm -rf "${WORK}"
}

# listing MODE PATH [MODE PATH ...]: print lines in the format of `git ls-files -s`.
listing() {
  while [ "$#" -ge 2 ]; do
    printf '%s %s 0\t%s\n' "$1" "${SHA}" "$2"
    shift 2
  done
}

@test "every shell script executable: exit 0 and the number of scripts checked" {
  listing 100755 scripts/a.sh 100755 rootfs/usr/local/lib/brokersre/b.sh 100644 README.md >"${WORK}/in"
  run "$SCRIPT" "${WORK}/in"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 shell scripts"* ]]
}

@test "a shell script without the execute bit: exit 1, its path and the command that fixes it" {
  listing 100755 scripts/a.sh 100644 rootfs/usr/local/lib/brokersre/screenshot.sh >"${WORK}/in"
  run "$SCRIPT" "${WORK}/in"
  [ "$status" -eq 1 ]
  [[ "$output" == *"rootfs/usr/local/lib/brokersre/screenshot.sh"* ]]
  [[ "$output" == *"git update-index --chmod=+x"* ]]
  [[ "$output" != *"scripts/a.sh"* ]]
}

@test "every script without the bit is named, not only the first" {
  listing 100644 scripts/one.sh 100755 scripts/two.sh 100644 tests/three.sh >"${WORK}/in"
  run "$SCRIPT" "${WORK}/in"
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/one.sh"* ]]
  [[ "$output" == *"tests/three.sh"* ]]
  [[ "$output" == *"2 of 3"* ]]
}

@test "files that are not shell scripts may have any mode" {
  listing 100755 scripts/a.sh 100644 docs/notes.md 100644 tests/bats/unit/x.bats 100644 sidecar/src/app.py >"${WORK}/in"
  run "$SCRIPT" "${WORK}/in"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 shell script"* ]]
}

@test "a path with a blank is read whole" {
  listing 100755 scripts/a.sh 100644 "docs/my notes/run me.sh" >"${WORK}/in"
  run "$SCRIPT" "${WORK}/in"
  [ "$status" -eq 1 ]
  [[ "$output" == *"docs/my notes/run me.sh"* ]]
}

@test "a symbolic link to a script is not a script file" {
  listing 100755 scripts/a.sh 120000 bin/link.sh >"${WORK}/in"
  run "$SCRIPT" "${WORK}/in"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 shell script"* ]]
}

@test "the listing is read from stdin when no file is given" {
  run bash -c "printf '100644 %s 0\tscripts/a.sh\n' '${SHA}' | '${SCRIPT}'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/a.sh"* ]]
}

@test "an empty listing is an error, never a pass" {
  : >"${WORK}/in"
  run "$SCRIPT" "${WORK}/in"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no shell script"* ]]
}

@test "a listing without any shell script is an error, never a pass" {
  listing 100644 README.md 100644 docs/a.md >"${WORK}/in"
  run "$SCRIPT" "${WORK}/in"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no shell script"* ]]
}

@test "a line that is not in the format of git ls-files -s is an error" {
  printf 'scripts/a.sh\n' >"${WORK}/in"
  run "$SCRIPT" "${WORK}/in"
  [ "$status" -eq 2 ]
  [[ "$output" == *"git ls-files -s"* ]]
}

@test "a file that does not exist is a usage error" {
  run "$SCRIPT" "${WORK}/missing"
  [ "$status" -eq 2 ]
}

@test "this repository: every tracked shell script is executable (needs git and a checkout)" {
  if ! command -v git >/dev/null 2>&1 || ! git -C "${REPO}" rev-parse --git-dir >/dev/null 2>&1; then
    skip "no git checkout here (the image has no git); the lint job runs this on the runner"
  fi
  git -C "${REPO}" ls-files -s >"${WORK}/in"
  run "$SCRIPT" "${WORK}/in"
  [ "$status" -eq 0 ]
}
