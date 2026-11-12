#!/usr/bin/env bash
# Keep one tracking issue per channel while its published image has a fixable CRITICAL/HIGH
# finding in OS packages.
#
# Purpose: rebuild.yml scans the published images every day. A finding must be visible to
# people (an issue that names the CVE ids), but a job that runs daily must not open an issue a
# day or post a comment a day. This script is the one place that decides create / rewrite /
# close, so the rule is testable with a stub `gh` (tests/bats/ci/rebuild-issue.bats).
#
# Contract:
#   rebuild-issue.sh <channel> <action> <cves> <image-ref>
#   channel        stable | latest
#   action, cves   the two values printed by scripts/rebuild-decision.sh: `rebuild` with a
#                  comma-separated id list, or `none` with an empty list
#   image-ref      the image that was scanned, by digest: <registry>/<repository>@sha256:<64 hex>
#   GH_TOKEN       token with `issues: write` on the repository
#   GITHUB_REPOSITORY   owner/name of the repository that holds the issues
#   RUN_URL        optional: link to the workflow run, added to the issue text
#   stdout         one line saying what was done
#   exit           0 done, 2 bad input (nothing was written), other: `gh` failed (the workflow
#                  run then fails, which is how a broken token becomes visible)
#
# Behaviour (the channel's issue is the OPEN issue labelled `os-vulnerability` and
# `channel:<channel>`):
#   rebuild, no open issue   create it (the two labels are created first when missing; an
#                            existing label is left as it is)
#   rebuild, open issue      rewrite its text with today's ids and image: no second issue and
#                            no comment, so watchers are not notified every day
#   none, open issue         close it with a comment naming the image that scanned clean
#   none, no open issue      nothing
# After a close, a later finding opens a new issue: closed issues are history, not state.
# Side effects: GitHub issues and labels of GITHUB_REPOSITORY, through `gh`.
set -euo pipefail

usage() {
  echo "usage: rebuild-issue.sh <stable|latest> <none|rebuild> <cves> <image@sha256:digest>" >&2
  exit 2
}

refuse() {
  echo "rebuild-issue: $1" >&2
  exit 2
}

[ $# -eq 4 ] || usage
channel="$1"
action="$2"
cves="$3"
image_ref="$4"

case "${channel}" in
  stable | latest) ;;
  *) refuse "unknown channel '${channel}' (expected stable or latest)" ;;
esac
# The ids and the reference end up in Markdown that anyone can read: plain tokens only.
[[ "${cves}" =~ ^[A-Za-z0-9._:,-]*$ ]] || refuse "the id list may hold only letters, digits and . _ : , -"
[[ "${image_ref}" =~ ^[a-z0-9][a-z0-9./_-]*@sha256:[0-9a-f]{64}$ ]] || refuse "'${image_ref}' is not an image reference by digest"
case "${action}" in
  rebuild) [ -n "${cves}" ] || refuse "action rebuild needs at least one vulnerability id" ;;
  none) [ -z "${cves}" ] || refuse "action none must come with an empty id list" ;;
  *) refuse "unknown action '${action}' (expected none or rebuild)" ;;
esac
[ -n "${GH_TOKEN:-}" ] || refuse "GH_TOKEN is required (issues: write)"
[ -n "${GITHUB_REPOSITORY:-}" ] || refuse "GITHUB_REPOSITORY is required"

repo="${GITHUB_REPOSITORY}"
label="os-vulnerability"
channel_label="channel:${channel}"
now="$(date -u '+%Y-%m-%d %H:%M UTC')"
run_note=""
if [[ "${RUN_URL:-}" =~ ^https://[A-Za-z0-9./_-]+$ ]]; then run_note=" ([workflow run](${RUN_URL}))"; fi

number="$(gh issue list -R "${repo}" --state open --label "${label}" --label "${channel_label}" --json number --jq '.[0].number // empty')"
[[ "${number}" =~ ^[0-9]*$ ]] || refuse "unexpected issue number from gh"

if [ "${action}" = none ]; then
  if [ -z "${number}" ]; then
    echo "rebuild-issue: ${channel}: no finding and no open issue; nothing to do"
    exit 0
  fi
  gh issue close "${number}" -R "${repo}" --reason completed \
    --comment "The daily scan of ${now}${run_note} found no CRITICAL or HIGH vulnerability with a fixed package in the OS packages of \`${image_ref}\`, the image the \`${channel}\` tag points at. Closing; a later finding opens a new issue." >/dev/null
  echo "rebuild-issue: ${channel}: closed #${number} (the published image scans clean)"
  exit 0
fi

body="$(printf '%s\n\n%s\n%s\n%s\n\n%s\n\n%s\n' \
  "The daily scan found CRITICAL or HIGH vulnerabilities in the OS packages of the published \`${channel}\` image for which a fixed package exists." \
  "- Image scanned: \`${image_ref}\`" \
  "- Vulnerability ids: \`${cves//,/\`, \`}\`" \
  "- Last scan: ${now}${run_note}" \
  "What happens next: the same workflow run requests an OS-patch rebuild of this channel (\`publish.yml\` with \`rebuild=true\`). If the rebuilt image passes the scan it is published with a \`-rYYYYMMDD\` tag and a release, and the next daily scan closes this issue. If the rebuild's scan still fails, nothing is published, this issue stays open and is rewritten every day, and a person decides what to do. Images are pinned by digest, so nothing a consumer runs changes until they move their pin (docs/upgrade-policy.md)." \
  "This text is rewritten in place by \`scripts/rebuild-issue.sh\`; there is one open issue per channel.")"

if [ -n "${number}" ]; then
  gh issue edit "${number}" -R "${repo}" --body "${body}" >/dev/null
  echo "rebuild-issue: ${channel}: rewrote #${number} (${cves})"
  exit 0
fi

# `gh issue create --label` fails on a label that does not exist. Without --force an existing
# label makes `gh label create` fail, which is fine: its colour and description stay untouched.
gh label create "${label}" -R "${repo}" --color D93F0B \
  --description "A published image has a fixable CRITICAL/HIGH finding in OS packages (rebuild.yml)" >/dev/null 2>&1 || true
gh label create "${channel_label}" -R "${repo}" >/dev/null 2>&1 || true
url="$(gh issue create -R "${repo}" --title "Fixable OS vulnerabilities in the published ${channel} image" \
  --label "${label}" --label "${channel_label}" --body "${body}")"
echo "rebuild-issue: ${channel}: opened ${url} (${cves})"
