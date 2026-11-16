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
#    Each block also runs the way a reader uses it: pasted in one write into an interactive
#    bash and zsh with bracketed paste off and on, and into an interactive sh (no bracketed
#    paste at all, like dash, busybox sh and macOS's bash 3.2); then the history must not hold
#    a password either. Found in the review of #37: without bracketed paste the first `read`
#    took the next pasted line, and the typed password ran as a command (on the screen and in
#    the history), unless the shell has read the whole block before it runs (a subshell
#    `( ... )` around it). And Ctrl-C at a password prompt must leave echo on and write no
#    password file (the subshell's `trap 'stty echo; exit 130' INT`).
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

# fresh_cwd: empty ${WORK}/cwd (where a block runs) and ${WORK}/home (an interactive shell's
# start-up file and history), so a test can run a block several times.
fresh_cwd() {
  rm -rf "${WORK}/cwd" "${WORK}/home"
  mkdir -p "${WORK}/cwd"
}

# run_block DOC SHELL MODE BRACKETED_PASTE [--answer PROMPT KIND VALUE]...: extract the marked
# block of DOC (relative to the repository root) and run it under SHELL in ${WORK}/cwd through
# a pty, answering the prompts in order. MODE `script` runs `SHELL block.sh`; MODE `paste`
# pastes the block in one write into an interactive SHELL whose bracketed paste is
# BRACKETED_PASTE (`on` or `off`; dash has none), as a reader copying it from the page does.
# Fails, printing the driver's findings, when a check fails.
run_block() {
  local doc="$1" shell="$2" mode="$3" bracketed="$4"
  shift 4
  require_command python3
  require_command "${shell}"
  awk -v marker="${MARKER}" -f "${EXTRACT}" "${ROOT}/${doc}" >"${WORK}/block.sh"
  run python3 "${DRIVER}" --shell "${shell}" --mode "${mode}" --bracketed-paste "${bracketed}" \
    --home "${WORK}/home" --script "${WORK}/block.sh" --cwd "${WORK}/cwd" "$@"
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

# exec_path_docs: the Markdown files whose exec commands must use the Git Bash-safe path.
# Left out: docs/changes.md and tasks/ (history, quoting commands as they were) and
# docs/evidence.md (commands recorded as run on 2026-11-12; it tells Git Bash users to export
# MSYS_NO_PATHCONV=1 instead, asserted below).
exec_path_docs() {
  markdown_files | grep -v -E '/(docs/changes\.md|docs/evidence\.md|tasks/[^/]*\.md)$'
}

# The four blocks. Each function takes SHELL [MODE [BRACKETED_PASTE]] (default: script) and
# checks the written files byte for byte; each *_interrupt function pastes the block into an
# interactive SHELL with bracketed paste on, presses Ctrl-C at the first password prompt, and
# checks that no password file was written (the driver checks that echo is on again).

quick_start() {
  fresh_cwd
  run_block README.md "$1" "${2:-script}" "${3:-off}" \
    --answer 'IBKR username: ' shown "${USERNAME}" \
    --answer 'IBKR password: ' hidden "${PASSWORD}"
  assert_file_bytes compose/secrets/ib-username "${USERNAME}"
  assert_file_bytes compose/secrets/ib-password "${PASSWORD}"
}

quick_start_interrupt() {
  fresh_cwd
  run_block README.md "$1" paste on \
    --answer 'IBKR username: ' shown "${USERNAME}" \
    --answer 'IBKR password: ' interrupt -
  [ ! -e "${WORK}/cwd/compose/secrets/ib-password" ]
}

several_gateways() {
  fresh_cwd
  run_block compose/README.md "$1" "${2:-script}" "${3:-off}" \
    --answer 'IBKR username for live: ' shown "${LIVE_USERNAME}" \
    --answer 'IBKR password for live: ' hidden "${LIVE_PASSWORD}" \
    --answer 'IBKR username for paper: ' shown "${PAPER_USERNAME}" \
    --answer 'IBKR password for paper: ' hidden "${PAPER_PASSWORD}"
  assert_file_bytes compose/secrets/live/ib-username "${LIVE_USERNAME}"
  assert_file_bytes compose/secrets/live/ib-password "${LIVE_PASSWORD}"
  assert_file_bytes compose/secrets/paper/ib-username "${PAPER_USERNAME}"
  assert_file_bytes compose/secrets/paper/ib-password "${PAPER_PASSWORD}"
}

several_gateways_interrupt() {
  fresh_cwd
  run_block compose/README.md "$1" paste on \
    --answer 'IBKR username for live: ' shown "${LIVE_USERNAME}" \
    --answer 'IBKR password for live: ' interrupt -
  [ ! -e "${WORK}/cwd/compose/secrets/live/ib-password" ]
  [ ! -e "${WORK}/cwd/compose/secrets/paper" ]
}

console_password() {
  fresh_cwd
  # The console page follows the quick start, which created compose/secrets.
  mkdir -p "${WORK}/cwd/compose/secrets"
  run_block docs/console.md "$1" "${2:-script}" "${3:-off}" \
    --answer 'VNC password: ' hidden "${VNC_PASSWORD}"
  assert_file_bytes compose/secrets/vnc-password "${VNC_PASSWORD}"
}

console_password_interrupt() {
  fresh_cwd
  mkdir -p "${WORK}/cwd/compose/secrets"
  run_block docs/console.md "$1" paste on --answer 'VNC password: ' interrupt -
  [ ! -e "${WORK}/cwd/compose/secrets/vnc-password" ]
}

loki_password() {
  fresh_cwd
  run_block docs/recipes/README.md "$1" "${2:-script}" "${3:-off}" \
    --answer 'Loki password: ' hidden "${LOKI_PASSWORD}"
  assert_file_bytes compose/secrets/vector/loki_password "${LOKI_PASSWORD}"
}

loki_password_interrupt() {
  fresh_cwd
  run_block docs/recipes/README.md "$1" paste on --answer 'Loki password: ' interrupt -
  [ ! -e "${WORK}/cwd/compose/secrets/vector/loki_password" ]
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

@test "README quick start block pasted into interactive bash without bracketed paste: exact bytes" {
  quick_start bash paste off
}

@test "README quick start block pasted into interactive zsh without bracketed paste: exact bytes" {
  quick_start zsh paste off
}

@test "README quick start block pasted into interactive sh: exact bytes, password never shown" {
  quick_start sh paste off
}

@test "README quick start block pasted with bracketed paste on (bash, zsh): exact bytes" {
  quick_start bash paste on
  quick_start zsh paste on
}

@test "README quick start block: Ctrl-C at the password prompt writes nothing, echo back on" {
  local shell
  for shell in bash zsh sh; do
    quick_start_interrupt "${shell}"
  done
}

@test "compose/README.md block pasted into interactive bash without bracketed paste: exact bytes" {
  several_gateways bash paste off
}

@test "compose/README.md block pasted into interactive zsh without bracketed paste: exact bytes" {
  several_gateways zsh paste off
}

@test "compose/README.md block pasted into interactive sh: exact bytes, passwords never shown" {
  several_gateways sh paste off
}

@test "compose/README.md block pasted with bracketed paste on (bash, zsh): exact bytes" {
  several_gateways bash paste on
  several_gateways zsh paste on
}

@test "compose/README.md block: Ctrl-C at the first password prompt writes nothing, echo back on" {
  local shell
  for shell in bash zsh sh; do
    several_gateways_interrupt "${shell}"
  done
}

@test "docs/console.md block pasted into interactive bash without bracketed paste: exact bytes" {
  console_password bash paste off
}

@test "docs/console.md block pasted into interactive zsh without bracketed paste: exact bytes" {
  console_password zsh paste off
}

@test "docs/console.md block pasted into interactive sh: exact bytes, password never shown" {
  console_password sh paste off
}

@test "docs/console.md block pasted with bracketed paste on (bash, zsh): exact bytes" {
  console_password bash paste on
  console_password zsh paste on
}

@test "docs/console.md block: Ctrl-C at the password prompt writes nothing, echo back on" {
  local shell
  for shell in bash zsh sh; do
    console_password_interrupt "${shell}"
  done
}

@test "docs/recipes/README.md block pasted into interactive bash without bracketed paste: exact bytes" {
  loki_password bash paste off
}

@test "docs/recipes/README.md block pasted into interactive zsh without bracketed paste: exact bytes" {
  loki_password zsh paste off
}

@test "docs/recipes/README.md block pasted into interactive sh: exact bytes, password never shown" {
  loki_password sh paste off
}

@test "docs/recipes/README.md block pasted with bracketed paste on (bash, zsh): exact bytes" {
  loki_password bash paste on
  loki_password zsh paste on
}

@test "docs/recipes/README.md block: Ctrl-C at the password prompt writes nothing, echo back on" {
  local shell
  for shell in bash zsh sh; do
    loki_password_interrupt "${shell}"
  done
}

@test "doc-exec-paths.awk tells the form Git Bash rewrites from the form it passes" {
  printf '%s\n' \
    'docker compose -f x.yml exec ib-gateway cat /var/log/ibgateway/state/phase' \
    'docker compose -f x.yml exec ib-gateway cat //var/log/ibgateway/state/phase' \
    '- Which volume: `docker compose ... exec ib-gateway df -h //var/log/ibgateway /home/ibgateway/Jts/settings`.' \
    'docker exec -e LOG_DIR=/tmp/x c true' \
    'docker exec c cat //var/log/x | grep y > /tmp/out' \
    '`docker compose ... logs ib-gateway` reads /var/log/ibgateway on the host' \
    '```powershell' \
    'docker exec c cat /var/log/ibgateway/state/phase' \
    '```' >"${WORK}/doc.md"
  run awk -f "${EXEC_PATHS}" "${WORK}/doc.md"
  [ "${status}" -eq 0 ]
  [ "${output}" == "$(printf '%s\n' \
    "${WORK}/doc.md:1:bad:/var/log/ibgateway/state/phase" \
    "${WORK}/doc.md:2:ok://var/log/ibgateway/state/phase" \
    "${WORK}/doc.md:3:ok://var/log/ibgateway" \
    "${WORK}/doc.md:3:bad:/home/ibgateway/Jts/settings" \
    "${WORK}/doc.md:4:bad:LOG_DIR=/tmp/x" \
    "${WORK}/doc.md:5:ok://var/log/x")" ]
}

@test "the README's exec commands, step 3 included, pass container paths that Git Bash leaves alone" {
  run awk -f "${EXEC_PATHS}" "${ROOT}/README.md"
  [ "${status}" -eq 0 ]
  echo "${output}"
  [[ "${output}" != *":bad:"* ]]
  [[ "${output}" == *"README.md:"*":ok://var/log/ibgateway/state/phase"* ]]
}

@test "no documented exec command passes a container path that Git Bash would rewrite" {
  local files
  mapfile -t files < <(exec_path_docs)
  [ "${#files[@]}" -gt 20 ]
  run awk -f "${EXEC_PATHS}" "${files[@]}"
  [ "${status}" -eq 0 ]
  run grep ':bad:' <<<"${output}"
  if [ "${status}" -eq 0 ]; then
    echo "Write these container paths with a leading // (Git Bash rewrites a leading /):"
    echo "${output}"
    false
  fi
}

@test "docs/evidence.md, whose commands are kept as run, tells Git Bash users to turn the rewriting off" {
  grep -F -- 'export MSYS_NO_PATHCONV=1' "${ROOT}/docs/evidence.md"
}
