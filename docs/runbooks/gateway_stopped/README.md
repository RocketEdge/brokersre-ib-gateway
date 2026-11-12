# The gateway was stopped on request

Alert class `gateway_stopped` · default severity info · [all runbooks](../README.md)

## What it means

The gateway's phase is `stopping` or `stopped`: something asked the container to shut down
(`docker compose stop` or `down`, a host shutdown, a deployment) and the gateway logged
`shutdown_requested`. It stays down until someone starts it. The message is information, not
an alarm: the dead-man ping continues while only this alert is active.

## Check first

- Was the stop intended: a maintenance window, a deployment, a colleague?
- If nobody knows: `docker events --since 2h --filter container=<container>` and the host's
  shutdown or update history.

## What to do

1. Intended: nothing now. Start the gateway when the work is done:
   `docker compose ... up -d ib-gateway`. The start is a new login; approve the second
   factor if IBKR asks.
2. Not intended: find out what stopped it (an unattended host reboot, an automatic update, a
   script) and turn that off for trading hours before you start the gateway again. On
   Windows, `windows/doctor.ps1` lists what can stop the gateway
   ([windows/README.md](../../../windows/README.md)).

## What not to do

- Do not disable this class to make planned stops quiet without a second look: it is also
  the only message that says "the gateway is down because something stopped it".

## When it clears

When a new start changes the phase. A `resolved` message follows.
