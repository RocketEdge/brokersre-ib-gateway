# brokersre-ib-gateway

IB Gateway and IBC in a container built for **unattended, observable operation**: one
parametrised Dockerfile for both IBKR channels, every input pinned by SHA-256, no `sudo`, a
read-only root filesystem, a truthful `HEALTHCHECK`, the IBC command server on loopback,
structured JSON on stdout and raw logs on a shared volume, `tini` as PID 1, multi-arch images
signed with Sigstore cosign and shipped with an SBOM.

Derived from [gnzsnz/ib-gateway-docker](https://github.com/gnzsnz/ib-gateway-docker) (MIT) and
maintained by [RocketEdge](https://rocketedge.com) as the gateway image of its
[BrokerSRE](https://rocketedge.com/brokersre/) service. It works standalone too.

Interactive Brokers, IBKR, Trader Workstation, TWS and IB Gateway are trademarks of Interactive
Brokers LLC. RocketEdge is an independent engineering firm and is not affiliated with, sponsored
by or endorsed by Interactive Brokers.

## Table of Contents

- [Images and tags](#images-and-tags)
- [Quick start](#quick-start)
- [Going live](#going-live)
- [The weekly login](#the-weekly-login)
- [Environment variables](#environment-variables)
- [Ports, volumes and the sidecar contract](#ports-volumes-and-the-sidecar-contract)
- [Health, phases and logs](#health-phases-and-logs)
- [Security posture](#security-posture)
- [Verifying an image](#verifying-an-image)
- [Get notified of new images](#get-notified-of-new-images)
- [Building and testing](#building-and-testing)
- [Upgrade policy](#upgrade-policy)
- [Automatic updates and repository secrets](#automatic-updates-and-repository-secrets)
- [Differences from gnzsnz/ib-gateway-docker](#differences-from-gnzsnzib-gateway-docker)
- [Documentation](#documentation)
- [License](#license)

## Images and tags

Registry: `ghcr.io/rocketedge/brokersre-ib-gateway`. The pinned versions live in
[versions.json](versions.json).

<!-- versions:start -->
| IBKR channel | IB Gateway | IBC | Tags |
|---|---|---|---|
| stable | 10.50.1g | 3.24.2 (RocketEdge/ibc `3.24.2-rocketedge.1`) | `stable`, `10.50`, `10.50.1g` |
| latest | 10.51.1e | 3.24.2 (RocketEdge/ibc `3.24.2-rocketedge.1`) | `latest`, `10.51`, `10.51.1e` |
<!-- versions:end -->

The table is generated from `versions.json` by `scripts/readme-versions.sh` (CI fails when it is
stale). `latest` is **IBKR's channel name**, not Docker's convention; this repository never
publishes a moving "newest build" tag under another name. In production pin the **digest**
printed by the publish workflow and in each release's `digests-<channel>.json`.

## Quick start

You need Docker with Linux containers (Docker Desktop on Windows or macOS, Docker Engine on
Linux), a clone of this repository, and an IBKR username used by nothing else: IBKR allows one
session per username. The example starts in **paper** mode with the read-only API.

### 1. Store the two secrets as files

The secret files live in `compose/secrets/` (ignored by git). Write them as UTF-8 **without** a
byte-order mark. On Windows do not use `>` or `echo`: Windows PowerShell 5.1 writes UTF-16 that
way, and the gateway refuses such a file (`secret_unreadable`) rather than send IBKR a wrong
password.

Windows (PowerShell 5.1 or 7), from the repository folder:

```powershell
New-Item -ItemType Directory -Force compose\secrets | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText("$PWD\compose\secrets\ib-username", (Read-Host 'IBKR username'), $utf8)
$secure = Read-Host 'IBKR password' -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try { [IO.File]::WriteAllText("$PWD\compose\secrets\ib-password", [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr), $utf8) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
```

Linux, macOS, WSL or Git Bash:

```bash
mkdir -p compose/secrets
read -r -p 'IBKR username: ' u && printf '%s' "$u" > compose/secrets/ib-username
read -r -s -p 'IBKR password: ' p && printf '%s' "$p" > compose/secrets/ib-password && echo
unset u p
```

You should see two files, `compose/secrets/ib-username` and `compose/secrets/ib-password`, and
the password never appeared on screen.

### 2. Start the gateway

```bash
docker compose -f compose/docker-compose.example.yml up -d
docker compose -f compose/docker-compose.example.yml logs -f
```

You should see JSON events ending with `ibc_starting`, `ibc_version` and `login_dialog`. If IBKR
asks for a second factor, the event `twofa_dialog` appears: approve the prompt in IBKR Mobile.
The image never answers a second factor for you. Stop following the log with Ctrl+C.

### 3. Check that it is logged in

```bash
docker compose -f compose/docker-compose.example.yml exec ib-gateway cat /var/log/ibgateway/state/phase
docker compose -f compose/docker-compose.example.yml ps
```

You should see `logged-in`, and `(healthy)` in the status column. The API is then reachable on
`127.0.0.1:4002` (paper) or `127.0.0.1:4001` (live). While the phase is `login` or
`2fa-pending` the container reports `unhealthy` on purpose.

### 4. If it does not log in

| You see | Cause | Fix |
|---|---|---|
| event `doctor_failed` naming `credentials`, and the container stops | A secret file is missing, empty or UTF-16 | Write it again with the commands in step 1 |
| event `doctor_failed` naming another check, and the container stops | The preflight found a setting the gateway cannot run with; the message says which and how to fix it | Fix the setting. `docker compose ... run --rm ib-gateway doctor` shows every check |
| event `login_failed_dialog`, phase `needs-human` | IBKR rejected the username or password | Correct the files, then `docker compose ... up -d --force-recreate`. The gateway does not retry on its own, so it cannot lock the account |
| event `unknown_window` or `login_stalled`, phase stays `login` | The Gateway shows a window that IBC does not handle | Look at `ibc/ibc.log` on the log volume for the window title; report it |
| event `existing_session` | The username is logged in somewhere else | Close the other session, or use a dedicated username |
| event `dirs_not_writable` | A tmpfs or volume is not writable by uid 1000 | Keep the `uid=1000,gid=1000` mount options of the example |
| a client gets "connection refused" on 4001/4002 | The Gateway is not logged in yet, or is restarting: the relay opens only while it is logged in | Retry; check the phase |

## Going live

Paper first. Before the same setup holds a live session, check each line:

- [ ] **A username of its own.** IBKR allows one session per username: a login with the same
      username in IBKR Mobile, Client Portal or TWS ends the gateway's session. Use a second
      username for people.
- [ ] **The image is pinned by digest** (`IBGW_IMAGE=ghcr.io/rocketedge/brokersre-ib-gateway@sha256:...`)
      and [verified](#verifying-an-image). A tag can move; a digest cannot.
- [ ] **`TRADING_MODE=live`**, and `READ_ONLY_API=no` only if the strategy places orders.
- [ ] **A daily restart time** (`AUTO_RESTART_TIME`, two-digit hour) outside IBKR's reset
      windows for your region; `doctor` checks the form and, for three time-zone families,
      the window.
- [ ] **The relay is published on a private address** (`PRIVATE_IP`), never on a public one.
      Every client that reaches the relay is trusted by the Gateway.
- [ ] **The preflight is clean:**
      `docker compose -f compose/docker-compose.example.yml run --rm ib-gateway doctor`.
- [ ] **Someone is told when a person is needed.** The image records `2fa-pending`,
      `needs-human` and `unknown_window` as events and phases; it does not notify anybody by
      itself. Read `events/events.jsonl` with your own tooling, or run a companion that turns
      them into messages.
- [ ] **The host stays up**: no sleep, no unattended reboot during trading hours, Docker
      starts at boot, the clock is synchronised.
- [ ] **You have stopped and started it once on purpose** (`docker compose ... down`, then
      `up -d`) and watched the phases, so the first real restart is not a surprise.
- [ ] **You know what is not covered**: [docs/limitations.md](docs/limitations.md).

## The weekly login

IBKR asks for a full login with the second factor about once a week; the daily restart in
between does not ask again. IBKR's own page puts it as "the weekly authentication cycle
starts on every Monday"
([Daily & Weekly Reauthentication](https://www.interactivebrokers.com/docs/third-party-integrations/tws-settings/best-practice-configure-tws-ib-gateway/daily-weekly-reauthentication));
IBC's user guide says authentication is required "the first time during the week that TWS or
Gateway run after 01:00 ET on Sunday". Either way, once a week a person must approve a
prompt, and no setting of this image changes that: the image never answers, types or bypasses
a second factor.

What happens: the phase becomes `2fa-pending` and the events `twofa_initiated` and
`twofa_dialog` appear (recognised from the text IBC's code logs; not yet seen in a real
session of this image, [limitations](docs/limitations.md) L09). Approve the prompt in IBKR
Mobile. A prompt that is not answered
expires after about three minutes; with the defaults IBC then logs in again and asks again,
without limit. Each time the phase passes through `login` for a few seconds (event
`twofa_timeout`) before it is `2fa-pending` again, so anything that watches for a waiting
person must look at the events ("a prompt without a completed login since"), not at how long
one phase value has lasted. `TWOFA_MAX_PROMPTS` sets a limit,
after which the gateway stops asking and waits in phase `needs-human` until someone restarts
the container.

Plan it: decide who approves the prompt and when, and make sure that person learns that it is
waiting.

## Environment variables

Full reference with defaults and rationale: [docs/env-vars.md](docs/env-vars.md).

| Variable | Default | Meaning |
|---|---|---|
| `TWS_USERID_FILE`, `TWS_PASSWORD_FILE` | required | Files holding the IBKR credentials (Docker secrets). `TWS_USERID`/`TWS_PASSWORD` also work but keep secrets in the process table. |
| `TRADING_MODE` | `paper` | `live` or `paper`. One brokerage session per container; `both` is not supported. |
| `READ_ONLY_API` | `yes` | Read-Only API in IBC. Set `no` only for a host that must place orders. |
| `AUTO_RESTART_TIME` | empty | IBC `AutoRestartTime` in the Gateway's time zone, with a two-digit hour, e.g. `11:45 PM` or `01:05 AM`; keep it outside the IBKR reset windows. A value IBC would not apply stops the start. |
| `TIME_ZONE` | `Etc/UTC` | IANA zone written to `jts.ini` on first start. |
| `TWOFA_TIMEOUT_ACTION` / `RELOGIN_AFTER_TWOFA_TIMEOUT` / `TWOFA_EXIT_INTERVAL` | `restart` / `yes` / `60` | 2FA retry behaviour: re-prompt instead of giving up. |
| `TWOFA_MAX_PROMPTS` | `0` (no limit) | After this many unanswered second-factor prompts the gateway stops asking and waits for a person (phase `needs-human`). It never answers a prompt itself. |
| `RELAY_MODE` | `gated` | `gated`: the relay on 4003/4004 listens only while the Gateway is logged in. `always`: it listens from container start. |
| `JAVA_HEAP_MB` | unset (768) | Gateway heap in megabytes, set at run time; `auto` takes half of the container memory limit (768 to 4096). |
| `DOCTOR_STRICT` | `yes` | `no` lets the container start although a preflight check failed (see `doctor` below). |
| `EXISTING_SESSION_DETECTED_ACTION` | `primary` | IBC action when another session of the same username appears. |
| `TWS_ACCEPT_INCOMING` | `reject` | IBC `AcceptIncomingConnectionAction`: API clients must be trusted. |
| `IBC_COMMAND_SERVER_PORT` | `7462` | IBC command server on `127.0.0.1`; `0` disables it. |
| `VNC_SERVER_PASSWORD_FILE` | unset | Enables x11vnc on `127.0.0.1:5900` inside the container (break-glass; tunnel in). |
| `CUSTOM_CONFIG` | `no` | `yes` to supply your own `/run/brokersre/config.ini` instead of rendering one. |
| `IBC_LAUNCH` | `yes` | `no` starts everything except IBC (used by the offline tests). |

## Ports, volumes and the sidecar contract

- IB Gateway listens on **loopback only** (`4001` live / `4002` paper, `TrustedIPs=127.0.0.1`).
  `socat` relays that port to the container interface on **4003 / 4004**; publish the relay
  bound to a private address your strategy host can reach, never to the public internet.
- The relay **follows the login**: it listens only while the Gateway is logged in. Before the
  login and during the daily restart a client gets "connection refused" and should simply
  retry; it is never accepted and then dropped. `RELAY_MODE=always` restores a relay that
  listens from container start.
- The IBC **command server** (`STOP`, `RESTART`, `RECONNECTDATA`, `RECONNECTACCOUNT`, ...) is on
  `127.0.0.1:7462`. A sidecar can use it only by sharing this container's network namespace
  (`network_mode: "service:ib-gateway"`), which is how the BrokerSRE agent does it. `ibc-cmd STOP`
  inside the container does the same.
- Volumes: `/home/ibgateway/Jts/settings` (Gateway settings, persist it) and
  `/var/log/ibgateway` (shared log volume; mount it read-only into a sidecar).

## Health, phases and logs

`HEALTHCHECK` is healthy only when the IBC/Gateway process is alive **and** the API port accepts a
connection; a pending 2FA is therefore honestly unhealthy, and nothing restarts the container on
unhealthy. The finer lifecycle lives in `/var/log/ibgateway/state/phase`:

| Phase | What it means | What to do |
|---|---|---|
| `starting`, `login` | starting up, logging in | wait |
| `2fa-pending` | IBKR waits for a second factor | approve it in IBKR Mobile |
| `logged-in` | login completed, API available | nothing |
| `restarting` | the daily restart | wait; clients retry |
| `existing-session` | the username is logged in elsewhere | close the other session |
| `needs-human` | nothing will change until a person acts (IBKR rejected the login, or the second factor was not approved after `TWOFA_MAX_PROMPTS` prompts) | fix the cause, then restart the container |
| `stopping`, `stopped`, `exited`, `test-mode` | shutting down, stopped, IBC ended, offline test | |

**Events.** Every event is one JSON object on one line (`ts`, `src`, `level`, `event`, `msg`,
`boot_id`, `seq`; schema in [schemas/log-event.v2.schema.json](schemas/log-event.v2.schema.json)).
It goes to stdout and, as the identical line, to `/var/log/ibgateway/events/events.jsonl`, so a
sidecar that mounts only the log volume sees what `docker logs` shows. `seq` counts the events
of one container start without gaps: a reader can tell that it lost nothing. Raw IBC output
goes to `/var/log/ibgateway/ibc/ibc.log` and the Gateway's own logs are mirrored under
`/var/log/ibgateway/jts/`, so a dialog that echoes a username can never leak through an event.

**Resources.** `/var/log/ibgateway/metrics/metrics.jsonl` gets one sample every 30 s from the
container's own cgroup and `/proc` (memory, CPU, processes, the Gateway JVM, open files, disk).
The events `oom_kill`, `memory_high`, `disk_low` and `login_stalled` are derived from it.

**Preflight.** `docker compose -f compose/docker-compose.example.yml run --rm ib-gateway doctor`
checks the configuration without starting the gateway (secret files and their encoding, the
restart time, variables the image ignores, heap against the memory limit, disk space) and names
the fix for each problem; `--json` prints one document. The same checks run at every start: a
failed check stops the container before any login is attempted.

All log files on the volume are size-capped and rotated (`LOG_MAX_BYTES`, `LOG_KEEP`). The
contract is specified in [docs/log-contract.md](docs/log-contract.md).

## Security posture

No `sudo`, no SSH or telnet client; runs as uid 1000; works with `read_only: true` (tmpfs on
`/tmp` and `/run/brokersre` mounted with `uid=1000,gid=1000`, see [docs/env-vars.md](docs/env-vars.md));
credentials enter through `_FILE` variables, are rendered into
`/run/brokersre/config.ini` (tmpfs, mode 0600) and are removed from the environment before any
child process starts; every artefact (base image, Gateway installer, IBC zip) is verified by
SHA-256 at build time; images are signed (keyless cosign), carry a CycloneDX SBOM and GitHub
build provenance, and are scanned by Trivy before any tag moves. See [SECURITY.md](SECURITY.md).

## Verifying an image

```bash
IMAGE=ghcr.io/rocketedge/brokersre-ib-gateway@sha256:<digest-from-the-release>
cosign verify "$IMAGE" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/RocketEdge/brokersre-ib-gateway/.github/workflows/publish.yml@'
cosign verify-attestation --type cyclonedx "$IMAGE" --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/RocketEdge/brokersre-ib-gateway/' | jq .
```

## Get notified of new images

Every new IB Gateway version and every OS-patch rebuild creates a
[release](https://github.com/RocketEdge/brokersre-ib-gateway/releases). Its notes carry the
exact digest to pin and the `cosign verify` command; the release's `digests-<channel>.json` always
holds the digest the channel tag points at. When an already released version is rebuilt (an
image fix, no new IB Gateway), its release is updated in place, which GitHub does not announce.
Follow the releases in either of two ways:

- **E-mail from GitHub** (needs a GitHub account): on this repository click **Watch**, then
  **Custom**, tick **Releases** and click **Apply**. In your GitHub
  [notification settings](https://github.com/settings/notifications), under **Subscriptions >
  Watching**, make sure **Email** is ticked. GitHub then e-mails you each new release.
- **Feed, no account needed:** subscribe to
  `https://github.com/RocketEdge/brokersre-ib-gateway/releases.atom` in a feed reader, or post it
  to a team channel through the channel's RSS integration (for example Microsoft Teams Workflows
  or the Slack RSS app).

Release names carry the channel (`v10.50.1g-stable`, `v10.51.1e-latest`); look for `-stable` if
that is the channel you run. A release changes nothing you run: images are pinned by digest.
BrokerSRE clients receive a new digest as a pull request in their own repository from the weekly
image-pin workflow and merge it only after it is verified.

## Building and testing

```bash
eval "$(scripts/bake-env.sh)"                      # variables from versions.json (needs jq)
docker buildx bake stable --set '*.platform=linux/amd64' --load
git -c core.autocrlf=false clone --depth 1 -b v1.14.0 https://github.com/bats-core/bats-core tests/.bats-core  # LF matters inside the image
tests/bats/run-in-image.sh ghcr.io/rocketedge/brokersre-ib-gateway:stable   # unit suite inside the image
IMAGE=ghcr.io/rocketedge/brokersre-ib-gateway:stable tests/container/run.sh  # offline container tests
```

The container tests never log in: the IBC smoke test runs with `--network none` and proves that
IBC starts, the command server listens and `STOP` shuts the Gateway down tidily.

## Upgrade policy

See [docs/upgrade-policy.md](docs/upgrade-policy.md). Summary: `detect-releases.yml` checks
IBKR daily and opens a pull request when IBKR publishes a build; a `stable` update merges itself
once CI passes, a `latest` update waits for a human (ADR 0009); `publish.yml` builds, scans,
pushes, signs; a monthly rebuild refreshes OS packages with `-rYYYYMMDD` tags. Consumers pin
digests.

## Automatic updates and repository secrets

For maintainers. Every day at 06:00 UTC `detect-releases.yml` reads IBKR's manifest for both
channels, downloads both installers and lets `scripts/release-decision.sh` decide:

| IBKR serves | What happens |
|---|---|
| A newer `stable` version, both installers changed | Installers archived, pull request opened with auto-merge: it merges once `lint` and `build-test` pass, then `publish.yml` publishes and the release notifies watchers |
| Any other new label (`latest`, a lower version, an installer unchanged) | Installers archived, pull request opened; a human merges it |
| The pinned version with different bytes | New bytes archived under `ibgateway-<channel>@<version>-<8 hex of x64><8 hex of arm>`, one `ibkr-reupload` issue per set of bytes; nothing changes |
| The pinned version, same bytes | Nothing |

To hold one `stable` update, disable auto-merge on its pull request and leave the pull request
open: the daily run enables auto-merge only on the run that creates the pull request, so it stays
off. Do not close it: the next daily run would open a new one with auto-merge. To skip a version
or stop all automatic merges:
`gh variable set STABLE_AUTOMERGE --body false -R RocketEdge/brokersre-ib-gateway` (delete the
variable to resume).

Repository settings this needs (both on): **Settings > General > Pull Requests > Allow
auto-merge**, and **Settings > Actions > General > Allow GitHub Actions to create and approve
pull requests**.

Repository secrets (fine-grained personal access tokens; GitHub adds **Metadata: Read-only** to
each by itself):

| Secret | Used by | Repository access | Repository permissions |
|---|---|---|---|
| `BOT_TOKEN` | `detect-releases.yml`: opens the pull request and enables auto-merge | `RocketEdge/brokersre-ib-gateway` | Contents: Read and write; Pull requests: Read and write |
| `ARCHIVE_WRITE_TOKEN` | `detect-releases.yml`: archives the installers | `RocketEdge/brokersre-ib-gateway-archive` | Contents: Read and write |
| `ARCHIVE_READ_TOKEN` | `ci.yml`, `publish.yml`: pre-fetch archived installers | `RocketEdge/brokersre-ib-gateway-archive` | Contents: Read-only |

Without `BOT_TOKEN` the pull request is opened with `GITHUB_TOKEN`: GitHub does not start its CI
by itself (it skips the runs or holds them for approval), it is not set to auto-merge, and a
merge made with `GITHUB_TOKEN` would not start `publish.yml`. Without the archive tokens a pinned
version stops building on the day IBKR moves past it.

To create and store each token:

1. Open [New fine-grained token](https://github.com/settings/personal-access-tokens/new).
2. **Token name:** for example `brokersre-ib-gateway-bot`. **Resource owner:** `RocketEdge`.
   **Expiration:** at most a year; put a reminder in the calendar two weeks before it expires.
   An expired `BOT_TOKEN` or `ARCHIVE_WRITE_TOKEN` fails only the run that needs it (the day IBKR
   publishes); an expired `ARCHIVE_READ_TOKEN` fails nothing and only logs an archive miss, so
   the reminder is the only warning.
3. **Repository access:** *Only select repositories*, then the repository from the table.
4. **Permissions > Repository permissions:** exactly the permissions in the table, nothing else.
5. **Generate token** and copy it once. If the organisation requires approval, approve the
   request under **RocketEdge > Settings > Personal access tokens > Pending requests**.
6. Store it, pasting the value at the prompt (never on the command line, where shell history
   keeps it):

   ```bash
   gh secret set BOT_TOKEN -R RocketEdge/brokersre-ib-gateway
   gh secret set ARCHIVE_WRITE_TOKEN -R RocketEdge/brokersre-ib-gateway
   gh secret set ARCHIVE_READ_TOKEN -R RocketEdge/brokersre-ib-gateway
   ```

7. Check: `gh secret list -R RocketEdge/brokersre-ib-gateway` lists all three. `ARCHIVE_READ_TOKEN`
   is proven by the next CI run: its "Pre-fetch archived stable installers" step logs
   `from ibgateway-stable@<version> (sha256 ok)`. `BOT_TOKEN` and `ARCHIVE_WRITE_TOKEN` are first
   used when IBKR publishes: that day's pull request shows CI checks and auto-merge, and the
   archive gains a release.

A GitHub App installation token would avoid tying the bot to a person; it needs an app with the
same permissions and `actions/create-github-app-token` in the workflow.

## Differences from gnzsnz/ib-gateway-docker

See [docs/migrating-from-gnzsnz.md](docs/migrating-from-gnzsnz.md) for the variable-by-variable
mapping. Removed: SSH tunnel, `TRADING_MODE=both`, the TWS desktop image, `telnet`, `sudo`.
Renamed: `JAVA_HEAP_SIZE` is `JAVA_HEAP_MB` (megabytes, or `auto`). Added: `HEALTHCHECK`, phase
file, JSON event contract on stdout and on the log volume, a preflight (`doctor`) that names
variables carried over from gnzsnz which this image ignores, a relay that follows the login,
resource samples, command server on loopback, checksum pinning of every input, SBOM and
signatures, read-only filesystem support.

## Documentation

[docs/architecture.md](docs/architecture.md) (Mermaid), [docs/adr/README.md](docs/adr/README.md),
[docs/changes.md](docs/changes.md), [docs/limitations.md](docs/limitations.md),
[docs/env-vars.md](docs/env-vars.md), [docs/log-contract.md](docs/log-contract.md),
[docs/upgrade-policy.md](docs/upgrade-policy.md).

## License

MIT, see [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md). IBC is GPL-3.0 and is aggregated, not
linked; its licence text ships at `/usr/share/doc/ibc/LICENSE.txt` and its complete source is the
tagged release in [RocketEdge/ibc](https://github.com/RocketEdge/ibc). IB Gateway is Interactive
Brokers' software, fetched from IBKR at build time under IBKR's terms; it is not redistributed
from this repository.
