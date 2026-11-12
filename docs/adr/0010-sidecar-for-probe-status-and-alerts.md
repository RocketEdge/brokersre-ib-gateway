# ADR 0010 — A separate sidecar image for the API probe, the status API and alerts

- **Status:** Proposed (2026-11-12)

## Context

Operators of the gateway image need three things the image deliberately does not provide:

1. proof that the API answers, not only that its port is open (the image's health check is
   "process alive and port accepts a connection", ADR 0006 and `docs/log-contract.md`);
2. one machine-readable place that says what state the gateway is in (`/status`,
   `/metrics`, `/readyz`);
3. a message to a human when only a human can help: the two-factor prompt, an existing
   session, a failed login.

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
- A container that joins another container's network namespace keeps the old namespace
  when that container restarts (verified on Docker 29: loopback connects are refused and
  the socket table is empty).

## Decision

Ship the probe, the status endpoints and the notifier as a **separate, optional image**
(`ghcr.io/rocketedge/brokersre-ib-gateway-sidecar`, source in `sidecar/`) that shares the
gateway's network namespace and mounts its log volume read-only.

- **A sidecar, not a larger gateway image.** The gateway image stays as small as IBKR's
  application allows: no Python, no HTTP client, no notification credentials next to the
  brokerage credentials. The sidecar can be released, patched and scanned on its own
  schedule, and an operator who does not want it does not carry it. The gateway never
  depends on it: the interface is the log volume (ADR 0006, contract v2) and the API port.
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
- **Nothing restarts the gateway.** The sidecar has no Docker socket and sends nothing to
  the IBC command server. A restart costs a login and a two-factor approval, can lock an
  account when repeated, and hides the evidence of what went wrong; whether it is worth
  that is a human's decision. The sidecar's only self-directed action is to exit when its
  own network namespace was orphaned by a gateway container restart, so that its restart
  policy rejoins it.

## Consequences

### Positive

Honest readiness (a round trip, not an open port); one status document and frozen metric
names for monitoring; a human is told within seconds that a two-factor approval is
pending, and again after 10 and 30 minutes; no new package or credential in the gateway
image; the sidecar can fail without affecting trading, and its failure is visible (health
check, task restart counters, missing heartbeat).

### Negative

A second image to build, scan, sign and keep current (`sidecar.yml`,
`sidecar-publish.yml`); about 300 MB, most of it the Python base image and numpy, which
ib_async's event library pulls in. The API round trip uses one of the gateway's client
connections. The probe is verified against a wire-level fake and a scriptable fake, not
against a live gateway (the repository's tests never log in, `docs/limitations.md` L04).
The orphaned-namespace exit needs a restart policy on the sidecar.

## Revisit trigger

IBKR or IBC exposes a supported health endpoint; `ib_async` is abandoned or a smaller
client appears; the gateway image gains an interpreter for another reason; operators ask
for automatic recovery actions (that would be a new decision, not an extension of this
one).
