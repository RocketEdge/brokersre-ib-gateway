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
- [ ] First qualified run: needs paper credentials that IBKR accepts (the first attempt on 2026-11-12 was rejected); then update the environment secrets and dispatch the workflow
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
- [ ] First runs of the three workflows; the first-publish path of `sidecar-publish.yml`
- [ ] A paper login with the sidecar attached (L20); one real message per channel
- [ ] A person checks the reset-window table against IBKR's system status page (L21)

## Roadmap P2: supply chain (2026-11-12, branch `feat/p2-supply-chain`)

- [x] `publish.yml`: push by digest, gate both platforms of that digest, one SBOM per platform, VEX attestation, tags moved last by `promote-tags.sh`; actions pinned by commit, Trivy by version
- [x] `rebuild.yml`: daily scan of the published images, rebuild request for a fixable CRITICAL/HIGH finding, bounded to three days
- [x] OpenVEX for IBKR's bundled jars with a drift check; `docs/evidence.md`; ADR 0015
- [ ] First runs of the changed workflows (start with `rebuild.yml`, mode `scan`); record the run ids (L24)
- [ ] A tested registry cleanup after a failed gate (L23); sign the platform manifests too
- [ ] Decide about `/usr/bin/pebble` (L22); re-attest the VEX without a rebuild
