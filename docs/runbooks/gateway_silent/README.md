# The gateway has gone silent

Alert class `gateway_silent` · default severity error · [all runbooks](../README.md)

## What it means

The sidecar has seen no event and no metrics sample from the gateway for five minutes,
although the log volume is mounted and the gateway was not stopped on request. A running
gateway writes a sample every `SAMPLE_INTERVAL_S` (30 seconds), so this silence means the
gateway was killed without the chance to say so, hangs, is paused, or writes somewhere the
sidecar does not look.

## Check first

- Does the container run, is it paused: `docker compose ... ps`.
- Does the gateway still write samples (look at the time `ts` of the last one):
  `docker compose ... exec ib-gateway tail -n 1 /var/log/ibgateway/metrics/metrics.jsonl`.
- Do both containers use the same volume:
  `docker inspect --format '{{json .Mounts}}' <gateway container>` and the same for the
  sidecar.

## What to do

1. **The container does not run.** Read its last log lines, then start it when it is safe:
   `docker compose ... up -d ib-gateway`. The start is a new login; have the person who
   approves the second factor ready.
2. **It runs and writes samples, but the sidecar does not see them.** The sidecar holds
   another volume, typically after the gateway's volume was created anew. Start the sidecar
   again with the gateway's log volume: `docker compose ... up -d --force-recreate sidecar`.
   That does not touch the gateway.
3. **It runs and writes nothing.** Check the disk ([disk_low](../disk_low/README.md)) and
   whether the container is paused (`docker unpause`). If the gateway hangs, keep what you
   can for the diagnosis (`docker compose ... logs ib-gateway`, the sidecar's
   `support-bundle`), then restart it in a planned way.
4. A `SAMPLE_INTERVAL_S` of five minutes or more makes this alert fire on a healthy
   gateway: keep it well below.

## What not to do

- Do not assume the sidecar is wrong and disable the class: this is the alert for a gateway
  that died without a word.
- Do not restart the gateway before you have looked: in case 2 the gateway is healthy.

## When it clears

When the sidecar sees a new event or sample.
