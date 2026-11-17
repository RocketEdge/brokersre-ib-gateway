# ADR 0018 — Private image, public build recipe

- **Status:** Accepted (2026-11-17, owner decision); amends
  [ADR 0007](0007-ibc-from-rocketedge-fork-no-ibkr-redistribution.md) and
  [ADR 0009](0009-stable-updates-merge-themselves.md)
- **Spec:** [docs/specs/2026-11-17-private-image-public-recipe.md](../specs/2026-11-17-private-image-public-recipe.md)

## Context

1. The public package `ghcr.io/rocketedge/brokersre-ib-gateway` contains the installed IB
   Gateway. ADR 0007 kept IBKR's installers out of this repository, but an image with the
   installed Gateway in it is IBKR's software too, and IBKR's client agreement (form 3203,
   clause 39) does not let a client transfer it to others. RocketEdge decided to stop
   distributing it publicly.
2. Building the image from this repository broke whenever IBKR shipped a new Gateway build.
   IBKR serves installers only at unversioned channel URLs
   (`.../installers/ibgateway/<channel>-standalone/ibgateway-<channel>-standalone-linux-<arch>.sh`);
   a versioned path answers 404 (checked 2026-11-17). On 2026-11-17 IBKR replaced stable
   10.50.1g with 10.50.1h (`buildDateTime 20261116 16:02:08`) after the daily detection had
   run, and a clean build of `main` failed: `fetch-installer: SHA-256 MISMATCH for
   ibgateway-10.50.1g-standalone-linux-x64.sh` (actual `eb578b23…`, the 10.50.1h installer).
   Only RocketEdge's private archive could rebuild the pin.
3. IBKR publishes no checksum, but it publishes the version a channel serves:
   `<channel>-standalone/version.json` is JSONP,
   `ibgatewaystable_callback({"buildVersion":"10.50.1h","buildDateTime":"20261116 16:02:08"});`.
   The installed Gateway records the same facts in `.install4j/i4jparams.conf`:
   `applicationName="IB Gateway 10.50" applicationVersion="(.1h) 20261116 16:02:08"` (the
   published 10.50.1g and 10.52.1d images carry `(.1g) 20261109 16:10:13` and
   `(.1d) 20261112 16:03:29`, equal to `versions.json`'s `build_datetime`). The installer
   carries the same file in the gzip archive install4j appends to it.
4. GitHub: a package linked to a repository takes over its permissions "but not the
   visibility"; a package created again after deletion is private by default (spec, owner
   answers).

## Decision

**The image is built by its users from this repository; RocketEdge's own signed image
becomes private** under the same name (Phases 3 and 4 of the spec). This repository stays
public and is the recipe.

**`scripts/build-image.sh` and `scripts/build-image.ps1` build it on any host with Docker.**
Resolving, downloading, verifying and caching run as one bash implementation
(`scripts/resolve-installer.sh`) inside a helper container built from
`scripts/build-helper/Dockerfile` (the official Docker CLI image pinned by digest, plus bash,
curl and jq); the wrappers run `docker buildx build` and the offline IBC smoke test
(`tests/container/run.sh --only ibc-smoke`) with the host's Docker. A build is accepted when:

- IBKR serves the pinned version and the installer has the pinned SHA-256 (the label
  `com.rocketedge.brokersre.qualified=yes`); or
- by default, IBKR serves another version (newer, or older when IBKR rolls a channel back):
  the installer is downloaded over HTTPS (redirects too), IBKR's
  `version.json` must be the same before and after the download (retried once when it
  changed), the installer's own stamp must equal it, and the Dockerfile checks the installed
  stamp and version again (`fetch-installer.sh --check-stamp`); the image is labelled
  `qualified=no` and a warning names `scripts/qualify-paper.sh`. `--strict` exits 4 instead;
- or the user supplied the installer (`--installer`): its stamp names the version, channel
  and architecture; its SHA-256 is recorded.

Every accepted installer is cached by version and SHA-256 with its source (`ibkr`,
`installer`, or `override` for the tests' server). A cached version other than the pin is
reused only from the origin the build talks to, so bytes a user gave with `--installer` never
stand in for IBKR's; they serve only as the pin, when their SHA-256 is the pin's. With IBKR
unreachable the cached pin is built, else (without `--strict`) the newest cached version of
the channel that came from IBKR, else the build exits 3 (no usable cached installer). The image
carries `com.rocketedge.brokersre.ibkr.version`, `.ibkr.build_stamp`, `.installer.sha256` (per
platform), `.installer.source` and `.qualified`. The bake path passes the pinned stamp too, so
CI and publish builds get the same post-install check. The wrappers never overwrite or remove
an installer the user keeps in `downloads/`.

**Amends ADR 0007.** "IBKR binaries never redistributed from here" now covers the image: no
public image once Phase 4 is done. The private archive stays RocketEdge's; a public user
rebuilds a superseded version from their own cache or with `--installer`, so the negative
consequence of ADR 0007 ("public contributors cannot rebuild a superseded Gateway version")
no longer blocks a build: they get IBKR's current build, verified and labelled not qualified.

**Amends ADR 0009.** Its auto-merged `stable` bump was what kept `main` buildable and what
moved a public image. `main` now builds while IBKR is ahead of the pin (CI falls forward), so
a bump changes what the project has qualified and what RocketEdge's private image holds, not
whether anyone can build. "Published publicly without review" reads "published to the
private package". Whether stable bumps keep merging themselves is decided with private
publishing (Phase 3): they do, see below.

**Private publishing (Phase 3, 2026-11-17).**

- `publish.yml` keeps publishing under `ghcr.io/rocketedge/brokersre-ib-gateway`. After the
  public package is deleted (Phase 4), its first push creates the package again: private (the
  default for a new package), linked to this repository (a push with the workflow's token
  links it), so this repository's workflows keep access. No workflow sets a visibility. Every
  registry step (push, Trivy's remote source, the SBOM tool, cosign, the provenance push,
  `imagetools`) reads the credential `docker/login-action` writes. The release stays public:
  its notes name the digest for RocketEdge's own pins and tell everyone else to build from the
  tag; the assets (digests, SBOMs, OpenVEX) hold no IBKR binary.
- Nothing started by a push or a pull request reads the package. CI's `build-test` and the
  sidecar's end-to-end job build the gateway image with `scripts/build-image.sh` and test it
  under the local name `brokersre-ib-gateway:stable`, which no registry serves; Trivy reads
  the local daemon (`TRIVY_IMAGE_SRC=docker`). The end-to-end job needs no secret any more
  and runs for pull requests from forks too.
- The jobs that do read the package log in to `ghcr.io` with the workflow's token first: the
  daily scan of `rebuild.yml` (`packages: read`) and `qualify-paper.yml` (one login before the
  pull, used by the attestation too; it still takes a digest only, from `main` only, behind its
  environment).
- `detect-releases.yml` runs hourly. The full check (download both installers, hash, decide)
  runs daily at 06:00 UTC, on a manual dispatch, and at the first sight of a version: a label
  other than the pin with no pull request from its branch yet (`scripts/detect-scope.sh`).
  ADR 0009's other behaviour is unchanged: a re-upload is found within a day, an open pull
  request is refreshed daily, a closed one is opened again by the next daily run. Runs never
  overlap (one concurrency group).
- **Stable updates keep merging themselves** (ADR 0009). With the image private, an
  auto-merged bump (1) moves RocketEdge's private image, which reaches production only through
  digest pins that BrokerSRE verifies (`cosign verify`) and regresses on a paper account
  (runbook R10) before use, and (2) makes `main`'s CI build the pin again (`qualified=yes`)
  instead of IBKR's newer build. The label `qualified=yes` on such a pin means that the pinned
  bytes passed the offline tests and the Trivy gate, not that a paper login passed (L04), as
  for every pin before. The repository variable `STABLE_AUTOMERGE=false` stops the automatic
  merges without a code change; it is the switch if the owner wants a pin to mean
  "paper-qualified" (the resolution L35 describes).

## Consequences

### Positive

- A clean checkout builds on the day IBKR moves a channel, without the private archive, on
  Linux, macOS, WSL and Windows (Git Bash or PowerShell), with Docker as the only tool.
- Each image says which Gateway build it holds, which stamp it was checked against, which
  installer bytes it came from and whether the project qualified that build.
- A version once built can be rebuilt after IBKR has moved on, offline from IBKR.
- Pull requests from forks run every check, the sidecar's end-to-end job included; no job
  started by a pull request depends on a package or a secret.
- A new IBKR build is seen within the hour instead of the next day.

### Negative

- A build IBKR moved past the pin is not qualified by the project (limitations L35): the
  stamp check proves the bytes are the build IBKR announced over HTTPS, not that the Gateway
  works; only a paper login does.
- Users build a 1.6 GB image themselves (about five minutes on the development host) instead
  of pulling it, and need Docker with buildx.
- The PowerShell wrapper's smoke test reaches the daemon through `/var/run/docker.sock`; the
  helper's packages come from Alpine's index when it is first built (L36).
- No pull request, and nobody outside RocketEdge, can test or verify the bytes `publish.yml`
  publishes: CI tests a build of the pull request, which may hold a newer Gateway than the pin
  (L39).
- Each scheduled detection run calls GitHub once per channel when IBKR serves a label other
  than the pin (24 times a day per channel), and IBKR's `version.json` 24 times a day.

## Revisit trigger

IBKR publishes versioned or checksummed installers; IBKR or counsel clears redistribution of
the installed Gateway; or a fall-forward build is found to differ from what IBKR announced.
