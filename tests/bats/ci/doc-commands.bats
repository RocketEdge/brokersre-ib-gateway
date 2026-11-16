#!/usr/bin/env bats
# Runs the documentation's copy-paste commands the way a reader runs them. Needs bash, awk and,
# for the secret blocks, python3, zsh and sh (the lint job of ci.yml installs zsh):
#   tests/.bats-core/bin/bats tests/bats/ci/doc-commands.bats
#
# 1. Secret blocks. Every block in which a person types a secret into a POSIX shell is marked
#    in its Markdown file with the HTML comment in MARKER below. Each is extracted
#    (doc-block.awk) and run under bash, zsh (the macOS default shell) and sh through a real
#    pseudo-terminal (pty-answers.py) with synthetic answers that carry blanks at both ends, a
#    backslash before `n` and a percent sign. The written files must hold exactly the typed
#    bytes, and a password must never appear on the terminal. Found on 2026-11-16 with a real
#    paper login: `read -r` without `IFS=` dropped the blanks of a password, and
#    `read -r -s -p` failed in zsh (`read: -p: no coprocess`) without writing a file.
# 2. Container paths. Git Bash, which the README names for Windows, rewrites an argument that
#    starts with one `/` into a Windows path, so `docker compose ... exec ib-gateway cat
#    /var/log/...` failed there; the documented form is `//var/log/...` (doc-exec-paths.awk).
#
# Outside GitHub Actions a missing python3, zsh or sh skips the secret-block tests (the image
# that runs this suite on a development host has none of the first two); on the runner it fails
# them, so CI cannot pass by skipping.

bats_require_minimum_version 1.5.0 # `run !`

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  EXTRACT="${BATS_TEST_DIRNAME}/doc-block.awk"
  EXEC_PATHS="${BATS_TEST_DIRNAME}/doc-exec-paths.awk"
  DRIVER="${BATS_TEST_DIRNAME}/pty-answers.py"
  MARKER='<!-- tested by tests/bats/ci/doc-commands.bats -->'
  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/cwd"
  # Synthetic values only: this repository is public. A read without IFS= drops the outer
  # blanks, a read without -r drops the backslash, and printf "$p" would turn \n into a
  # newline and %d into a number.
  local backslash='\'
  USERNAME=" synthetic.user "
  PASSWORD="  pw-SYNTH ${backslash}n%d end  "
  LIVE_USERNAME=" live.synthetic "
  LIVE_PASSWORD="  live-PW ${backslash}n%d x  "
  PAPER_USERNAME=" paper.synthetic "
  PAPER_PASSWORD="  paper-PW ${backslash}t%s y  "
  VNC_PASSWORD="  vnc-PW ${backslash}n%d  "
  LOKI_PASSWORD="  loki-PW ${backslash}n%d  "
}

teardown() {
  rm -rf "${WORK}"
}

# require_command NAME: succeed when NAME is installed; otherwise skip the test, except on
# GitHub Actions, where a missing tool fails it.
require_command() {
  if command -v "$1" >/dev/null 2>&1; then
    return 0
  fi
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    echo "$1 is not installed on the runner; the lint job of ci.yml installs it"
    return 1
  fi
  skip "$1 is not installed here; the lint job of ci.yml runs this test"
}

# run_block DOC SHELL [--answer PROMPT shown|hidden VALUE]...: extract the marked block of
# DOC (relative to the repository root) and run it under SHELL in ${WORK}/cwd through a pty,
# typing the answers in order. Fails, printing the driver's findings, when a check fails.
run_block() {
  local doc="$1" shell="$2"
  shift 2
  require_command python3
  require_command "${shell}"
  awk -v marker="${MARKER}" -f "${EXTRACT}" "${ROOT}/${doc}" >"${WORK}/block.sh"
  run python3 "${DRIVER}" --shell "${shell}" --script "${WORK}/block.sh" --cwd "${WORK}/cwd" "$@"
  echo "${output}"
  [ "${status}" -eq 0 ]
}

# assert_file_bytes PATH VALUE: PATH (relative to ${WORK}/cwd) holds exactly VALUE, without a
# newline added or a byte removed.
assert_file_bytes() {
  printf '%s' "$2" >"${WORK}/expected"
  if ! cmp "${WORK}/expected" "${WORK}/cwd/$1"; then
    echo "expected $1: $(od -c "${WORK}/expected")"
    echo "actual $1: $(od -c "${WORK}/cwd/$1" 2>&1)"
    return 1
  fi
}

# markdown_files: every Markdown file of the repository, without tools, caches and build
# output that may lie in a working tree.
markdown_files() {
  find "${ROOT}" \( -name .git -o -name .bats-core -o -name node_modules -o -name .venv \
    -o -name bin -o -name obj -o -name '.*_cache' \) -prune -o -type f -name '*.md' -print
}

quick_start() {
  run_block README.md "$1" \
    --answer 'IBKR username: ' shown "${USERNAME}" \
    --answer 'IBKR password: ' hidden "${PASSWORD}"
  assert_file_bytes compose/secrets/ib-username "${USERNAME}"
  assert_file_bytes compose/secrets/ib-password "${PASSWORD}"
}

several_gateways() {
  run_block compose/README.md "$1" \
    --answer 'IBKR username for live: ' shown "${LIVE_USERNAME}" \
    --answer 'IBKR password for live: ' hidden "${LIVE_PASSWORD}" \
    --answer 'IBKR username for paper: ' shown "${PAPER_USERNAME}" \
    --answer 'IBKR password for paper: ' hidden "${PAPER_PASSWORD}"
  assert_file_bytes compose/secrets/live/ib-username "${LIVE_USERNAME}"
  assert_file_bytes compose/secrets/live/ib-password "${LIVE_PASSWORD}"
  assert_file_bytes compose/secrets/paper/ib-username "${PAPER_USERNAME}"
  assert_file_bytes compose/secrets/paper/ib-password "${PAPER_PASSWORD}"
}

console_password() {
  # The console page follows the quick start, which created compose/secrets.
  mkdir -p "${WORK}/cwd/compose/secrets"
  run_block docs/console.md "$1" --answer 'VNC password: ' hidden "${VNC_PASSWORD}"
  assert_file_bytes compose/secrets/vnc-password "${VNC_PASSWORD}"
}

loki_password() {
  run_block docs/recipes/README.md "$1" --answer 'Loki password: ' hidden "${LOKI_PASSWORD}"
  assert_file_bytes compose/secrets/vector/loki_password "${LOKI_PASSWORD}"
}

@test "each document with a secret block marks exactly one, and no other document has one" {
  local doc
  for doc in README.md compose/README.md docs/console.md docs/recipes/README.md; do
    [ "$(grep -c -F -- "${MARKER}" "${ROOT}/${doc}")" -eq 1 ] || {
      echo "${doc}: expected one marker"
      false
    }
  done
  [ "$(markdown_files | xargs grep -l -F -- "${MARKER}" | wc -l)" -eq 4 ]
}

@test "doc-block.awk refuses a marker without a block instead of printing nothing" {
  printf '%s\n' '# Title' '' "${MARKER}" '' 'text, not a fence' >"${WORK}/doc.md"
  run awk -v marker="${MARKER}" -f "${EXTRACT}" "${WORK}/doc.md"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"not a code fence"* ]]
}

@test "doc-block.awk prints an indented block without its indentation" {
  printf '%s\n' '1. Step:' '' "   ${MARKER}" '' '   ```sh' '   echo one' '     echo two' '   ```' \
    >"${WORK}/doc.md"
  run awk -v marker="${MARKER}" -f "${EXTRACT}" "${WORK}/doc.md"
  [ "${status}" -eq 0 ]
  [ "${output}" == $'echo one\n  echo two' ]
}

@test "README quick start secret block in bash: exact bytes, password never shown" {
  quick_start bash
}

@test "README quick start secret block in zsh: exact bytes, password never shown" {
  quick_start zsh
}

@test "README quick start secret block in sh: exact bytes, password never shown" {
  quick_start sh
}

@test "compose/README.md secret block in bash: exact bytes, passwords never shown" {
  several_gateways bash
}

@test "compose/README.md secret block in zsh: exact bytes, passwords never shown" {
  several_gateways zsh
}

@test "compose/README.md secret block in sh: exact bytes, passwords never shown" {
  several_gateways sh
}

@test "docs/console.md VNC password block in bash: exact bytes, password never shown" {
  console_password bash
}

@test "docs/console.md VNC password block in zsh: exact bytes, password never shown" {
  console_password zsh
}

@test "docs/console.md VNC password block in sh: exact bytes, password never shown" {
  console_password sh
}

@test "docs/recipes/README.md Loki password block in bash: exact bytes, password never shown" {
  loki_password bash
}

@test "docs/recipes/README.md Loki password block in zsh: exact bytes, password never shown" {
  loki_password zsh
}

@test "docs/recipes/README.md Loki password block in sh: exact bytes, password never shown" {
  loki_password sh
}
