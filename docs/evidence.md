# Evidence for operational due diligence

Which artefact of this image answers which question of a due-diligence questionnaire, and the
command that produces the evidence. The page covers this container image only: your strategy
code, your host, your network and your IBKR account settings are yours to evidence.

**RocketEdge no longer distributes a public image** (decided 2026-11-17,
[ADR 0018](adr/0018-private-image-public-build-recipe.md); the former public package
`ghcr.io/rocketedge/brokersre-ib-gateway` was withdrawn the same day, deleted with every image
in it): you build the image from this repository
([README, "Build the image"](../README.md#build-the-image)). The commands marked **[P]** below
were run against an image RocketEdge published then; that digest was deleted with the
package, so nobody can repeat them against it. No RocketEdge image is published at the moment.
The next one keeps the signature, SBOMs, provenance and releases for its BrokerSRE service, in
a package that ghcr.io does not serve to anonymous users: only those granted read access can
repeat the **[P]** commands on it.
For an image you built, start with [An image you built](#an-image-you-built); the questions
from "Who can reach the API?" on concern what the image does at run time and apply to any
image built from this repository.

Every command below was run on 2026-11-12 and its result seen, unless it is marked **[N]**:

- **[P]** run against the image RocketEdge published then
  `ghcr.io/rocketedge/brokersre-ib-gateway@sha256:693bd6306d94708a87e5b0c43180874f671010a5edf142796eb8f46f51e869ea`
  (`stable`, IB Gateway 10.50.1g, published 2026-11-11, deleted with the former public package
  on 2026-11-17);
- **[L]** run against a local build of this repository's image, started from the reference
  compose **without a login** (`IBC_LAUNCH=no`, dummy secret files): it proves what the image
  does around the Gateway, not what a logged-in Gateway does. The image published on
  2026-11-11 predates the `data` fields of C5 and C9 and the files of C19 and C20;
- **[N]** not run here; the reason is given.

Tools used: cosign v3.1.4, Trivy 0.76.2 (the version every scanner step of the workflows
pins) and syft 1.54.0 from their container images, GitHub CLI 2.81.0, jq 1.8.1 (the image
ships jq: `docker run --rm -i --entrypoint jq <image>`). Trivy ran with the vulnerability
database of 2026-11-12 already downloaded, so its commands also carried
`--skip-db-update --skip-java-db-update --scanners vuln`. In the commands, `IMAGE` is the
image by digest and `C` is the container name. In Git Bash on Windows run
`export MSYS_NO_PATHCONV=1` first: Git Bash rewrites an argument that starts with `/`, such
as a path inside the container, into a Windows path (`C:/Program Files/Git/...`), and the
command fails (checked 2026-11-17 with `docker exec`, and with `docker run -v` and `-e`):

```bash
IMAGE=<the image: RocketEdge's by digest from digests-<channel>.json, or yours>
C=<name of the running gateway container>
IDENTITY='^https://github.com/RocketEdge/brokersre-ib-gateway/.github/workflows/publish.yml@refs/heads/main$'
ISSUER=https://token.actions.githubusercontent.com
```

The identity ends in `@refs/heads/main$` on purpose: without the branch, a signature made by
the same workflow file on any other branch of the repository would verify too. With
`@refs/heads/other$` the same command fails (checked).

## An image you built

Run on 2026-11-17 against `brokersre-ib-gateway:stable` built with `scripts/build-image.sh`
(IB Gateway 10.50.1h); **[B]** marks these commands.

| What the build provides | Where it comes from | Command |
|---|---|---|
| The build's own record: version, channel, whether version and installer equal the pin (`qualified_by_project`), the installer's SHA-256, IBKR's build stamp, the image id | the last seven lines of `scripts/build-image.sh` / `.ps1` | keep them with your change record |
| The same facts as image labels (`com.rocketedge.brokersre.*`) | `Dockerfile`, `scripts/resolve-installer.sh` | B1 |
| The installer's bytes, where they came from (`source`) and when they were accepted, by version and SHA-256 | the installer cache (`installers/<version>/<arch>/<sha256>/meta`) | B2 |
| The installed Gateway carries IBKR's build stamp (the build fails otherwise) | `scripts/fetch-installer.sh --check-stamp` in the `Dockerfile` | B3 |
| Every other input pinned by SHA-256 or digest | `versions.json` and `scripts/build-helper/Dockerfile` of the commit you built | read them |
| An SBOM of your image | not produced by the build | B4 |

```bash
# B1 [B] ... "com.rocketedge.brokersre.ibkr.version":"10.50.1h", ..."com.rocketedge.brokersre.installer.source":"ibkr","com.rocketedge.brokersre.qualified":"no" ...
docker image inspect brokersre-ib-gateway:stable --format '{{json .Config.Labels}}'
# B2 [B] version: 10.50.1h ... sha256: eb578b23...fe7aa ... source: ibkr, accepted_at: <when it was accepted>
cat ~/.cache/brokersre-ib-gateway/installers/10.50.1h/x64/*/meta
# B3 [B] applicationVersion="(.1h) 20261116 16:02:08", equal to the label ibkr.build_stamp
docker run --rm --entrypoint cat brokersre-ib-gateway:stable //home/ibgateway/Jts/ibgateway/10.50.1h/.install4j/i4jparams.conf | grep -o 'applicationVersion="[^"]*"'
# B4 [B] a CycloneDX SBOM of the local image with syft, read through the Docker socket: 9776 components
MSYS_NO_PATHCONV=1 docker run --rm -v /var/run/docker.sock:/var/run/docker.sock anchore/syft:v1.54.0 brokersre-ib-gateway:stable -o cyclonedx-json > sbom.cdx.json
jq '.components | length' sbom.cdx.json
```

Limits: an image you built has no signature, no attested SBOM and no provenance unless you add
them in your own pipeline. `qualified_by_project: yes` says that the version and installer
equal the repository's pin, which passed the project's offline CI; a build that says `no` holds
a Gateway build the project's CI has not run on ([limitations](limitations.md), L35). Neither
says that a login happened: a paper login is a separate qualification
(`scripts/qualify-paper.sh`, [ADR 0014](adr/0014-paper-login-qualification.md)). The build
scripts label the image with `org.opencontainers.image.revision` (the commit, or `unknown`
outside a git clone) and `org.opencontainers.image.created`, which is that commit's time in UTC
(outside a git clone, IBKR's build time of the installer), not the time of the build, so that
an unchanged rebuild keeps its image id; the maintainers' bake path writes the build time.
`docker image inspect --format '{{.Created}}'` gives the time the image's last layer was built,
which a rebuild from Docker's build cache keeps. The scripts build with `--provenance=false`.

## Which exact software is running?

| What the image provides | Where it comes from | Command |
|---|---|---|
| One digest per build; tags are discovery aids, consumers pin the digest | `.github/workflows/publish.yml`, release asset `digests-<channel>.json` | C1 |
| A signature that only this repository's publish workflow can make (Sigstore keyless) | `publish.yml`, step "Sign and attest" | C2 |
| One CycloneDX SBOM per platform, each attested to the manifest of the platform it describes (the two platforms differ: arm64 carries Ubuntu's `openjdk-25-jre`). **The image published on 2026-11-11 has one SBOM, attested to the index, and it describes linux/amd64 only** | `publish.yml`, steps "SBOM of the linux/amd64 image" and "SBOM of the linux/arm64 image", `scripts/platform-digests.sh` | C3, C3a, C3b |
| Build provenance: which workflow, on which runner, built the digest | `publish.yml`, `actions/attest-build-provenance` | C4 |
| The running container states its Gateway version, IBKR channel, IBC version and release, trading mode and instance in its first event | `rootfs/usr/local/bin/entrypoint.sh` (`container_start`) | C5 |
| Image labels with version, source revision and base image digest | `Dockerfile`, `docker-bake.hcl` | C6 |
| Every build input pinned by SHA-256 in one file; the build fails on a mismatch | `versions.json`, `scripts/fetch-installer.sh`, `Dockerfile` | read `versions.json` |

```bash
# C1 [P] the digest a channel tag points at -> sha256:693bd630...e869ea
docker buildx imagetools inspect ghcr.io/rocketedge/brokersre-ib-gateway:stable --format '{{json .Manifest}}' | jq -r .digest
# C2 [P] exit 0, "The code-signing certificate was verified using trusted certificate authority certificates"
cosign verify "$IMAGE" --certificate-oidc-issuer "$ISSUER" --certificate-identity-regexp "$IDENTITY"
# C3 [P] exit 0; the payload is the SBOM (CycloneDX 1.7) of the image published on 2026-11-11:
#        9776 components. It describes linux/amd64 only: syft on the linux/amd64 manifest gives
#        9776 components, on the linux/arm64 manifest 9946 (with openjdk-25-jre)
cosign verify-attestation --type cyclonedx "$IMAGE" --certificate-oidc-issuer "$ISSUER" --certificate-identity-regexp "$IDENTITY" \
  | jq -r .payload | base64 -d | jq '.predicate.components | length'
# C3a [P] the manifest of each platform inside the index (also in digests-<channel>.json, key
#         "platforms", from the first publish after this change)
docker buildx imagetools inspect "$IMAGE" --format '{{json .Manifest}}' \
  | jq -r '.manifests[] | select(.platform.os == "linux") | "\(.platform.os)/\(.platform.architecture) \(.digest)"'
# C3b [N] the SBOM of one platform, attested to that platform's manifest: no published image
#         carries per-platform SBOMs yet (they start with the first publish after this change)
cosign verify-attestation --type cyclonedx "ghcr.io/rocketedge/brokersre-ib-gateway@<platform manifest digest>" \
  --certificate-oidc-issuer "$ISSUER" --certificate-identity-regexp "$IDENTITY"
# C4 [P] exit 0; SLSA provenance v1 from publish.yml@refs/heads/main on a GitHub-hosted runner (needs `gh auth login`)
gh attestation verify "oci://$IMAGE" --repo RocketEdge/brokersre-ib-gateway
# C5 [L] {"gateway_version":"10.50.1g","channel":"stable","ibc_version":"3.24.2","ibc_release":"3.24.2-rocketedge.1","trading_mode":"paper","instance":"default"}
docker logs "$C" 2>&1 | jq -c 'select(.event == "container_start") | .data'
# C6 [L] 10.50.1g-stable <git revision> sha256:6a06111c...4d3c
docker inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.version"}} {{index .Config.Labels "org.opencontainers.image.revision"}} {{index .Config.Labels "org.opencontainers.image.base.digest"}}'
```

Limits: the SHA-256 of IBKR's installers are computed by RocketEdge when a release is
detected, because IBKR publishes none ([limitations](limitations.md), L06). They prove that
every build used the same bytes, not that IBKR signed them.

## What changed and when?

| What the image provides | Where it comes from | Command |
|---|---|---|
| Nothing you run changes until you move your digest pin; every publish and every OS-patch rebuild is a release that names its digest | `publish.yml`, [upgrade policy](upgrade-policy.md), [ADR 0008](adr/0008-tagging-and-rebuild-policy.md) | C8 |
| A fingerprint of the non-secret configuration in the `config_rendered` event of every start: it changes when a setting changes and does not depend on the credentials | `rootfs/usr/local/lib/brokersre/render-config.sh` (`config_fingerprint`); tests "config_hash changes when a setting changes" and "config_hash does not depend on the username or the password" (`tests/bats/unit/render.bats`) | C9 |
| A new `boot_id` per container start, carried by every event and sample | `rootfs/usr/local/lib/brokersre/common.sh` (`new_boot_id`); test "two starts get different boot ids" (`tests/bats/unit/common.bats`) | C9 |
| An append-only change log with what did not work, and one decision record per design decision | [changes.md](changes.md), [adr/](adr/README.md), `git log` | read them |

```bash
# C8 [P] the releases, and the digest one of them names
gh release list -R RocketEdge/brokersre-ib-gateway
gh release download v10.50.1g-stable -R RocketEdge/brokersre-ib-gateway --pattern digests-stable.json
# C9 [L] {"ts":"2026-11-12T03:05:29.802Z","boot_id":"cd5008b6346b44c1","data":{"config_hash":"a540a30b7e85ccc6","trading_mode":"paper","read_only_api":"yes","auto_restart_time":"","time_zone":"Etc/UTC"}}
docker logs "$C" 2>&1 | jq -c 'select(.event == "config_rendered") | {ts, boot_id, data}'
```

Limit: a release of an already released version is updated in place, so the release date is
not always the build date; the `created` field of `digests-<channel>.json` is.

## Who can reach the trading API?

| What the image provides | Where it comes from | Command |
|---|---|---|
| IB Gateway trusts loopback only, and IBC rejects API connections that are not trusted | `rootfs/etc/brokersre/jts.ini.tmpl` (`TrustedIPs=127.0.0.1`), `rootfs/etc/brokersre/ibc.config.ini.tmpl` (`AcceptIncomingConnectionAction`) | C11 |
| A relay publishes the API on the container interface, and it listens only while the phase is `logged-in` | `rootfs/usr/local/lib/brokersre/start-socat.sh`; tests "the relay stays closed while the Gateway is not logged in", "the relay closes when the Gateway leaves logged-in (daily restart, re-login)" (`tests/bats/unit/relay.bats`) and "relay closed while the Gateway is not logged in" (`tests/container/run.sh`) | C13 |
| The reference compose publishes the relay on `127.0.0.1` unless you set a private address | `compose/docker-compose.example.yml`; test "compose: API ports published on loopback by default" (`tests/container/run.sh`) | C10 |
| The API is read-only unless you set `READ_ONLY_API=no`; the value in force is in the `config_rendered` event | `ibc.config.ini.tmpl` (`ReadOnlyApi`), `docs/env-vars.md` | C12 |
| The command channel that can stop the Gateway listens on loopback inside the container only; no SSH; VNC is off unless you supply a password file, and then on loopback | `ibc.config.ini.tmpl` (`ControlFrom`, `BindAddress`), `rootfs/usr/local/lib/brokersre/start-vnc.sh`; tests "no telnet or ssh client", "IBC_COMMAND_SERVER_PORT=0 keeps 7462 closed" (`tests/container/run.sh`) | C13 |

```bash
# C10 [L] 4003/tcp -> 127.0.0.1:4001 and 4004/tcp -> 127.0.0.1:4002
docker port "$C"
# C11 [L] TrustedIPs=127.0.0.1
docker exec "$C" grep '^TrustedIPs=' /home/ibgateway/Jts/settings/jts.ini
# C12 [L] yes
docker logs "$C" 2>&1 | jq -r 'select(.event == "config_rendered") | .data.read_only_api'
# C13 [L] every listening socket of the container (without a login and with IBC_LAUNCH=no: the relay only)
docker exec "$C" ss -ltn
```

Limits: the TWS API has no authentication and no encryption. The relay forwards from inside
the container, so the Gateway sees every client as local: whoever can reach the published
port can use the API with the rights of the session. Which address the port is published on
is your compose file's decision, and what your firewall allows is yours to evidence.

## Where are the credentials?

| What the image provides | Where it comes from | Command |
|---|---|---|
| The username and password arrive as files (Docker secrets), never as values in the compose file | `compose/docker-compose.example.yml`, `rootfs/usr/local/lib/brokersre/common.sh` (`file_env`) | read the compose file |
| They are written to one file, `/run/brokersre/config.ini`, mode 0600, on a tmpfs in the reference compose, because IBC reads them from a file | `render-config.sh`; tests "credentials from _FILE land in config.ini with mode 0600 and are not expanded" (`tests/bats/unit/render.bats`), "config.ini rendered with mode 0600" (`tests/container/run.sh`) | C15 |
| They are removed from the environment before any other process starts | `render-config.sh` (`unset_secret`); tests "secrets are unset from the environment after rendering" (`render.bats`), "no credential in PID 1 environment", "the sampler runs without any credential in its environment" (`tests/container/run.sh`) | C14 |
| They never appear in an event, in the preflight output or under the log volume | `rootfs/usr/local/lib/brokersre/log.sh`; tests "no event of the rendering step contains the username or the password" (`render.bats`), "raw lines never reach stdout: the credential-bearing line produces no event text" (`tests/bats/unit/classify.bats`), "password absent from the log volume", "doctor: no credential in its output" (`tests/container/run.sh`) | run the suites: C16 |
| A secret file that would corrupt the password (UTF-16, empty) stops the container instead of sending IBKR a wrong password | `common.sh` (`read_secret_file`); tests in `tests/bats/unit/common.bats` | C16 |

```bash
# C14 [L] 0
docker exec "$C" sh -c 'tr "\0" "\n" < /proc/1/environ | grep -c -E "^TWS_(USERID|PASSWORD)="'
# C15 [L] "600 /run/brokersre/config.ini" and "tmpfs"
docker exec "$C" stat -c '%a %n' /run/brokersre/config.ini
docker exec "$C" findmnt -n -o FSTYPE --target /run/brokersre
# C16 [N] the two test suites, with dummy credentials and no login; not re-run for this page
#         (docs/changes.md records the last full runs)
tests/bats/run-in-image.sh "$IMAGE"
IMAGE="$IMAGE" tests/container/run.sh
```

Limits, stated in [SECURITY.md](../SECURITY.md): the plaintext password exists in that tmpfs
file while the container runs, which is inherent to IBC; the raw IBC and Gateway logs on the
log volume can contain the username and must not leave the host unredacted; `TWS_USERID` and
`TWS_PASSWORD` given as plain environment variables also work and are then visible in
`docker inspect`, which is why the preflight warns about a password passed that way.

## How do you know it is healthy, and how fast do you notice?

| What the image provides | Where it comes from | Command |
|---|---|---|
| A health check that is healthy only when the Gateway process is alive and its API port accepts a connection: a pending second factor is unhealthy. Checked every 15 s, unhealthy after 3 failures, 300 s start period | `Dockerfile` (`HEALTHCHECK`), `rootfs/usr/local/lib/brokersre/healthcheck.sh`; tests in `tests/bats/unit/healthcheck.bats`, "healthcheck honestly unhealthy before login" (`tests/container/run.sh`) | C17 |
| The lifecycle phase as one token in a file: `starting`, `login`, `2fa-pending`, `logged-in`, `restarting`, `existing-session`, `needs-human`, `stopping`, `stopped`, `exited`, `test-mode` | `common.sh` (`set_phase`), `rootfs/usr/local/lib/brokersre/classify-ibc-log.sh` | C18 |
| Structured events on stdout and on the log volume, each with the start's `boot_id` and a sequence number without gaps, so a reader can prove that it lost none | `log.sh`; tests "events written by many processes at once get unique, gap-free sequence numbers" (`tests/bats/unit/log.bats`), "every event carries the boot id and the sequence 1..n without a gap" (`tests/container/run.sh`) | C19 |
| A resource sample every 30 s (memory, CPU, processes, disk, OOM kills) and events for an OOM kill, a full disk, a stalled login and high memory | `rootfs/usr/local/lib/brokersre/sampler.sh`; `tests/bats/unit/sampler.bats` | C20 |
| A preflight that names configuration problems before any login is attempted | `rootfs/usr/local/lib/brokersre/doctor.sh`; `tests/bats/unit/doctor.bats` | C21 |

```bash
# C17 [L] "healthy" / "healthy: relay listening on 4004 (IBC not launched)" in test mode
docker inspect "$C" --format '{{.State.Health.Status}}'
docker exec "$C" /usr/local/lib/brokersre/healthcheck.sh
# C18 [L] test-mode
docker exec "$C" cat /var/log/ibgateway/state/phase
# C19 [L] true: within every boot the sequence numbers are consecutive
docker exec "$C" sh -c 'jq -es "group_by(.boot_id) | all(([.[].seq] | sort) as \$s | \$s == [range(\$s[0]; \$s[0] + length)])" /var/log/ibgateway/events/events.jsonl'
# C20 [L] {"ts":"...","src":"metrics","boot_id":"...","seq":280,"phase":"test-mode","mem_working_set_bytes":18833408,"oom_kills":0,...}
docker exec "$C" tail -n 1 /var/log/ibgateway/metrics/metrics.jsonl
# C21 [L] {"schema":"brokersre.doctor.v1","result":"warn","checks":[...12 checks...]}, exit 0
#         (the warning: no AUTO_RESTART_TIME was set for this run)
docker run --rm -v "$PWD/compose/secrets:/run/secrets:ro" -e TWS_USERID_FILE=/run/secrets/ib-username \
  -e TWS_PASSWORD_FILE=/run/secrets/ib-password -e TRADING_MODE=paper "$IMAGE" doctor --json
```

**The image alone notifies nobody.** It produces a health status, a phase file, events and
samples; it sends no e-mail, page or message, and it restarts nothing. Notification, and a
probe that makes a real API call instead of a TCP connection, are the job of the optional
sidecar and of the Azure Log Analytics pack, which are separate components. Without them, or
without your own monitoring reading the outputs above, a gateway that waits for a second
factor at 03:00 waits unnoticed. How fast you notice is therefore a property of what reads
these outputs, not of this image. The health check itself proves an open port, not a working
market-data or order session.

## Is the second factor automated?

No, by design. A second factor exists so that a person approves each new session; software
that answers it turns it into a second stored password and removes the control. The image
has no TOTP secret, no authenticator and no code that approves a prompt.

| What the image provides | Where it comes from |
|---|---|
| IBC prompts again after a timeout instead of giving up; the phase is `2fa-pending`, the event is `twofa_initiated` (and `twofa_dialog` where the Gateway opens a separate dialog, which according to IBC's source Gateway 10.16 and later does not), and the container is unhealthy until a person approves | `ibc.config.ini.tmpl` (`ReloginAfterSecondFactorAuthenticationTimeout`), `rootfs/etc/brokersre/ibc-patterns.tsv`; test "a 2FA dialog sets phase 2fa-pending and login completion sets logged-in" (`tests/bats/unit/classify.bats`) |
| An optional cap on unanswered prompts (`TWOFA_MAX_PROMPTS`): the image then stops asking, sets the phase `needs-human` and stays up, so a restart policy cannot loop through more logins | `classify-ibc-log.sh`, `entrypoint.sh`; test "after TWOFA_MAX_PROMPTS unanswered prompts the gateway asks for a human and stops IBC" (`classify.bats`) |

Limit: the log lines for the second factor come from IBC's source code and have not yet been
seen in a real log of this image ([limitations](limitations.md), L01).

## How are vulnerabilities handled?

| What the image provides | Where it comes from | Command |
|---|---|---|
| A gate before any tag moves: both platforms of the digest about to be tagged must have no CRITICAL or HIGH finding in OS packages that has a fixed package, each report must name the platform it was asked to read, and the index must hold exactly one image per platform | `publish.yml`, `scripts/check-report-arch.sh`, `scripts/platform-digests.sh`, `scripts/promote-tags.sh` and their tests in `tests/bats/ci/` | C22 |
| A scheduled scan of the published images (daily when GitHub runs the schedule; it can be late, and GitHub disables schedules after 60 days without repository activity). A fixable finding opens one tracking issue and requests a rebuild of that channel on the first 3 days; while the published image stays the same, one comment a day says so, and after 3 days a person must decide. A target, not a guarantee: no number of hours is promised | `.github/workflows/rebuild.yml`, `scripts/rebuild-decision.sh`, `scripts/rebuild-issue.sh`, `scripts/rebuild-channels.sh` and their tests in `tests/bats/ci/`; [upgrade policy](upgrade-policy.md) | C22 is the scan it runs |
| Scanner and actions pinned like every other input: one Trivy version (v0.76.2) on every scanner step, every action of the publish and rebuild workflows by commit | `publish.yml`, `rebuild.yml`, `tests/bats/ci/workflows.bats` | read the workflow files |
| A machine-readable statement about each CVE in IBKR's bundled jars, which this image cannot patch: every one is `under_investigation` and says what is unknown | [`security/vex/ibgateway-vendor-jars.openvex.json`](../security/vex/ibgateway-vendor-jars.openvex.json) (OpenVEX v0.2.0), [limitations](limitations.md) L08 | C23 |
| A check that the statement list and the scanner agree, in every CI and publish run (a warning, not a gate) | `scripts/check-vex.sh` (`tests/bats/ci/check-vex.bats`), `ci.yml`, `publish.yml` | C24 |

```bash
# C22 [P] exit 0 for linux/amd64 and for linux/arm64 ("Vulnerabilities: 0")
trivy image --image-src remote --platform linux/arm64 --pkg-types os --severity CRITICAL,HIGH --ignore-unfixed --exit-code 1 "$IMAGE"
# C23 [P] exit 0; the 25 jar findings stay listed, because under_investigation hides nothing
trivy image --image-src remote --pkg-types library --vex security/vex/ibgateway-vendor-jars.openvex.json "$IMAGE"
# C24 [P] "check-vex: in sync: 25 statements cover 25 jar findings in 1 report(s)", exit 0 (needs jq)
trivy image --image-src remote --pkg-types library --list-all-pkgs --format json --output jars.json "$IMAGE"
scripts/check-vex.sh security/vex/ibgateway-vendor-jars.openvex.json jars.json
# C25 [N] the VEX document as an attestation of the image: no published image carries it yet
cosign verify-attestation --type openvex "$IMAGE" --certificate-oidc-issuer "$ISSUER" --certificate-identity-regexp "$IDENTITY"
```

State on 2026-11-12, to be read with the table: the two-platform gate, the scheduled scan,
the per-platform SBOMs, the tag promotion and the VEX attestation are in the workflow files
and their decisions are covered by tests, but **no workflow run has executed them yet**. The
published images were gated on linux/amd64 only and carry one SBOM that describes
linux/amd64; C22 is a manual scan of both platforms of those digests. The first publish
after this change produces the first image that C3b and C25 can verify. A change to the VEX
document reaches the attestation only with the next publish; the file in the repository and
in the newest release is the current one.

Also known and not hidden: Trivy reports one more finding outside OS packages and outside
the jars, in the Go standard library of `/usr/bin/pebble` (severity not yet assigned on
2026-11-12). The binary comes with the Ubuntu base image and belongs to no package, so the
OS gate does not cover it and `apt-get upgrade` cannot replace it: only a move of the pinned
base image digest does. The VEX document for the jars does not cover it either;
`check-vex.sh` prints it as a note. It is left in place: nothing in the image starts it, and
removing a file of the base layer is a change of its own.

## What is not covered?

Read [limitations.md](limitations.md) in full; the points an auditor should not miss:

- **Only fresh paper logins have been observed.** The published digests `7773ff7`
  (`stable`, 10.50.1g) and `cc3a6a9` (`latest`, 10.52.1d) completed real paper logins and
  passed the qualification on 2026-11-16, run by hand outside CI (L16); a digest that a
  channel tag moves to later is not covered by those runs. The patterns for the second factor, the daily
  restart and a competing session are unconfirmed (L01), no session has run through a daily
  restart or a weekly re-authentication, and no test in CI ever logs in (L04).
- **This is not an IBKR-supported way to run IB Gateway.** IB Gateway is a desktop
  application with a login window; this image runs it under a virtual display and lets IBC
  type the credentials. IBKR can change the window in any release, and the upstream of IBC is
  archived ([ADR 0015](adr/0015-login-controller-succession.md)).
- The arm64 image has never completed a login on real hardware (L05).
- IBKR's bundled jars carry CVEs that this image cannot patch (L08).
- The image alerts nobody and restarts nothing (see above).
- The licence is MIT: no warranty and no service level.

Interactive Brokers, IBKR, IB Gateway and Trader Workstation are trademarks of Interactive
Brokers LLC. This project is not affiliated with, endorsed by or sponsored by Interactive
Brokers.
