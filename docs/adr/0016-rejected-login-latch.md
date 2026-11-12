# ADR 0016 — A rejected login is not repeated: the latch on the log volume

- **Status:** Accepted (2026-11-12)

## Context

When IBKR rejects the credentials, IBC leaves the "Unrecognized Username or Password" dialog
open and does not retry (seen in this image's real log, 2026-11-11; `docs/changes.md`). The
container then holds in phase `needs-human` (ADR 0013), so one start makes one attempt.

That hold ends with the container. Every later start makes a new attempt with the same
credentials: Docker's restart policy after a daemon or host restart, an operator's `up -d`, a
scheduled start task on a Windows host. An unattended host whose password expired at IBKR
therefore sends a rejected login at every boot, and IBKR locks an account after repeated
failures. A review of the Windows host kit found exactly this path (the kit recorded a
rejection only while its setup script was watching); the same holds for any host.

The fix belongs in the image: it is the one component every deployment has, and the only one
that sees the rejection in every case.

Constraints: no credential, and nothing derived from one, may be written anywhere (invariant
2); a start may be stopped only on positive evidence (the rule the preflight follows, ADR
0013); the mechanism must never answer, retry or bypass anything at IBKR (invariant 6).

## Decision

1. **Record.** When the classifier sees IBKR's rejection (`login_failed_dialog`) it writes
   `state/login-rejected` on the log volume: `v1 <fingerprint> <UTC time>`, and emits
   `login_latch_set`.
2. **The fingerprint identifies the source of the credentials, not their content**: for secret
   files, a SHA-256 over the files' modification times (16 hex digits kept); for credentials in
   plain variables the word `env`. A hash of the password, even a keyed one, was rejected: the
   key would lie next to it, and a weak password could be recovered from the volume.
3. **Hold.** At every start the entrypoint compares, before IBC is started. The same
   fingerprint means the same secret files: it emits `login_rejected_latched`, sets phase
   `needs-human` and keeps the container up and unhealthy without starting IBC. Nothing
   contacts IBKR. Exiting instead was rejected: a restart policy would restart the container
   for ever.
4. **Release.** Rewriting a secret file changes its modification time and with it the
   fingerprint; the record is removed (`login_latch_cleared`) and the start goes on. A
   completed login removes the record too. For `env` credentials a change cannot be seen, so
   they stay held until `LOGIN_LATCH=clear` is set for one start.
5. **Fail open on doubt.** A record that cannot be read, or one whose fingerprint cannot be
   compared (`none`, `unknown`), never holds a start; it is removed with a warning.
   `LOGIN_LATCH=off` restores the behaviour before this record existed.
6. **The preflight reports, the entrypoint acts.** `doctor` shows the latch as a warning with
   the way out. It is not a failed check: a failed preflight makes the container exit.

## Consequences

- Positive: after one rejection no restart policy, reboot or start task can send the same
  credentials again; the cost of a wrong password is one failed attempt per deliberate edit of
  the secret files. Hosts need no logic of their own for this.
- Positive: a consumer of the log volume sees why the gateway does not log in (the event, the
  phase, the record), and the resource samples go on, so a waiting gateway does not look dead.
- Negative: the record lives on the log volume. Without a persistent log volume it does not
  survive a re-created container, and the latch then protects only against restarts of the
  same container.
- Negative: the modification time is a proxy. Restoring a file with its old modification time
  keeps the latch; a rewrite with the same wrong password releases it for one attempt.
  Secrets on a tmpfs that is rebuilt per container (Swarm) get a new time with every
  container.
- Negative: credentials in plain variables need a deliberate `LOGIN_LATCH=clear`, and whoever
  leaves it set has switched the latch off (the preflight warns about it at every start).
- Not established: the latch is tested with the real rejected-login log as a fixture and
  offline in the container suite. It has not been observed across a real password change at
  IBKR, and only the "Unrecognized Username or Password" dialog sets it; whether IBKR shows
  another dialog for an expired password or a locked account is unknown (L01).

## Revisit trigger

A real log of another rejection (expired password, locked account, disabled user); a report of
a false hold; a secret source whose modification time does not follow rewrites.
