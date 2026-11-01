# ADR 0003 — No sudo, uid 1000, read-only root filesystem

- **Status:** Accepted (2026-11-01)

## Context

Upstream grants the `ibgateway` user `NOPASSWD:ALL` sudo. The container runs a large Java
desktop application that holds brokerage credentials in memory and in a config file; any code
execution in the JVM would become root for no operational benefit.

## Decision

The `sudo`, `openssh-client`, `sshpass` and `telnet` packages are not installed. The process runs
as uid/gid 1000 (`ibgateway`), owning only `/home/ibgateway`, `/var/log/ibgateway` and
`/run/brokersre`. The reference compose runs with `read_only: true`, tmpfs on `/tmp` and
`/run/brokersre`, and named volumes for settings and logs. Java preferences and temp files are
redirected into those tmpfs paths through `ibgateway.vmoptions` at build time. `IBC_LAUNCH=no`
plus `--read-only` is a container test.

## Consequences

### Positive

Smaller blast radius; `read_only` is proven for everything up to IBC start.

### Negative

Gateway write paths after a real login are unverified (`docs/limitations.md` L02); a writable
volume for `~/Jts` may be needed. Runtime `JAVA_HEAP_SIZE` became a build argument.

## Revisit trigger

A real login shows a write path that cannot be redirected to tmpfs.
