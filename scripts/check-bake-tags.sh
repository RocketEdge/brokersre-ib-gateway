#!/usr/bin/env bash
# Fail when the two channels of docker-bake.hcl would publish the same tag.
#
# Purpose: publish.yml publishes `stable` and `latest` in two independent jobs, and each moves
# its own tags to its own digest (scripts/promote-tags.sh). The tag lists come from
# docker-bake.hcl: <version>[-rDATE], <version>, <major.minor> and the channel name. If IBKR
# ever has both channels on one major.minor, or on one version, both jobs would move the same
# tag: the last writer wins, and the other job's check that every tag resolves to its digest
# fails after its channel tag has already moved. This check stops that before any build:
# ci.yml runs it on every pull request (so a version bump that causes it cannot merge
# unnoticed) and publish.yml runs it before the build matrix starts.
#
# Contract:
#   check-bake-tags.sh [<bake-print.json>]
#   input    the JSON printed by `docker buildx bake --print stable latest`, from the file or,
#            without an argument, from standard input
#   stdout   a summary line; when tags are shared, one line per shared tag before it
#   exit     0  the two targets share no tag
#            1  at least one tag is in both lists
#            2  bad input: not the JSON of both targets, or a target without tags (message on
#               stderr only). Nothing was compared, so this is never reported as "no shared tag".
#
# What to do when it fails: decide which channel keeps the shared tag and change the tag
# scheme in docker-bake.hcl (and ADR 0008) in the same pull request.
# No side effects. Needs jq.
set -euo pipefail

usage() {
  echo "usage: check-bake-tags.sh [<bake-print.json>]   (default: standard input)" >&2
  exit 2
}

refuse() {
  echo "check-bake-tags: $1" >&2
  exit 2
}

[ $# -le 1 ] || usage
command -v jq >/dev/null 2>&1 || refuse "jq is required"

if [ $# -eq 1 ]; then
  if [ ! -f "$1" ] || [ ! -r "$1" ]; then refuse "'$1' is not a readable file"; fi
  definition="$(cat "$1")"
else
  definition="$(cat)"
fi
[ -n "${definition}" ] || refuse "the bake definition is empty"

# jq program (slurp mode): prints the tags both targets list, one per line; fails with the
# reason when the input is not one bake definition holding both targets with their tags.
# shellcheck disable=SC2016  # $name is a jq variable, not a shell one
shared_tags='
  def tags($name):
    (.target[$name].tags) as $t
    | if ($t | type) != "array" or ($t | length) == 0
        then error("target " + $name + " is missing or has no tags")
      elif ([$t[] | type == "string" and . != ""] | all | not)
        then error("target " + $name + " has a tag that is not text")
      else $t end;
  if length != 1 then error("expected exactly one JSON document")
  else .[0]
  | if type != "object" or (.target | type) != "object" then error("not a bake definition (no target object)")
    else (tags("stable")) as $stable | (tags("latest")) as $latest
      | [$stable[] | select(. as $tag | $latest | index($tag))] | unique | .[]
    end
  end'

if ! shared="$(jq -s -r "${shared_tags}" <<<"${definition}" 2>/dev/null)"; then
  reason="$(jq -s -r "${shared_tags}" <<<"${definition}" 2>&1 >/dev/null | tail -n 1 || true)"
  refuse "the bake definition is not usable: ${reason}"
fi

if [ -n "${shared}" ]; then
  printf '%s\n' "${shared}"
  echo "check-bake-tags: the stable and latest targets both list the tags above; two publish jobs would move them to different digests"
  exit 1
fi
echo "check-bake-tags: the stable and latest targets share no tag"
