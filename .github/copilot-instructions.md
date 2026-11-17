# CLAUDE.md — brokersre-ib-gateway (project agent contract)

Public, MIT-licensed container image of IB Gateway + IBC for unattended, observable operation;
derived from gnzsnz/ib-gateway-docker and consumed by RocketEdge BrokerSRE. This file and
`.github/copilot-instructions.md` are the same contract; keep them identical.

## THE COMMANDS

```bash
scripts/build-image.sh [--channel stable|latest] [--strict] [--installer FILE] [--platform linux/amd64|linux/arm64] [--tag NAME] [--no-smoke] [--cache-dir DIR] [--print-plan]   # THE build (only Docker needed; ADR 0018): exit 0 built, 1 failed, 2 usage, 3 IBKR unreachable and no usable cached installer, 4 --strict and IBKR serves another version; last 7 stdout lines `key: value`
pwsh -NoProfile -File scripts/build-image.ps1 [-Channel ...] [-Strict] [-Installer FILE] [-Platform ...] [-Tag ...] [-NoSmoke] [-CacheDir DIR] [-PrintPlan]   # the same from PowerShell 7 or Windows PowerShell 5.1
pwsh -NoProfile -Command "Invoke-Pester scripts/tests" ; powershell -NoProfile -Command "Invoke-Pester scripts/tests"   # build-image.ps1, Pester 6.2.0, both editions (docker mocked)
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path scripts -Recurse -Settings windows/PSScriptAnalyzerSettings.psd1"   # 0 findings
IMAGE=<image> tests/container/run.sh --only ibc-smoke                                     # the offline IBC smoke test alone (what build-image runs after a build)
eval "$(scripts/bake-env.sh)"                                        # variables from versions.json (jq), incl. <CHANNEL>_BUILD_STAMP
docker buildx bake --print stable latest > /dev/null                 # bake definition resolves
docker buildx bake stable --set '*.platform=linux/amd64' --load      # maintainer build of the PINNED version (fails when IBKR moved past it and no archived copy is in downloads/)
hadolint Dockerfile ; shellcheck -x rootfs/usr/local/bin/*.sh rootfs/usr/local/lib/brokersre/*.sh scripts/*.sh tests/bats/*.sh tests/container/*.sh tests/compose/*.sh tests/recipes/*.sh examples/*.sh
git clone --config core.autocrlf=false --config core.eol=lf --depth 1 -b v1.14.0 https://github.com/bats-core/bats-core tests/.bats-core   # once; LF matters inside the image (core.eol too: bats-core says `* text=auto`)
tests/bats/run-in-image.sh brokersre-ib-gateway:stable                                  # unit suite, inside the image (the image scripts/build-image.sh built)
tests/.bats-core/bin/bats tests/bats/ci                                                  # CI scripts (release and rebuild policy, tag promotion, VEX drift, workflow policy, archive pre-fetch, README table, documented commands, build helper against a fake IBKR server, Dockerfile stamp check), on the host (needs jq; doc-commands.bats needs python3, zsh and sh; build-image.bats needs curl and python3; dockerfile-stamp.bats and bake-env.bats need Docker)
scripts/check-vex.sh security/vex/ibgateway-vendor-jars.openvex.json                     # VEX document valid (add Trivy `--pkg-types library --list-all-pkgs --format json` reports to compare)
IMAGE=brokersre-ib-gateway:stable tests/container/run.sh                                 # offline container tests (incl. the reference compose as shipped)
IMAGE=brokersre-ib-gateway:stable tests/compose/run.sh                                   # compose files as shipped (several gateways, gateway + strategy, console override); offline
tests/recipes/run.sh                                                                     # docs/recipes: vector validate, then an offline run against a stand-in receiver (needs only Docker)
scripts/check-upgrade.sh --container <name>                                              # channel tag vs running digest; one JSON document; exit 0/10/2; asks only
(cd examples/python && uv sync --locked && uv run ruff check . && uv run black --check . && uv run mypy && uv run pytest)
(cd examples/csharp && dotnet build -warnaserror && dotnet test && dotnet format GatewayClient.slnx --verify-no-changes)
bash azure/tests/run.sh [group...]                                                       # Azure pack, offline (Docker + Bicep CLI, no Azure login); the group kql-run is opt-in
(cd sidecar && uv sync && uv run ruff check . && uv run black --check . && uv run mypy && uv run pytest --cov)
docker build -t brokersre-ib-gateway-sidecar:dev sidecar
IMAGE=brokersre-ib-gateway-sidecar:dev sidecar/tests/container/run.sh                    # sidecar smoke suite (SMOKE_TIMEOUT_SCALE=5 for an emulated arm64 image)
sidecar/tests/e2e/run.sh <gateway image> brokersre-ib-gateway-sidecar:dev                # gateway + sidecar on an internal network; never contacts IBKR
sidecar/tests/e2e/fresh-volumes.sh <gateway image> brokersre-ib-gateway-sidecar:dev      # both images created together on fresh volumes; the shipped compose files started without a login
pwsh -NoProfile -Command "Invoke-Pester windows/tests" ; powershell -NoProfile -Command "Invoke-Pester windows/tests"   # Windows kit, Pester 6.2.0, under BOTH PowerShell 7 and Windows PowerShell 5.1
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path windows -Recurse -Settings windows/PSScriptAnalyzerSettings.psd1"   # PSScriptAnalyzer 1.25.0, 0 findings
scripts/readme-versions.sh --check                                                       # README version table matches versions.json (drop --check to regenerate)
git ls-files -s | scripts/check-file-modes.sh                                            # every tracked *.sh is 100755 in git (a Windows host does not record the bit)
scripts/qualify-paper.sh --image <ref> --secrets-dir <dir>                               # ONE real paper login (operator-run, never in CI; the container suite runs it offline)
pre-commit run --all-files
```

All of these must be green before claiming a change done; run them fresh.

## Invariants

1. **Every input is pinned and verified**: `versions.json` holds the base digest, the Gateway
   version, IBKR's `build_datetime` and installer SHA-256 per architecture, and the IBC release
   tag and SHA-256. The Dockerfile fails the build on any mismatch, and on an installed Gateway
   whose build stamp differs from `IB_GATEWAY_BUILD_STAMP` (`fetch-installer.sh --check-stamp`).
   The one deliberate exception is the build helper's fall-forward (ADR 0018): when IBKR serves
   another version than the pin, `scripts/build-image.sh` verifies it against IBKR's own stamp
   instead of a pin and labels the image `com.rocketedge.brokersre.qualified=no`; `--strict`
   refuses it. No other file carries a version of anything that goes INTO the gateway image
   (the build helper's base image, `docker:<v>-cli` by digest in
   `scripts/build-helper/Dockerfile`, builds nothing into it). A companion that runs next to it pins its own third-party
   image by digest in the file that uses it: the Vector shipper in
   `compose/docker-compose.azure.yml`, repeated as the default of `vectorImage` in
   `azure/bicep/vm.bicep`; `azure/tests/run.sh` fails when the two differ. The sidecar image
   names its two base images by digest in the `FROM` lines of `sidecar/Dockerfile` (not in an
   `ARG`: Dependabot cannot see those) and its Python dependencies in `sidecar/uv.lock`. The
   Windows kit pins a `busybox` image by digest for two host-side probes in the one constant
   `$script:GwProbeImage` (`windows/src/Checks.ps1`); `windows/tests/Kit.Tests.ps1` fails on a
   second copy. The log-shipper recipes name the Vector image once, in
   `docs/recipes/docker-compose.vector.yml`; `tests/recipes/run.sh` fails on a second copy
   and when it differs from the Azure pack's pin, so the repository carries one Vector
   version: bump the two files and `vm.bicep` together.
2. **No credentials anywhere**: not in this repository, not in image layers, not in stdout, not
   in `ps`. Secrets enter via `_FILE`, land only in tmpfs `config.ini` (0600), and are unset
   before children start. `tests/container/run.sh` checks PID 1's environment and the log volume.
   The opt-in screenshots (`SCREENSHOTS=yes`, `screenshot.sh`) are pictures of the screen and
   can show the username: they are private files under `screens/` on the log volume, off by
   default, and no event, log line or shipper of this repository may carry one.
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
   anything derived from a credential. The break-glass console (ADR 0017) is for a person:
   view-only unless `VNC_VIEW_ONLY=no`, started with `-noremote` so the mode cannot change
   while the container runs, every visit an event; nothing in the image connects to it.
7. **IBKR binaries are never redistributed from here** (ADR 0007): the installer is fetched from
   IBKR at build time; the private archive is RocketEdge's internal fallback. The image holds
   the installed Gateway, so it is not distributed publicly either (ADR 0018): users build it
   with `scripts/build-image.sh`; RocketEdge's own image goes to a package ghcr.io does not
   serve anonymously (spec phases 3 and 4; the former public package was withdrawn on
   2026-11-17; the package was created again by hand, internal and not linked to this
   repository, ADR 0018 amendment). No job started by a push or a pull request reads the package (CI and the sidecar's
   end-to-end job test `brokersre-ib-gateway:stable` built in the job, Trivy with
   `TRIVY_IMAGE_SRC=docker`); `publish.yml`, the daily scan of `rebuild.yml` and
   `qualify-paper.yml` read it after a `ghcr.io` login with the workflow's token; no workflow
   sets a visibility, and release notes never tell the public to pull
   (`tests/bats/ci/private-package.bats`). Nothing with IBKR software is pushed before
   `publish.yml`'s job `private-package`, and again the step right before the push, have
   proven that ghcr.io refuses an anonymous TOKEN request for the package
   (`scripts/check-package-private.sh`; a granted token means anonymous pulls are allowed,
   whatever the manifest answers; a package that a workflow of this public repository creates
   comes out public, seen 2026-11-17; an internal package passes the check too, L40). Each gate step passes on exit 0 only, without `continue-on-error`. `qualified_by_project: yes` means "equals the pin, which passed the offline
   CI", never "logged in with": a stable pin moves without a person unless
   `STABLE_AUTOMERGE=false`.
   The installer cache of the build helper lives on the user's machine, never here.
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
scripts/fetch-installer.sh build-time installer fetch + SHA-256 verification (pre-fetched copy first); --read-stamp / --check-stamp: the installed Gateway's build stamp (i4jparams.conf)
scripts/build-image.sh, scripts/build-image.ps1   the build for users and CI (ADR 0018, spec docs/specs/2026-11-17-private-image-public-recipe.md); thin wrappers: helper image, resolve, buildx build, smoke test, accept
scripts/resolve-installer.sh                      the ONE implementation of resolve/download/verify/cache (resolve, accept, discard), run in the helper container; BROKERSRE_TEST_IBKR_BASE_URL is its test-only override
scripts/build-helper/Dockerfile                   the helper image (docker CLI pinned by digest + bash, curl, jq), built locally as brokersre-ib-gateway-build-helper:local
scripts/tests/build-image.Tests.ps1               Pester tests of build-image.ps1 (docker mocked)
tests/bats/ci/build-image.bats, fake-ibkr.py, fake-installer.bash   the helper and wrapper against a fake IBKR server and fake install4j installers (stub docker)
tests/bats/ci/dockerfile-stamp.bats, fetch-installer.bats, bake-env.bats   the stamp check in the Dockerfile's setup stage, in the script, and on the bake path
rootfs/usr/local/bin/entrypoint.sh            orchestration under tini; SIGTERM -> IBC STOP
rootfs/usr/local/lib/brokersre/*.sh           common, log (events), render-config, java-env, start-xvfb/vnc/socat/ibc, classify-ibc-log, login-latch (a rejected login is not repeated), screenshot (opt-in picture of the screen, a copy of Xvfb's framebuffer file), rotating-append, tail-gateway-logs, sampler (metrics), doctor (preflight), ibc-cmd, healthcheck
scripts/readme-versions.sh                    README version table <- versions.json (--check in CI; the detect workflows run it)
scripts/qualify-paper.sh                      one real paper login and its checks -> qualify-out/result.json (ADR 0014)
scripts/publish-channels.sh, check-bake-tags.sh, platform-digests.sh, check-report-arch.sh, promote-tags.sh, release-upsert.sh   decisions of publish.yml as tested scripts (channel list, no tag in both channels, platform manifests, platform of a scan report, tags -> the scanned digest, the release written with retries and read back)
scripts/rebuild-decision.sh, rebuild-channels.sh, rebuild-issue.sh   decisions of rebuild.yml (fixable CRITICAL/HIGH -> rebuild request; one issue per channel, one comment per day, stop after REBUILD_MAX_ATTEMPTS days)
scripts/release-decision.sh, detect-scope.sh   decisions of detect-releases.yml (new version / re-upload / none; whether an hourly run does the full check: only at the first sight of a version)
scripts/check-vex.sh, security/vex/               OpenVEX statements for IBKR's bundled jars and their drift check; docs/evidence.md maps due-diligence questions to artefacts
tests/bats/ci/workflows.bats, workflow-steps.awk    workflow policy as tests (gate flags, pins, no expression in a script, cron strings); tests/bats/ci/fixtures/ real Trivy reports
tests/bats/ci/private-package.bats, detect-scope.bats   the private package (who names it, logins before reads, the visibility gate before any push, local test images, no pulls, release notes); hourly detection (scope script, cron strings, concurrency, the auto-merge switch)
scripts/check-package-private.sh, tests/bats/ci/check-package-private.bats   publish.yml's visibility gate: 0 private only when ghcr.io refuses the anonymous token request (401/403; an internal package too, L40), 1 public (token and manifest 200), 3 inconclusive (anything else, including a granted token with a manifest 404); takes the repository WITHOUT `ghcr.io/` (`rocketedge/brokersre-ib-gateway visibility-probe`)
tests/bats/ci/doc-commands.bats, doc-block.awk, doc-exec-paths.awk, pty-answers.py   documented commands as tests: marked secret blocks typed into through a pty under bash, zsh and sh; container paths of exec commands in the Git Bash-safe `//` form
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
sidecar/                                              optional second image (Python 3.15, uv): API probe, /livez /readyz /status /metrics, notifier; src/, tests/ (unit, container/, e2e/), schemas/status.v1.schema.json, Dockerfile, README.md (ADR 0010, docs/sidecar.md)
compose/docker-compose.sidecar.yml, -sidecar-shared.yml   the sidecar next to the gateway: own network namespace (default) or the gateway's (option)
windows/                                              host kit for Windows 10/11: setup, doctor, harden, start, uninstall (.ps1) over BrokerSre.Gateway.psm1 + src/{Native,Core,Secrets,Stack,Checks,Harden,Commands}.ps1; templates/compose.yaml.tmpl; tests/ (Pester); README.md (ADR 0011)
.github/workflows/  ci (lint, build-test with scripts/build-image.sh, build-image-ps1 under 5.1 and 7, recipes, examples), azure-pack (the pack's offline suite), sidecar (tests, image, smoke, end to end), sidecar-publish (from main only), sidecar-rescan (weekly), windows-kit (Pester under 5.1 and 7, PSScriptAnalyzer), publish, rebuild, detect-releases, detect-ibc-release, qualify-paper (manual, environment paper-qualification) (CodeQL comes from GitHub default setup, enabled by the organisation)
rootfs/usr/local/lib/brokersre/vnc-hook.sh            x11vnc -afteraccept/-gone hook -> vnc_client_connected, vnc_client_disconnected (ADR 0017)
compose/docker-compose.console.yml                    break-glass console over the reference compose (secret, VNC_VIEW_ONLY, loopback bridge port); docs/console.md
tests/container/vnc-client.sh                         RFB 3.8 client in bash with DES: the tests' stand-in for a person on the console
scripts/check-upgrade.sh                              channel tag vs running digest (brokersre.upgrade-check.v1); asks only; docs/upgrade-check.md
docs/recipes/                                         Vector recipes (Loki, OTLP, Datadog), docker-compose.vector.yml (the recipes' one Vector pin), README.md
tests/recipes/                                        run.sh (validate + offline run against a stand-in), receiver.yaml, fixtures/; CI job recipes
docs/  architecture.md, changes.md, limitations.md, env-vars.md, log-contract.md, upgrade-policy.md, migrating-from-gnzsnz.md, console.md, upgrade-check.md, passkeys.md, recipes/, specs/ (design notes, nothing built), runbooks/ (one page per sidecar alert class), adr/
```

## Gotchas

- IBKR's installer URLs are unversioned (a versioned path answers 404); when IBKR moves a
  channel, the bake path's `fetch-installer.sh` fails with a checksum mismatch by design (bump
  `versions.json`, or drop the archived installer under `downloads/`). `scripts/build-image.sh`
  falls forward instead: IBKR's `version.json` (`<channel>-standalone/version.json`, JSONP)
  before and after the download, the installer's own stamp and the installed stamp must agree,
  and the image is labelled not qualified. The stamp is `applicationVersion="(.<suffix>)
  <buildDateTime>"` in `.install4j/i4jparams.conf`; the version is `applicationName`'s number
  plus that suffix. A re-pin needs `build_datetime` too (bake-env.sh refuses a channel without
  it, and the Dockerfile fails a stamp that differs).
- The build helper runs as the calling user on Linux (`--user uid:gid`, so the cache and
  `downloads/` stay the user's) and creates the cache directory before mounting it (Docker
  would create a missing one as root). It writes into `downloads/` only for the duration of a
  build, and never touches a file that was there before (same bytes: used and kept,
  `context_owned: no`; other bytes: exit 1). `build-image.sh` must stay bash 3.2-safe (macOS):
  no empty-array expansion under `set -u`, no `${x,,}`, no `mapfile`.
- The helper's cache is keyed by version AND SHA-256 (`installers/<v>/<arch>/<sha256>/`) and
  records each entry's source (`ibkr`, `installer`, `override`); a non-pinned version is reused
  only from the origin of the current run, so a test server's or a user's bytes never stand in
  for IBKR's (review of #39). Every trust check has a bats test that fails when the check is
  weakened; when you touch `resolve-installer.sh`, mutate the check you changed and watch a
  test fail (the review's ten mutations are listed in `docs/changes.md`). Redirects must lead
  to HTTPS also under `BROKERSRE_TEST_IBKR_BASE_URL`; a docker failure of the helper run
  (125-127) is exit 1.
- PowerShell's parameter binder ends a script with exit 1 before it runs when a parameter is
  given without its value; `build-image.ps1` therefore parses `$args` itself to keep exit 2
  for usage errors. In Pester, `$script:` inside a function defined in `BeforeAll` does not
  reach the variables the mocks and the tests share (pass them as parameters), and a function
  that returns an array of arrays must `return , $array` or the caller indexes the first
  inner element. A test that runs a script as a process uses `Start-Process` with
  `-RedirectStandardError <file>`, never `& exe 2>$null`: under `$ErrorActionPreference =
  'Stop'` (the CI steps) a Windows PowerShell 5.1 host turns the redirected standard error
  line into a terminating error (first CI run of the wrapper's tests, 2026-11-17).
- A `head ... | grep -m 1` under `pipefail` is the `grep -q` trap again (SIGPIPE to the
  writer): `resolve-installer.sh` reads the installer header with `sed -n` over the whole
  input. Setting `BATS_TEST_TIMEOUT` in `setup_file` left every test of a suite waiting on its
  `sleep` watchdog in the Alpine runner (2026-11-17, not isolated); the suites do not set it.
- `ibcstart.sh` resolves Java from `.install4j/inst_jre.cfg` in the Gateway directory; the
  Dockerfile writes it (bundled JRE on x64, system OpenJDK 25 on arm64).
- Four rows of `ibc-patterns.tsv` are confirmed by a real log, the rest are from IBC 3.24.x
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
- A temporary image for local iteration (an image you built plus `COPY rootfs/ /`) is enough
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
  tar -C //tmp/work -xf -`) and run bats there. In a test, wait for your own background
  processes by pid: a bare `wait` never returns when `BATS_TEST_TIMEOUT` is set.
- A Windows host records a new script as `100644` and still shows and runs it as executable
  (Git Bash, the Docker Desktop share, a tree streamed with `tar`), so a missing execute bit
  passes every local run and fails on the Linux runner with "Permission denied" (it did, on
  `screenshot.sh`). Add new scripts with `git add --chmod=+x <path>`; before pushing run
  `git ls-files -s | scripts/check-file-modes.sh`, which the lint job runs too.
- `scripts/migrate-from-gnzsnz.sh` carries its own copy of the doctor's known names (it must run
  outside the image); `tests/bats/ci/migrate-from-gnzsnz.bats` fails when the two differ, so a
  new variable goes into `doctor.sh`, `docs/env-vars.md` and the converter together.
- `docs/env-vars.md`: `doctor.bats` requires every backticked name in the first column of any
  table to be known to the doctor; keep compose-only variables out of that column.
- `docker-compose.multi.yml`: `docker compose down` without the profiles stops nothing; `exec
  <service>` and `ps` work without them. Docker mounts a compose tmpfs `noexec`: run a script
  placed there with `bash <file>`.
- RocketEdge no longer distributes a public image (ADR 0018; the former public package was
  withdrawn on 2026-11-17): every shipped gateway service defaults to
  `brokersre-ib-gateway:stable` with a literal `pull_policy: never` (a missing image fails with
  "No such image" instead of a Docker Hub lookup; `pull --policy missing` and `up --pull
  missing` override it, Compose 2.22.0 and later; `docker pull <ref>` works with any version).
  Never interpolate `pull_policy`: compose validates the
  key against its pattern even under `config --no-interpolate`, which
  `sidecar/tests/test_docs.py` uses for every shipped file (the Windows kit's template keeps
  the literal line and `ConvertTo-GwComposeText` replaces it with `missing` for a name with a
  registry path). The Azure VM overlay (`apply-config.sh`) sets `pull_policy: missing` for the
  digest its userData names. `setup.ps1` builds a missing `brokersre-ib-gateway:stable` or
  `:latest` with `scripts/build-image.ps1` (`Invoke-GwImageBuild`); with Docker Engine in WSL
  it copies a named list of the build's inputs into the distribution first
  (`Invoke-GwWslImageBuild`: Dockerfile, `.dockerignore`, `versions.json`, `rootfs/`, the
  build, resolve and fetch scripts, `scripts/build-helper/`, `tests/container/run.sh`), never
  the whole tree (a checkout holds IBKR credentials in `compose/secrets`) and never builds from
  `/mnt/c`; a new file that `build-image.sh` reads joins that list. `.dockerignore` admits only
  the Dockerfile's inputs and excludes `**/secrets`, `**/.env`, `**/*.env` after the re-includes
  (`tests/bats/ci/build-context.bats`). `start.ps1` never builds. Docs say "no longer
  distributes a public image" and "was withdrawn on 2026-11-17"; until a publish has run
  (owner steps in `tasks/todo.md`) they say no RocketEdge image is published, and never
  promise a date.
  `qualified_by_project: yes` means the pin passed the offline CI, never that a login did.
- COPY takes owner and mode from the build host (Windows context: 0755 on every file; a 0777
  context left `/etc` and `/usr` world-writable): the Dockerfile sets owner and mode of every
  path from `rootfs/` and of `/etc`, `/usr`, `/usr/local`, `/usr/local/bin`, `/usr/local/lib`
  right after the COPY; the container suite checks them ("files from rootfs/ have fixed
  modes"). A new file under `rootfs/` outside those trees needs its mode set there too.
- Proxies reach a build only through the Docker CLI's `config.json` (`proxies`): the CLI
  passes them into the helper container and as build arguments; `HTTPS_PROXY` in the calling
  shell is not forwarded by `build-image.sh`/`.ps1` (checked with a local Squid, 2026-11-17).
  Windows PowerShell 5.1 drops inner double quotes of a native argument
  (`--format '{{index .Config.Labels "x"}}'` fails); document `{{json .Config.Labels}}` with
  `ConvertFrom-Json` for PowerShell.
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
  lives in `redact.vrl`, `entrypoint.sh` and `apply-config.sh`, and in the sidecar (next
  item). A helper image used by a check must be listed in `helper_images` in `run.sh`
  (pulled before any check): a first `docker run` of an image writes its pull notice to
  standard error, and a check that compares standard error then fails on a fresh machine
  only.
- The shape of an account id (an optional `D`, then `U`, `F` or `I`, up to two further capital
  letters, 5 to 9 digits; as a regular expression `D?[UFI][A-Z]{0,2}\d{5,9}`, with `[0-9]`
  for `\d` in `redact.vrl`, where `\d` takes any script's digits and `slice!` counts bytes)
  is written in four places that change together, each with its tests: `ACCOUNT_RE` in
  `sidecar/src/brokersre_sidecar/redaction.py` (the label check refuses a label it would
  rewrite; the farm-name guard of `probe/tracker.py` refuses five digits in a row instead,
  because the pattern does not start behind a capital and an id glued to a farm stem always
  is), rules 1 to 3 of `azure/vector/redact.vrl`, `account_like` in
  `azure/vector/entrypoint.sh` and `good_label` in `azure/vm/apply-config.sh` (`run.sh`
  fails when the last two differ in text, and `label_verdicts` when the three Azure copies
  decide one of its boundary labels differently or unexpectedly; the VRL unit tests pin
  each rule at the bounds of the shape). The text follows: the bundle MANIFEST
  (`support/bundle.py`), `sidecar/README.md`, `azure/README.md`, `docs/limitations.md` L32.
  The prefixes are IBKR's, the letters after them are one observation plus headroom: a real
  paper id (`DU`, one more letter, six digits; 2026-11-16) passed the earlier shape and a
  support bundle carried it in full, while every fixture agreed with the pattern. Take a
  new shape from the shape of a real id, and never write a real id into a test, a fixture,
  a commit or a pull request.
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
- The sidecar's Python version is written in seven places that change together:
  `requires-python`, the black target, the ruff target and mypy's `python_version` in
  `sidecar/pyproject.toml`, `sidecar/.python-version`, the `FROM python:<minor>-slim@<digest>`
  line of `sidecar/Dockerfile`, and `sidecar/uv.lock` (`uv lock`). Dependabot bumps only the
  `FROM` line when a new minor appears, and that pull request cannot build ("No interpreter
  found for Python ==3.14.*"): take it as the notice, verify that the dependencies resolve and
  the suite passes on the new minor, and make the whole change in one pull request.
- A change to what the sidecar image is (interpreter, dependencies, behaviour) needs a new
  sidecar version: `sidecar-publish.yml` never moves an existing version tag, so a change
  merged under the old version is published as `sha-<commit>` only, and the next security
  rebuild (`<version>-rYYYYMMDD`) would change the image under the same version. The version
  is written in `sidecar/pyproject.toml`, `sidecar/src/brokersre_sidecar/__init__.py`,
  `ARG VERSION` of `sidecar/Dockerfile`, `sidecar/uv.lock`, the image tag in both sidecar
  compose files and `sidecar/README.md`, and five test assertions (`grep -rn` the old number).
- Every sidecar `AlertClass` has a runbook `docs/runbooks/<class>/README.md` (first line: `#` and
  the catalogue title; sections What it means, Check first, What to do, What not to do,
  When it clears) and a row in `docs/runbooks/README.md`; `sidecar/tests/test_docs.py` fails
  on a class without a page, a page without a class, and a relative link or `#anchor` that
  leads nowhere. Change a rule's firing or clearing condition and its page together, and
  never write into a page what the code does not do (no measured claims without a run).
- GitHub's package behaviour, seen 2026-11-17 (ADR 0018 amendment): a package a workflow of
  this public repository creates comes out PUBLIC (publish.yml's gate stopped that run); one
  pushed with a personal token into this enterprise organisation comes out INTERNAL (every
  enterprise member may read it, and per GitHub's docs every workflow of the enterprise; the
  gate cannot tell it from private, L40); the `org.opencontainers.image.source` label did NOT
  link it to the repository (the API names none), and a package without a link refuses the
  workflow's token (`permission_denied: write_package`) until "Manage Actions access" grants
  the repository. Never delete the package again to "fix" its visibility: change it in its
  settings, and recreate it only by the hand procedure in ADR 0018.
- The gateway package is not public (ADR 0018). Trivy, syft (`anchore/sbom-action`, also when it
  pulls through the Docker daemon), cosign, `imagetools` and `attest-build-provenance` all read
  the credential `docker/login-action` writes to the Docker CLI's `config.json`; a job that
  reads the package needs that login step before its first read, unconditionally, and
  `packages: read` (or `write`). Trivy's default image source order ends with `remote`: a step
  that must scan the local build sets `TRIVY_IMAGE_SRC=docker`, and test images carry a name
  without a registry (`brokersre-ib-gateway:stable`), so a missing build fails instead of
  scanning or pulling something else.
- `detect-releases.yml` runs hourly, but only the daily run (`0 6 * * *`, repeated in the scope
  step's condition) and the first sight of a version download the installers
  (`scripts/detect-scope.sh`); a closed update pull request is opened again by the daily run,
  as ADR 0009 says. `github.event.schedule` is the cron string that started the run.
- trivy-action ignores `severity` when `format: sarif` unless `limit-severities-for-sarif: "true"`
  is set; with `exit-code: 1` a gate then fails on any severity. Bump the Trivy version in the
  three workflows, `tests/bats/ci/workflows.bats` and `docs/evidence.md` together.
- `publish.yml` writes the release only through `scripts/release-upsert.sh` (a test fails on a
  `gh release upload|create|edit|delete-asset` in the workflow): the step runs after the tags
  have moved, and a bare `gh` command died there of one HTTP 502. `gh release view` exits 1
  both for "release not found" and for a server error; only the message tells them apart. If
  a publish still fails in "Tag and release", the tags and the release disagree: compare
  `docker buildx imagetools inspect --raw <image>:<tag> | sha256sum` with the release's
  `digests-<channel>.json` (it can be missing: replacing an asset deletes the old one
  first), then `gh run rerun <id> --failed` (L30). `gh release create` with assets makes a
  draft first; a failed creation can leave it, and an update does not publish a draft
  unless it says `--draft=false`. A variable set inside `$(...)` is lost: keep a failure
  reason in a file when the failing call runs in a command substitution.
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
- A screenshot needs no tool: `Xvfb -fbdir <dir>` keeps the framebuffer in `<dir>/Xvfb_screen0`
  (XWD), and `screenshot.sh` copies it. Do not add `xwd`, `import` or a converter to the image
  for this (invariant 4). The option stays opt-in while a picture can show the username.
- x11vnc 0.9.17: `PORT=5900` goes to stdout even with `-quiet`; hooks (`-afteraccept`, `-gone`)
  inherit descriptors 0 to 2 only, so the container's stdout is passed as descriptor 0 and
  the hook command ends in `>&0`; `-gone` also runs for a connection that never authenticated;
  without `-noremote` any process on the display lifts `-viewonly` (`x11vnc -R noviewonly`);
  there is no idle-disconnect option. Because of `-noremote`, a test that asks where the
  pointer is (`x11vnc -Q pointer_pos`) starts a second, throwaway x11vnc first.
- A VNC client must authenticate (DES) before x11vnc runs `-afteraccept`; the image has no
  client, so tests use `tests/container/vnc-client.sh` (`docker exec -i <c> bash -s -- ... <file`).
- Vector 0.61: `${VAR}` is not expanded unless started with
  `--dangerously-allow-env-var-interpolation` (recipes use files and `SECRET[files.x]`);
  `to_unix_timestamp(x, unit: "nanoseconds")` is fallible; the `http_server` source removes a
  request's `Content-Encoding` itself; the `datadog_agent` source rejects attributes beyond
  the agent's fixed fields; the image runs as root and `/var/lib/vector` is root's. A new
  named volume takes owner and mode from the image directory it is mounted over.
- `docker buildx imagetools inspect --format ...` fetches every platform's manifest (Docker Hub
  and public ECR answered 429); `--raw` is one request and `sha256sum` of it is the digest.
- gitleaks `generic-api-key` flags a word containing `auth` or `key` next to `=` and a hex
  string (`FAKE_VNC_SESSION=unauthenticated BOOT_ID=...`, `datadog_key="..."`): name and
  generate test values accordingly.
- A stack of branches must be re-checked after a commit is added below: a branch that forked
  earlier does not get it (the `quiet_grep` fix was missing from every branch above the
  supply-chain one). `git merge-base --is-ancestor <lower> <upper>` for each pair, before
  building on the top.
- `unknown_window` means a window that STAYS open (`UNKNOWN_WINDOW_GRACE_S`, 10 s), decided in
  the read loop of `classify-ibc-log.sh`: the `read` has a time limit only while a window
  waits, and what bash hands back of an unfinished line at the limit is kept (`LC_ALL=C`, or
  bash can drop bytes there). Time is `/proc/uptime` (bash's `SECONDS` only where it cannot
  be read at start; a failed read later keeps the last value). A due window is reported
  only once no line of IBC is waiting (its "closed" line may be in the pipe), for at most
  one second counted from the first postponement, never from the due time (after a pause
  the window is long overdue and its "closed" line is what waits). A new
  IBC (`ibc_version`) empties the waiting list: `ibcstart.sh` relaunches the Gateway inside
  one classifier run and the old process writes no "closed" line. Never put a title that
  says nothing about the content (`Warning`) on `known-windows.txt`: the grace period covers
  the one IBC answers; a list line that starts with `frame:` applies to frames only. A test of
  the list sets `UNKNOWN_WINDOW_GRACE_S=0`. A test of the grace period keeps the pipe open
  past it (`{ printf ...; sleep N; } | classify-ibc-log.sh`): when the input ends every wait
  ends, and a test that replays a file passes whatever the classifier does with a window.
- IBC's window lines carry a title and no id. The start-up frame changes its title while open
  (opened as `Authenticating...`, closed as `Starting application...`), a normal paper login
  opens a `Warning` that IBC accepts, and the configuration dialog's title starts with the
  account id. IBC stamps its first lines in UTC and the later ones in `TIME_ZONE`. All of it
  is in `tests/fixtures/ibc-real-paper-login.log` (real, scrubbed, 2026-11-15 UTC).
- A bare `wait` in a bats test never returns (bats keeps jobs of its own in the test's
  shell): `wait "${pid}"`.
- Docker gives an EMPTY named volume the owner and mode of its mount point in the image of
  a container created on it, when that image has the directory and the mount does not say
  `nocopy` (engine behaviour, seen on Engine 29; not documented). `docker compose up`
  creates every container before it starts any, the sidecar after the gateway. A sidecar
  image with a root-owned `/var/log/ibgateway` made the gateway's log volume unwritable
  for the gateway (`dirs_not_writable`, restart loop; first real session, 2026-11-16).
  Two protections, keep both: no image other than the gateway's has `/var/log/ibgateway`
  (the sidecar since 0.2.1; the Vector image never had it), and every shipped compose
  file mounts the log volume into another container read-only with `volume.nocopy`, in
  the long syntax. `sidecar/tests/test_docs.py` resolves every shipped compose file with
  `docker compose config --no-interpolate` (so spelling, key order and a trailing slash
  do not matter) and fails when a service other than the gateway mounts a gateway log
  volume, or any volume at `/var/log/ibgateway`, without `read_only` and `nocopy`, and when
  a compose file is not in its list. Containers started one after the other with
  `docker run` never show this: test with `docker compose up` or `docker create` on fresh
  volumes (`sidecar/tests/e2e/fresh-volumes.sh`). A stack already in the loop is repaired
  only by creating the gateway container again (`down` then `up -d`, or `up -d
  --force-recreate`); `up -d` alone re-creates the sidecar only.
- `docker compose run --rm sidecar <command>` starts the gateway first (`depends_on`), and
  the gateway logs in: always `--no-deps` for a sidecar command.
- Sidecar notifier: a delivery result can arrive after its condition cleared. The dispatcher
  reports a message at its FIRST acceptance (`_Delivery.settle`), and the ladder keeps an
  episode that cleared with a message still out as `_Closing` until the result is in; while
  one waits, nothing new is sent for that class. Keep both: 0.2.1 lost the "resolved" when a
  failing Teams channel held back the webhook's acceptance (2026-11-16), and PagerDuty keys
  an incident by instance and class (`dedup_key`), so a resolve queued after the next
  trigger closes the new incident. A late resolution is rendered from the `Moment` its
  closing kept (the tick that sends it may see the next episode); only a late acceptance
  of the announcement (`announced_late`) lets the episode active by then through the
  15-minute hold, once per window. After a restart everything the file shows in flight
  counts as possibly received: the file is saved once per evaluation, so a mark set
  between saves ("a channel has begun") is lost by a hard kill, and a rule built on it
  dropped the resolution of a message accepted just before the kill (second review of
  #32, reverted). Test restarts from the snapshot saved after the last step, never from a
  live `export_state()`. `Notifier.tick` writes the state before it queues the step's
  messages (a channel may accept a message the moment it is queued); keep that order. Only
  the stop cancels an evaluation: a stop during the write logs `notify_queued_at_stop`
  (info), a failed or overdue write `notify_queued_unsaved` (warning). The
  state is saved again after the shutdown flush (`Notifier.save_on_stop`; compose gives
  the sidecar `stop_grace_period: 20s`). A `resolved` is sent once and not tracked: a
  stop or kill while it is queued, or every attempt failing, loses it (L34, planned for
  0.2.3). A change to the ladder state bumps `notifier-state.vN` and keeps reading the
  previous version.
- Sidecar `clock_skew`: IBKR's time request is whole seconds and IBKR documents neither
  truncation nor rounding. `skew_exceeds` counts a reading only when it is beyond the limit
  under both (above +1.5 s, below −2 s, plus RTT/2); do not tighten a side without evidence
  of which IBKR does (`tests/test_notify_rules.py` models both). `clock_skew_s` is the raw
  reading: a correct clock reads about −1 to +0.5 s.
- Documented commands are tested (`tests/bats/ci/doc-commands.bats`, lint job). A block in
  which a person types a secret into a POSIX shell is marked with the HTML comment that names
  that file and runs under bash, zsh (the macOS default) and sh through a pty
  (`pty-answers.py`), as a script, pasted into an interactive shell (bracketed paste off and
  on) and with Ctrl-C at the password prompt: exact file bytes, no password on the screen or
  in the history, echo on afterwards. Write it as one subshell `( ... )` whose first line is
  `trap 'stty echo; exit 130' INT`, with a `printf` prompt, `stty -echo` around `IFS= read
  -r`, and `printf '%s'`: zsh has no `read -p` (`-p: no coprocess`), dash no `read -s`, and
  `read` without `IFS=` drops the blanks at both ends (all three found with the README's
  block on 2026-11-16); without bracketed paste (dash, busybox, macOS's bash 3.2) a shell
  reads a pasted block line by line and the first `read` takes the next pasted line unless
  the block is one compound command, and braces with that trap go on after Ctrl-C and write
  the password file (review of #37). A new marked block needs its own tests there. A path inside the container in a documented `docker exec` or `docker compose
  ... exec` command starts with `//` (`cat //var/log/...`): Git Bash, which the README names
  for Windows, rewrites a single leading `/` into `C:/Program Files/Git/...`, Linux reads
  `//var` as `/var`. Keep such a command on one line and outside a PowerShell fence, or the
  check does not see it. `docker run` lines with `-v`/`-e`/`-w` container paths (in
  `docs/evidence.md`, and the bats-in-the-image line of this file) need
  `MSYS_NO_PATHCONV=1` in Git Bash.
- Build wrappers (`scripts/build-image.sh`, `.ps1`): a value that may hold a secret (a proxy
  URL) travels to Docker by name only, `-e NAME` and `--build-arg NAME`, so it is in no
  argument list and no output; proxy names are predefined build arguments, which Docker keeps
  out of `docker history` and the image configuration unless the Dockerfile declares them
  (it must not: `build-image.bats` checks). BuildKit's build records do keep every build
  argument's value (`docker buildx history inspect`, `history export`, Docker Desktop's Builds
  view) until `docker buildx history rm <ref>`: the wrappers name those records when a proxy
  value holds `@` (`--metadata-file`, deleted at once). The helper image's build gets the
  proxy names too (its `apk add`). curl quotes a proxy value it cannot parse in full, so the
  wrappers refuse a malformed one before anything runs (exit 2, the name only;
  `proxy_url_valid` and `Test-BiProxyUrl` must accept the same values), and the helper's
  `hide_proxy_values` masks each value as written and decoded, its `user:password` and its
  password in curl's errors; never match proxy URLs with a pattern alone. PowerShell 5.1 turns a trailing backslash before its closing quote into an
  escaped quote: no argument may end in a separator (`ConvertTo-BiTrimmedPath`). Probe the
  daemon with `docker version --format '{{.Server.Version}}'` before anything else (`buildx
  version` answers without a daemon) and do not echo Docker's error (it can carry
  `DOCKER_HOST`). The helper names host paths, not its mounts: a new message about the cache
  or the `--installer` file goes through `shown` (`BROKERSRE_HOST_CACHE`,
  `BROKERSRE_HOST_INSTALLER`). The wrappers' labels never hold the build time:
  `org.opencontainers.image.created` is the checkout's commit time in UTC (asked inside the
  checkout), else IBKR's build time from the plan's stamp, and the image build passes
  `--provenance=false` (buildx's default attestation records the build's start and end time,
  and the containerd image store's image id covers it), so an unchanged rebuild on the same
  builder keeps its image id. Compose recreates a container when the platform manifest changes
  (label `com.docker.compose.image`), which means a new login. A test string with a backslash
  goes in through the Edit tool or `bs='\'`: a Bash heredoc on this host halves backslashes,
  and `"\${X}"` then stops expanding.
