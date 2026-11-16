# The host clock differs from IBKR time

Alert class `clock_skew` · default severity warning · [all runbooks](../README.md)

## What it means

Two consecutive probes showed that the clock the containers use differs from IBKR's time by
provably more than one second plus half the probe's round-trip time. IBKR answers in whole
seconds and does not document whether it truncates or rounds, so a reading counts only when
it is beyond the limit either way: IBKR time minus host time above +1.5 s, or below −2 s,
each plus half the round-trip time. A true difference of up to 1 s never raises it; from
2.5 s (plus the round-trip time) in either direction every probe is beyond the limit. In
between it depends on where in the second each probe falls, so the alert can come late or
not at all. Containers have no clock of their own: this is the clock of the host, or of
the virtual machine Docker runs in.

It is measured only while the gateway is logged in and the probe gets answers.

## Check first

- The reading: `clock_skew_s` in the status document,
  `docker compose ... exec sidecar brokersre-sidecar status`. It is IBKR's whole second
  minus the host time at the middle of the round trip, not corrected for the whole second:
  a correct clock reads between about −1 and +0.5 s, so −0.9 s alone is no fault. The true
  difference lies between the reading minus 0.5 s and the reading plus 1 s, each widened
  by half `last_probe.rtt_s`: a reading of −1.77 s means the host clock is 0.77 to 2.27 s
  ahead of IBKR.
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

When one probe is within the limit again: a reading from −2 s to +1.5 s, each widened by
half the round-trip time.
