# The gateway keeps restarting

Alert class `restart_storm` · default severity error · [all runbooks](../README.md)

## What it means

The gateway container started three or more times within 30 minutes. Every start is a login
attempt, so a loop is more than a nuisance: it can use up login attempts and it asks for a
second factor again and again.

## Check first

- What restarts it: `docker inspect --format '{{.RestartCount}} {{.State.ExitCode}}' <container>`
  and `docker events --since 1h --filter container=<container>`.
- The usual sources: Docker's restart policy after the gateway exits each time; a tool that
  restarts unhealthy containers (the gateway is unhealthy on purpose while it logs in); a
  deployment job that runs repeatedly; a host that reboots.
- The first error of one start, not the last line of the last one:
  `docker compose ... logs --since 1h ib-gateway`. Look for `doctor_failed`, `ibc_exited`,
  `oom_kill`, `dirs_not_writable`.

## What to do

1. Stop the loop: `docker compose ... stop ib-gateway`. A container stopped this way is not
   started again by `restart: unless-stopped`.
2. Stop the source too, if it is a tool or a job outside Docker.
3. Fix the first error. A failed preflight names the setting and the fix;
   `docker compose ... run --rm ib-gateway doctor` shows every check without logging in.
4. Start once, with the person who approves the second factor ready:
   `docker compose ... up -d ib-gateway`.

## What not to do

- Do not leave the loop running while you investigate.
- Do not run a tool that restarts unhealthy containers against the gateway.
- Do not set `DOCTOR_STRICT=no` to make a failing start pass.

If IBKR rejected the credentials in one of those starts, the gateway holds the later ones in
`needs-human` without logging in (the rejected-login latch), as long as its log volume is a
persistent one.

## When it clears

When fewer than three starts lie in the last 30 minutes.
