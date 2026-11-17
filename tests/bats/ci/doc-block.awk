# Prints the fenced code block that follows a marker line in a Markdown file, without the
# fence lines and without the fence's own indentation (a block inside a list item is
# indented). Used by doc-commands.bats to run a copy-paste block exactly as a reader copies it.
#
#   awk -v marker='<!-- ... -->' -f doc-block.awk FILE > block.sh
#
# Contract: the marker occurs exactly once in FILE; only blank lines may stand between it and
# the opening fence (markdownlint wants a blank line before a fence). Exit 2, with the reason
# on standard error, when the marker is missing or repeated, when something else follows it,
# or when the block is never closed; nothing is printed then. POSIX awk (mawk in the image,
# gawk on the GitHub runner).

BEGIN {
  state = "search" # search -> after_marker -> in_block -> done
  markers = 0
  problem = ""
  lines = 0
}

index($0, marker) > 0 {
  markers++
  if (state == "search") {
    state = "after_marker"
  }
  next
}

state == "after_marker" && $0 ~ /^[ \t]*$/ {
  next
}

state == "after_marker" {
  if (match($0, /^[ \t]*```/)) {
    indent = RLENGTH - 3
    state = "in_block"
  } else if (problem == "") {
    problem = "line " NR " follows the marker and is not a code fence"
    state = "done"
  }
  next
}

state == "in_block" && $0 ~ /^[ \t]*```[ \t]*$/ {
  state = "done"
  next
}

state == "in_block" {
  block[++lines] = substr($0, indent + 1)
  next
}

END {
  if (markers != 1) {
    problem = "the marker occurs " markers " times, expected once"
  } else if (problem == "" && state != "done") {
    problem = "the block after the marker is missing or not closed"
  }
  if (problem != "") {
    print "doc-block.awk: " FILENAME ": " problem > "/dev/stderr"
    exit 2
  }
  for (i = 1; i <= lines; i++) {
    print block[i]
  }
}
