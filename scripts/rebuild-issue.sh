#!/usr/bin/env bash
# Keep one tracking issue per channel while its published image has a fixable CRITICAL/HIGH
# finding in OS packages, and decide whether today's run requests a rebuild.
#
# Purpose: rebuild.yml scans the published images every day. Three things must hold, and this
# script is the one place that decides them, so they are testable with a stub `gh`
# (tests/bats/ci/rebuild-issue.bats):
#   * a finding is visible to people as ONE issue per channel that names the CVE ids;
#   * when a requested rebuild does not publish (its own scan fails), people hear about it:
#     an issue whose text is rewritten sends no notification, so each further day with the
#     same published image adds exactly one comment;
#   * a rebuild that keeps failing is not requested for ever: every request is a full
#     two-platform build that leaves an untagged image in the registry when its gate fails.
#     After REBUILD_MAX_ATTEMPTS days with the same image the requests stop and the comments
#     say that a person must decide.
#
# Contract:
#   rebuild-issue.sh <channel> <action> <cves> <image-ref>
#   channel        stable | latest
#   action, cves   the two values printed by scripts/rebuild-decision.sh: `rebuild` with a
#                  comma-separated id list, or `none` with an empty list
#   image-ref      the image that was scanned, by digest: <registry>/<repository>@sha256:<64 hex>
#   GH_TOKEN       token with `issues: write` on the repository
#   GITHUB_REPOSITORY   owner/name of the repository that holds the issues
#   RUN_URL        optional: https link to the workflow run, added to the texts
#   REBUILD_MAX_ATTEMPTS   optional: on how many consecutive days with the same published image
#                  a rebuild is requested (1 to 99, default 3)
#   stdout         two lines, GITHUB_OUTPUT-ready:
#                    request=true|false           request a rebuild of this channel now
#                    <channel>=rebuild|none       the same decision under the channel's name
#                                                 (a matrix job needs one output name per leg)
#   stderr         one line saying what was done
#   exit           0 done, 2 bad input (nothing was written), other: `gh` failed. Nothing is
#                  printed on stdout then, so no rebuild is requested, and the workflow run
#                  fails, which is how a broken token becomes visible.
#
# Behaviour (the channel's issue is the OPEN issue labelled `os-vulnerability` and
# `channel:<channel>`; its text ends in a state line
# `<!-- rebuild-state digest=<digest> days=<n> last=<YYYY-MM-DD> -->`):
#   rebuild, no open issue        create it with days=1 (the two labels are created first when
#                                 missing; an existing label is left as it is); request
#   rebuild, open issue for another image, or without a readable state line
#                                 the published image changed (or the issue predates the state
#                                 line): rewrite the text with days=1; no comment; request
#   rebuild, same image, same day rewrite the text, state unchanged; no comment; no request
#                                 (one request and at most one comment per day and channel)
#   rebuild, same image, new day  the rebuild requested before did not publish: days+1, rewrite
#                                 the text, then ONE comment. Request while days is at most
#                                 REBUILD_MAX_ATTEMPTS; after that no request, and the comment
#                                 says so and how to start again
#   none, open issue              close it with a comment naming the image that scanned clean
#   none, no open issue           nothing
# After a close, a later finding opens a new issue: closed issues are history, not state. The
# state is written before the comment is posted: if the comment fails, the run fails and the
# day has no comment, but a re-run can never post a second one.
# Side effects: GitHub issues and labels of GITHUB_REPOSITORY, through `gh`. Reads the clock
# (UTC) once.
set -euo pipefail

usage() {
  echo "usage: rebuild-issue.sh <stable|latest> <none|rebuild> <cves> <image@sha256:digest>" >&2
  exit 2
}

refuse() {
  echo "rebuild-issue: $1" >&2
  exit 2
}

# decide REQUEST: print the two output lines.
decide() {
  local request="$1" word=none
  if [ "${request}" = true ]; then word=rebuild; fi
  printf 'request=%s\n%s=%s\n' "${request}" "${channel}" "${word}"
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
max_days="${REBUILD_MAX_ATTEMPTS:-3}"
[[ "${max_days}" =~ ^[1-9][0-9]?$ ]] || refuse "REBUILD_MAX_ATTEMPTS must be a number from 1 to 99 (got '${max_days}')"
[ -n "${GH_TOKEN:-}" ] || refuse "GH_TOKEN is required (issues: write)"
[ -n "${GITHUB_REPOSITORY:-}" ] || refuse "GITHUB_REPOSITORY is required"

repo="${GITHUB_REPOSITORY}"
label="os-vulnerability"
channel_label="channel:${channel}"
digest="${image_ref##*@}"
now="$(date -u '+%Y-%m-%d %H:%M UTC')"
today="${now%% *}"
run_note=""
if [[ "${RUN_URL:-}" =~ ^https://[A-Za-z0-9./_-]+$ ]]; then run_note=" ([workflow run](${RUN_URL}))"; fi
ids_text="\`${cves//,/\`, \`}\`"

number="$(gh issue list -R "${repo}" --state open --label "${label}" --label "${channel_label}" --json number --jq '.[0].number // empty')"
[[ "${number}" =~ ^[0-9]*$ ]] || refuse "unexpected issue number from gh"

if [ "${action}" = none ]; then
  if [ -z "${number}" ]; then
    echo "rebuild-issue: ${channel}: no finding and no open issue; nothing to do" >&2
  else
    gh issue close "${number}" -R "${repo}" --reason completed \
      --comment "The daily scan of ${now}${run_note} found no CRITICAL or HIGH vulnerability with a fixed package in the OS packages of \`${image_ref}\`, the image the \`${channel}\` tag points at. Closing; a later finding opens a new issue." >/dev/null
    echo "rebuild-issue: ${channel}: closed #${number} (the published image scans clean)" >&2
  fi
  decide false
  exit 0
fi

# State of the open issue: for how many days the same published image has had a finding.
days=1
previous_day=""
same_day=false
if [ -n "${number}" ]; then
  old_text="$(gh issue view "${number}" -R "${repo}" --json body --jq '.body')"
  state_re='<!-- rebuild-state digest=(sha256:[0-9a-f]{64}) days=([0-9]{1,4}) last=([0-9]{4}-[0-9]{2}-[0-9]{2}) -->'
  if [[ "${old_text}" =~ ${state_re} ]] && [ "${BASH_REMATCH[1]}" = "${digest}" ]; then
    previous_day="${BASH_REMATCH[3]}"
    # 10# : a count written with leading zeros is still decimal.
    days=$((10#${BASH_REMATCH[2]}))
    if [ "${previous_day}" = "${today}" ]; then same_day=true; else days=$((days + 1)); fi
  fi
fi

body="$(printf '%s\n\n%s\n%s\n%s\n%s\n\n%s\n\n%s\n%s\n' \
  "The daily scan found CRITICAL or HIGH vulnerabilities in the OS packages of the published \`${channel}\` image for which a fixed package exists." \
  "- Image scanned: \`${image_ref}\`" \
  "- Vulnerability ids: ${ids_text}" \
  "- Last scan: ${now}${run_note}" \
  "- Days with this image and a finding: ${days} (a rebuild is requested on each of the first ${max_days})" \
  "What happens next: on each of the first ${max_days} days the daily scan requests an OS-patch rebuild of this channel (\`publish.yml\` with \`rebuild=true\`). If a rebuilt image passes the scan it is published with a \`-rYYYYMMDD\` tag and a release, and the next daily scan closes this issue. While the published image stays the same, the scan adds one comment a day here; after ${max_days} days it stops requesting rebuilds and a person decides what to do. Images are pinned by digest, so nothing a consumer runs changes until they move their pin (docs/upgrade-policy.md)." \
  "This text is rewritten in place by \`scripts/rebuild-issue.sh\`; there is one open issue per channel. Do not edit the last line: it is the state the next scan reads." \
  "<!-- rebuild-state digest=${digest} days=${days} last=$(if [ "${same_day}" = true ]; then printf '%s' "${previous_day}"; else printf '%s' "${today}"; fi) -->")"

if [ -z "${number}" ]; then
  # `gh issue create --label` fails on a label that does not exist. Without --force an existing
  # label makes `gh label create` fail, which is fine: its colour and description stay untouched.
  gh label create "${label}" -R "${repo}" --color D93F0B \
    --description "A published image has a fixable CRITICAL/HIGH finding in OS packages (rebuild.yml)" >/dev/null 2>&1 || true
  gh label create "${channel_label}" -R "${repo}" >/dev/null 2>&1 || true
  url="$(gh issue create -R "${repo}" --title "Fixable OS vulnerabilities in the published ${channel} image" \
    --label "${label}" --label "${channel_label}" --body "${body}")"
  echo "rebuild-issue: ${channel}: opened ${url} (${cves}); requesting rebuild 1 of ${max_days}" >&2
  decide true
  exit 0
fi

gh issue edit "${number}" -R "${repo}" --body "${body}" >/dev/null

if [ "${same_day}" = true ]; then
  echo "rebuild-issue: ${channel}: #${number} was already handled today (day ${days}); no comment, no request" >&2
  decide false
  exit 0
fi

if [ -z "${previous_day}" ]; then
  echo "rebuild-issue: ${channel}: rewrote #${number} for a new image (${cves}); requesting rebuild 1 of ${max_days}" >&2
  decide true
  exit 0
fi

if [ "${days}" -le "${max_days}" ]; then
  gh issue comment "${number}" -R "${repo}" \
    --body "Day ${days}: the \`${channel}\` tag still points at \`${image_ref}\`, so the rebuild requested on ${previous_day} did not publish (its own scan failed, or the run failed: see the \`publish.yml\` runs). Findings today: ${ids_text}. Requesting rebuild ${days} of ${max_days} now${run_note}." >/dev/null
  echo "rebuild-issue: ${channel}: #${number} day ${days}: commented; requesting rebuild ${days} of ${max_days}" >&2
  decide true
  exit 0
fi

requests_word="requests"
if [ "${max_days}" -eq 1 ]; then requests_word="request"; fi
gh issue comment "${number}" -R "${repo}" \
  --body "Day ${days}: the \`${channel}\` tag still points at \`${image_ref}\` and ${max_days} rebuild ${requests_word} did not publish. No further rebuild is requested automatically. Findings today: ${ids_text}. A person needs to look at the failed \`publish.yml\` runs and decide: wait for the fixed package to become installable, or accept the finding. To try again, run \`publish.yml\` with \`rebuild=true\` and \`channels=${channel}\`, or close this issue: the next daily scan then opens a new one and starts over${run_note}." >/dev/null
echo "rebuild-issue: ${channel}: #${number} day ${days}: commented; no rebuild requested (limit ${max_days} reached)" >&2
decide false
