# ADR 0006 — JSON log contract on stdout, raw logs on a volume, phase file

- **Status:** Accepted (2026-11-01)

## Context

IBC prints human-oriented text, including dialog contents that can contain the username. A
sidecar needs a handful of events (2FA pending, login completed, existing session, daily
restart) and a current lifecycle phase, without parsing free text and without the raw lines ever
leaving the host through container logging.

## Decision

Container stdout carries only JSON objects (`ts`, `src`, `level`, `event`, `msg`; schema
`schemas/log-event.v1.schema.json`). IBC's output is tee'd to `/var/log/ibgateway/ibc/ibc.log` and
piped through `classify-ibc-log.sh`, which emits events from `ibc-patterns.tsv` and writes
`/var/log/ibgateway/state/phase` atomically. The Gateway's own logs are mirrored into
`/var/log/ibgateway/jts/` so a sidecar never mounts the settings volume. `docs/log-contract.md`
is the authoritative contract; any change is a version bump.

## Consequences

### Positive

Machine-readable, credential-free stdout; one file tells the phase; raw evidence preserved.

### Negative

Pattern wording is unverified against this image until Phase 0 (`docs/limitations.md` L01); a
new IBC release may need a pattern update.

## Revisit trigger

IBC emits structured logs itself, or a second consumer needs fields beyond v1.
