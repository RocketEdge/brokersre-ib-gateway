# tasks/todo.md — brokersre-ib-gateway

- [x] Repository design per BrokerSRE plan section 5.3 (2026-11-01)
- [x] Dockerfile, bake, versions.json, rootfs scripts, templates, patterns, schema
- [x] bats unit suite (classify, render, healthcheck, ibc-cmd) and container test script
- [x] Workflows: ci, publish, rebuild, detect-releases, detect-ibc-release; CodeQL via GitHub default setup (advanced workflow removed 2026-11-01: default setup rejects it)
- [x] Docs: README, SECURITY, NOTICE, LICENSE, ADRs 0001-0008, env-vars, log-contract, upgrade policy, migration guide, limitations
- [x] Local build of stable (amd64) green: bats 25/25, container suite 28/28 (2026-11-01)
- [x] First push; `ci.yml` green on 2f109b8
- [x] First `publish.yml` run green (41285824630); in-job cosign verify of signature + SBOM attestation; stable sha256:a35fcafe..., latest sha256:8fb845fb...
- [x] GHCR package public (owner, 2026-11-01): anonymous pull and credential-free `cosign verify` / `verify-attestation` of both digests pass
- [ ] Operator-gated: add `BOT_TOKEN`, `ARCHIVE_WRITE_TOKEN`, `ARCHIVE_READ_TOKEN` secrets (step-by-step in README "Automatic updates and repository secrets"; without `BOT_TOKEN` stable updates cannot auto-merge); Phase-0 scrubbed logs to replace the synthetic fixture (limitations L01-L03). Since 2026-11-11 Actions may open PRs without `BOT_TOKEN`, but such PRs run no CI until closed and reopened
- [x] 2026-11-11 Option A (ADR 0009): daily detection with `scripts/release-decision.sh`; stable PRs auto-merge, latest PRs wait for a human, re-uploads open an `ibkr-reupload` issue; CI and publish pre-fetch archived installers (`scripts/prefetch-installers.sh`); auto-merge allowed; archive repository initialised and seeded with 10.50.1g (stable) and 10.51.1e (latest); README: follow releases, create the tokens
- [x] 2026-11-11: "Detect IB Gateway releases" red daily (could not open the 10.50.1g PR); repository setting "Allow GitHub Actions to create and approve pull requests" turned on; release PR #5 merged (owner decision), `stable` 10.50.1g published as `sha256:2479cc94…` (signed, SBOM-attested, Trivy clean), `latest` republished as `sha256:5eecf3a8…`
- [x] Trivy OS gate red from 2026-11-09 (apt CVE-2026-109518): runtime stage runs `apt-get upgrade` (PR #3); superseded release records kept in `docs/changes.md` 2026-11-10
- [ ] Follow-up: `publish.yml` re-uses an existing release (`--clobber`) when a push republishes an already-released version; give such a publish a `-rYYYYMMDD` tag as ADR 0008 describes for rebuilds
- [ ] Follow-up: the Buildx `type=gha` cache is not in effect (0 cached steps in runs 42595391755, 42683161039); if it is repaired, bust the apt layer on rebuilds or OS patches stop silently
- [ ] Follow-up: arm64 images are published but not Trivy-scanned in CI
- [ ] Follow-up: `detect-releases.yml` downloads about 1.1 GB from IBKR every day to hash the installers; ask for the headers (`Last-Modified`, `Content-Length`) first and download only when they change
- [ ] Follow-up: once `BOT_TOKEN` is set, watch the first `stable` auto-merge end to end (PR checks, merge, `publish.yml` started by the merge, release e-mail to watchers)
- [x] `latest` re-pinned to IBKR's 2026-11-05 re-upload of 10.51.1e (owner decision 2026-11-10); `fetch-installer.sh` verified on amd64 and arm64
- [x] Follow-up: `detect-releases.yml` compares only `buildVersion`; also compare the installers' SHA-256 so a same-version re-upload opens a pull request (IBKR re-uploaded 10.51.1e on 2026-11-05) — done 2026-11-11 as an `ibkr-reupload` issue (ADR 0009)
- [ ] Follow-up: a push-triggered `publish.yml` publishes both channels; publish only the channels whose `versions.json` entry changed (a `latest`-only re-pin republished `stable` too)

## Roadmap P0 (2026-11-12, branch `feat/p0-windows-safe-start`)

- [x] First real login attempt (operator-run, paper, 10.50.1g): read-only login hang root-caused and fixed (`java-env.sh`, `_JAVA_OPTIONS`); L01 to L03 partly resolved
- [x] Windows-written secret files (CR/LF, UTF-8 BOM accepted; UTF-16 and empty refused); credentials escaped for IBC's `.properties` parser
- [x] Classifier patterns checked against a real log (login window title, one event per dialog); real scrubbed fixture added
- [x] VNC password out of the process list; log rotation (`rotating-append.sh`) and a restart-safe mirror
- [x] Reference compose hardened and started as shipped by the container suite; quick start rewritten for Windows and Linux; README version table generated from `versions.json`
- [ ] Repeat the paper login with working credentials: record a successful session, second-factor prompt, daily restart and competing session; extend the real fixtures; close L01 to L03
- [ ] Paired change in the BrokerSRE agent: its copy of the IBC patterns carries the same two wrong assumptions (login window title, three log lines per dialog)
- [ ] Next: log contract v2 (events and metrics on the log volume, `needs-human` phase), preflight `doctor`, relay gated on login, runtime heap

## Roadmap P1 (2026-11-12, branch `feat/p1-contract-v2`, stacked on P0)

- [x] Log contract v2: events on the volume with `boot_id`, `seq` and `data`; schema v2; ADR 0013; `docs/log-contract.md` rewritten
- [x] Phase `needs-human` (rejected login; optional `TWOFA_MAX_PROMPTS`), `unknown_window`, entrypoint hold
- [x] Relay gated on the login (`RELAY_MODE`); runtime heap (`JAVA_HEAP_MB`); exit on OutOfMemoryError
- [x] Preflight `doctor` (command and at start); resource sampler (`metrics/metrics.jsonl`, last sample at shutdown)
- [ ] Needs a real session: L09 to L13 in `docs/limitations.md` (second-factor wording, relay across a daily restart, JVM figures, memory under load)
- [ ] The BrokerSRE agent must learn phase `needs-human` and the v2 events (paired change in its repository)

## Roadmap P1: qualification (2026-11-12, branch `feat/p1-canary`, stacked on `feat/p1-contract-v2`)

- [x] `api-handshake.sh`: read-only proof that the API answers; `HEALTHCHECK_API=handshake` (opt-in)
- [x] `scripts/qualify-paper.sh`: one real paper login with checks and a result document; offline test in the container suite
- [x] Workflow `qualify-paper.yml` (manual, by digest, from `main`), ADR 0014; GitHub environment `paper-qualification` created (required reviewer, `main` only, secrets `PAPER_USERID` and `PAPER_PASSWORD`)
- [x] First qualified run: needs an account with paper trading enabled at IBKR. The attempt of 2026-11-12 was rejected; on 2026-11-13 IBKR accepted the credentials, but the account had no paper trading access (L31) and the run ended "not qualified". Done 2026-11-16 with the script, run by hand: the published stable `7773ff7` and latest `cc3a6a9` qualified (L16); the workflow's first run waits for its reviewer (below)
- [ ] After three recorded passes: move `stable` only after a `qualified-paper` attestation exists

## Roadmap P3: rejected-login latch (2026-11-12, branch `feat/p3-login-latch`)

- [x] `login-latch.sh`: record IBKR's rejection on the log volume, hold later starts with the same secret files (no IBC, phase `needs-human`), release when a secret file is rewritten; ADR 0016
- [x] Preflight check `login_latch`; events `login_latch_set`, `login_rejected_latched`, `login_latch_cleared`, `login_latch_unreadable`
- [ ] Observe one real cycle: rejection, corrected secret file, login (L18)
- [ ] Real logs of other rejections (expired password, locked account) and whether they need the latch too (L18)

## Roadmap P2/P4: Azure Log Analytics pack (2026-11-12, branch `feat/azure-pack`)

- [x] `azure/`: Bicep (tables, data collection rule, role, alerts, workbook, query pack), Vector shipper with redaction, compose profiles, optional gateway VM, offline suite, ADR 0012
- [ ] First deployment to a test subscription (owner's go-ahead: it creates billable resources); then L19
- [ ] Run the `kql-run` group once (needs a person to accept the Kusto emulator's licence)

## Roadmap P1/P2: optional sidecar (2026-11-12, branch `feat/sidecar`)

- [x] `sidecar/`: read-only API probe, `/livez` `/readyz` `/status` `/metrics`, notifier with an escalation ladder (seven channels), dead-man ping, own network namespace by default, ADR 0010
- [x] Workflows: tests + image + smoke + end to end; publish from `main` only (both architectures tested and scanned before the push); weekly rescan
- [x] First runs of the tests workflow and of `sidecar-publish.yml`, its first-publish path included (run 43183803821, 2026-11-12: pushed, signed, signature verified; four publish runs by 2026-11-16)
- [ ] First run of `sidecar-rescan.yml` (weekly; it has never run)
- [x] A paper login with the sidecar attached (L20; 2026-11-15/16 UTC, sidecar 0.2.0 and 0.2.1)
- [ ] One real message per channel
- [ ] A person checks the reset-window table against IBKR's system status page (L21)

## Roadmap P2: supply chain (2026-11-12, branch `feat/p2-supply-chain`)

- [x] `publish.yml`: push by digest, gate both platforms of that digest, one SBOM per platform, VEX attestation, tags moved last by `promote-tags.sh`; actions pinned by commit, Trivy by version
- [x] `rebuild.yml`: daily scan of the published images, rebuild request for a fixable CRITICAL/HIGH finding, bounded to three days
- [x] OpenVEX for IBKR's bundled jars with a drift check; `docs/evidence.md`; ADR 0015
- [ ] First runs of the changed workflows (start with `rebuild.yml`, mode `scan`); record the run ids (L24)
- [ ] A tested registry cleanup after a failed gate (L23); sign the platform manifests too
- [ ] Decide about `/usr/bin/pebble` (L22); re-attest the VEX without a rebuild

## Roadmap P3: Windows host kit (2026-11-12, branch `feat/windows-kit`)

- [x] `windows/`: `setup.ps1`, `doctor.ps1`, `harden.ps1` (reversible), `start.ps1`, `uninstall.ps1`; both PowerShell editions; ADR 0011; two independent reviews fixed before the pull request
- [ ] Validate on a second computer: Docker Engine in WSL end to end, the boot task without sign-in, a real login, the clock fix after a real resume (`windows/README.md`, "To validate on your computer")
- [ ] First run of `windows-kit.yml` on a GitHub runner

## Roadmap P1: screenshot of a blocking window (2026-11-12, branch `feat/p1-screenshot`)

- [x] `SCREENSHOTS=yes`: Xvfb keeps its framebuffer in a file; `screenshot.sh` saves it to `screens/` after `unknown_window`, after `login_stalled` and on request; bounded by count and interval
- [ ] Look at the automatic screenshot of a real blocking dialog (a picture on request showed one on 2026-11-13; the automatic one was deleted unviewed) and at a real login window; decide whether the automatic picture should be taken a moment after the window opens (L25)
- [ ] Decide: classify the dialog `Paper Account Notice` (no paper trading access) as phase `needs-human` with an event of its own (L31)

## Roadmap P2: a runbook per alert (2026-11-12, branch `docs/p2-runbooks`)

- [x] `docs/runbooks/`: index and one page per sidecar alert class; `NOTIFY_RUNBOOK_BASE` set in the compose override; tests keep pages, classes and links in step
- [ ] Correct the pages from the first real incidents; decide whether a clearing by timer (`login_failed`, `unknown_window`, an unrequested restart) should say so in the `resolved` message

## Roadmap P4 (2026-11-12, branch `feat/p4-depth`)

- [x] Break-glass console: view-only by default (`VNC_VIEW_ONLY`), `-noremote`, session events, console override compose, `docs/console.md`, ADR 0017; no idle limit (x11vnc has none), no web console (no image from a publisher that can be verified)
- [x] `scripts/check-upgrade.sh` (asks only; `brokersre.upgrade-check.v1`) and `docs/upgrade-check.md`
- [x] Log-shipper recipes for Loki, OTLP and Datadog (`docs/recipes/`), tested against stand-ins (`tests/recipes/run.sh`, CI job `recipes`); same Vector pin as the Azure pack
- [x] `docs/passkeys.md`; design notes for log export, a market data canary and strategy telemetry (`docs/specs/`), nothing built
- [x] The dead "Daily & Weekly Reauthentication" link in the README
- [ ] First run of the `recipes` job on a GitHub runner
- [ ] Needs a real session: the console during a login (L26), one recipe against a real system (L28)
- [ ] Decide: a run-time switch for console input with its own event; limit the console bridge to the Docker host (ADR 0017, revisit triggers)
- [ ] Follow-up: a console session open at shutdown has no `vnc_client_disconnected`

## Release step retry (2026-11-13, branch `fix/publish-release-retry`)

- [x] `scripts/release-upsert.sh`: the release is created or updated with five attempts and read back; `publish.yml` uses it (the HTTP 502 of 2026-11-13)
- [ ] First publish with the new step; then consider the same for the archive upload in `detect-releases.yml`
- [ ] A check after each publish that every channel tag equals the digest in its release (L30)

## The real paper session of 2026-11-16 (branches `fix/unknown-window-grace`, `fix/sidecar-log-volume-owner`, `fix/account-id-third-letter`, `docs/paper-session-2026-11-16`)

- [x] The first completed logins on this image: login, health, API handshake, relay, sidecar readiness, notifications, graceful stop and restart work with a real paper account
- [x] The gateway with a sidecar did not start on fresh volumes (`dirs_not_writable` loop): the sidecar image has no `/var/log/ibgateway` and every reader mounts the log volume with `nocopy` (sidecar 0.2.1)
- [x] Publish sidecar 0.2.1 and watch the run through "Verify the signature" (a re-run cannot sign a tag that was already pushed): published, signed and verified by the publish workflow (2026-11-16)
- [x] Start the shipped stack (reference compose plus sidecar override) with a real paper login once 0.2.1 is published: logged in on fresh volumes, no `dirs_not_writable`, no false alert (2026-11-16)
- [ ] Decide L33: should a failed preflight keep the container up in a phase of its own instead of exiting into a restart loop?
- [ ] Approve the waiting run 43789700905 of `qualify-paper.yml` (the published stable digest `7773ff7`) and record its result (L04, L16)
- [x] Sidecar 0.2.2 (#32) reviewed independently and merged on 2026-11-16 (`cbfd49c`); the published digest sent the `resolved` in both paper scenarios (L20). The item as first written: review the sidecar 0.2.2 pull request from the branch `fix/sidecar-resolved-and-skew` when it is opened: no `resolved` followed a short stop of the gateway while a second channel (Teams) was unreachable, because the firing message's result is recorded only when every channel has finished
- [x] `sidecar/README.md` said "Not verified against a logged-in gateway"; corrected in the sidecar 0.2.2 pull request (#32) from what L20 records, and L20 extended with what 0.2.1 showed on 2026-11-16
- [ ] Track owed resolutions until a channel accepts them (sidecar 0.2.3, L34): a `resolved` is sent once today, so a stop or kill while it is queued, or every attempt failing, loses it; also resolve or drop the episodes of a class switched off before a restart. Weigh the option the review inferred (not probed): queue resolutions and heartbeats before the state write and announcements and escalations after it, which narrows that window
- [ ] Observe with a real paper login: a daily restart, a second-factor prompt and a competing session (L01, L02, L09, L12)
- [ ] Decide what `tail-gateway-logs.sh` should do about `ibgateway.*.log`, a name that was not seen (L03), and correct its header (lines 4 to 7, which call the name unverified documentation) with that decision: a change under `rootfs/` rebuilds the image

## The README's examples, run as written (2026-11-16/17, branch `docs/readme-examples-checked`)

- [x] Secret blocks exact and portable in bash, zsh and sh (D1, D2); typed into through a pty by `tests/bats/ci/doc-commands.bats` in the lint job
- [x] Container paths of documented exec commands in the `//` form that Git Bash passes unchanged (D3); `docs/evidence.md` carries the `MSYS_NO_PATHCONV=1` note
- [x] The C# client and `examples/compose-with-client.yml` recorded as run against a paper Gateway (D5); the weekly login cited from IBKR's auto-restart guide
- [x] D4 (`sidecar/README.md`, `docker compose run` without `-f`) fixed in pull request #32 (merged 2026-11-16)
- [x] Review of #37: each secret block is one subshell with `trap 'stty echo; exit 130' INT`; tested pasted into interactive bash and zsh (bracketed paste off and on) and sh, and with Ctrl-C at the password prompt; bash 3.2 and busybox sh checked by hand in containers
- [ ] Not covered: a run on a Mac (Terminal.app or iTerm2 with its own paste behaviour)

## Private image, public build recipe: phase 2 (2026-11-17, branch `docs/build-recipe`, stacked on #39)

- [x] README "Build the image": prerequisites per host, measured time and disk, one command per shell with its output, the seven result lines and `qualified_by_project: no`, latest channel, arm64 under emulation, proxies, cache and `--installer`, pinning, private registries, a CI example (actionlint), upgrade and rollback, troubleshooting; quick start starts with the build; verifying, notification and upgrade-check sections rewritten for a self-built image
- [x] Compose files and the client example default to `brokersre-ib-gateway:stable` with `pull_policy: never` (tests in `tests/compose/run.sh`); the Azure VM overlay pulls its digest (`pull_policy: missing`)
- [x] Windows kit: `setup.ps1` builds a missing `brokersre-ib-gateway:stable` or `:latest` with `scripts/build-image.ps1` (Pester under 5.1 and 7, one real build)
- [x] Azure pack documents the operator's own registry; evidence, upgrade check, upgrade policy, SECURITY, NOTICE and the gnzsnz table no longer point at a public image
- [ ] L37: give the Azure VM a registry login (`AcrPull` for its identity and a token exchange before the pull)
- [ ] L38: an option to hand the build a CA bundle for a TLS-inspecting proxy
- [ ] Reported from #39 (not fixed here; #39 is merged): the PowerShell wrapper says "architecture '' is not supported; pass -Platform" when Docker is not running; neither wrapper forwards `HTTPS_PROXY` from the shell; a helper build carries the base image's `org.opencontainers.image.created` and no revision; the helper's messages name the container path `/cache`
- [ ] Not covered: a build on macOS (Intel, Apple silicon), on arm64 hardware, in WSL 2, behind a real corporate proxy, pushes to GHCR, ACR, ECR and Docker Hub, the CI example on GitHub, the kit's build through Docker Engine in WSL
- [x] After #39 merged: the recipe shows where the installer cache lives and how to clean it (nothing prunes it); a refused `downloads/` file is named as a likely leftover with its safe removal (bats, red first)
- [ ] An automatic prune of the installer cache (for example keep the pin and the newest N versions), if users ask for it
- [x] After the public package is deleted (Phase 4): a follow-up pull request switches "RocketEdge no longer distributes a public image ... is being withdrawn" to the past tense with the date and the proof (an anonymous pull that fails), in README, NOTICE, SECURITY, evidence, upgrade policy, upgrade check, the compose and kit texts, the Azure pack and the contract files. Done on 2026-11-17 (branch `docs/package-state`): "was withdrawn on 2026-11-17", no RocketEdge image published at the moment, the next publish non-public; the proof is the refused anonymous token request (ADR 0018, amendment). Left as they were (code, not documentation): the comments of `publish.yml`, `rebuild.yml`, `qualify-paper.yml`, `detect-releases.yml`, `ci.yml`, `tests/bats/ci/private-package.bats` and the doc comment in `windows/src/Commands.ps1` that call the package private or "being withdrawn"; correct them with the next change to those files
- [x] Review of #41 (2026-11-17): rootfs owner and modes fixed in the Dockerfile (container check); the kit builds in WSL from a copy in the distribution; the leftover advice names the caller's command and path; wording true before and after the deletion; `qualified_by_project` defined as "the pin passed the offline CI"; migration steps for users of the public default
- [ ] Not covered after the review: a real WSL distribution for the kit's copy-and-build path
- [x] Re-review of #41 (2026-11-17): the WSL copy packs a named list of the build's inputs (no `compose/secrets`, `.env`, `downloads/`), removes the archive after unpacking; `.dockerignore` excludes `**/secrets` and `.env` files inside admitted folders (`build-context.bats`); the leftover advice quotes the path per shell; README wording on the paper-qualified digests and the WSL cache; merged `origin/main` after #40

## Private image, public build recipe: phase 3 (2026-11-17, branch `ci/private-publish`)

- [x] CI `build-test` and the sidecar's end-to-end job test a local build (`brokersre-ib-gateway:stable`, build helper); Trivy reads the local daemon; the end-to-end job runs for forks
- [x] `rebuild.yml` daily scan and `qualify-paper.yml` log in to ghcr.io before their first read; `publish.yml` release notes tell readers to build, not to pull
- [x] `detect-releases.yml` hourly; full check daily, on dispatch and at the first sight of a version (`scripts/detect-scope.sh`); stable bumps keep merging themselves (ADR 0018)
- [x] Review of #40: `publish.yml` refuses to push anything with IBKR software unless an anonymous read of a placeholder is refused (job `private-package`, `scripts/check-package-private.sh`); the qualification logs in and pulls before the credential files exist; `qualified_by_project: yes` defined (pin + offline CI, not a paper login); hourly detection: separate concurrency groups, a short retry of `version.json`, only this repository's update pull requests count
- [ ] Owner, in this order (each step proves something; L39, L40; what happened and why: ADR 0018, amendment of 2026-11-17). Deleting the package deleted every digest published so far, including every digest BrokerSRE pinned (the monorepo's `infra/bicep/params/sandbox.bicepparam` line 35, the imports of runbook R10), and the monorepo's Monday `image-pin.yml` (06:00 UTC) fails until its pull request #45 and the pin move:
  - [x] (0) The build-recipe pull request (#41) merged on 2026-11-17 before the deletion.
  - [x] (a) The public package was deleted on 2026-11-17 at 08:09 UTC. Proof: from then on an anonymous token request for `repository:rocketedge/brokersre-ib-gateway:pull` was refused (403) and the API answered "Package not found". A deleted package can be restored for 30 days only while no new package takes its name: the push of 08:10 took it, so the deleted package and its digests cannot be restored.
  - [x] (b) and (c), first attempt, 2026-11-17: `publish.yml` dispatched at 08:10 (run 44044468594). Its placeholder push created the package again, PUBLIC; `check-package-private.sh` said so, the job failed, `publish` was skipped, nothing with IBKR software was pushed (the gate worked). About 08:45 the public placeholder package was deleted and the package created by hand with a personal token (the recovery path below): internal, not linked to this repository, `check-package-private.sh` exit 0 (anonymous token request 401). `publish.yml` dispatched at 08:47 (run 44049788033): the placeholder push failed with `permission_denied: write_package`, `publish` skipped, nothing pushed (the gate worked again). `publish.yml`, `rebuild.yml` and `detect-releases.yml` are disabled again; no RocketEdge image is published.
  - [ ] (1) Optional, in the package settings (<https://github.com/orgs/RocketEdge/packages/container/brokersre-ib-gateway/settings>): *Change visibility* from Internal to Private. Internal lets every member of the enterprise, and by GitHub's documentation every workflow of the enterprise, read the image; the gate cannot tell the two apart (L40).
  - [ ] (2) Same page, *Manage Actions access*, *Add repository*: `RocketEdge/brokersre-ib-gateway` with role Write (publish, the rebuild scan, the qualification), `RocketEdge/brokersre` with role Read (its `image-pin.yml`), and with role Read each client repository exported from its template whose `image-pin.yml` reads the image (those workflows also need a registry login, monorepo #45, phase 5). Not a repository connection with inherited access (ADR 0018, amendment).
  - [ ] (3) Re-enable `publish.yml` and `detect-releases.yml` (`gh workflow enable <file> -R RocketEdge/brokersre-ib-gateway`), not yet `rebuild.yml`. Dispatch `publish.yml` for both channels (`gh workflow run publish.yml -R RocketEdge/brokersre-ib-gateway -f channels="stable latest"`) and read the run through the job "the package is private" (its log must say `private: an anonymous read ... was refused`), the same check right before the push, and each channel through "Verify the signature and attestations". Proves: the workflow's token pushes into the package, the package is not public before the gateway image is pushed, and Trivy (remote), the SBOM tool, cosign sign/attest/verify and the provenance push work against it. The first hourly detection run shows `scope=` in its log.
  - [ ] (4) Re-enable `rebuild.yml` only after (3): its 05:30 UTC scan fails while the package holds no channel tags. Its next scan proves the login and both scans.
  - [ ] (5) Package settings: the visibility you chose in (1) and the Actions access of (2); an anonymous pull fails, `docker login ghcr.io` plus `docker pull` and `cosign verify` of the digest pass. Then one `qualify-paper.yml` run against a digest of the package.
  - Recovery path, only when the package must be created again (it does not exist): create it by hand with a personal access token (classic, `write:packages`), never through a workflow of this repository (that creates it public). The ADR 0018 amendment has the reasons; then steps (1) to (5):

    ```bash
    # 1. The placeholder, built with your usual Docker configuration: FROM scratch, one text
    #    file, no IBKR software, the source label of this repository.
    probe="$(mktemp -d)"
    printf '%s\n' 'Placeholder of ghcr.io/rocketedge/brokersre-ib-gateway. It holds no IBKR software.' > "$probe/README.txt"
    printf '%s\n' 'FROM scratch' 'COPY README.txt /README.txt' > "$probe/Dockerfile"
    docker build --label org.opencontainers.image.source=https://github.com/RocketEdge/brokersre-ib-gateway \
      -t ghcr.io/rocketedge/brokersre-ib-gateway:visibility-probe "$probe"
    # 2. The push, from a throwaway Docker configuration (no docker login), removed afterwards.
    export DOCKER_CONFIG="$(mktemp -d)"
    read -r -p 'GitHub user: ' gh_user
    read -r -s -p 'Token (classic, write:packages): ' gh_token; echo
    printf '{"auths":{"ghcr.io":{"auth":"%s"}}}\n' "$(printf '%s:%s' "$gh_user" "$gh_token" | base64 | tr -d '\n')" > "$DOCKER_CONFIG/config.json"
    unset gh_token
    docker push ghcr.io/rocketedge/brokersre-ib-gateway:visibility-probe
    rm -rf "$DOCKER_CONFIG" "$probe"; unset DOCKER_CONFIG
    # 3. publish.yml's gate on it. The repository WITHOUT the ghcr.io/ prefix. Exit 0 means
    #    ghcr.io refused the anonymous token request: private OR internal, so read the visibility
    #    in the package settings (L40).
    scripts/check-package-private.sh rocketedge/brokersre-ib-gateway visibility-probe
    ```

- [ ] Decide L40: a gate that also reads the package's `visibility` from GitHub's API and refuses anything but the chosen value (first establish whether the workflow's token may read the package's metadata)
- [ ] After the build-recipe pull request merges: README "Automatic updates" and `docs/upgrade-policy.md` still say the detection runs daily (now hourly, full check daily)
