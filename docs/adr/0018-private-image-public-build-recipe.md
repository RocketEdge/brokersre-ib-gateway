# ADR 0018 — Private image, public build recipe

- **Status:** Accepted (2026-11-17, owner decision); amends
  [ADR 0007](0007-ibc-from-rocketedge-fork-no-ibkr-redistribution.md) and
  [ADR 0009](0009-stable-updates-merge-themselves.md); amended 2026-11-17
  ([how the package was created again](#amendment-2026-11-17-how-the-package-was-created-again))
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
   answers). (Not so for this repository: see the amendment below.)

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
  links it), so this repository's workflows keep access. (Observed otherwise on 2026-11-17:
  the workflow's push created a public package, and the package was then created by hand;
  see the amendment below.) No workflow sets a visibility. Every
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
  request is refreshed daily, a closed one is opened again by the next daily run. Full and
  hourly runs have their own concurrency groups, so a pending full check is never replaced by
  an hourly run.
- **Stable updates keep merging themselves** (ADR 0009; behaviour unchanged). With the image
  private, the consumers of a pin are the people who build from this repository, and
  RocketEdge's private image, which BrokerSRE verifies (`cosign verify`) and regresses on a
  paper account (runbook R10) before use. An auto-merged stable bump becomes `main`'s pin and a
  release whose notes say "build this"; from then on a build of that version prints
  `qualified_by_project: yes` (and `--strict` accepts it), about an hour after IBKR's release,
  with no person and no paper login involved. So `qualified_by_project: yes` (the label
  `com.rocketedge.brokersre.qualified=yes`) means: **the version and the installer's SHA-256
  equal the repository's pin, which passed the project's offline CI** (the build, the offline
  container tests and the Trivy gate). A paper login is a separate qualification
  (`scripts/qualify-paper.sh`, ADR 0014, L04); it is not part of `yes`. The build scripts'
  help, the spec's interface and L35 say the same. Setting the repository variable
  `STABLE_AUTOMERGE` to `false` makes every pin wait for a human, who can run the paper
  qualification first; `tests/bats/ci/detect-scope.bats` checks that the variable stops the
  step that enables auto-merge.

## Consequences

### Positive

- A clean checkout builds on the day IBKR moves a channel, without the private archive, on
  Linux, macOS, WSL and Windows (Git Bash or PowerShell), with Docker as the only tool.
- Each image says which Gateway build it holds, which stamp it was checked against, which
  installer bytes it came from and whether the project qualified that build.
- A version once built can be rebuilt after IBKR has moved on, offline from IBKR.
- Pull requests from forks run every check, the sidecar's end-to-end job included; no job
  started by a pull request depends on a package or a secret.
- A new IBKR build is seen within the hour instead of the next day. That is a target, not a
  guarantee: GitHub starts scheduled runs late or drops them under load (the daily run
  started 6.5 to 8 hours late from 2026-11-13 to 2026-11-16).

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

## Amendment 2026-11-17: how the package was created again

Phase 4 ran on 2026-11-17 and did not go as the Context (item 4) and the Phase 3 decision
assumed. What happened (UTC; every line observed, the runs read in their logs):

| Time | Action | Result |
|---|---|---|
| 08:09 | The public package `ghcr.io/rocketedge/brokersre-ib-gateway` deleted | Until the push at 08:10 an anonymous token request for it was refused (403) and the API answered "Package not found". Every image published until then is gone with it |
| 08:10 | `publish.yml` dispatched (run 44044468594) | Its job `private-package` pushed the placeholder `visibility-probe` (FROM scratch, one text file), and that push created the package again, **public**. `scripts/check-package-private.sh` reported PUBLIC (exit 1), the job failed, `publish` was skipped: no IBKR software was pushed. From 08:10:35 until 08:46:22 the public package held only the placeholder |
| 08:46:22 | The public placeholder package deleted | No package of that name until 08:46:43 |
| 08:46:43 | The same kind of placeholder (with the label `org.opencontainers.image.source=https://github.com/RocketEdge/brokersre-ib-gateway`) pushed with a classic personal access token with `write:packages`, from an operator machine, without `docker login`, through a throwaway `DOCKER_CONFIG` | The push created the package, **internal**. `check-package-private.sh` exit 0: an anonymous token request is refused (401). The API's record of the package names **no repository**: the source label did not link it |
| 08:47 | `publish.yml` dispatched again (run 44049788033) | The placeholder push with the workflow's token failed, `permission_denied: write_package`; the job failed, `publish` was skipped, nothing was pushed |
| after 08:47 | `publish.yml`, `rebuild.yml` and `detect-releases.yml` disabled again | No RocketEdge gateway image is published. The package exists, not public, and holds only the placeholder (an index, its one image and Docker's attestation manifest) |

**The visibility gate worked as designed, twice.** The job `private-package` stopped both
runs before `publish` could start: the first at the anonymous-read check (a public package),
the second at the placeholder push (no write access). No IBKR software reached the registry.

**What GitHub does, as observed here** (with what GitHub documents, read on 2026-11-17):

1. A package that a workflow of this public repository creates is **public**. GitHub
   documents it: a package a workflow creates with `GITHUB_TOKEN` "inherits the visibility
   and permissions model of the repository where the workflow is run"
   ([Publishing and installing a package with GitHub Actions](https://docs.github.com/en/enterprise-cloud@latest/packages/managing-github-packages-using-github-actions-workflows/publishing-and-installing-a-package-with-github-actions)).
   Context item 4 ("private by default") and the Phase 3 statement that the workflow's first
   push creates it private and linked were wrong for this repository.
2. A package pushed with a personal token into this organisation, which belongs to a GitHub
   enterprise, came out **internal**. GitHub: an internal package of an organisation in an
   enterprise is "visible to all enterprise members"
   ([Configuring a package's access control and visibility](https://docs.github.com/en/enterprise-cloud@latest/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility)),
   and "all workflows running in any repository owned by the Enterprise account can download
   the package" (the Actions page above). ghcr.io refuses it to anonymous users, so
   `check-package-private.sh` cannot tell it from a private one
   ([limitations](../limitations.md) L40).
3. The label `org.opencontainers.image.source` did **not** link the package to the
   repository, although GitHub documents the label as the way to link an image before it is
   published (the access-control page above). Why is not established.
4. A package without a link refuses the workflow's token until its settings grant the
   repository under **Manage Actions access**; GitHub notes that this is not the same as
   connecting the package to a repository, and that a new version can be uploaded only by
   "workflows running in repositories that are given write permission on that package".

**Decision.**

- The package is created by hand, once, with a personal token (the recovery path below),
  never by a workflow of this repository: such a workflow creates a public package. Its
  visibility is changed in its settings; deleting it again is not a way to change it.
- The package is **not public**: private, or internal (its state since 2026-11-17). Internal
  keeps IBKR's software from anonymous users, but every member of the enterprise, and by
  GitHub's description every workflow in the enterprise, may read it; private limits it to the
  people and repositories it names. The owner chooses; the gate accepts both (L40).
- Workflows reach the package only through **Manage Actions access**: this repository with
  role **Write** (`publish.yml`, the scan of `rebuild.yml`, `qualify-paper.yml`) and the
  BrokerSRE repository with role **Read** (its pin job). Not a repository connection with
  inherited access: by GitHub's description ("a user who has read access to the linked
  repository will also have read access to the package") that would extend read access to
  everyone who can read this public repository, and the anonymous check would not see it
  (inference, not tested).
- No workflow or script changes. `publish.yml`'s gate already refuses a public package and
  refuses to push without write access; what it cannot see is recorded in L40.
- The name was taken again at 08:10, so the deleted public package cannot be restored (GitHub
  restores a deleted package only while no new package has taken its name, `tasks/todo.md`
  step (a)). The releases still name the digests published until 2026-11-17; no registry
  serves them.

**Owner steps** (web UI, package settings,
<https://github.com/orgs/RocketEdge/packages/container/brokersre-ib-gateway/settings>; the
checklist is in `tasks/todo.md`):

1. Optional: *Change visibility* from Internal to Private; then update L39 and the second
   bullet of the decision above, which say internal.
2. *Manage Actions access*, *Add repository*: `RocketEdge/brokersre-ib-gateway` with role
   Write; `RocketEdge/brokersre` with role Read.
3. Re-enable `publish.yml` and `detect-releases.yml`; dispatch `publish.yml` with
   `channels="stable latest"`; read the run through the job "the package is not public" (its log
   says `private: an anonymous read ... was refused`), the same check right before the push,
   and each channel's "Verify the signature and attestations".
4. Then re-enable `rebuild.yml`: its scan fails while the package holds no channel tags.

**Recovery path: create the package by hand.** Only when the package has to be created
again (it does not exist, or it was deleted). The procedure of 2026-11-17, written out (the
build and a push from a throwaway Docker configuration were checked against a local registry;
the push to ghcr.io ran on 2026-11-17). A personal access token (classic) with
`write:packages` is typed at the prompt; no token is stored in a file of your usual
configuration or a credential store. Run it in bash (Git Bash on Windows): zsh refuses
`read -p` ("no coprocess") and sh (dash) refuses `read -s` ("Illegal option").

```bash
# Run in bash: zsh refuses read -p, sh (dash) refuses read -s.
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

Then the owner steps above: the package comes out unlinked, so step 2 is what lets the
workflows in.

Rejected: letting `publish.yml` create the package and making it private afterwards (the
package is public in between, and the gate stops that run anyway); a workflow step that sets
the visibility (the decision above keeps "no workflow sets a visibility"); deleting the
internal package to try again (a push with a personal token creates it internal again, a
push from a workflow of this repository public).

## Note 2026-11-17: the first publish to the non-public package

- **Visibility:** the owner kept the package **internal** (2026-11-17), accepting what L40
  describes: every member of the enterprise, and every workflow in it, may read the image.
- **Access:** the owner granted this repository Write under *Manage Actions access*, which let
  the workflow's token push. That publish then **linked** the package to this repository (the
  API names `RocketEdge/brokersre-ib-gateway` from 20:19:57 UTC; at 08:46 it named none), as
  the source label predicts. A linked package can inherit the repository's access, and
  everyone can read a public repository (the decision above), so the owner then switched off
  "Inherit access from repository" in the package settings and granted the repositories
  explicitly (the owner's report; the API does not expose that setting).
- **An outsider is refused (20:41 UTC):** a signed-in GitHub account that is not a member of
  the organisation got a ghcr.io token for the package but was refused the manifests of
  `stable` and `latest` (403), while the same token read the public sidecar's (200). That token
  lacked `read:packages`; whether ghcr.io refuses on the missing scope first for a non-public
  package is not established, so this is strong but not conclusive evidence.
- **Publish:** `publish.yml` was dispatched at 20:10 UTC (run 44166458142, both channels) and
  succeeded. The job "the package is not public" pushed the placeholder with the workflow's
  token and saw the anonymous read refused; each channel passed the same check right before
  its push and "Verify the signature and attestations".
- **Checked from outside the workflow (20:20 UTC):** an anonymous token request answers 401;
  with a token that can read packages, `stable` is
  `sha256:8ff97ed6d53980ad95ea9bfdf2049ad36a6d206f206cc0cce3873adf6806e633` (IB Gateway
  10.50.1g, `qualified=yes`) and `latest` is
  `sha256:fd4ecd5504ac19a773e8f05d7ee77298c709e3cd15235ed4124a592a1d285fa6`; the pull of the
  stable digest and `cosign verify` of it against `publish.yml`'s identity on `main` passed.
  The release `v10.50.1g-stable` names the new digest and says the image is not public.
- **Workflows:** `publish.yml`, `detect-releases.yml` and `rebuild.yml` are enabled again.
- **Still open:** one `qualify-paper.yml` run against a digest of this package (owner-gated
  environment), and the first scan of `rebuild.yml` and the first hourly run of
  `detect-releases.yml` against it.
