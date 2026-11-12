# Daily heartbeat

Alert class `heartbeat` · default severity info · [all runbooks](../README.md)

## What it means

Once a day at `HEARTBEAT_TIME` the sidecar says that it runs, that it can see the gateway's
phase and that no alert is active. The message names what is **not** measured, for example
an API that is not probed or a gateway that has not written events yet.

The message that matters is the one that does **not** arrive.

## Check first

Nothing, when the heartbeat arrives and names nothing unmeasured.

When it is missing at the usual time, one of these holds:

- an alert is active (the heartbeat is withheld then): look for its notification;
- the sidecar cannot see the gateway ([volume_missing](../volume_missing/README.md));
- the sidecar does not run: `docker compose ... ps`;
- the channel failed: `notifier` in the status document shows the failures per channel,
  `docker compose ... exec sidecar brokersre-sidecar status`.

## What to do

1. The heartbeat names something unmeasured: decide whether that is intended (a probe turned
   off with `PROBE_ENABLED=no`) and correct it if not.
2. The heartbeat is missing and the sidecar runs without an active alert: send a test
   message to every channel, `docker compose ... exec sidecar brokersre-sidecar notify test`,
   and repair the channel that fails.
3. The sidecar does not run: start it, `docker compose ... up -d sidecar`. That does not
   touch the gateway.

## What not to do

- Do not take the heartbeat as proof that the host is alive between two heartbeats. For a
  host, a Docker daemon or a sidecar that dies, configure the
  [dead-man ping](../../../sidecar/README.md#dead-man-ping-recommended): a check outside the
  host that alarms when the pings stop.

## When it clears

It does not: the heartbeat is a single message, not a condition. PagerDuty receives none.
