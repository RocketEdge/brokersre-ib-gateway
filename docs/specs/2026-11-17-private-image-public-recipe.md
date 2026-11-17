# Private image, public build recipe, robust against IBKR's installer updates

- **Status:** approved by the owner on 2026-11-17 (option B of the distribution decision;
  answers recorded below).
- **Supersedes:** the public-image part of ADR 0007 ("IBKR binaries never redistributed"
  covered the installers, not the image); see the ADR written with this spec.

## Problem

1. The public package `ghcr.io/rocketedge/brokersre-ib-gateway` contains the installed IB
   Gateway, which IBKR's client agreement (form 3203, clause 39) does not let a client
   transfer to others. RocketEdge decided to stop distributing it publicly.
2. Building the image from this repository breaks whenever IBKR ships a new Gateway build:
   IBKR serves installers only at unversioned channel URLs
   (`.../installers/ibgateway/<channel>-standalone/ibgateway-<channel>-standalone-linux-<arch>.sh`;
   versioned paths answer 404, checked 2026-11-17), the bytes change, and the SHA-256 pinned in
   `versions.json` rejects them. Seen 2026-11-17: IBKR replaced stable 10.50.1g with 10.50.1h
   (`buildDateTime 20261116 16:02:08`) after the daily detection had run, and a clean build
   from `main` failed with `SHA-256 MISMATCH`.

## Owner decisions (2026-11-17)

| Question | Answer |
|---|---|
| IBKR serves a newer build than the pin | Build it, verified against IBKR's own stamp; label it "not qualified by the project"; `--strict` refuses |
| How RocketEdge's signed image goes private | Same name: delete the public package, republish privately under `ghcr.io/rocketedge/brokersre-ib-gateway`; BrokerSRE pins move to the rebuilt digests and are re-qualified |
| When to delete the public package | As soon as the private publishing path is ready, before the blog post |

## Design

### What makes a build trustworthy without a pinned checksum

IBKR publishes no checksum, but it publishes the version a channel serves:
`<channel>-standalone/version.json` is JSONP, e.g.
`ibgatewaystable_callback({"buildVersion":"10.50.1h","buildDateTime":"20261116 16:02:08"});`.
The installed Gateway records the same facts in
`<install dir>/.install4j/i4jparams.conf` as `applicationVersion="(.1h) 20261116 16:02:08"`
(seen on 10.50.1g: `(.1g) 20261109 16:10:13`, whose build time equals `versions.json`).
A build is accepted when:

- the version equals the pin in `versions.json` and the installer's SHA-256 equals the pin; or
- (default) the version is another than the pin (newer, or older when IBKR rolls a channel
  back), the installer came from IBKR over HTTPS (redirects too), and after installation the
  stamp `(.<suffix>) <buildDateTime>` equals what `version.json` announced before AND after
  the download; the image is then labelled not qualified; or
- the user supplied an installer file (`--installer`): its stamp after installation must
  name a version, which becomes the image's version; its SHA-256 is recorded.

Every accepted installer is cached by version and SHA-256, with its source (`ibkr`,
`installer`, or `override` for the tests' server), so the same version can be rebuilt after
IBKR has moved on, without network access to IBKR. A build reuses a cached version other than
the pin only when it came from the same origin; bytes given with `--installer` are reused
only as the pin, when their SHA-256 is the pin's.

### Interface (contract for every part of the work)

```text
scripts/build-image.sh  [--channel stable|latest] [--strict] [--installer FILE]
                        [--platform linux/amd64|linux/arm64] [--tag NAME] [--no-smoke]
                        [--cache-dir DIR] [--print-plan] [--help]
scripts/build-image.ps1 -Channel stable|latest -Strict -Installer FILE -Platform ... -Tag ...
                        -NoSmoke -CacheDir DIR -PrintPlan          (same behaviour)
```

- Default channel `stable`; default platform the host's (`docker info` architecture); default
  tags `brokersre-ib-gateway:<channel>` and `brokersre-ib-gateway:<version>`.
- Host requirements: Docker with buildx (Docker Desktop or Engine 23+); bash for the `.sh`,
  Windows PowerShell 5.1 or PowerShell 7 for the `.ps1`. Nothing else: resolving, downloading
  and verifying run inside a small pinned helper container (one implementation for every
  host), the image build and the smoke test run with the host's Docker.
- Default cache: `${XDG_CACHE_HOME:-$HOME/.cache}/brokersre-ib-gateway` (Linux, macOS, WSL,
  Git Bash); `%LOCALAPPDATA%\brokersre-ib-gateway` (PowerShell).
- Exit codes: `0` built (and smoke-tested unless `--no-smoke`); `1` download, verification,
  build or smoke test failed (also any docker failure outside these codes); `2` usage; `3` IBKR
  unreachable and no usable cached installer (offline the cached pin is preferred, else the
  newest cached installer of the channel that came from IBKR; with `--strict` only the pin);
  `4` `--strict` and IBKR serves a version other than the pin.
- Last lines printed (machine-readable `key: value`): `version`, `channel`,
  `qualified_by_project: yes|no`, `installer_sha256`, `ibkr_build_stamp`, `image`, `image_id`.
  `qualified_by_project: yes` means the version and the installer's SHA-256 equal the pin in
  `versions.json`, which passed the project's offline CI; a paper login is a separate
  qualification (`scripts/qualify-paper.sh`). A stable pin can move without a person
  (ADR 0009 and 0018; the repository variable `STABLE_AUTOMERGE=false` makes every pin wait
  for a human). Amended 2026-11-17 in the review of the private-publishing pull request.
- Image labels added: `com.rocketedge.brokersre.ibkr.version`,
  `com.rocketedge.brokersre.ibkr.build_stamp`, `com.rocketedge.brokersre.installer.sha256`,
  `com.rocketedge.brokersre.qualified` (`yes` when version and SHA-256 equal the pin),
  `com.rocketedge.brokersre.installer.source` (`ibkr`, `installer` or `override`).
- `--print-plan` resolves and prints what it would build (version, pinned or not, cache hit)
  and exits 0 without downloading or building.
- The smoke test is the existing offline IBC check (no network, IBC starts, the command
  server answers, `STOP` ends the Gateway tidily), callable on its own.

### The Dockerfile

`scripts/fetch-installer.sh` keeps its contract (pre-fetched installer in `downloads/`,
SHA-256 check) and gains the stamp check after installation: when `IB_GATEWAY_BUILD_STAMP`
is set, the installed `applicationVersion` must equal it, otherwise the build fails naming
both values. `versions.json` already records `build_datetime` per channel, so CI builds get
the same check.

### RocketEdge's own image

`publish.yml` keeps publishing under the same name, now private (a re-created package is
private by default; GitHub: a linked repository passes on permissions "but not the
visibility"). Release detection runs hourly instead of daily. CI and the sidecar's
end-to-end job build the gateway image with the recipe instead of pulling it.

### Not in scope

Changing what the image does at run time; publishing any IBKR binary anywhere; deploying
anything to Azure; automating the second factor.

## Phases and pull requests (gateway repository unless stated)

1. **Robust build** (`feat/robust-build`): helper scripts, Dockerfile stamp check, labels,
   tests (bats against a fake IBKR server; Pester for the wrapper), CI builds with the helper,
   spec + ADR + changes + contract files.
2. **Recipe and defaults** (`docs/build-recipe`): README "Build the image" (detailed recipe),
   quick start starts with the build, compose files and examples default to the local tag,
   Windows kit builds when the image is missing, Azure template documents the user's own
   registry, verification section rewritten, limitations.
3. **Private publishing** (`ci/private-publish`): publish to the private package, hourly
   detection, CI and the sidecar end-to-end job without anonymous pulls, workflows re-enabled.
4. **Delete the public package** (owner's token or click), publish privately, verify that an
   anonymous pull fails and an authenticated pull plus `cosign verify` pass.
5. **BrokerSRE and the blog** (monorepo): pins to the new private digests via the pin flow,
   private-registry credentials for the ACR import, blog brief reworked; paper re-verification
   of a self-built image.

## Corrections (review of #39, 2026-11-17)

The implementation's behaviour was the better choice in two places, so the text above follows
it: a build falls forward to any version other than the pin (IBKR may roll a channel back, and
the owner's table row "newer" describes the case seen on 2026-11-17), and exit `3` means that
IBKR is unreachable and no usable installer is cached, not only that the pin is missing. The
review also added the cache's source (and the label `installer.source`), the cache key by
version and SHA-256, HTTPS for redirects in every mode, and exit `1` for a docker failure.
