# The sidecar cannot read the gateway's log volume

Alert class `volume_missing` · default severity error · [all runbooks](../README.md)

## What it means

For five minutes the sidecar could not read a phase it knows. The message says which of
three cases it is:

- the gateway's log volume is not mounted at `GATEWAY_LOG_DIR`;
- the file `state/phase` is missing or unreadable;
- the file holds a phase this sidecar does not know.

**While this lasts nothing about the gateway is measured, no other alert can fire, the
heartbeat is not sent and the dead-man ping is withheld.** Treat it as "we are blind", not
as "the gateway is down".

## Check first

- The gateway itself, directly: `docker compose ... ps` and
  `docker compose ... exec ib-gateway cat /var/log/ibgateway/state/phase`.
- The sidecar's mounts and its `GATEWAY_LOG_DIR`:
  `docker inspect --format '{{json .Mounts}}' <sidecar container>`.
- The versions of the two images, when the phase is not known to the sidecar.

## What to do

1. **Not mounted.** Mount the gateway's log volume read-only at `GATEWAY_LOG_DIR` in the
   sidecar, as in `compose/docker-compose.sidecar.yml`, and start the sidecar again:
   `docker compose ... up -d --force-recreate sidecar`. The gateway is not touched.
2. **`state/phase` is missing.** The gateway has never started with this volume, or the
   volume is not writable for it (event `dirs_not_writable` in the gateway's log). Fix the
   mount options of the gateway (`uid=1000,gid=1000` in the reference compose file).
3. **Unknown phase.** The gateway image is newer than the sidecar: update the sidecar to the
   version that belongs to the gateway image.

## What not to do

- Do not mount the volume writable into the sidecar to "repair" it: the sidecar only reads.
- Do not restart the gateway for this alert: in cases 1 and 3 the gateway is fine.

## When it clears

When the sidecar reads a known phase again. Conditions that hold at that moment are
announced then; what happened while the sidecar was blind is in the gateway's events.
