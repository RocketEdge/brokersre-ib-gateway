#!/usr/bin/env bash
# Prove that a ghcr.io package is not anonymously readable: an ANONYMOUS read of one of its
# tags must be refused. That is all it proves: a private and an internal package both pass
# (docs/limitations.md L40); the word "private" in its output and its name means exactly this.
#
# Purpose: publish.yml's gate before any image with IBKR software in it is pushed (ADR 0018).
# A package GitHub creates on the first push from a workflow comes out public here (GitHub's
# "Default permissions and access settings for packages modified through workflows": such a
# package "inherits the visibility and permissions model of the repository", and this
# repository is public; seen on 2026-11-17, ADR 0018 amendment; the organisation's "Package
# creation" setting can also force public).
# So publish.yml first pushes a placeholder without IBKR content (FROM scratch, one text file)
# and runs this script on it; only exit 0 lets the gateway image be built and pushed.
#
# Contract:
#   check-package-private.sh <repository> <tag>
#   repository  the package path below ghcr.io, lower case, e.g. rocketedge/brokersre-ib-gateway
#   tag         a tag that exists in the package (publish.yml pushed it just before)
#   stdout      on exit 0 one line: private: <why>
#   exit        0 private (not anonymously readable; private or internal): the anonymous token
#                 request was refused (401/403)
#               1 PUBLIC: the anonymous token was granted and the manifest request with it
#                 returned the manifest (message on stderr)
#               2 bad input (nothing requested)
#               3 inconclusive: an anonymous token granted but any manifest answer other than
#                 200, a network or TLS error, a server error, a rate limit, a redirect, a token
#                 answer without a token. Never read as private.
#
# How ghcr.io answers without credentials (observed 2026-11-17 07:15 UTC): the private package
# rocketedge/brokersre-agent -> token 401 UNAUTHORIZED; a package that does not exist -> token
# 403 DENIED; the public gateway package, tag stable -> token 200, manifest 200; the public
# sidecar package with a tag it does not have -> token 200, manifest 404 MANIFEST_UNKNOWN. A
# package that may not be read anonymously is refused at the token request: a granted token
# means anonymous pulls are allowed, so a manifest 401/403/404 after it is no evidence of a
# private package (the first version read the 404 as private).
#
# Side effects: two HTTPS requests to ghcr.io, without any credential (the script never reads
# GH_TOKEN, GITHUB_TOKEN or the Docker configuration, and passes no user or netrc to curl).
# Needs curl and jq.
set -euo pipefail

registry="ghcr.io"
manifest_types="application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json"

# refuse MESSAGE: bad input; exit 2 before any request.
refuse() {
  printf 'check-package-private: %s\n' "$1" >&2
  printf 'usage: check-package-private.sh <repository> <tag>\n' >&2
  exit 2
}

# inconclusive MESSAGE: no answer either way; exit 3.
inconclusive() {
  printf 'check-package-private: INCONCLUSIVE for %s: %s\n' "${reference}" "$1" >&2
  exit 3
}

[ "$#" -eq 2 ] || refuse "expected 2 arguments, got $#"
repository="$1"
tag="$2"
# Docker's grammar for a repository path (lower case components separated by /, at least two)
# and a tag; it also keeps anything that is not a plain name out of the URLs below.
[[ "${repository}" =~ ^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)+$ ]] || refuse "not a repository path: '${repository}'"
[[ "${tag}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || refuse "not a tag: '${tag}'"
reference="${registry}/${repository}:${tag}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

code="$(curl -sS --proto '=https' --max-time 30 -o "${work}/token.json" -w '%{http_code}' \
  "https://${registry}/token?scope=repository:${repository}:pull&service=${registry}")" \
  || inconclusive "the anonymous token request failed (curl exit $?)"
case "${code}" in
  401 | 403)
    printf 'private: an anonymous read of %s was refused (token request: HTTP %s)\n' "${reference}" "${code}"
    exit 0
    ;;
  200) ;;
  *) inconclusive "the anonymous token request answered HTTP ${code}" ;;
esac
token="$(jq -r '.token // empty' "${work}/token.json" 2>/dev/null || true)"
[ -n "${token}" ] || inconclusive "the anonymous token request answered HTTP 200 without a token"

code="$(curl -sS --proto '=https' --max-time 30 -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${token}" -H "Accept: ${manifest_types}" \
  "https://${registry}/v2/${repository}/manifests/${tag}")" \
  || inconclusive "the anonymous manifest request failed (curl exit $?)"
case "${code}" in
  200)
    printf 'check-package-private: PUBLIC: an anonymous read of %s returned its manifest (HTTP 200)\n' "${reference}" >&2
    exit 1
    ;;
  *) inconclusive "an anonymous token was granted (anonymous pulls are allowed), and the manifest request answered HTTP ${code}" ;;
esac
