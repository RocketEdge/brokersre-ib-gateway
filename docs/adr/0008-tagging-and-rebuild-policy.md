# ADR 0008 — Tagging: channel + version tags, no Docker latest, monthly -rDATE rebuilds

- **Status:** Accepted (2026-11-01)

## Context

Two meanings of "latest" collide: Docker's conventional newest-build tag and IBKR's `latest`
release channel. Base-image security patches arrive without any Gateway change, so an image
must be rebuildable with the same Gateway and IBC versions.

## Decision

Tags per channel: `<version>` (e.g. `10.50.1f`), `<major.minor>` (`10.50`), and the channel
name (`stable` or `latest`, meaning IBKR's channel). Docker's `:latest` as a newest-build marker
is never published. A rebuild adds `<version>-rYYYYMMDD` and re-points the other tags. Each
publish tags git `v<version>-<channel>[-rDATE]` and creates a release with
`digests-<channel>.json`. Consumers pin digests; channel tags are discovery aids.

## Consequences

### Positive

Unambiguous tags; rollbacks by digest; OS patches without pretending the Gateway changed.

### Negative

Users expecting `:latest` to mean "newest" must read the README; monthly rebuilds move channel
tags even when nothing visible changed.

## Revisit trigger

IBKR renames its channels, or a consumer requires immutable channel tags.
