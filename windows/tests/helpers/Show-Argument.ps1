# Test helper, run as a separate process: prints each argument it received as the hexadecimal
# code units of its characters, one argument per line (an empty argument prints an empty line).
# The calling test passes awkward arguments (spaces, quotes, trailing backslashes) through the
# kit's command runner and compares what arrived with what was sent.
foreach ($argument in $args) {
    (([string]$argument).ToCharArray() | ForEach-Object { ([int]$_).ToString('X4') }) -join ' '
}
exit 0
