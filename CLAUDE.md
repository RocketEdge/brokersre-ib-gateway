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
git -c core.autocrlf=false clone --depth 1 -b v1.14.0 https://github.com/bats-core/bats-core tests/.bats-core   # once; LF matters inside the image
tests/bats/run-in-image.sh ghcr.io/rocketedge/brokersre-ib-gateway:stable                # unit suite, inside the image
tests/.bats-core/bin/bats tests/bats/ci                                                  # CI scripts (release policy, archive pre-fetch, README table), on the host (needs jq)
IMAGE=ghcr.io/rocketedge/brokersre-ib-gateway:stable tests/container/run.sh               # offline container tests (incl. the reference compose as shipped)
scripts/readme-versions.sh --check                                                       # README version table matches versions.json (drop --check to regenerate)
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
3. **Events follow log contract v2** (`schemas/log-event.v2.schema.json`, `docs/log-contract.md`):
   every event goes through `log_event` (stdout and `events/events.jsonl`, identical lines,
   with `boot_id` and a gap-free `seq`); nothing else writes to stdout. Raw IBC and Gateway
   output goes to `/var/log/ibgateway/{ibc,jts}`; the phase file is
   `/var/log/ibgateway/state/phase`; resource samples go to `metrics/metrics.jsonl`. Changing a
   key, a phase, an event name or a path is a contract version bump coordinated with every
   consumer (the sidecar, the Azure pack, the BrokerSRE agent).
4. **No sudo, no SSH/telnet, uid 1000, read-only root filesystem supported.** Adding a package
   needs a reason in the ADR log.
5. **One brokerage session per container** (`TRADING_MODE` is `live` or `paper`, never `both`).
6. **Honest health**: unhealthy while not logged in, including during a pending 2FA; nothing in
   this image restarts the Gateway on its own. The second-factor cap (`TWOFA_MAX_PROMPTS`)
   stops IBC and holds the container in phase `needs-human`; it never restarts, answers or
   bypasses anything.
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
rootfs/usr/local/lib/brokersre/*.sh           common, log (events), render-config, java-env, start-xvfb/vnc/socat/ibc, classify-ibc-log, rotating-append, tail-gateway-logs, sampler (metrics), doctor (preflight), ibc-cmd, healthcheck
scripts/readme-versions.sh                    README version table <- versions.json (--check in CI; the detect workflows run it)
rootfs/etc/brokersre/                         ibc.config.ini.tmpl, jts.ini.tmpl, ibc-patterns.tsv (event classification), known-windows.txt (titles IBC handles)
schemas/log-event.v2.schema.json (current), log-event.v1.schema.json (history)
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
- Three rows of `ibc-patterns.tsv` are confirmed by a real log, the rest are from IBC 3.24.x
  sources (`docs/limitations.md` L01). IBC logs every dialog three times (`event=Opened`,
  `Activated`, `Focused`): match `Opened` only. The login window and the Gateway main window are
  both titled "IBKR Gateway": never classify by that title.
- `tests/container/run.sh` needs ~4 minutes: the IBC smoke test waits for the Gateway JVM.
- JVM options: `ibcstart.sh` drops every `-D` line of `ibgateway.vmoptions` and clears
  `JAVA_TOOL_OPTIONS`; only `_JAVA_OPTIONS` reaches the Gateway JVM (`java-env.sh`). Check what
  the JVM really got in `/proc/<pid>/cmdline` and `/proc/<pid>/environ`, not in the files.
- The Gateway needs a writable JVM `user.home` (it writes `.hwid` during login). Without it the
  login blocks behind a dialog IBC does not see and nothing is logged; `kill -3 <java pid>`
  prints a thread dump into `ibc/ibc.log`, which is how it was found.
- IBC reads `config.ini` with `java.util.Properties.load`: backslashes, non-ASCII characters
  and leading spaces in a value must be escaped (`properties_escape` in `render-config.sh`).
- A login can be exercised without touching a real account: a made-up username reaches IBKR's
  "Unrecognized Username or Password" dialog, which proves everything up to authentication.
  Never loop it, and never run it in CI (invariant 9).
- bats: a background process started in a test must close descriptor 3 and its output
  (`cmd >/dev/null 2>&1 3>&- &`), or bats waits for it and the run hangs.
- A literal backslash-u sequence in a file written through an editor or agent tool can come out
  as the character it names; assemble such test strings from parts (see `render.bats`).
- The host that develops this repository may lack `jq`: run `tests/bats/ci` inside the image
  (`docker run --rm -v "$PWD:/code:ro" -w /code --entrypoint bash <image> -c 'tests/.bats-core/bin/bats tests/bats/ci'`).
- Events: always `log_event` / `log_event_data` (never `echo` to stdout). The sequence number
  is handed out under `flock` on the log volume, so every process of the container shares one
  gap-free series; a function that may end the entrypoint must not be called inside `$(...)`
  or with its stdout redirected, or its error event is captured instead of printed.
- The preflight (`doctor --startup`) may stop a start only for a condition under which the
  gateway cannot work or would send IBKR a wrong login. Anything the image cannot verify (a
  time zone without a zone database, a likely-but-uncertain memory problem) is a warning. A new
  variable documented in `docs/env-vars.md` must be added to the doctor's known names (a test
  compares the two).
- IBC parses `AutoRestartTime` with `hh:mm a`: a two-digit hour is required (`01:05 AM`).
  Verify such rules by running IBC's own classes from the image's `IBC.jar`, not from memory.
- A supervised child in bash: poll a counter or a file in tests (`wait_until`), never read it
  once; and `pgrep -f <path>` inside `bash -c "..."` matches that very shell.
- The unit suite reads the worktree live through a read-only mount: do not edit scripts or
  tests while it runs. Remove test containers by name, never by image.
- A temporary image for local iteration (the published image plus `COPY rootfs/ /`) is enough
  for the unit and container suites; the full build from the Dockerfile is what CI proves.
