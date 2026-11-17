#!/usr/bin/env bash
# Decide how much one run of detect-releases.yml does for one channel: the full check, or
# nothing beyond reading IBKR's version.json.
#
# Purpose: detect-releases.yml runs hourly (IBKR replaced stable 10.50.1g with 10.50.1h on
# 2026-11-16 between two daily runs, and every build of the pin failed until a human noticed).
# The full check downloads both installers of the channel (about 565 MB) to hash them; that is
# what finds a re-upload under the pinned label and what refreshes an open pull request. Doing
# it every hour would download about 27 GB a day from IBKR to learn nothing new. So an hourly
# run does the full check only at the FIRST SIGHT of a version: a label other than the pin for
# which no pull request was ever opened. Everything else stays with the daily full check, so
# ADR 0009 keeps its behaviour: a re-upload is found within a day, an open pull request is
# refreshed daily, and a closed one is opened again by the next daily run, not within the hour.
#
# Contract:
#   detect-scope.sh <check> <channel> <remote version> <pinned version>
#   check           full    the daily run (06:00 UTC) or a manual dispatch
#                   hourly  any other scheduled run
#   channel         stable | latest
#   remote version  the buildVersion IBKR's version.json announces, e.g. 10.50.1h
#   pinned version  versions.json's .channels.<channel>.version
#   stdout          two lines, GITHUB_OUTPUT-ready:
#                     scope=full|skip
#                     reason=<one line for the run log>
#   exit            0 decided; 1 the pull request lookup failed or answered something other
#                   than a count (a failed lookup is never read as "no pull request"); 2 bad
#                   input. On 1 and 2 nothing is printed on stdout and the message is on stderr.
#
# Side effects: for an hourly run that sees a label other than the pin, one read of GitHub:
#   gh pr list -R "$GITHUB_REPOSITORY" --head update-<channel>-to-<remote> --state all
#     --limit 100 --json number,headRepositoryOwner
# (open, closed and merged pull requests; the branch is the one detect-releases.yml opens its
# pull request from). Only pull requests whose branch is in this repository count: `--head`
# also matches a fork's branch of the same name. Needs gh with GH_TOKEN, GITHUB_REPOSITORY and
# jq, only then.
#
# Why the inputs are checked: the versions come from IBKR's server and reach a branch name and
# GITHUB_OUTPUT; anything but a plain IBKR build label, or a line break, is refused.
set -euo pipefail

# refuse MESSAGE: bad input; exit 2 with nothing on stdout.
refuse() {
  printf 'detect-scope: %s\n' "$1" >&2
  printf 'usage: detect-scope.sh full|hourly stable|latest <remote version> <pinned version>\n' >&2
  exit 2
}

# decide SCOPE REASON: print the decision and stop.
decide() {
  printf 'scope=%s\nreason=%s\n' "$1" "$2"
  exit 0
}

[ "$#" -eq 4 ] || refuse "expected 4 arguments, got $#"
check="$1"
channel="$2"
remote="$3"
pinned="$4"
version_pattern='^10\.[0-9]+\.[0-9]+[a-z]?$'
case "${check}" in full | hourly) ;; *) refuse "check must be full or hourly, got '${check}'" ;; esac
case "${channel}" in stable | latest) ;; *) refuse "channel must be stable or latest, got '${channel}'" ;; esac
# bash compiles the pattern without REG_NEWLINE: ^ and $ anchor the whole value, so a value
# with a line break in it (which would forge a GITHUB_OUTPUT line) is refused too.
[[ "${remote}" =~ ${version_pattern} ]] || refuse "remote version is not an IBKR build label: '${remote}'"
[[ "${pinned}" =~ ${version_pattern} ]] || refuse "pinned version is not an IBKR build label: '${pinned}'"

if [ "${check}" = full ]; then
  decide full "daily full check: IBKR serves ${remote}, the pin is ${pinned}"
fi
if [ "${remote}" = "${pinned}" ]; then
  decide skip "IBKR serves the pinned ${pinned}; the daily full check looks for a re-upload"
fi

branch="update-${channel}-to-${remote}"
repository="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
if ! listing="$(gh pr list -R "${repository}" --head "${branch}" --state all --limit 100 --json number,headRepositoryOwner)"; then
  printf 'detect-scope: could not list the pull requests from %s\n' "${branch}" >&2
  exit 1
fi
# `--head` matches the branch name in any repository, forks included: anyone can open a pull
# request from a fork branch named update-<channel>-to-<version>. Only this repository's own
# branches count (the owner's login, compared without regard to case as GitHub does).
if ! count="$(jq -e --arg owner "${repository%%/*}" \
  'if type == "array" then [.[] | select(((.headRepositoryOwner.login // "") | ascii_downcase) == ($owner | ascii_downcase))] | length else error("not a list") end' \
  <<<"${listing}" 2>/dev/null)" || ! [[ "${count}" =~ ^[0-9]+$ ]]; then
  printf 'detect-scope: the pull request lookup for %s did not answer with a list of pull requests\n' "${branch}" >&2
  exit 1
fi
if [ "${count}" -gt 0 ]; then
  decide skip "a pull request from ${branch} exists (open, closed or merged); the daily full check refreshes or reopens it"
fi
decide full "first sight of ${remote} (pin ${pinned}): no pull request from ${branch} yet"
