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

| IBKR channel | IB Gateway | IBC | Tags |
|---|---|---|---|
| stable | 10.50.1f | 3.24.2 (RocketEdge/ibc `3.24.2-rocketedge.1`) | `stable`, `10.50`, `10.50.1f` |
| latest | 10.51.1e | 3.24.2 (RocketEdge/ibc `3.24.2-rocketedge.1`) | `latest`, `10.51`, `10.51.1e` |

`latest` is **IBKR's channel name**, not Docker's convention; this repository never publishes a
moving "newest build" tag under another name. In production pin the **digest** printed by the
publish workflow and in each release's `digests-<channel>.json`.

## Quick start

```bash
mkdir -p secrets && printf '%s' 'your-username' > secrets/ib-username && printf '%s' 'your-password' > secrets/ib-password
docker compose -f compose/docker-compose.example.yml up -d
docker compose -f compose/docker-compose.example.yml logs -f   # JSON events; raw IBC log is on the ibgw-logs volume
```

Acknowledge the IB Key prompt on your device when the `twofa_dialog` event appears. The API is
then reachable on the published port (`4001` live, `4002` paper by default in the example).

## Environment variables

Full reference with defaults and rationale: [docs/env-vars.md](docs/env-vars.md).

| Variable | Default | Meaning |
|---|---|---|
| `TWS_USERID_FILE`, `TWS_PASSWORD_FILE` | required | Files holding the IBKR credentials (Docker secrets). `TWS_USERID`/`TWS_PASSWORD` also work but keep secrets in the process table. |
| `TRADING_MODE` | `paper` | `live` or `paper`. One brokerage session per container; `both` is not supported. |
| `READ_ONLY_API` | `yes` | Read-Only API in IBC. Set `no` only for a host that must place orders. |
| `AUTO_RESTART_TIME` | empty | IBC `AutoRestartTime` in the Gateway's time zone, e.g. `11:45 PM`; keep it outside the IBKR reset windows. |
| `TIME_ZONE` | `Etc/UTC` | IANA zone written to `jts.ini` on first start. |
| `TWOFA_TIMEOUT_ACTION` / `RELOGIN_AFTER_TWOFA_TIMEOUT` / `TWOFA_EXIT_INTERVAL` | `restart` / `yes` / `60` | 2FA retry behaviour: re-prompt instead of giving up. |
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
`starting`, `login`, `2fa-pending`, `logged-in`, `restarting`, `existing-session`, `stopping`,
`stopped`, `exited`, `test-mode`.

Stdout carries one JSON object per line (`ts`, `src`, `level`, `event`, `msg`; schema in
[schemas/log-event.v1.schema.json](schemas/log-event.v1.schema.json)). Raw IBC output goes to
`/var/log/ibgateway/ibc/ibc.log` and the Gateway's own logs are mirrored under
`/var/log/ibgateway/jts/`, so a dialog that echoes a username can never leak through container
logging. The contract is specified in [docs/log-contract.md](docs/log-contract.md).

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
exact digest to pin and the `cosign verify` command. Follow the releases in either of two ways:

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
| A new `stable` version | Installers archived, pull request opened with auto-merge: it merges once `lint` and `build-test` pass, then `publish.yml` publishes and the release notifies watchers |
| A new `latest` version | Installers archived, pull request opened; a human merges it (CI tests `stable` only) |
| The pinned version with different bytes | An `ibkr-reupload` issue; nothing changes |
| The pinned version, same bytes | Nothing |

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

Without `BOT_TOKEN` the pull request is opened with `GITHUB_TOKEN`: it runs no CI, cannot
auto-merge, and a merge made with it would not start `publish.yml`. Without the archive tokens
a pinned version stops building on the day IBKR moves past it.

To create and store each token:

1. Open [New fine-grained token](https://github.com/settings/personal-access-tokens/new).
2. **Token name:** for example `brokersre-ib-gateway-bot`. **Resource owner:** `RocketEdge`.
   **Expiration:** at most a year; put a reminder in the calendar two weeks before it expires
   (an expired token fails the daily run).
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

7. Check: `gh secret list -R RocketEdge/brokersre-ib-gateway` lists all three; run
   `gh workflow run detect-releases.yml -R RocketEdge/brokersre-ib-gateway` and confirm the log
   has no "not set" warning.

A GitHub App installation token would avoid tying the bot to a person; it needs an app with the
same permissions and `actions/create-github-app-token` in the workflow.

## Differences from gnzsnz/ib-gateway-docker

See [docs/migrating-from-gnzsnz.md](docs/migrating-from-gnzsnz.md) for the variable-by-variable
mapping. Removed: SSH tunnel, `TRADING_MODE=both`, the TWS desktop image, `telnet`, `sudo`,
runtime `JAVA_HEAP_SIZE` (now a build argument). Added: `HEALTHCHECK`, phase file, JSON log
contract, command server on loopback, checksum pinning of every input, SBOM and signatures,
read-only filesystem support.

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
