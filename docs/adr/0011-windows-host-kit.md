# ADR 0011 — Windows host kit: Linux containers only, two start modes, file secrets, reversible host changes

- **Status:** Proposed (2026-11-12); accepted when the `windows/` directory merges

## Context

Small trading desks run this image on Windows desktops. The image itself is the same everywhere,
but a Windows desktop interrupts an unattended gateway in ways a Linux server does not, and the
people installing it are traders, not Docker users. Observed and documented facts that shaped
the kit (`windows/`):

- IB Gateway is a graphical Java application; the image runs it under Xvfb on Linux. Windows
  containers have no display server for it.
- Docker Desktop is a per-user application whose documented start option is "Start Docker
  Desktop when you sign in to your computer"
  ([Docker settings](https://docs.docker.com/desktop/settings-and-maintenance/settings/)); its
  licence is free only for small businesses "fewer than 250 employees AND less than $10 million
  in annual revenue", personal use, education and non-commercial open source
  ([Docker Desktop licence](https://docs.docker.com/subscription/desktop-license/)).
- WSL shuts an idle distribution down (`[general] instanceIdleTimeout`, default 15000 ms) and an
  idle VM (`[wsl2] vmIdleTimeout`, default 60000 ms); `networkingMode=mirrored` has a documented
  known issue with published container ports
  ([WSL configuration](https://learn.microsoft.com/windows/wsl/wsl-config),
  [WSL troubleshooting](https://learn.microsoft.com/windows/wsl/troubleshooting),
  moby/moby#48056).
- Whether WSL starts in a session without sign-in is unresolved upstream: microsoft/WSL#9231
  "Store WSL isn't accessible from Session 0" is open.
- The WSL VM clock can lag after the host resumes from sleep (microsoft/WSL#10006).
- Windows restarts for updates outside "active hours", at most 18 hours long
  ([Manage device restarts after updates](https://learn.microsoft.com/windows/deployment/update/waas-restart)).
- The image reads credentials with `"$(<file)"`. Windows PowerShell 5.1 writes UTF-16 with a
  byte-order mark for `>` and `Out-File`, and a UTF-8 byte-order mark for
  `Set-Content -Encoding UTF8` (measured 2026-11-12, see `windows/README.md`); either becomes
  part of the password and the login fails. Repeated failed logins can lock an IBKR account.
- A restricted access list on the secrets folder (current user only, inheritance off) is still
  readable through a Docker Desktop bind mount (measured with a dummy file on Docker Desktop
  4.99.0, WSL 2 backend, 2026-11-12).
- A folder created directly under `C:\` inherits write access for every local user
  (Authenticated Users: Modify), so the default gateway folder and a kit extracted there are
  writable by other accounts unless inheritance is switched off.
- `docker compose up -d` does not recreate a container when only the content of a file-based
  secret changed; `--force-recreate` does (measured 2026-11-12 with a small test container).
- With `restart: unless-stopped` every start of the container is a login attempt, and a
  container that was stopped "isn't restarted even after Docker daemon restarts"
  ([Start containers automatically](https://docs.docker.com/engine/containers/start-containers-automatically/)).

## Decision

1. **Linux containers only.** The kit supports Docker Desktop with the WSL 2 backend and Docker
   Engine inside a WSL 2 distribution; an engine in Windows-container mode is a failed
   prerequisite. A Linux VM in Hyper-V is documented as the most robust server option and needs
   no kit.
2. **Two start-at-boot modes, both opt-in.** `harden.ps1 -StartAtBoot DockerDesktop` registers a
   task after sign-in; `-StartAtBoot WslEngine` registers a task at startup that runs as the
   user without sign-in and keeps one WSL session open. Both run
   `docker compose up -d --no-recreate`, so a stopped stack starts and a running gateway is
   never replaced.
3. **Auto-logon is documented, not scripted.** An unattended Docker Desktop host needs Windows
   to sign in by itself. The kit explains Sysinternals Autologon and the trade-off and stops
   there: configuring it would make the kit handle a Windows password and silently weaken the
   computer for anyone with physical access. That decision belongs to the operator.
4. **Secrets are files written without byte-order mark.** `setup.ps1` reads both values with a
   hidden prompt, writes them with `System.IO.File.WriteAllText` and `UTF8Encoding($false)`
   (no mark, no newline), zero-frees the BSTR in a `finally`, restricts the folder to the
   current account and verifies with a dummy file that a container can still read it. The
   values never reach `compose.yaml`, a command line, a log or the screen. The gateway folder
   itself is closed to other accounts too (current account, SYSTEM, Administrators,
   inheritance off) before anything is written into it, and nothing is written into a folder
   that could not be closed. The default path stays `C:\BrokerSRE\gateway`.
5. **Every host change is journaled and reversible.** Power settings, Windows Update policy
   values, scheduled tasks, `.wslconfig` keys and the firewall rule are each behind
   `ShouldProcess`, recorded with the previous value in `harden-journal.json` before they are
   made, and reverted by `harden.ps1 -Undo`. `.wslconfig` is merged, never overwritten. The
   journal is a file and undo often runs elevated, so undo acts only on entries that match
   what the kit itself records (the Windows Update policy key and its three value names, the
   `.wslconfig` of the run and the three keys the kit sets, the kit's task names, its firewall
   rule name, a power scheme GUID with one of two setting aliases) and refuses everything else
   loudly; `-Undo` exits with 1 while any change is still in place.
6. **Alert, do not act; a rejected login is never sent twice by the kit.** The kit never
   automates 2FA and never restarts a running gateway. Its guarantee about a rejected login is
   exactly this: (a) `setup.ps1` and `start.ps1` never start a gateway while a rejection is on
   record in `kit-state.json`; only entering the credentials again clears it, and that
   replaces the container. (b) Both scripts look for a rejection since the container's
   current start (`.State.StartedAt`), not since their own start, so a rejection nobody
   watched is found by the next run, including the start task after a restart; on a hit they
   record it and run `docker compose stop` (in a `finally`, so the stop does not depend on the
   record). (c) The kit is not a service: between a rejection and the next run of one of its
   scripts it cannot act. In that window an image that latches a rejected login (event
   `login_rejected_latched`, state `needs-human`) refuses by itself; with an image that does
   not, Docker's restart policy can still make one login attempt per container start.
   `doctor.ps1` is read-only and reports `SKIP`, never `PASS`, for what it cannot measure.
7. **Both PowerShell editions.** Windows PowerShell 5.1 is what a trader's computer has, so the
   kit is ASCII-only, avoids newer syntax and is tested under 5.1 and 7 in
   `.github/workflows/windows-kit.yml`.

## Consequences

### Positive

A trader gets from a fresh computer to "Approve the IBKR Mobile prompt on your phone now" with
one script and no Docker knowledge; the usual Windows causes of a silent outage are detected
and have a reversible fix; credentials cannot be mis-encoded.

### Negative

PowerShell and Pester become a second toolchain in a repository that was shell-only, with its
own workflow on a Windows runner. Docker Engine inside WSL, the boot task without sign-in and
the clock fix after a real resume are tested with mocks only and are listed as "to validate" in
`windows/README.md`. The start tasks refer to the kit's folder, so moving the kit breaks them
until `harden.ps1` runs again, and whoever can write to that folder can change what the task
runs: `doctor.ps1` warns (`KitFolderAccess`), the kit does not move or lock its own folder.
The two host-side probes (container clock, secret mount) run a `busybox` image pinned by
digest in one constant (`$script:GwProbeImage` in `windows/src/Checks.ps1`). That is an
accepted exception to invariant 1 ("no other file carries a version"): `versions.json`
describes the inputs of the gateway image, and the probe image is not one of them. It needs a
manual bump, and a test fails when a second copy of the reference appears.
The rejected-login guarantee has the gap described in decision 6 (c) with an image that has
no latch of its own; the image gets one with ADR 0016, and the kit then is a second line, not
the only one. The start task now runs for up to 15 more minutes after each start to watch
the login.

## Revisit trigger

microsoft/WSL#9231 is resolved either way (then the boot task becomes dependable or is removed);
Docker Desktop gains a supported way to run before sign-in; the image's secret handling or
phase tokens change (log contract); or Windows PowerShell 5.1 leaves the supported set.
