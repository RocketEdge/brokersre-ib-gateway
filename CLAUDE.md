# CLAUDE.md — brokersre-ib-gateway (project agent contract)

Public, MIT-licensed container image of IB Gateway + IBC for unattended, observable operation;
derived from gnzsnz/ib-gateway-docker and consumed by RocketEdge BrokerSRE. This file and
`.github/copilot-instructions.md` are the same contract; keep them identical.

## THE COMMANDS

```bash
eval "$(scripts/bake-env.sh)"                                        # variables from versions.json (jq)
docker buildx bake --print stable latest > /dev/null                 # bake definition resolves
docker buildx bake stable --set '*.platform=linux/amd64' --load      # local build
hadolint Dockerfile ; shellcheck -x rootfs/usr/local/bin/*.sh rootfs/usr/local/lib/brokersre/*.sh scripts/*.sh tests/bats/*.sh tests/container/*.sh tests/compose/*.sh examples/*.sh
git -c core.autocrlf=false clone --depth 1 -b v1.14.0 https://github.com/bats-core/bats-core tests/.bats-core   # once; LF matters inside the image
tests/bats/run-in-image.sh ghcr.io/rocketedge/brokersre-ib-gateway:stable                # unit suite, inside the image
tests/.bats-core/bin/bats tests/bats/ci                                                  # CI scripts (release and rebuild policy, tag promotion, VEX drift, workflow policy, archive pre-fetch, README table), on the host (needs jq)
scripts/check-vex.sh security/vex/ibgateway-vendor-jars.openvex.json                     # VEX document valid (add Trivy `--pkg-types library --list-all-pkgs --format json` reports to compare)
IMAGE=ghcr.io/rocketedge/brokersre-ib-gateway:stable tests/container/run.sh               # offline container tests (incl. the reference compose as shipped)
IMAGE=ghcr.io/rocketedge/brokersre-ib-gateway:stable tests/compose/run.sh                 # compose files as shipped (several gateways, gateway + strategy); offline
(cd examples/python && uv sync --locked && uv run ruff check . && uv run black --check . && uv run mypy && uv run pytest)
(cd examples/csharp && dotnet build -warnaserror && dotnet test && dotnet format GatewayClient.slnx --verify-no-changes)
bash azure/tests/run.sh [group...]                                                       # Azure pack, offline (Docker + Bicep CLI, no Azure login); the group kql-run is opt-in
(cd sidecar && uv sync && uv run ruff check . && uv run black --check . && uv run mypy && uv run pytest --cov)
docker build -t brokersre-ib-gateway-sidecar:dev sidecar
IMAGE=brokersre-ib-gateway-sidecar:dev sidecar/tests/container/run.sh                    # sidecar smoke suite (SMOKE_TIMEOUT_SCALE=5 for an emulated arm64 image)
sidecar/tests/e2e/run.sh <gateway image> brokersre-ib-gateway-sidecar:dev                # gateway + sidecar on an internal network; never contacts IBKR
pwsh -NoProfile -Command "Invoke-Pester windows/tests" ; powershell -NoProfile -Command "Invoke-Pester windows/tests"   # Windows kit, Pester 6.2.0, under BOTH PowerShell 7 and Windows PowerShell 5.1
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path windows -Recurse -Settings windows/PSScriptAnalyzerSettings.psd1"   # PSScriptAnalyzer 1.25.0, 0 findings
scripts/readme-versions.sh --check                                                       # README version table matches versions.json (drop --check to regenerate)
scripts/qualify-paper.sh --image <ref> --secrets-dir <dir>                               # ONE real paper login (operator-run, never in CI; the container suite runs it offline)
pre-commit run --all-files
```

All of these must be green before claiming a change done; run them fresh.

## Invariants

1. **Every input is pinned and verified**: `versions.json` holds the base digest, the Gateway
   version and installer SHA-256 per architecture, and the IBC release tag and SHA-256. The
   Dockerfile fails the build on any mismatch. No other file carries a version of anything
   that goes INTO the gateway image. A companion that runs next to it pins its own third-party
   image by digest in the file that uses it: the Vector shipper in
   `compose/docker-compose.azure.yml`, repeated as the default of `vectorImage` in
   `azure/bicep/vm.bicep`; `azure/tests/run.sh` fails when the two differ. The sidecar image
   names its two base images by digest in the `FROM` lines of `sidecar/Dockerfile` (not in an
   `ARG`: Dependabot cannot see those) and its Python dependencies in `sidecar/uv.lock`. The
   Windows kit pins a `busybox` image by digest for two host-side probes in the one constant
   `$script:GwProbeImage` (`windows/src/Checks.ps1`); `windows/tests/Kit.Tests.ps1` fails on a
   second copy.
2. **No credentials anywhere**: not in this repository, not in image layers, not in stdout, not
   in `ps`. Secrets enter via `_FILE`, land only in tmpfs `config.ini` (0600), and are unset
   before children start. `tests/container/run.sh` checks PID 1's environment and the log volume.
3. **Events follow log contract v2** (`schemas/log-event.v2.schema.json`, `docs/log-contract.md`):
   every event goes through `log_event` (stdout and `events/events.jsonl`, identical lines,
   with `boot_id` and a gap-free `seq`); nothing else writes to stdout. Raw IBC and Gateway
   output goes to `/var/log/ibgateway/{ibc,jts}`; the phase file is
   `/var/log/ibgateway/state/phase`; resource samples go to `metrics/metrics.jsonl`. Changing a
   key, a phase, an event name or a path is a contract version bump coordinated with every
   consumer (the sidecar, the Azure pack, the Windows kit, the BrokerSRE agent). The Windows
   kit reads the phase tokens and the events `login_failed`, `login_failed_dialog` and
   `login_rejected_latched`; `windows-kit.yml` runs when `ibc-patterns.tsv` or
   `docs/log-contract.md` change, and a kit test fails on a phase it does not know.
4. **No sudo, no SSH/telnet, uid 1000, read-only root filesystem supported.** Adding a package
   needs a reason in the ADR log.
5. **One brokerage session per container** (`TRADING_MODE` is `live` or `paper`, never `both`).
6. **Honest health**: unhealthy while not logged in, including during a pending 2FA; nothing in
   this image restarts the Gateway on its own. The second-factor cap (`TWOFA_MAX_PROMPTS`)
   stops IBC and holds the container in phase `needs-human`; it never restarts, answers or
   bypasses anything. The rejected-login latch (`login-latch.sh`, ADR 0016) does the same at
   a start whose secret files IBKR already rejected: no IBC, phase `needs-human`, container
   held. A state that needs a person holds the container; it never exits into the restart
   policy. The latch stores the modification times of the secret files as a hash, never
   anything derived from a credential.
7. **IBKR binaries are never redistributed from here** (ADR 0007): the installer is fetched from
   IBKR at build time; the private archive is RocketEdge's internal fallback.
8. **Docker `latest` is never published**; `latest` is IBKR's channel name. Channel tags move
   only through `publish.yml` after Trivy passes on both platforms of the pushed digest;
   consumers pin digests. Tags are created from the scanned, signed digest by
   `scripts/promote-tags.sh`; nothing else may tag. In `publish.yml` and `rebuild.yml` every
   action is pinned by commit, Trivy by version, and no `${{ }}` appears inside a `run:`
   script (`tests/bats/ci/workflows.bats`).
9. **Tests never log in**: nothing started by a push or a pull request contacts IBKR; the IBC
   smoke test runs with `--network none`. The one exception is not a test: the qualification
   (`scripts/qualify-paper.sh`, `qualify-paper.yml`, ADR 0014) makes exactly one login to a
   PAPER account, is dispatched by hand, and its credentials live in the environment
   `paper-qualification` behind a required reviewer. It never answers a second factor and
   never retries. Do not add a retry, a schedule or a `pull_request` trigger to it.
10. Public repository: no BrokerSRE pricing, client names, Azure identifiers or internal plans.
11. Trademark sentence on every public artefact (README, release notes, image description).
12. **Examples are read-only**: no order, cancel or what-if API name under `examples/`
    (`examples/python/tests/test_no_order_api.py` scans for them), and no IBKR code or binary
    is ever committed (the C# sample takes the path of the user's own `CSharpAPI.dll`).
13. **The sidecar alerts and never acts**: no order, cancel or what-if call (a test asserts the
    exact set of API calls the probe can make, another the frames on the wire), no IBC
    command, no restart of the gateway, no second-factor automation, and no IBKR credential
    in its container. A human-needed state is derived from events, never from how long a
    phase has lasted. An alert counts as sent only when a channel accepted it.

## Layout

```text
Dockerfile                 two-stage build; ARGs come from docker-bake.hcl <- versions.json
docker-bake.hcl            targets stable/latest, tags, labels; scripts/bake-env.sh exports variables
scripts/fetch-installer.sh build-time installer fetch + SHA-256 verification (pre-fetched copy first)
rootfs/usr/local/bin/entrypoint.sh            orchestration under tini; SIGTERM -> IBC STOP
rootfs/usr/local/lib/brokersre/*.sh           common, log (events), render-config, java-env, start-xvfb/vnc/socat/ibc, classify-ibc-log, login-latch (a rejected login is not repeated), rotating-append, tail-gateway-logs, sampler (metrics), doctor (preflight), ibc-cmd, healthcheck
scripts/readme-versions.sh                    README version table <- versions.json (--check in CI; the detect workflows run it)
scripts/qualify-paper.sh                      one real paper login and its checks -> qualify-out/result.json (ADR 0014)
scripts/publish-channels.sh, check-bake-tags.sh, platform-digests.sh, check-report-arch.sh, promote-tags.sh   decisions of publish.yml as tested scripts (channel list, no tag in both channels, platform manifests, platform of a scan report, tags -> the scanned digest)
scripts/rebuild-decision.sh, rebuild-channels.sh, rebuild-issue.sh   decisions of rebuild.yml (fixable CRITICAL/HIGH -> rebuild request; one issue per channel, one comment per day, stop after REBUILD_MAX_ATTEMPTS days)
scripts/check-vex.sh, security/vex/               OpenVEX statements for IBKR's bundled jars and their drift check; docs/evidence.md maps due-diligence questions to artefacts
tests/bats/ci/workflows.bats, workflow-steps.awk    workflow policy as tests (gate flags, pins, no expression in a script, cron strings); tests/bats/ci/fixtures/ real Trivy reports
rootfs/usr/local/lib/brokersre/api-handshake.sh   read-only proof that the API answers (TWS API handshake only); HEALTHCHECK_API=handshake uses it
rootfs/etc/brokersre/                         ibc.config.ini.tmpl, jts.ini.tmpl, ibc-patterns.tsv (event classification), known-windows.txt (titles IBC handles)
schemas/log-event.v2.schema.json (current), log-event.v1.schema.json (history)
tests/bats/unit/*.bats (run inside the image), tests/container/run.sh (docker CLI), tests/fixtures/
compose/docker-compose.example.yml
compose/docker-compose.multi.yml, compose/README.md   several gateways on one host (profiles live/paper, commented third block)
scripts/check-compose-usernames.sh                    no two gateways with the same username (SHA-256; prints no username)
scripts/migrate-from-gnzsnz.sh                        gnzsnz .env -> this image's .env; report on stderr, never a value
examples/                                             wait-for-gateway.sh, compose-with-client.yml, python/ (uv, ib_async), csharp/ (.NET 10; the user supplies IBKR's CSharpAPI.dll), README.md
tests/compose/run.sh                                  both compose files above, started as shipped (docker CLI)
azure/                                                Log Analytics pack: bicep/ (tables, DCR, alerts, workbook, query pack; vm.bicep), vector/ (shipper config, redact.vrl, entrypoint), kql/ (alert and report queries, scenarios), vm/ + cloud-init/ (optional gateway VM), tests/run.sh; README.md (ADR 0012)
compose/docker-compose.azure.yml                      the shipper next to the gateway (profiles azure, azure-cert); Vector pinned by digest
sidecar/                                              optional second image (Python 3.14, uv): API probe, /livez /readyz /status /metrics, notifier; src/, tests/ (unit, container/, e2e/), schemas/status.v1.schema.json, Dockerfile, README.md (ADR 0010, docs/sidecar.md)
compose/docker-compose.sidecar.yml, -sidecar-shared.yml   the sidecar next to the gateway: own network namespace (default) or the gateway's (option)
windows/                                              host kit for Windows 10/11: setup, doctor, harden, start, uninstall (.ps1) over BrokerSre.Gateway.psm1 + src/{Native,Core,Secrets,Stack,Checks,Harden,Commands}.ps1; templates/compose.yaml.tmpl; tests/ (Pester); README.md (ADR 0011)
.github/workflows/  ci, azure-pack (the pack's offline suite), sidecar (tests, image, smoke, end to end), sidecar-publish (from main only), sidecar-rescan (weekly), windows-kit (Pester under 5.1 and 7, PSScriptAnalyzer), publish, rebuild, detect-releases, detect-ibc-release, qualify-paper (manual, environment paper-qualification) (CodeQL comes from GitHub default setup, enabled by the organisation)
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
- A pattern row must be checked against every place IBC writes similar text, in its Java
  source and in `ibcstart.sh` (whose `echo` lines carry no timestamp and no `IBC:` prefix).
  `Login has completed: exiting via ...` is IBC's stop message, not a login; anchor rows with
  `$` where IBC continues the sentence elsewhere.
- The phase file is written only through `phase_write` (`set_phase` for the entrypoint,
  `write_phase` for the classifier). Never write `state/phase` directly: the lock and the
  rule that the classifier cannot leave `stopping`, `stopped` or `exited` live there.
- On Windows the Docker Desktop file share can be very slow (listing 500 files took 42 s on
  2026-11-12), which makes `run-in-image.sh` take an hour. To iterate, start the image with
  `sleep`, stream the tree in (`tar -C <repo> --exclude=.git -cf - . | docker exec -i <name>
  tar -C /tmp/work -xf -`) and run bats there. In a test, wait for your own background
  processes by pid: a bare `wait` never returns when `BATS_TEST_TIMEOUT` is set.
- `scripts/migrate-from-gnzsnz.sh` carries its own copy of the doctor's known names (it must run
  outside the image); `tests/bats/ci/migrate-from-gnzsnz.bats` fails when the two differ, so a
  new variable goes into `doctor.sh`, `docs/env-vars.md` and the converter together.
- `docs/env-vars.md`: `doctor.bats` requires every backticked name in the first column of any
  table to be known to the doctor; keep compose-only variables out of that column.
- `docker-compose.multi.yml`: `docker compose down` without the profiles stops nothing; `exec
  <service>` and `ps` work without them. Docker mounts a compose tmpfs `noexec`: run a script
  placed there with `bash <file>`.
- `gitleaks dir examples` and markdownlint over `examples/**/*.md` also scan
  `examples/python/.venv` and the C# `bin`/`obj` folders: scan a clean checkout or a
  `git archive` export.
- ib_async 2.1.0: `readonly=True` still requests positions; `IB._onError` opens an
  account-summary subscription on every 1102; `timeout` applies per connect step; its loggers
  print IBKR's message text. The Python sample works around each (see its docstrings).
- `pgrep -f <text>` inside `bash -c '...'` (and so inside `docker exec ... bash -c`) matches the
  very shell that runs it: such a check can never fail. Look for the process by exact name
  (`pgrep -x java`) and read its `/proc/<pid>/cmdline`, or write the pattern as `[s]ampler.sh`.
  Found when a new test failed for that reason and an old one turned out to pass for it.
- Adding a preflight check changes the count in about ten assertions of `doctor.bats` (rows,
  "n passed", indexes into the event list) and the list in `docs/log-contract.md`; a new
  variable goes into `doctor.sh`, `docs/env-vars.md` and `scripts/migrate-from-gnzsnz.sh`.
- Azure pack: `bash azure/tests/run.sh [group...]` is the whole gate; never edit `run.sh` while
  it runs. Vector logs discarded over-long lines, hence the `VECTOR_LOG` override in
  `azure/vector/entrypoint.sh`; the pipeline canary guards it at every Vector bump.
  `azure/cloud-init/gateway.yaml` is pinned by `gateway.yaml.sha256`: change both
  deliberately, because existing VMs keep the old bootstrap. `vmConfig` in `vm.bicep` and
  `required_keys` in `azure/vm/apply-config.sh` change together. The account-id pattern
  lives in `redact.vrl`, `entrypoint.sh` and `apply-config.sh`. A helper image used by a
  check must be listed in `helper_images` in `run.sh` (pulled before any check): a first
  `docker run` of an image writes its pull notice to standard error, and a check that
  compares standard error then fails on a fresh machine only.
- Never end a pipeline with `grep -q` in a script that sets `pipefail`: the quiet grep exits
  at its first match, the writer gets SIGPIPE (exit 141) and the pipeline is "false" although
  the text was found. In an `if ...; then fail; else pass` check for a leaked secret that is
  a false pass. Write `grep ... >/dev/null`. It does not show on the Windows development
  host; it showed on the first Linux run.
- A consumer must not alert on how long a phase has lasted: an unanswered second-factor
  prompt flips the phase between `2fa-pending` and `login` every three minutes. Use events
  (`docs/log-contract.md`), as the Azure rule "human needed" does.
- Sidecar: regenerate `sidecar/schemas/status.v1.schema.json` after any change to the status
  model (`uv run brokersre-sidecar print-schema status`; the smoke suite compares the two).
  The default compose override gives the sidecar its own network namespace: it reaches the
  API through the relay (`GATEWAY_HOST`, 4004/4003), never the loopback port, and cannot use
  the IBC command server. A new gateway event that puts the gateway into `needs-human` needs
  its cause added to `notify/rules.py`, or the alert says only that the phase is `needs-human`.
- trivy-action ignores `severity` when `format: sarif` unless `limit-severities-for-sarif: "true"`
  is set; with `exit-code: 1` a gate then fails on any severity. Bump the Trivy version in the
  three workflows, `tests/bats/ci/workflows.bats` and `docs/evidence.md` together.
- A new or vanished CVE in IBKR's jars shows as a VEX drift warning in CI and publish: update
  `security/vex/ibgateway-vendor-jars.openvex.json` (bump `version`, never `fixed`, never
  `not_affected` without evidence). `tests/bats/ci/fixtures/vex/in-sync.openvex.json` and
  `fixtures/trivy/gateway-library.json` are a frozen pair: refresh both or neither.
- A bats line `! command` that is not the last line of a test never fails it (checked with a
  four-line probe in bats 1.14): write `! command || false`, or `run ! command` with
  `bats_require_minimum_version 1.5.0`. Twelve such lines existed, several guarding "no secret
  appears here".
- jq's `test("^...$")` matches per line; validate tokens with a negated character class.
- syft and Trivy read the runner's platform from an image index. Pass a platform manifest
  digest (`scripts/platform-digests.sh`) or `--platform`, and check the result
  (`scripts/check-report-arch.sh`). The CI-script suite must also pass under gawk (the GitHub
  runner), not only under the image's mawk.
- Windows kit: sources are ASCII and avoid `&&`, `??` and the ternary (Windows PowerShell 5.1).
  Every external command goes through one wrapper in `windows/src/Native.ps1` so Pester can mock
  it. After adding a function, add it to `FunctionsToExport` in `BrokerSre.Gateway.psd1` (a test
  compares the list). The folder is `src`, not `lib`: a common global gitignore excludes `lib`.
- Windows kit: `docker compose up -d` does not recreate a container when only a secret file's
  content changed (measured 2026-11-12); setup passes `--force-recreate` after writing credentials.
- Windows kit: never use `Set-Acl` on a folder with inheritance off (it needs
  SeSecurityPrivilege); use `DirectoryInfo.SetAccessControl` (5.1) or
  `FileSystemAclExtensions.SetAccessControl` (7), as `Protect-GwSecretFolder` does.
- Windows kit: `wsl -d <distro> --exec docker ...`, never `wsl -- docker ...`; with `--` the
  line goes through the Linux shell and `|` in a format string becomes a pipe.
- Windows kit: a command that times out is ended with its whole process tree
  (`Invoke-GwProcessTreeKill`); `Process.Kill()` alone leaves `docker-compose.exe` running.
- Windows kit: `harden.ps1 -Undo` acts only on journal entries the harden functions can write
  (`Get-GwJournalEntryProblem`). A new kind of host change needs its allow-list entry and a test.
  A new folder under `C:\` is writable by every local user: the kit closes its gateway folder
  before writing anything into it.
