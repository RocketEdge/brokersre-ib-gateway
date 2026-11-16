# Lists every path inside a container that a documented `docker exec` or `docker compose ...
# exec` command passes as an argument, and says whether Git Bash would rewrite it. Used by
# doc-commands.bats.
#
#   awk -f doc-exec-paths.awk FILE...
#
# Output, one line per path: FILE:LINE:ok:TOKEN or FILE:LINE:bad:TOKEN. Git Bash (MSYS) turns
# an argument that starts with one `/`, or a NAME=/... assignment, into a Windows path
# (`/var/log/x` reaches the container as `C:/Program Files/Git/var/log/x`); an argument that
# starts with `//` passes unchanged, and Linux reads `//var` as `/var`. So `//...` is ok and
# `/...` is bad.
#
# What it reads: from each `docker ` on a line up to the next backtick (the end of inline
# code) or the end of the line, the words after ` exec `, cut at the first `|`, `;`, `&`, `<`
# or `>` (what follows runs on the host, not in the container). Lines inside a powershell
# fence are skipped: PowerShell passes arguments unchanged. A command wrapped onto the next
# line is not seen; keep documented exec commands on one line. POSIX awk (mawk and gawk).

FNR == 1 {
  fence = ""
}

/^[ \t]*```/ {
  if (fence == "") {
    language = $0
    sub(/^[ \t]*```[ \t]*/, "", language)
    sub(/[ \t].*$/, "", language)
    fence = (language == "") ? "plain" : language
  } else {
    fence = ""
  }
  next
}

fence == "powershell" || fence == "pwsh" || fence == "ps1" {
  next
}

{
  rest = $0
  while ((start = index(rest, "docker ")) > 0) {
    rest = substr(rest, start + 7)
    command = rest
    tick = index(command, "`")
    if (tick > 0) {
      command = substr(command, 1, tick - 1)
    }
    at = index(" " command, " exec ")
    if (at == 0) {
      continue
    }
    arguments = substr(" " command, at + 6)
    cut = match(arguments, /[|;&<>]/)
    if (cut > 0) {
      arguments = substr(arguments, 1, cut - 1)
    }
    count = split(arguments, words, /[ \t]+/)
    for (i = 1; i <= count; i++) {
      word = words[i]
      gsub(/^["'(]+/, "", word)
      gsub(/["'.,:)]+$/, "", word)
      if (word ~ /^\/\/[A-Za-z]/) {
        print FILENAME ":" FNR ":ok:" word
      } else if (word ~ /^\/[A-Za-z]/ || word ~ /^[A-Za-z_][A-Za-z0-9_]*=\/[A-Za-z]/) {
        print FILENAME ":" FNR ":bad:" word
      }
    }
  }
}
