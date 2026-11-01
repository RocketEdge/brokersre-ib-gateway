# ADR 0002 — One Dockerfile + docker-bake + versions.json; every input verified by SHA-256

- **Status:** Accepted (2026-11-01)

## Context

Upstream keeps `Dockerfile.template` plus `update.sh` that copies `image-files/` into `stable/`
and `latest/` directories: two generated trees to review and drift between. IBKR publishes
installers at unversioned URLs with no checksums (verified 2026-11-01: versioned URLs return
404; no `.sha256` files), so a build can silently pick up different bytes.

## Decision

A single `Dockerfile` with build arguments; `docker-bake.hcl` defines the `stable` and `latest`
targets; `versions.json` is the only place a version or digest lives and `scripts/bake-env.sh`
exports it. The base image is pinned by digest. `scripts/fetch-installer.sh` verifies the
installer against the pinned SHA-256 (pre-fetched copy first, IBKR's URL second) and the IBC zip
is verified the same way. Any mismatch fails the build.

## Consequences

### Positive

One file to review; reproducible builds; a moved IBKR channel is a loud failure, not a silent
change.

### Negative

Bumping a version always needs the checksum step (automated by `detect-releases.yml`); local
builds need `jq`.

## Revisit trigger

IBKR publishes versioned, checksummed installers.
