#!/usr/bin/env bash
# Turn the two per-channel decisions of the daily scan into one `channels` value for publish.yml.
#
# Purpose: rebuild.yml scans each channel in its own matrix leg; each leg reports `rebuild` or
# `none` (scripts/rebuild-issue.sh), and a leg that failed reports nothing. One job then asks
# publish.yml for a rebuild of exactly the channels that need it. Assembling that list is a
# decision (which channels, what when a leg failed, what when none), so it lives here with
# tests instead of in workflow shell.
#
# Contract:
#   rebuild-channels.sh <stable-decision> <latest-decision>
#   decision   `rebuild`, `none`, or empty (the leg did not report)
#   stdout     one line, GITHUB_OUTPUT-ready: channels=<stable|latest|stable latest>
#   exit       0 at least one channel is named
#              2 bad input, or no channel asked for a rebuild (message on stderr only). An
#                empty list is never printed: publish.yml reads an empty `channels` input as
#                "both channels", which would rebuild what nobody asked for.
#
# A leg without a report does not stop the other channel's rebuild; its own failure is already
# visible as a failed job.
# No side effects; reads nothing but its arguments.
set -euo pipefail

usage() {
  echo "usage: rebuild-channels.sh <rebuild|none|''> <rebuild|none|''>   (stable, then latest)" >&2
  exit 2
}

refuse() {
  echo "rebuild-channels: $1" >&2
  exit 2
}

[ $# -eq 2 ] || usage
channels=""
names=(stable latest)
for i in 0 1; do
  decision="$1"
  shift
  case "${decision}" in
    rebuild) channels="${channels:+${channels} }${names[i]}" ;;
    none | "") ;;
    *) refuse "unexpected decision for ${names[i]} (expected rebuild, none or empty)" ;;
  esac
done
[ -n "${channels}" ] || refuse "no channel asked for a rebuild; nothing to request"
printf 'channels=%s\n' "${channels}"
