# CLAUDE.md — brokersre-ib-gateway (project agent contract)

Public, MIT-licensed container image of IB Gateway + IBC for unattended, observable operation;
derived from gnzsnz/ib-gateway-docker and consumed by RocketEdge BrokerSRE. This file and
`.github/copilot-instructions.md` are the same contract; keep them identical.

## THE COMMANDS

```bash
eval "$(scripts/bake-env.sh)"                                        # variables from versions.json (jq)
docker buildx bake --print stable latest > /dev/null                 # bake definition resolves
docker buildx bake stable --set '*.platform=linux/amd64' --load      # local build
hadolint Dockerfile ; shellcheck -x rootfs/usr/local/bin/*.sh rootfs/usr/local/lib/brokersre/*.sh scripts/*.sh tests/bats/*.sh tests/container/*.sh
git clone --depth 1 -b v1.14.0 https://github.com/bats-core/bats-core tests/.bats-core   # once
tests/bats/run-in-image.sh ghcr.io/rocketedge/brokersre-ib-gateway:stable                # unit suite, inside the image
tests/.bats-core/bin/bats tests/bats/ci                                                  # CI scripts (release policy, archive pre-fetch), on the host
IMAGE=ghcr.io/rocketedge/brokersre-ib-gateway:stable tests/container/run.sh               # offline container tests
pre-commit run --all-files
```

All of these must be green before claiming a change done; run them fresh.

## Invariants

1. **Every input is pinned and verified**: `versions.json` holds the base digest, the Gateway
   version and installer SHA-256 per architecture, and the IBC release tag and SHA-256. The
   Dockerfile fails the build on any mismatch. No other file carries a version.
2. **No credentials anywhere**: not in this repository, not in image layers, not in stdout, not
   in `ps`. Secrets enter via `_FILE`, land only in tmpfs `config.ini` (0600), and are unset
   before children start. `tests/container/run.sh` checks PID 1's environment and the log volume.
3. **Stdout is the JSON log contract v1** (`schemas/log-event.v1.schema.json`); raw IBC and
   Gateway output goes to `/var/log/ibgateway/{ibc,jts}`; the phase file is
   `/var/log/ibgateway/state/phase`. Changing any of these is a contract version bump
   coordinated with the BrokerSRE agent (`docs/log-contract.md`).
4. **No sudo, no SSH/telnet, uid 1000, read-only root filesystem supported.** Adding a package
   needs a reason in the ADR log.
5. **One brokerage session per container** (`TRADING_MODE` is `live` or `paper`, never `both`).
6. **Honest health**: unhealthy while not logged in, including during a pending 2FA; nothing in
   this image restarts the Gateway on its own.
7. **IBKR binaries are never redistributed from here** (ADR 0007): the installer is fetched from
   IBKR at build time; the private archive is RocketEdge's internal fallback.
8. **Docker `latest` is never published**; `latest` is IBKR's channel name. Channel tags move
   only through `publish.yml` after Trivy passes; consumers pin digests.
9. **Tests never log in**: the IBC smoke test runs with `--network none`.
10. Public repository: no BrokerSRE pricing, client names, Azure identifiers or internal plans.
11. Trademark sentence on every public artefact (README, release notes, image description).

## Layout

```text
Dockerfile                 two-stage build; ARGs come from docker-bake.hcl <- versions.json
docker-bake.hcl            targets stable/latest, tags, labels; scripts/bake-env.sh exports variables
scripts/fetch-installer.sh build-time installer fetch + SHA-256 verification (pre-fetched copy first)
rootfs/usr/local/bin/entrypoint.sh            orchestration under tini; SIGTERM -> IBC STOP
rootfs/usr/local/lib/brokersre/*.sh           common, log, render-config, start-xvfb/vnc/socat/ibc, classify-ibc-log, tail-gateway-logs, ibc-cmd, healthcheck
rootfs/etc/brokersre/                         ibc.config.ini.tmpl, jts.ini.tmpl, ibc-patterns.tsv (event classification)
schemas/log-event.v1.schema.json
tests/bats/unit/*.bats (run inside the image), tests/container/run.sh (docker CLI), tests/fixtures/
compose/docker-compose.example.yml
.github/workflows/  ci, publish, rebuild, detect-releases, detect-ibc-release (CodeQL comes from GitHub default setup, enabled by the organisation)
docs/  architecture.md, changes.md, limitations.md, env-vars.md, log-contract.md, upgrade-policy.md, migrating-from-gnzsnz.md, adr/
```

## Gotchas

- IBKR's installer URLs are unversioned; when IBKR moves a channel, `fetch-installer.sh` fails
  with a checksum mismatch by design. Bump `versions.json` (detect-releases does) or drop the
  archived installer under `downloads/`.
- `ibcstart.sh` resolves Java from `.install4j/inst_jre.cfg` in the Gateway directory; the
  Dockerfile writes it (bundled JRE on x64, system OpenJDK 25 on arm64).
- Dialog titles in `ibc-patterns.tsv` are from IBC 3.24.x documentation; verify against real
  scrubbed logs (`docs/limitations.md` L01).
- `tests/container/run.sh` needs ~3 minutes: the IBC smoke test waits for the Gateway JVM.
