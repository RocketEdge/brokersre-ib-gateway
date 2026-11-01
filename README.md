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
- [Building and testing](#building-and-testing)
- [Upgrade policy](#upgrade-policy)
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

See [docs/upgrade-policy.md](docs/upgrade-policy.md). Summary: `detect-releases.yml` opens a
pull request when IBKR publishes a build; a human merges; `publish.yml` builds, scans, pushes,
signs; a monthly rebuild refreshes OS packages with `-rYYYYMMDD` tags. Consumers pin digests.

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
