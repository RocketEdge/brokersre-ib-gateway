# Sidecar architecture

The sidecar (`sidecar/`, image `ghcr.io/rocketedge/brokersre-ib-gateway-sidecar`) is an
optional companion of the gateway container. It observes and reports; it never acts on the
gateway. User documentation: [sidecar/README.md](../sidecar/README.md). Decision record:
[ADR 0010](adr/0010-sidecar-for-probe-status-and-alerts.md).

## Where it sits

```mermaid
flowchart LR
  subgraph host["Docker host"]
    subgraph ns["network namespace of the ib-gateway container"]
      gw["ib-gateway<br/>API 127.0.0.1:4002 or 4001<br/>IBC command server 127.0.0.1:7462"]
      sc["sidecar (uid 1000, read-only root)<br/>HTTP 0.0.0.0:9810"]
    end
    logs[("ibgw-logs volume<br/>state/phase<br/>events/events.jsonl<br/>metrics/metrics.jsonl")]
    state[("sidecar-state volume<br/>notifier-state.json")]
  end
  gw -- "writes" --> logs
  logs -- "read-only mount" --> sc
  sc -- "handshake + server-time request<br/>client id 999" --> gw
  sc -- "atomic writes" --> state
  sc -- "HTTPS, 10 s timeout" --> channels["Teams / Slack / Telegram / ntfy / PagerDuty / SMTP / webhook"]
  monitor["Prometheus / operator / load balancer"] -- "GET /livez /readyz /status /metrics<br/>port published on the ib-gateway service" --> sc
```

The sidecar never connects to the IBC command server and never mounts the gateway's
settings volume or the Docker socket.

## Tasks and isolation

Every subsystem is an asyncio task under one supervisor. A task that raises or returns is
recorded (exception class, time, restart count) and started again after a capped
exponential back-off (1 s doubling to 60 s). The records are in `/status` (`tasks`) and in
`ibgw_sidecar_task_restarts_total`.

```mermaid
flowchart TB
  sup["Supervisor<br/>restart with capped back-off, crash records"]
  sup --> follow["follow<br/>phase file + two JSON-lines feeds<br/>(file I/O in a worker thread)"]
  sup --> probe["probe<br/>one API step per second<br/>+ network-namespace watch"]
  sup --> http["http<br/>stdlib asyncio server"]
  sup --> notify["notify<br/>rules -> ladder -> messages"]
  sup --> w1["notify-teams"]
  sup --> w2["notify-pagerduty"]
  sup --> wn["notify-<channel> ..."]
  follow --> model[("GatewayState<br/>in memory, bounded")]
  model --> probe
  model --> notify
  probe --> psnap[("ProbeSnapshot")]
  psnap --> notify
  psnap --> http
  model --> http
  notify -- "bounded outbox per channel" --> w1
  notify --> w2
  notify --> wn
```

What one failing part can do to the others:

| Failure | Effect | What still works |
|---|---|---|
| A webhook never answers | Its own `notify-<channel>` task waits out a 10 s timeout, retries three times, counts a failure | Every other channel, the probe, the endpoints |
| The log volume hangs | `follow` times out after 10 s and is restarted; `gateway_silent` fires | The probe, the endpoints, delivery |
| The gateway API hangs | `probe` is bounded by the handshake and round-trip timeouts; status becomes `down` | Everything else |
| A slow or malformed HTTP client | One of 32 connection slots for at most 5 s | Other clients, everything else |
| The state directory is read-only | The notifier keeps its state in memory and reports that in `/status` | Notifications (de-duplication does not survive a restart) |
| The sidecar is down | Nothing is reported; the Docker health check and the missing heartbeat show it | The gateway: it does not depend on the sidecar |

## Layers

Import rules, enforced by `sidecar/tests/test_architecture.py` (a module imports its own
unit and lower layers only):

```mermaid
flowchart BT
  leaves["vocab, clock, backoff, redaction, fsutil, logsetup, config"]
  tail["tail<br/>LineFollower, read_phase"]
  model["model<br/>events, GatewayState, snapshots, status document"]
  mid["probe | notify | http | metrics | support | supervisor<br/>(independent of each other)"]
  app["app<br/>the only wiring place"]
  cli["cli"]
  leaves --> tail --> model --> mid --> app --> cli
```

`ib_async` is imported by `probe/adapter.py` only, and that module by `app.py` only.
Everything else talks to the gateway through the `IbClient` protocol (connect, ask the
server time, disconnect, receive notice codes), so it is tested against a scriptable fake
gateway, and the adapter itself against an in-process server that speaks the IB API wire
protocol and records what the client sends.

## Following the gateway

`LineFollower` re-opens the file on every poll and identifies it by device, inode and its
first bytes. It tolerates the file missing at start, a partial last line, rotation by
rename (the predecessor `<name>.1` is drained first), truncation in place, bytes that are
not UTF-8 and oversized lines. Parsing keeps only vocabulary fields and numbers: the `msg`
of an event and unknown keys are dropped at this boundary, because the gateway may put the
IBKR username there. What the model never holds, no output can leak.

## The probe

```mermaid
stateDiagram-v2
  [*] --> not_measured
  not_measured --> probing: phase becomes logged-in
  probing --> ready: round trip ok, no 1100, no broken farm
  probing --> degraded: round trip ok, 1100 or farm broken
  probing --> down: no handshake / timeout
  probing --> client_id_in_use: error 326
  ready --> degraded: 1100 or 2103/2105/2157
  degraded --> ready: 1101/1102 or 2104/2106/2158
  ready --> down: round trip fails (connection dropped, back-off)
  degraded --> down: round trip fails
  down --> probing: next attempt (15 s doubling to 5 min)
  client_id_in_use --> probing: every 5 min
  ready --> not_measured: phase leaves logged-in (connection closed)
  degraded --> not_measured: phase leaves logged-in
  down --> not_measured: phase leaves logged-in
```

The adapter uses ib_async's low-level `Client`, not its `IB` class: in ib_async 2.1.0
`IB.connectAsync` always requests positions, and `IB` answers notice 1102 with an
account-summary subscription that is never cancelled. `Client` performs the handshake and
then sends only what the adapter asks for: the server-time request.

## Notifications

```mermaid
flowchart LR
  snap["gateway + probe snapshots"] --> rules["RuleEngine<br/>ACTIVE / INACTIVE / UNKNOWN per class"]
  rules --> ladder["LadderEngine<br/>15 min de-duplication<br/>escalation at 10 and 30 min<br/>state in notifier-state.json"]
  ladder --> factory["MessageFactory<br/>catalogue text + numbers, scrubbed"]
  factory --> disp["Dispatcher<br/>bounded outbox, timeout, 3 retries"]
  disp --> ch["channels"]
```

An `UNKNOWN` verdict (a value not measured, a duration not yet elapsed, an IBKR reset
window) changes nothing: it neither raises nor resolves an alert. That is also why a
restart of the sidecar cannot send a false "resolved".

## When the gateway container restarts

A container that shares another container's network namespace keeps the old namespace
when that container restarts. The sidecar notices (it had seen the gateway's listening
sockets, the gateway is alive according to its log volume, and the sockets stay gone for
60 s) and exits with code 75. Its restart policy starts it again, inside the gateway's new
namespace. The gateway is not touched. `EXIT_WHEN_ORPHANED=no` turns this off.

Interactive Brokers, IBKR, IB Gateway and Trader Workstation are trademarks of Interactive Brokers LLC. This project is not affiliated with, endorsed by or sponsored by Interactive Brokers.
