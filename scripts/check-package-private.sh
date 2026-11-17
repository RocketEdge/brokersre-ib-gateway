#!/usr/bin/env bash
# Prove that a ghcr.io package is private: an ANONYMOUS read of one of its tags must be refused.
#
# Purpose: publish.yml's gate before any image with IBKR software in it is pushed (ADR 0018).
# A package GitHub creates on the first push from a workflow may come out public (GitHub's
# "Default permissions and access settings for packages modified through workflows": such a
# package "inherits the visibility and permissions model of the repository", and this
# repository is public; the organisation's "Package creation" setting can also force public).
# So publish.yml first pushes a placeholder without IBKR content (FROM scratch, one text file)
# and runs this script on it; only exit 0 lets the gateway image be built and pushed.
#
# Contract:
#   check-package-private.sh <repository> <tag>
#   repository  the package path below ghcr.io, lower case, e.g. rocketedge/brokersre-ib-gateway
#   tag         a tag that exists in the package (publish.yml pushed it just before)
#   stdout      on exit 0 one line: private: <why>
#   exit        0 private: the anonymous token request was refused (401/403, what ghcr.io
#                 answers for a package nobody may read anonymously), or the manifest request
#                 with the anonymous token was refused (401/403/404)
#               1 PUBLIC: the anonymous read returned the manifest (message on stderr)
#               2 bad input (nothing requested)
#               3 inconclusive: a network or TLS error, a server error, a rate limit, a redirect,
#                 a token answer without a token. Never read as private.
#
# How ghcr.io answers (checked 2026-11-17 against the then public package and a repository
# that does not exist): anonymous token request -> 200 {"token": ...} for a public package,
# 403 DENIED for one that cannot be read anonymously; manifest with that token -> 200.
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
  401 | 403 | 404)
    printf 'private: an anonymous read of %s was refused (manifest request: HTTP %s)\n' "${reference}" "${code}"
    exit 0
    ;;
  *) inconclusive "the anonymous manifest request answered HTTP ${code}" ;;
esac
