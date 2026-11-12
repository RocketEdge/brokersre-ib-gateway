# The gateway stopped unexpectedly

Alert class `gateway_exited` · default severity critical · [all runbooks](../README.md)

## What it means

The gateway went away without being asked to. One of two things was seen:

- the phase is `exited`: IBC and the Gateway ended on their own (event `ibc_exited` with the
  exit status);
- the gateway started again with a new boot id although the previous start never logged
  `shutdown_requested`: the container was killed or crashed, or the host went down. This is
  reported for 15 minutes.

A stop that somebody requested is [gateway_stopped](../gateway_stopped/README.md) instead.

## Check first

- Does the container run, and since when: `docker compose ... ps`.
- The last events before the end: `docker compose ... logs --since 1h ib-gateway`. Look for
  `ibc_exited`, `oom_kill`, `disk_low`.
- Whether the kernel killed it:
  `docker inspect --format '{{.State.OOMKilled}} {{.State.ExitCode}} {{.RestartCount}}' <container>`.
- Whether the host restarted (uptime, the system log, Windows Update).

## What to do

1. Find the reason before anything else; the first error in the log matters more than the
   last.
2. With the reference compose file (`restart: unless-stopped`) Docker has usually started
   the container again already. That start is a new login: watch for
   [twofa_pending](../twofa_pending/README.md) and approve the prompt.
3. If the container does not run, remove the cause and start it when it is safe:
   `docker compose ... up -d ib-gateway`, with the person who approves the second factor
   ready.
4. An out-of-memory kill: continue on [resource_alert](../resource_alert/README.md).

## What not to do

- Do not start it again and again without knowing why it ended: three starts in 30 minutes
  raise [restart_storm](../restart_storm/README.md), and every start is a login.
- Do not add a tool that restarts unhealthy containers. The gateway is unhealthy on purpose
  while it logs in.

## When it clears

- Phase `exited`: when a new start changes the phase.
- A restart without a requested shutdown: 15 minutes after that restart. The `resolved`
  message then says only that the gateway runs again; whether it is logged in is the phase.
