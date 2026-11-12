# The host clock differs from IBKR time

Alert class `clock_skew` · default severity warning · [all runbooks](../README.md)

## What it means

Two consecutive probes showed that the clock the containers use differs from IBKR's time by
more than one second plus half the probe's round-trip time. IBKR answers in whole seconds,
so the limit is not tighter than that. Containers have no clock of their own: this is the
clock of the host, or of the virtual machine Docker runs in.

It is measured only while the gateway is logged in and the probe gets answers.

## Check first

- The reading: `clock_skew_s` in the status document,
  `docker compose ... exec sidecar brokersre-sidecar status`.
- Linux host: `timedatectl` (is the clock synchronised?), `chronyc tracking` where chrony
  runs.
- Windows with WSL 2 or Docker Desktop: did the computer sleep? The clock of the container
  virtual machine can lag by the time the computer slept.

## What to do

1. Linux: make sure one time service runs and synchronises (chrony or systemd-timesyncd),
   and that it can reach its servers.
2. Windows with WSL 2: correct the clock now with `wsl -u root hwclock -s`; for good, run
   `harden.ps1 -ResumeClockFix` and `-DisableSleep` of the host kit
   ([windows/README.md](../../../windows/README.md)).
3. A virtual machine in a cloud: use the provider's time source and check that the time
   service is not disabled.

## What not to do

- Do not restart the gateway: its clock is the host's, a restart changes nothing and is a
  new login.
- Do not ignore it for long: the time stamps of the events and logs, the daily restart time
  (`AUTO_RESTART_TIME`) and the times your own records carry all follow this clock.

## When it clears

When one probe is within the limit again.
