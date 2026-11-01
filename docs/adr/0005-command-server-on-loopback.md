# ADR 0005 — IBC command server enabled on loopback for a namespace-sharing sidecar

- **Status:** Accepted (2026-11-01)

## Context

IBC's command server (`STOP`, `RESTART`, `PAUSE`, `RECONNECTDATA`, `RECONNECTACCOUNT`,
`ENABLEAPI`) lets an operator or agent recover a wedged Gateway without `docker exec`. Upstream
hard-codes `CommandServerPort=0` (off). Exposing it on the Docker network would let any
container on the host stop the Gateway.

## Decision

`CommandServerPort=${IBC_COMMAND_SERVER_PORT:-7462}` with `BindAddress=127.0.0.1` and
`ControlFrom=127.0.0.1`; `0` disables. Reachable only from inside the network namespace, which a
sidecar joins with `network_mode: "service:ib-gateway"`. `ibc-cmd` wraps the protocol; the
entrypoint uses it to stop the Gateway tidily on SIGTERM.

## Consequences

### Positive

Clean shutdowns (settings saved), remote data/account reconnects, restart without 2FA.

### Negative

A compromised sidecar can stop the Gateway; the sidecar is therefore read-only and minimal
(BrokerSRE agent). Documented in SECURITY.md.

## Revisit trigger

IBC gains authentication on the command server, or the Gateway exposes an equivalent API.
