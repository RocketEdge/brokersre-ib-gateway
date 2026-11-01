# ADR 0001 — Derive from gnzsnz/ib-gateway-docker under MIT with attribution

- **Status:** Accepted (2026-11-01)

## Context

gnzsnz/ib-gateway-docker (MIT, about 1,300 stars) is the de-facto community image for headless
IB Gateway: it solved the Xvfb, IBC templating, secrets-file and socat-relay problems years ago.
It lacks a HEALTHCHECK, grants the Gateway user passwordless sudo, keeps the IBC command server
off, publishes no SBOM or signature and downloads IBC without a checksum. A clean-room rewrite
would re-derive the same solutions more slowly; a thin fork would inherit the structure we want to
change.

## Decision

Start from gnzsnz's design and templates under the MIT licence, keep the original copyright line
in `LICENSE`, document the derivation in `NOTICE.md`, and restructure freely (ADRs 0002–0008).
Publish under RocketEdge's own name and registry.

## Consequences

### Positive

Proven startup choreography from day one; licence obligations limited to attribution.

### Negative

Divergence makes upstream fixes non-trivial to port; `docs/migrating-from-gnzsnz.md` must be
kept honest for users switching.

## Revisit trigger

Upstream adopts the same guarantees (health, signing, checksums), making the fork redundant.
