# ADR 0007 — IBC from the RocketEdge fork; IBKR binaries never redistributed

- **Status:** Accepted (2026-11-01)

## Context

IbcAlpha/IBC was archived on 2026-09-01; downloading from an archived repository is fine today
but offers no path for fixes. IBKR's installer URLs are unversioned; upstream solves
reproducibility by re-hosting every installer as a public GitHub release asset. RocketEdge is a
commercial entity and chose not to redistribute IBKR binaries publicly.

## Decision

IBC is fetched from the release named in `versions.json` on
[RocketEdge/ibc](https://github.com/RocketEdge/ibc) (first release `3.24.2-rocketedge.1`,
byte-identical to upstream) and verified by SHA-256; its GPL-3.0 text ships in the image and the
source offer points at the tagged commit. The Gateway installer is fetched from IBKR at build
time; RocketEdge keeps a **private** archive (`RocketEdge/brokersre-ib-gateway-archive`) for
rebuilds of superseded versions, used by `publish.yml` only when `ARCHIVE_READ_TOKEN` is present.
This repository never publishes an IBKR binary.

## Consequences

### Positive

A fixable IBC; no public redistribution exposure; reproducible rebuilds for RocketEdge.

### Negative

Public contributors cannot rebuild a superseded Gateway version once IBKR moves the channel
(the build fails with a checksum mismatch by design).

## Revisit trigger

IBKR publishes versioned, checksummed installers, or counsel clears public redistribution.
