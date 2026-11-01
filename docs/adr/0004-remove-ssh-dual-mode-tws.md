# ADR 0004 — Remove SSH tunnel, dual mode and the TWS desktop image

- **Status:** Accepted (2026-11-01)

## Context

Upstream offers an SSH tunnel (sshpass, ssh client, several `SSH_*` variables), a dual mode
running live and paper sessions in one container (`TRADING_MODE=both`), start-up hook
directories, and a second image with a full XFCE desktop for TWS over RDP.

## Decision

Remove all four for v1. The API consumer is either a sidecar sharing the network namespace or a
strategy host on a private network, so the tunnel has no caller. One brokerage session per
container keeps health, logs and the phase file unambiguous and matches IBKR's one-session-per-
username rule. The desktop image is out of scope. Hook directories return only with a concrete
need.

## Consequences

### Positive

About a third less shell, two fewer secrets, a single process tree to reason about.

### Negative

Users of the tunnel or dual mode must change their deployment (`docs/migrating-from-gnzsnz.md`).

## Revisit trigger

A consumer that cannot share a network namespace or a private network with the gateway.
