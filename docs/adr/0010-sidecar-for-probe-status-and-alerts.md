# ADR 0010 — A separate sidecar image for the API probe, the status API and alerts

- **Status:** Proposed (2026-11-12; revised the same day after review: own network namespace
  by default, dead-man ping, and the promise about the second factor reduced to what the
  tests prove)

## Context

Operators of the gateway image need three things the image deliberately does not provide:

1. proof that the API answers, not only that its port is open (the image's health check is
   "process alive and port accepts a connection", ADR 0006 and `docs/log-contract.md`);
2. one machine-readable place that says what state the gateway is in (`/status`,
   `/metrics`, `/readyz`);
3. a message to a human when only a human can help: the two-factor prompt, an existing
   session, a failed login, a gateway that is gone.

Facts that shape the decision:

- The gateway image has no interpreter beyond Bash and its JRE, runs IBKR's proprietary
  application and holds the brokerage credentials (ADR 0003: uid 1000, read-only root, a
  reason for every package).
- A real API round trip needs an IB API client. The maintained Python client is
  `ib_async` (2.1.0 at the time of writing); its source shows that the high-level `IB`
  class always requests positions on connect and opens an account-summary subscription on
  notice 1102, while the low-level `Client` sends only what it is asked to.
- Notification channels need outbound HTTPS and their own credentials (webhook URLs,
  tokens), and they change more often than the gateway.
- IBKR allows one brokerage session per username, and every restart of the gateway forces
  a new login and usually a two-factor approval.
- A container that joins another container's network namespace keeps only loopback when
  that container stops, and stays in the dead namespace when it restarts (verified on
  Docker 29: loopback connects are refused and the socket table is empty). A sidecar
  inside the gateway's namespace is therefore mute exactly when the gateway goes away.
- The gateway publishes its API to other containers through a relay port (4004 paper, 4003
  live) that listens only while the gateway is logged in (log contract v2, ADR 0013), and
  it samples its own half-closed API sockets into `metrics/metrics.jsonl`.
- With the gateway's defaults an unanswered two-factor prompt times out after about three
  minutes, the gateway logs in again and prompts again: the phase flips between
  `2fa-pending` and `login` for hours (log contract v2).
- Nothing the sidecar sends can report the death of the sidecar or of its host.

## Decision

Ship the probe, the status endpoints and the notifier as a **separate, optional image**
(`ghcr.io/rocketedge/brokersre-ib-gateway-sidecar`, source in `sidecar/`) that runs as an
ordinary container next to the gateway and mounts the gateway's log volume read-only.

- **A sidecar, not a larger gateway image.** The gateway image stays as small as IBKR's
  application allows: no Python, no HTTP client, no notification credentials next to the
  brokerage credentials. The sidecar can be released, patched and scanned on its own
  schedule, and an operator who does not want it does not carry it. The gateway never
  depends on it: the interface is the log volume (ADR 0006, contract v2) and the relay
  port.
- **Its own network namespace by default.** The sidecar reaches the gateway by service
  name on the relay port, the path a strategy container uses, and takes the half-closed
  socket count from the gateway's own sample. It outlives the gateway container, so it can
  announce a gateway that stopped (information when a shutdown was requested), exited or
  was killed (critical), and it needs no workaround to rejoin anything. The shared network
  namespace remains available as an option for operators who want the probe on the
  Gateway's own API port; only in that mode does the sidecar exit (code 75) to rejoin a
  restarted gateway, and only on evidence of a container restart (a changed boot id), not
  merely because nothing listens.
- **The relay's timing is part of the probe.** The relay opens a moment after the phase
  says `logged-in`. For 20 seconds after a login a refused connection is "not measured"
  and retried every 3 seconds; after that it is "down". Outside `logged-in` nothing is
  probed, so a closed relay port is never an outage.
- **Python 3.14.** The only maintained asyncio IB API client is a Python library; one
  language covers the probe, the endpoints and the channels with the standard library plus
  three pinned dependencies (`ib_async`, `httpx`, `pydantic`), all locked with hashes.
- **The notifier is not in the gateway.** It holds webhook URLs and tokens and talks to
  the internet. Keeping it out of the container that holds the IBKR password limits what
  a flaw in a notification path can reach, and a hanging webhook can never delay the
  gateway's start-up or shutdown.
- **A reserved API client id** (`HEALTH_CLIENT_ID`, default 999) for one persistent,
  read-only connection. A client id identifies a connection to the gateway; a fixed,
  documented id makes the probe recognisable in the gateway's own log, keeps it from
  colliding with strategy clients by accident, and turns a collision into a distinct
  status (`client_id_in_use`, error 326) instead of a mysterious failure. The probe uses
  the low-level client and sends only the handshake and the server-time request.
- **The gateway is the source of truth for what it measures.** A stalled login, low disk
  space and memory pressure arrive as event pairs from the gateway's own thresholds; the
  sidecar relays them and keeps no second threshold that could disagree.
- **Nothing restarts the gateway.** The sidecar has no Docker socket and sends nothing to
  the IBC command server. A restart costs a login and a two-factor approval, can lock an
  account when repeated, and hides the evidence of what went wrong; whether it is worth
  that is a human's decision.
- **An optional dead-man ping.** The sidecar can fetch one URL at a fixed interval while
  it is alive, sees the gateway and no alert asks for a person, so that a monitoring
  service outside the host raises the alarm when the pings stop. It is the only answer to
  "who reports that the sidecar is dead", and it is recommended, not required: it needs an
  outside service the operator must choose.
- **No default reset window.** `api_unhealthy` is held back during IBKR's daily server
  reset only when the operator names the region (`IBKR_REGION`); the default excuses
  nothing. A false alert at night costs less than a missed outage at the close.

## Consequences

### Positive

Honest readiness (a round trip through the path clients use, not an open port); one
status document and frozen metric names for monitoring; no new package or credential in
the gateway image; the sidecar can fail without affecting trading, and its failure is
visible (health check, task progress, the dead-man check). A gateway that stops is
announced, because the sidecar does not live in its network namespace.

About the second factor, what the tests show and no more: a notification is queued within
one polling step (one second) of the sidecar reading phase `2fa-pending`, and the alert
stays one alert while the gateway cycles through prompt, timeout and new prompt; it is
repeated on the escalation channels 10 and 30 minutes after the FIRST prompt and is
resolved only by a completed login (`tests/test_twofa_timeline.py` replays that timeline
over simulated hours). An alert counts as notified only when a channel accepted it and is
re-sent until then. How long a channel takes to reach a person is outside the sidecar, and
the timeline has not been observed with a real IBKR prompt.

### Negative

A second image to build, scan, sign and keep current (`sidecar.yml`,
`sidecar-publish.yml`, `sidecar-rescan.yml`); about 300 MB, most of it the Python base
image and numpy, which ib_async's event library pulls in. The API round trip uses one of
the gateway's client connections. In the default mode the probe depends on the relay: when
the relay is broken and the Gateway is not, the status is `down` (which is what a client
on the network experiences, and the reason the shared mode still exists). A gateway that
is killed without writing anything is announced only after five minutes of silence. The
probe is verified against a wire-level fake, a scriptable fake and the real gateway image
without a login, not against a logged-in gateway (the repository's tests never log in,
`docs/limitations.md` L04). Without the dead-man ping a dead host is silent.

## Revisit trigger

IBKR or IBC exposes a supported health endpoint; `ib_async` is abandoned or a smaller
client appears; the gateway image gains an interpreter for another reason; the relay port
goes away or changes its gating; operators ask for automatic recovery actions (that would
be a new decision, not an extension of this one).
