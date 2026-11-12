# ADR 0013 — Log contract v2: events on the volume, a `needs-human` phase and a relay that follows the login

- **Status:** Accepted (2026-11-12)

## Context

The first contact of this image with IBKR's login servers (2026-11-12, `docs/changes.md`)
showed three things the v1 contract (ADR 0006) could not express.

- **A sidecar could not see the events.** Events went to the container's stdout only. A
  companion container shares the log volume and the network namespace, not the Docker socket
  (the socket would give it control of the host), so it had the phase file and nothing else.
- **"Still logging in" and "nothing will happen until a person acts" were the same phase.** A
  login with rejected credentials stays at IBC's dialog forever; the phase stayed `login`. The
  read-only hang looked the same. An operator could not tell waiting from stuck.
- **The relay accepted clients the Gateway could not serve.** It listened from container start,
  so a strategy connecting during login or the daily restart was accepted and then dropped,
  which client code sees as a reset, not as "not ready yet".

Second-factor prompts were also unbounded: with `TWOFA_TIMEOUT_ACTION=restart` IBC asks again
after every timeout, for as long as the container runs.

## Decision

1. **Every event is written twice, as the identical line**: to stdout and to
   `events/events.jsonl` on the log volume. Each line gains `boot_id` (one container start) and
   `seq` (gap-free per boot, handed out under a file lock across all processes), so a reader
   can prove it lost nothing. The stdout line is never lost: without a writable volume the event
   is printed without `seq`. Schema: `schemas/log-event.v2.schema.json`; v1 readers that ignore
   unknown keys keep working.
2. **Phase `needs-human`**: set when only a person can go on. Today that is a rejected login
   (seen in a real log) and, when `TWOFA_MAX_PROMPTS` is set, a second factor left unanswered
   that many times. In the second case the classifier asks IBC to stop and the entrypoint keeps
   the container running and unhealthy, because exiting would hand the next login to the
   restart policy.
3. **`TWOFA_MAX_PROMPTS` is off by default.** Without a notifier, endless prompts are the only
   way a person arriving later can still approve one; with a notifier a cap avoids a night of
   prompts. The image cannot know which case applies, so the operator chooses.
4. **`unknown_window`** is raised for an opened window that neither the pattern table nor the
   list of titles IBC handles knows. The raw title is not put into the event (it is Gateway
   text and may carry a name); it stays in `ibc/ibc.log`.
5. **The relay follows the phase** (`RELAY_MODE=gated`, default): it listens only in phase
   `logged-in`. `RELAY_MODE=always` keeps the v1 behaviour.
6. **A resource sampler** writes `metrics/metrics.jsonl` from the container's own cgroup and
   `/proc`. It needs no Docker socket and no new package.
7. **Rotation everywhere**: the events and metrics files rotate by size like the other logs.

## Consequences

### Positive

- A sidecar needs only a read-only mount of the log volume to follow the gateway.
- "Stuck" is distinguishable from "busy": `needs-human`, `unknown_window` and the sampler's
  `login_stalled` each say why.
- A client that gets "connection refused" retries on its own; nothing is accepted and dropped.
- Still nothing in the image answers, bypasses or automates a second factor, and nothing
  restarts the Gateway: the cap only stops asking (invariant 6 unchanged).

### Negative

- Consumers that validate stdout against the v1 schema (`additionalProperties: false`) reject
  the two new keys and must move to the v2 schema.
- One `flock` process per event. Events are rare (tens per login), so the cost is negligible,
  but the event path now depends on the log volume's lock file being usable; when it is not, the
  event is printed without `seq`.
- A client that relied on the relay port being open as soon as the container starts now gets
  "connection refused" until the login completes.
- The second-factor and re-login patterns are taken from IBC's source code, not yet from a real
  log (`docs/limitations.md` L01): the prompt cap is correct only if IBC logs what its source
  says it logs.

## Revisit trigger

A real log shows different wording for the second-factor lines; or IBC gains a setting that
caps prompts itself; or a consumer needs a field that is neither in the event nor derivable
from the files on the volume.
