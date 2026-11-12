# List the steps of a GitHub Actions workflow file as records the bats tests can assert on.
#
# Purpose: tests/bats/ci/workflows.bats keeps a few properties of the workflows in step (the
# gate flags, the pinned scanner version, actions pinned by commit, no expression pasted into a
# script). The tests must run where the other CI-script tests run: bash, awk and jq, inside the
# image, with no YAML parser. This program reads the files the way they are written in this
# repository: two-space indentation, `steps:` at four spaces, a step starting with `      - `.
# workflows.bats also asserts how many steps it finds, so a change of layout fails loudly
# instead of making every check pass on nothing.
#
# Usage: awk -f workflow-steps.awk <workflow.yml>
# Output: one line per fact, tab separated: <step number> <key> <value>
#   key is a step key (name, uses, id, if, continue-on-error, shell), `with.<input>`,
#   `env.<variable>`, or `run` (one record per line of the script, text as written).
#   Values lose surrounding quotes; a `uses` value keeps its trailing `# version` comment.
#   Comment lines outside a script are skipped.
function emit(key, value) {
  gsub(/^[ \t]+|[ \t]+$/, "", value)
  if (key != "run" && value ~ /^".*"$/) value = substr(value, 2, length(value) - 2)
  if (key != "run" && value ~ /^'.*'$/) value = substr(value, 2, length(value) - 2)
  printf "%d\t%s\t%s\n", step, key, value
}
function keyvalue(text, prefix,    colon, key, value) {
  colon = index(text, ":")
  if (colon == 0) return
  key = substr(text, 1, colon - 1)
  value = substr(text, colon + 1)
  gsub(/^[ \t]+|[ \t]+$/, "", value)
  if (prefix == "" && (key == "with" || key == "env") && value == "") { section = key; return }
  if (prefix == "" && key == "run") {
    if (value ~ /^[|>][-+]?$/) { section = "run" } else { section = ""; emit("run", value) }
    return
  }
  if (prefix == "") section = ""
  emit(prefix key, value)
}
BEGIN { step = 0; section = ""; in_steps = 0 }
{
  line = $0
  sub(/\r$/, "", line)
  # Indentation of the line (blank lines keep the current context: they occur inside scripts).
  if (line ~ /^[ \t]*$/) { if (section == "run") emit("run", ""); next }
  match(line, /^ */)
  indent = RLENGTH
  if (indent <= 4) {
    in_steps = (line ~ /^    steps:[ \t]*$/)
    section = ""
    next
  }
  if (!in_steps) next
  if (section == "run" && indent >= 10) { emit("run", substr(line, 11)); next }
  if (line ~ /^[ \t]*#/) next
  if (indent == 6 && substr(line, 7, 2) == "- ") {
    step++
    section = ""
    keyvalue(substr(line, 9), "")
    next
  }
  if (indent == 8) { keyvalue(substr(line, 9), ""); next }
  if (indent == 10 && (section == "with" || section == "env")) { keyvalue(substr(line, 11), section "."); next }
}
