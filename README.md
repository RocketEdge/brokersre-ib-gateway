# brokersre-ib-gateway

IB Gateway and IBC in a container built for **unattended, observable operation**: one
parametrised Dockerfile for both IBKR channels, every input verified (pinned by SHA-256, or
checked against IBKR's own build stamp), no `sudo`, a read-only root filesystem, a truthful
`HEALTHCHECK`, the IBC command server on loopback, structured JSON on stdout and raw logs on
a shared volume, `tini` as PID 1, amd64 and arm64.

**You build the image yourself**, with one command and nothing but Docker: there is no public
image ([why](#why-there-is-no-public-image)). [Build the image](#build-the-image) is the
recipe.

Derived from [gnzsnz/ib-gateway-docker](https://github.com/gnzsnz/ib-gateway-docker) (MIT) and
maintained by [RocketEdge](https://rocketedge.com) as the gateway image of its
[BrokerSRE](https://rocketedge.com/brokersre/) service. It works standalone too.

Interactive Brokers, IBKR, Trader Workstation, TWS and IB Gateway are trademarks of Interactive
Brokers LLC. RocketEdge is an independent engineering firm and is not affiliated with, sponsored
by or endorsed by Interactive Brokers.

## Table of Contents

- [Build the image](#build-the-image)
- [Quick start](#quick-start)
- [Running on Windows](#running-on-windows)
- [Going live](#going-live)
- [The weekly login](#the-weekly-login)
- [Several gateways on one host](#several-gateways-on-one-host)
- [Connecting a strategy](#connecting-a-strategy)
- [Environment variables](#environment-variables)
- [Ports, volumes and the sidecar contract](#ports-volumes-and-the-sidecar-contract)
- [Health, phases and logs](#health-phases-and-logs)
- [Break-glass console](#break-glass-console)
- [Shipping events to your own log system](#shipping-events-to-your-own-log-system)
- [Optional sidecar: API probe, status endpoints, alerts](#optional-sidecar-api-probe-status-endpoints-alerts)
- [Shipping to Azure Log Analytics](#shipping-to-azure-log-analytics)
- [Security posture](#security-posture)
- [Verifying what you built](#verifying-what-you-built)
- [Evidence for due diligence](#evidence-for-due-diligence)
- [Qualifying an image with a real paper login](#qualifying-an-image-with-a-real-paper-login)
- [Get notified of new versions](#get-notified-of-new-versions)
- [Is a newer IB Gateway available?](#is-a-newer-ib-gateway-available)
- [Building and testing](#building-and-testing)
- [Upgrade policy](#upgrade-policy)
- [Automatic updates and repository secrets](#automatic-updates-and-repository-secrets)
- [Differences from gnzsnz/ib-gateway-docker](#differences-from-gnzsnzib-gateway-docker)
- [Documentation](#documentation)
- [License](#license)

## Build the image

One command builds the image on your machine, with Docker as the only tool you need. It
downloads IB Gateway from IBKR, checks the installer, builds the image, runs an offline test of
IBC in it and prints what it built. Everything below was run on a Windows 11 computer with
Docker Desktop 29.9.3 (Git Bash, PowerShell 7 and Windows PowerShell 5.1) on 2026-11-17;
what was not run is marked **not tested**.

- [Why there is no public image](#why-there-is-no-public-image)
- [What you need](#what-you-need)
- [Build it](#build-it)
- [What the last lines mean](#what-the-last-lines-mean)
- [The latest channel](#the-latest-channel)
- [Apple silicon and other arm64 hosts](#apple-silicon-and-other-arm64-hosts)
- [Behind a corporate proxy](#behind-a-corporate-proxy)
- [Offline, or when IBKR has moved on](#offline-or-when-ibkr-has-moved-on)
- [Pinning and reproducing a build](#pinning-and-reproducing-a-build)
- [Pushing to your own private registry](#pushing-to-your-own-private-registry)
- [Building in your own CI](#building-in-your-own-ci)
- [Upgrading and rolling back](#upgrading-and-rolling-back)
- [Troubleshooting the build](#troubleshooting-the-build)

### Why there is no public image

The image contains IB Gateway as installed from IBKR's installer, and IB Gateway is IBKR's
software. RocketEdge does not redistribute it, so it publishes no image that contains it: the
image RocketEdge builds for its own BrokerSRE service is private. This repository is the
recipe instead. When you build, your machine downloads IB Gateway from IBKR itself, under your
own agreement with IBKR, and the image stays with you (keep it in a private registry if you
move it, [below](#pushing-to-your-own-private-registry)). The decision is
[ADR 0018](docs/adr/0018-private-image-public-build-recipe.md).

### What you need

| Host | Docker | Shell | Tested |
|---|---|---|---|
| Linux, x86-64 or arm64 | Docker Engine 23 or later with the buildx plugin (`docker-buildx-plugin` in Docker's own package repositories) | bash | no (the build-test job of this repository's CI runs it on GitHub's Ubuntu runner) |
| macOS, Intel | Docker Desktop | bash 3.2, which macOS ships, runs the script from zsh too | no |
| macOS, Apple silicon | Docker Desktop; builds `linux/arm64` by default ([below](#apple-silicon-and-other-arm64-hosts)) | as above | no |
| Windows 10 or 11 | Docker Desktop with the WSL 2 backend, Linux containers | Git Bash (Git for Windows) | yes |
| Windows 10 or 11 | Docker Desktop | PowerShell 7 or Windows PowerShell 5.1 | yes |
| WSL 2 | Docker Desktop's WSL integration, or Docker Engine inside the distribution | bash; clone into the Linux file system (`~/...`), not under `/mnt/c` | no |

Also: `git` to clone this repository, about 6 GB of free disk and a connection to
`download2.interactivebrokers.com`, Docker Hub and GitHub. Nothing else is installed on the
host: finding, downloading and checking IBKR's installer run in a small helper container that
the script builds first (the official Docker CLI image pinned by digest, plus bash, curl and
jq).

What one build took on the development computer (20 cores, Docker Desktop 29.9.3, 2026-11-17,
from Singapore):

| | Time | Notes |
|---|---|---|
| First build, nothing cached (a new buildx builder, an empty installer cache) | 9 min 1 s | of which about 3 min downloading IBKR's installer (360,312,436 bytes for `stable` x64) |
| Build with Docker's build cache warm, the installer downloaded once more (`latest` channel) | 3 min 54 s | |
| Rebuild of the same version, installer and Docker's build cache warm (`stable`) | 1 min 14 s | the offline IBC test included |

| On disk after one build | Size |
|---|---|
| The image (`docker image inspect brokersre-ib-gateway:stable --format '{{.Size}}'`) | 1,622,526,158 bytes (1.6 GB) |
| Docker's build cache of that build (`docker buildx du`, on a builder used for nothing else) | 3.55 GB; `docker builder prune` frees it |
| The installer cache, per IB Gateway version and architecture | 344 MiB |
| The helper image `brokersre-ib-gateway-build-helper:local` | 232 MB |

### Build it

Clone the repository and run the script from its folder.

Linux, macOS, WSL or Git Bash:

```bash
git clone https://github.com/RocketEdge/brokersre-ib-gateway.git
cd brokersre-ib-gateway
scripts/build-image.sh
```

PowerShell 7, or Windows PowerShell 5.1 (the second form):

```powershell
git clone https://github.com/RocketEdge/brokersre-ib-gateway.git
cd brokersre-ib-gateway
pwsh -NoProfile -File scripts/build-image.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-image.ps1
```

You should see, on standard error: a line naming what it downloads
(`resolve-installer: downloading https://download2.interactivebrokers.com/installers/ibgateway/stable-standalone/ibgateway-stable-standalone-linux-x64.sh`,
or `IBKR serves the pinned ... using the cached copy`), then
`build-image: building brokersre-ib-gateway:stable: IB Gateway 10.50.1h (stable) for linux/amd64`
and Docker's build output, then the offline IBC test:

```text
== IBC smoke (offline, --network none, hardened: read-only root, no capabilities) ==
PASS  IBC command server listening on 7462 within 180s
...
PASS  shutdown_complete event emitted

ALL CONTAINER TESTS PASSED
resolve-installer: cached 10.50.1h (x64) in /cache/installers/10.50.1h/x64
```

and at the end, on standard output, seven `key: value` lines (here the build of 2026-11-17,
when IBKR's `stable` channel served 10.50.1h and `versions.json` still pinned 10.50.1g):

```text
version: 10.50.1h
channel: stable
qualified_by_project: no
installer_sha256: eb578b23b636e19c8417fc969264853a22792bcffa8fc79990cf15ff032fe7aa
ibkr_build_stamp: (.1h) 20261116 16:02:08
image: brokersre-ib-gateway:stable
image_id: sha256:c48cdbacf48c60bda36c9e3093dbe0d3501b3f01439851b101dd6b79fd02a8ff
```

The exit status is 0. The image is tagged twice, `brokersre-ib-gateway:stable` and
`brokersre-ib-gateway:10.50.1h`. `--tag NAME` (repeatable; `-Tag` in PowerShell) replaces both.
`--help` lists every option; `--print-plan` says what would be built and builds nothing.

The installer cache is `~/.cache/brokersre-ib-gateway` (`$XDG_CACHE_HOME` when set) for the
bash script and `%LOCALAPPDATA%\brokersre-ib-gateway` for the PowerShell script;
`--cache-dir DIR` (`-CacheDir`) chooses another.

### What the last lines mean

| Line | Meaning |
|---|---|
| `version` | The IB Gateway build in the image, as IBKR names it (`10.50.1h`) |
| `channel` | IBKR's channel it came from: `stable` or `latest` |
| `qualified_by_project` | `yes`: the version and the installer's SHA-256 are the ones pinned in [versions.json](versions.json), which the project has built, tested and logged in with. `no`: IBKR serves a newer build than the pin (or you gave an installer of your own); the script built it after checking it against IBKR's own build stamp, and no login has been made with it by the project |
| `installer_sha256` | SHA-256 of the installer the image was built from; also the label `com.rocketedge.brokersre.installer.sha256` |
| `ibkr_build_stamp` | IBKR's build stamp, `(.<suffix>) <build date and time>`; the installed Gateway carries exactly this stamp, or the build would have failed |
| `image` | The first tag of the image |
| `image_id` | Docker's id of the image you just built |

**`qualified_by_project: no`.** IBKR serves only its newest build of a channel, at an address
that never changes; when it publishes a new one, the installer no longer matches the pin, so
the script builds IBKR's current build instead. It accepts that build only when IBKR's
`version.json` names the same build before and after the download and the installer and the
installed Gateway carry IBKR's stamp. That proves the bytes are the build IBKR announced; it does
not prove that this Gateway logs in through IBC. A warning says so after the build:

```text
WARNING: IB Gateway 10.50.1h (stable) is not qualified by this project.
  versions.json pins 10.50.1g; this image holds 10.50.1h, build stamp (.1h) 20261116 16:02:08.
  ...
    scripts/qualify-paper.sh --image brokersre-ib-gateway:stable --secrets-dir <dir>
```

What to do, in order of preference:

1. Qualify it yourself with one login to a **paper** account of your own:
   `scripts/qualify-paper.sh --image brokersre-ib-gateway:10.50.1h --secrets-dir <dir>`
   ([Qualifying an image with a real paper login](#qualifying-an-image-with-a-real-paper-login));
   exit 0 means the image logged in, was healthy and stopped tidily.
2. Or wait until this repository pins the new build (a pull request that changes
   `versions.json`), pull, and build again: the line then says `yes`.
3. Or refuse such builds: `--strict` (`-Strict`) builds only the pinned version and exits 4
   when IBKR serves another one.

### The latest channel

```bash
scripts/build-image.sh --channel latest
```

```powershell
pwsh -NoProfile -File scripts/build-image.ps1 -Channel latest
```

`latest` is **IBKR's channel name** for its newest Gateway, not Docker's moving tag. The image is
tagged `brokersre-ib-gateway:latest` and `brokersre-ib-gateway:<version>`. On 2026-11-17 IBKR's
`latest` channel served the pinned build, so the last lines read:

```text
version: 10.52.1d
channel: latest
qualified_by_project: yes
installer_sha256: 11443650c0305751b8e239c894e4730db8a452c03a41255298f29f89a4fcc603
ibkr_build_stamp: (.1d) 20261112 16:03:29
image: brokersre-ib-gateway:latest
image_id: sha256:0d2f7ce4012b679ef5ebac0a8c8475669d756419c738d429fabe84a578ee75e0
```

The versions this repository pins (generated from [versions.json](versions.json) by
`scripts/readme-versions.sh`; the tags are those of RocketEdge's own image, yours are
`brokersre-ib-gateway:<channel>` and `brokersre-ib-gateway:<version>`):

<!-- versions:start -->
| IBKR channel | IB Gateway | IBC | Tags |
|---|---|---|---|
| stable | 10.50.1g | 3.24.2 (RocketEdge/ibc `3.24.2-rocketedge.1`) | `stable`, `10.50`, `10.50.1g` |
| latest | 10.52.1d | 3.24.2 (RocketEdge/ibc `3.24.2-rocketedge.1`) | `latest`, `10.52`, `10.52.1d` |
<!-- versions:end -->

### Apple silicon and other arm64 hosts

The script builds for the Docker host's architecture: `linux/arm64` on Apple silicon and on
arm64 Linux, from IBKR's arm64 installer. IBKR ships no Java runtime for Linux on arm64, so
the arm64 image runs Ubuntu's OpenJDK 25 instead of the runtime IBKR bundles for x86-64.
**No arm64 image has completed a login on real hardware**
([limitations](docs/limitations.md) L05); qualify yours with a paper login before you rely on it.

To build the other architecture, name it; Docker then emulates it (Docker Desktop has the
emulation built in; on Linux it needs QEMU's binfmt handlers). A separate tag keeps it apart
from the image of your own architecture, and under emulation the build and the IBC test are
much slower, so `SMOKE_TIMEOUT=900` gives the test more time (PowerShell: set
`$env:SMOKE_TIMEOUT = '900'` first, then `-Platform linux/arm64 -Tag ...`):

```bash
SMOKE_TIMEOUT=900 scripts/build-image.sh --platform linux/arm64 --tag brokersre-ib-gateway:stable-arm64
```

On the Windows computer (x86-64, Docker Desktop's emulation) this took 8 min 53 s on
2026-11-17, including the download of IBKR's arm64 installer (221,123,393 bytes); the IBC test
passed (the command server answered within its 900 s), and the image is 1,708,394,140 bytes. Docker prints
`WARNING: The requested image's platform (linux/arm64) does not match the detected host platform`
for each test container; that is expected under emulation. On Apple silicon,
`--platform linux/amd64` builds an x86-64 image under emulation. **Not tested on a Mac**, nor on
an arm64 Linux host.

### Behind a corporate proxy

Three parts of a build go to the network, and each takes its proxy from a different place:

| What | Goes to | Takes the proxy from |
|---|---|---|
| Docker pulling the base images (`ubuntu`, `docker`) and BuildKit's own image | Docker Hub | the Docker **daemon**: Docker Desktop, Settings, Resources, Proxies; Docker Engine: `/etc/docker/daemon.json` (`"proxies"`) or a systemd drop-in ([Docker's guide](https://docs.docker.com/engine/daemon/proxy/)) |
| The helper container: IBKR's `version.json` and installer | `download2.interactivebrokers.com` | the Docker **CLI**'s `config.json`, key `proxies` |
| The image build: Ubuntu packages, IBC from GitHub | `archive.ubuntu.com`, `github.com` | the same `config.json`: the CLI passes it to every build as `HTTP_PROXY`, `HTTPS_PROXY` and `NO_PROXY` (both cases) |

So put the proxy into `~/.docker/config.json` (`%USERPROFILE%\.docker\config.json` on
Windows), next to the keys already there:

```json
{
  "proxies": {
    "default": {
      "httpProxy": "http://proxy.example.com:3128",
      "httpsProxy": "http://proxy.example.com:3128",
      "noProxy": "localhost,127.0.0.1"
    }
  }
}
```

and the same proxy into the daemon's settings. **`HTTPS_PROXY` set in your shell does not
reach the build**: the script does not pass it into the helper container (checked: with
`HTTPS_PROXY` pointing at a closed port the helper still reached IBKR directly).

Checked on 2026-11-17 with a local Squid proxy standing in for a corporate one: with
`proxies` in `config.json`, `scripts/build-image.sh --print-plan` reached IBKR through it (the
proxy logged `CONNECT download2.interactivebrokers.com:443`), and a `RUN` step of a build saw
`HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` and their lower-case forms and fetched through the
proxy. **Not tested**: a real corporate proxy, a proxy that needs authentication, the daemon's
proxy for pulls, and a proxy that inspects TLS with its own certificate authority: neither the
helper container nor the build can be given an extra CA certificate, so such a proxy makes the
download fail ([limitations](docs/limitations.md) L38).

### Offline, or when IBKR has moved on

**The cache.** Every installer a successful build used is kept in the installer cache, by
version and architecture, with its SHA-256 (`installers/<version>/<arch>/` holds the file and a
`meta` file). When IBKR cannot be reached, the script builds the pinned version from the cache;
without `--strict` it falls back to the newest cached version of the channel; with nothing
cached it exits 3. A version you built once therefore builds again after IBKR has moved on, as
long as you keep the cache. With IBKR unreachable the build says so before it starts:

```text
resolve-installer: IBKR is unreachable (https://download2.interactivebrokers.com/installers/ibgateway/stable-standalone/version.json); building the cached 10.50.1h, accepted 2026-11-17T03:51:49Z
```

and the last lines then say `qualified_by_project` as for any build of that version. Only IBKR
may be missing: the image build itself still needs Docker Hub (the Ubuntu base image), Ubuntu's
package archive and GitHub (IBC), unless Docker's build cache already holds those steps from an
earlier build. Look at the cache:

```bash
cat ~/.cache/brokersre-ib-gateway/installers/10.50.1h/x64/meta
```

```text
version: 10.50.1h
channel: stable
arch: x64
sha256: eb578b23b636e19c8417fc969264853a22792bcffa8fc79990cf15ff032fe7aa
ibkr_build_stamp: (.1h) 20261116 16:02:08
source: ibkr
accepted_at: 2026-11-17T03:51:49Z
```

**An installer you downloaded yourself.** IBKR offers the installers on its website: the
[IB Gateway download page](https://www.interactivebrokers.com/en/trading/ibgateway-latest.php)
has the tabs *Latest* and *Stable*, each with *Linux (X86_64)* and *Linux (ARM64)* (read
through a search engine on 2026-11-17; the page refused an automated fetch, so where its
buttons point was not checked). The Linux files are named
`ibgateway-<stable|latest>-standalone-linux-<x64|arm>.sh`, and IBKR's download server serves
them at the address the script uses, which you can also fetch by hand:

```bash
curl -fLO https://download2.interactivebrokers.com/installers/ibgateway/stable-standalone/ibgateway-stable-standalone-linux-x64.sh
scripts/build-image.sh --installer ibgateway-stable-standalone-linux-x64.sh
```

`--installer FILE` (`-Installer`) asks IBKR nothing: the version, the channel and the
architecture come from the installer's own build stamp, its SHA-256 is recorded, and the image
is `qualified_by_project: yes` only when both equal the pin. Use it on a machine without
access to IBKR (copy the file over), or to rebuild exactly the bytes you kept. An installer for
the other architecture, or one whose stamp cannot be read, is refused (exit 1).

### Pinning and reproducing a build

What a build used is written down in three places:

- **The image's labels**: `com.rocketedge.brokersre.ibkr.version`, `.ibkr.channel`,
  `.ibkr.build_stamp`, `.installer.sha256`, `.qualified`, `.ibc.version`, `.ibc.release`.
- **[versions.json](versions.json)** of the commit you built from: the Ubuntu base image by
  digest, IBC by release and SHA-256, and the pinned Gateway versions with their SHA-256 and
  build stamps. The helper image is pinned by digest in `scripts/build-helper/Dockerfile`.
- **The installer cache**: the installer's bytes, by version.

To build the same Gateway again, check out the same commit and build with the same cache
(or `--installer` with the kept file). Two things are not frozen: Ubuntu packages are
installed and upgraded at build time (so a later build has later security fixes), and the
helper's Alpine packages come from Alpine's index at its first build
([limitations](docs/limitations.md) L36). A rebuild therefore has the same IB Gateway and IBC,
not the same image id. To run exactly one image, name it by its id, by a tag you do not
rebuild, or by its digest in your registry.

### Pushing to your own private registry

To run the image on another machine, push it to a registry **only you can read**. A public
repository would publish IBKR's software. In every case: log in, tag, push, and keep the
version tag next to the channel tag.

Run on 2026-11-17 against a throwaway local registry (`registry:2` on `localhost:5000`), as the
pattern for every registry below:

```bash
docker run -d --name local-registry -p 127.0.0.1:5000:5000 registry:2
docker tag brokersre-ib-gateway:stable localhost:5000/brokersre-ib-gateway:10.50.1h
docker push localhost:5000/brokersre-ib-gateway:10.50.1h
docker image inspect localhost:5000/brokersre-ib-gateway:10.50.1h --format '{{index .RepoDigests 0}}'
```

The last line prints `localhost:5000/brokersre-ib-gateway@sha256:<digest>`: that is the
reference to pin (`IBGW_IMAGE=...@sha256:<digest>`). The other registries were **not tested**;
the commands are their documented ones:

- **GitHub Container Registry (private package).** A token with `write:packages`
  (a classic personal access token), then:

  ```bash
  echo "$GHCR_TOKEN" | docker login ghcr.io -u <github-user> --password-stdin
  docker tag brokersre-ib-gateway:stable ghcr.io/<owner>/brokersre-ib-gateway:10.50.1h
  docker push ghcr.io/<owner>/brokersre-ib-gateway:10.50.1h
  ```

  GitHub documents a newly published package as private; check it on the package's page
  under *Package settings*, *Danger Zone*, and keep it private.

- **Azure Container Registry** (the Azure CLI, logged in):

  ```bash
  az acr create --resource-group <group> --name <registry> --sku Basic
  az acr login --name <registry>
  docker tag brokersre-ib-gateway:stable <registry>.azurecr.io/brokersre-ib-gateway:10.50.1h
  docker push <registry>.azurecr.io/brokersre-ib-gateway:10.50.1h
  ```

  Leave anonymous pull off (the default). ACR Tasks (`az acr build`) were not tested: the
  build needs the helper container next to it, so build locally and push.

- **Amazon ECR** (the AWS CLI, logged in):

  ```bash
  aws ecr create-repository --repository-name brokersre-ib-gateway --region <region>
  aws ecr get-login-password --region <region> | docker login --username AWS --password-stdin <account>.dkr.ecr.<region>.amazonaws.com
  docker tag brokersre-ib-gateway:stable <account>.dkr.ecr.<region>.amazonaws.com/brokersre-ib-gateway:10.50.1h
  docker push <account>.dkr.ecr.<region>.amazonaws.com/brokersre-ib-gateway:10.50.1h
  ```

- **Docker Hub, private repository**: create the repository as *Private* on Docker Hub first
  (a push to a name that does not exist creates it with your namespace's default repository
  privacy, which may be public), then:

  ```bash
  docker login -u <docker-hub-user>
  docker tag brokersre-ib-gateway:stable <docker-hub-user>/brokersre-ib-gateway:10.50.1h
  docker push <docker-hub-user>/brokersre-ib-gateway:10.50.1h
  ```

On the machine that runs it, the compose files of this repository never pull the gateway
image on their own (`pull_policy: never`); pull yours on purpose, after `docker login`:

```bash
IBGW_IMAGE=localhost:5000/brokersre-ib-gateway@sha256:<digest> docker compose -f compose/docker-compose.example.yml pull --policy missing
```

### Building in your own CI

A minimal GitHub Actions workflow for a **private** copy of this repository: it builds with the
build helper and pushes to that account's GitHub Container Registry. Run it in a private
repository, and after the first run check that the package is private (its page, *Package
settings*): a package that a workflow publishes is linked to the repository the workflow runs
in. The build runs on GitHub's Ubuntu runner, which has Docker and buildx; nothing is
cached between runs, so every run downloads the installer from IBKR. Linted with actionlint
1.7.12 (which runs shellcheck on the `run:` scripts), no finding; it has **not run** on GitHub.

```yaml
# .github/workflows/build-gateway-image.yml
name: Build gateway image
on:
  workflow_dispatch:
  schedule:
    - cron: "30 7 * * 1"   # Mondays 07:30 UTC
permissions:
  contents: read
  packages: write          # push to this account's GitHub Container Registry
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - name: Build with the build helper (the result lines go to build.txt)
        run: scripts/build-image.sh --channel stable --platform linux/amd64 > build.txt
      - name: Push to the private package
        env:
          GHCR_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          cat build.txt
          version="$(sed -n 's/^version: //p' build.txt)"
          image="ghcr.io/${GITHUB_REPOSITORY_OWNER,,}/brokersre-ib-gateway"
          echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin
          docker tag brokersre-ib-gateway:stable "$image:$version"
          docker push "$image:$version"
```

Add `--strict` to the build to push only versions the project has qualified (the run then
fails with exit 4 while IBKR serves another one), or keep `qualified_by_project` from
`build.txt` and qualify the version with a paper login before you deploy it. For arm64, run
the same job with `--platform linux/arm64` on an arm64 runner (not tested).

### Upgrading and rolling back

An upgrade is a rebuild. Before it, give the image you run a name the build will not move:

```bash
docker tag brokersre-ib-gateway:stable brokersre-ib-gateway:previous
scripts/build-image.sh
```

The new build moves `brokersre-ib-gateway:stable` and adds `brokersre-ib-gateway:<version>`;
`:previous` and the old version tag stay. Start the new one (the gateway logs in again; have
the phone ready for the second factor):

```bash
docker compose -f compose/docker-compose.example.yml up -d
```

To roll back, start the old image by name:

```bash
IBGW_IMAGE=brokersre-ib-gateway:previous docker compose -f compose/docker-compose.example.yml up -d
```

`docker image ls brokersre-ib-gateway` lists what you have. With a registry, push each version
and roll back by pinning the earlier digest. A rebuild of the same version (for Ubuntu's
security fixes) is a new image under the same version tag: tag the old one first if you want
to keep it. [Is a newer IB Gateway available?](#is-a-newer-ib-gateway-available) says when a
rebuild brings a new Gateway.

### Troubleshooting the build

| You see | Exit | Cause | Fix |
|---|---|---|---|
| `SHA-256 MISMATCH: IBKR's stable channel says 10.50.1g, the pinned version, but the installer differs` | 1 | IBKR replaced the installer of the pinned version without a new version label | Nothing was built. Build from your cache or with `--installer`, or wait for a pin update; report it in an issue |
| `the downloaded installer is not the build IBKR announced` | 1 | The installer's stamp differs from IBKR's `version.json` | Run again later; if it repeats, report it |
| `IBKR's stable channel changed during the download again` | 1 | IBKR published a build while the script downloaded, twice | Run again |
| `the image build failed; nothing was cached` or `the IBC smoke test failed` | 1 | Docker's build or the offline IBC test failed; the lines above say which step | Read the lines above; see the rows below for disk and network |
| `build-image: ... needs a value`, `unknown option` | 2 | A typing error | `scripts/build-image.sh --help` |
| `IBKR is unreachable (...version.json), and no installer of the stable channel (x64) is in the cache` | 3 | No connection to IBKR and nothing cached | Check the connection or the [proxy](#behind-a-corporate-proxy); or build with `--installer` |
| `--strict: IBKR's stable channel serves 10.50.1h; versions.json pins 10.50.1g` | 4 | `--strict` and IBKR moved on | Build without `--strict` and qualify the image, or use the cache |
| `failed to connect to the docker API at npipe:////./pipe/dockerDesktopLinuxEngine; check if the path is correct and if the daemon is running` (Windows), `Cannot connect to the Docker daemon` (Linux, macOS) | 1 | Docker Desktop is not running (Linux: the daemon is stopped, or your user may not use it) | Start Docker Desktop and wait until it says the engine is running; Linux: `sudo systemctl start docker`, and add your user to the `docker` group |
| PowerShell, below Docker's line above: `the Docker host's architecture '' is not supported; pass -Platform` | 1 | The same: the script could not ask the daemon for its architecture | Start Docker Desktop (passing `-Platform` does not help) |
| `docker buildx is required` | 1 | Docker without the buildx plugin (an old Docker Engine) | Install `docker-buildx-plugin` from Docker's repository, or Docker Desktop |
| `no space left on device` in the build output | 1 | The Docker disk is full (Docker Desktop: its virtual disk) | `docker builder prune`, `docker image prune`; Docker Desktop: Settings, Resources, Disk usage limit |
| `$'\r': command not found` or `/usr/bin/env: 'bash\r'` | 1 | The scripts have Windows line endings: the files were copied or edited with a tool that wrote CRLF (a clone keeps LF, `.gitattributes` says so) | Clone again with git; do not convert the files |
| A path such as `C:/Program Files/Git/cache` in an error, from a `docker run` you typed in Git Bash | | Git Bash rewrote a container path | Put `MSYS_NO_PATHCONV=1` in front of the command, or write the path with `//` (`//var/log/...`); the build script does this itself |
| `cannot read a build stamp from ...: not an install4j IB Gateway installer` | 1 | `--installer` names a file that is not IBKR's Linux installer (for example the Windows or macOS one, or an HTML error page) | Download `ibgateway-<channel>-standalone-linux-<x64 or arm>.sh` |

## Quick start

You need Docker with Linux containers (Docker Desktop on Windows or macOS, Docker Engine on
Linux), a clone of this repository, and an IBKR username used by nothing else: IBKR allows one
session per username. The example starts in **paper** mode with the read-only API.

### 0. Build the image

From the repository folder, in bash, zsh, Git Bash or WSL:

```bash
scripts/build-image.sh
```

or in PowerShell: `pwsh -NoProfile -File scripts/build-image.ps1` (Windows PowerShell 5.1:
`powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-image.ps1`).

You should see, after a few minutes, `ALL CONTAINER TESTS PASSED` and seven last lines ending
with `image: brokersre-ib-gateway:stable`; the compose files use that name. If a line reads
`qualified_by_project: no`, IBKR serves a newer Gateway than the project has qualified:
[what that means](#what-the-last-lines-mean). Everything about the build, from prerequisites to
proxies, is in [Build the image](#build-the-image).

### 1. Store the two secrets as files

The secret files live in `compose/secrets/` (ignored by git). Write them as UTF-8 **without** a
byte-order mark. On Windows do not use `>` or `echo`: Windows PowerShell 5.1 writes UTF-16 that
way, and the gateway refuses such a file (`secret_unreadable`) rather than send IBKR a wrong
password.

Windows (PowerShell 5.1 or 7), from the repository folder:

```powershell
New-Item -ItemType Directory -Force compose\secrets | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText("$PWD\compose\secrets\ib-username", (Read-Host 'IBKR username'), $utf8)
$secure = Read-Host 'IBKR password' -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try { [IO.File]::WriteAllText("$PWD\compose\secrets\ib-password", [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr), $utf8) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
```

Linux, macOS, WSL or Git Bash (bash, zsh or sh):

<!-- tested by tests/bats/ci/doc-commands.bats -->

```sh
(
  trap 'stty echo; exit 130' INT
  mkdir -p compose/secrets
  printf 'IBKR username: '; IFS= read -r u; printf '%s' "$u" > compose/secrets/ib-username
  printf 'IBKR password: '; stty -echo; IFS= read -r p; stty echo; echo
  printf '%s' "$p" > compose/secrets/ib-password
)
```

You should see two files, `compose/secrets/ib-username` and `compose/secrets/ib-password`, and
the password never appeared on screen. The files hold exactly what you typed, blanks at either
end and backslashes included. The parentheses make the shell read the whole block before it
asks anything, so it also works when pasted into a shell without bracketed paste; Ctrl-C at a
prompt stops it, turns echo back on and writes no password file.

### 2. Start the gateway

```bash
docker compose -f compose/docker-compose.example.yml up -d
docker compose -f compose/docker-compose.example.yml logs -f
```

You should see JSON events with `ibc_starting`, `ibc_version` and `login_dialog`, then
`login_completed` and `relay_opened` once IBKR has accepted the login (in the paper logins of
2026-11-15/16, none of which asked for a second factor, `login_completed` came 8.2 to 11.4 s
after the event `container_start`). If IBKR asks for a second factor, the event
`twofa_initiated` appears (`twofa_dialog` may not: according to IBC's source, Gateway 10.16
and later logs only the first, [log contract](docs/log-contract.md)): approve the prompt in
IBKR Mobile.
The image never answers a second factor for you. Stop following the log with Ctrl+C.

The compose file runs `brokersre-ib-gateway:stable`, the image of step 0, and never pulls an
image: without step 0, `up` stops with `No such image: brokersre-ib-gateway:stable`.
`IBGW_IMAGE` names another image, for example the version tag the build printed.

### 3. Check that it is logged in

```bash
docker compose -f compose/docker-compose.example.yml exec ib-gateway cat //var/log/ibgateway/state/phase
docker compose -f compose/docker-compose.example.yml ps
```

You should see `logged-in`, and `(healthy)` in the status column. The API is then reachable on
`127.0.0.1:4002` (paper) or `127.0.0.1:4001` (live). While the phase is `login` or
`2fa-pending` the container reports `unhealthy` on purpose.

The two slashes in `//var/log/...` are on purpose: Git Bash on Windows rewrites an argument
that starts with a single `/` into a Windows path (`C:/Program Files/Git/var/...`) and the
command fails, while Linux reads `//var` as `/var`. The line works unchanged in bash, zsh,
Git Bash and PowerShell.

### 4. If it does not log in

| You see | Cause | Fix |
|---|---|---|
| `No such image: brokersre-ib-gateway:stable` from `docker compose up` | The image was not built on this host | [Step 0](#0-build-the-image) |
| event `doctor_failed` naming `credentials`, and the container stops | A secret file is missing, empty or UTF-16 | Write it again with the commands in step 1 |
| event `doctor_failed` naming another check, and the container stops | The preflight found a setting the gateway cannot run with; the message says which and how to fix it | Fix the setting. `docker compose ... run --rm ib-gateway doctor` shows every check |
| event `login_failed_dialog`, phase `needs-human` | IBKR rejected the username or password | Correct the files, then `docker compose ... up -d --force-recreate`. The gateway does not retry on its own, so it cannot lock the account |
| event `login_rejected_latched` right after a start, phase `needs-human`, no login | IBKR rejected these credentials at an earlier start and the secret files are unchanged; the gateway does not send them again (the latch, [ADR 0016](docs/adr/0016-rejected-login-latch.md)) | Write the correct username and password into the secret files and start again: a rewritten file releases the latch. `doctor` shows the same and when IBKR refused |
| event `unknown_window` or `login_stalled`, phase stays `login` | The Gateway shows a window that IBC does not handle and that stays open | Look at `ibc/ibc.log` on the log volume for the window title, or at the screen through the [break-glass console](docs/console.md); report it. To see the window afterwards, start with `SCREENSHOTS=yes`: the next time it happens a picture of the screen is saved to `screens/` on the log volume (XWD format, opens in GIMP or ImageMagick). It is off by default because the screen can show your username |
| in paper mode: event `unknown_window` some ten seconds after `login_dialog` (the dialog has then stayed open for `UNKNOWN_WINDOW_GRACE_S`), the phase stays `login`, and `ibc/ibc.log` names a dialog `Paper Account Notice` | Seen on 2026-11-13 with one account: IBKR had accepted the credentials, but the account had no paper trading access, and the dialog said "This account does not have paper trading access enabled". The title alone does not prove it: confirm the text with a screenshot (`SCREENSHOTS=yes`) | Request the paper trading account at IBKR ([Request a Paper Trading Account](https://www.ibkrguides.com/clientportal/request-paper-trading.htm)): a first request starts on the Account Status home page of Client Portal ("Try Our Platforms with a Simulated Account"); a secondary user, and an account whose paper account was closed for inactivity, asks under User menu, Settings, Account Configuration, Paper Trading Account and gets separate paper credentials. IBKR's page says that "under normal business circumstances" paper accounts are created within 24 hours, and only for a funded account. Then start the gateway again |
| event `existing_session` | The username is logged in somewhere else | Close the other session, or use a dedicated username |
| event `dirs_not_writable` | A tmpfs or volume is not writable by uid 1000. On a first start with a sidecar: the log volume took the sidecar image's owner (sidecar up to 0.2.0 mounted without `nocopy`) | Keep the `uid=1000,gid=1000` mount options of the example. For the log volume: mount it in the sidecar as [the sidecar override](compose/docker-compose.sidecar.yml) does or use sidecar 0.2.1 or later, then create the gateway container again: `docker compose ... down` (the volumes stay) and `up -d`, or `up -d --force-recreate`. `up -d` alone re-creates only the sidecar and leaves the volume root-owned |
| a client gets "connection refused" on 4001/4002 | The Gateway is not logged in yet, or is restarting: the relay opens only while it is logged in | Retry; check the phase |

## Running on Windows

`windows/` holds a host kit for Windows 10 22H2 and Windows 11 (Docker Desktop with the WSL 2
backend, or Docker Engine inside a WSL 2 distribution). `setup.ps1` checks the computer, stores
the credentials as two protected files, builds the image with `scripts/build-image.ps1` when it
is not on the computer yet, starts the gateway and tells you when to approve the login on your
phone. `doctor.ps1` reports what can interrupt the gateway (sleep, Windows Update,
WSL idle shutdown, clock drift, folder permissions). `harden.ps1` applies the fixes and can undo
them. The kit never automates the second factor, never restarts a running gateway on its own,
and stops the gateway when IBKR rejected the login. It was tested with mocked Docker and with
read-only runs on one Windows 11 computer; no gateway was started with it yet, and
[windows/README.md](windows/README.md) lists what you should validate on your computer. See
also [ADR 0011](docs/adr/0011-windows-host-kit.md).

## Going live

Paper first. Before the same setup holds a live session, check each line:

- [ ] **A username of its own.** IBKR allows one session per username: a login with the same
      username in IBKR Mobile, Client Portal or TWS ends the gateway's session. Use a second
      username for people.
- [ ] **The image cannot move under you** and you [verified it](#verifying-what-you-built):
      `IBGW_IMAGE` names the version tag you built and do not rebuild, or the digest of your
      copy in your own private registry (`IBGW_IMAGE=<registry>/brokersre-ib-gateway@sha256:...`).
      The channel tag moves with every build.
- [ ] **The Gateway in it was qualified**: `qualified_by_project: yes`, or one paper login of
      your own with that image ([qualifying](#qualifying-an-image-with-a-real-paper-login)).
- [ ] **`TRADING_MODE=live`**, and `READ_ONLY_API=no` only if the strategy places orders.
- [ ] **A daily restart time** (`AUTO_RESTART_TIME`, two-digit hour) outside IBKR's reset
      windows for your region; `doctor` checks the form and, for three time-zone families,
      the window.
- [ ] **The relay is published on a private address** (`PRIVATE_IP`), never on a public one.
      Every client that reaches the relay is trusted by the Gateway.
- [ ] **The preflight is clean:**
      `docker compose -f compose/docker-compose.example.yml run --rm ib-gateway doctor`.
- [ ] **The log volume is persistent** (a named volume, as in the example). It holds the
      record that IBKR rejected a login, which is what stops a restart policy or a reboot from
      sending a wrong password again and again until the account is locked.
- [ ] **Someone is told when a person is needed.** The image records `2fa-pending`,
      `needs-human` and `unknown_window` as events and phases; it does not notify anybody by
      itself. Read `events/events.jsonl` with your own tooling, or run the
      [optional sidecar](#optional-sidecar-api-probe-status-endpoints-alerts), which turns them
      into messages. Give it a dead-man ping too, or nobody is told when the host itself dies.
- [ ] **The host stays up**: no sleep, no unattended reboot during trading hours, Docker
      starts at boot, the clock is synchronised.
- [ ] **You have stopped and started it once on purpose** (`docker compose ... down`, then
      `up -d`) and watched the phases, so the first real restart is not a surprise.
- [ ] **You know what is not covered**: [docs/limitations.md](docs/limitations.md).

## The weekly login

IBKR asks for a full login with the second factor about once a week; the daily restart in
between does not ask again. IBKR's guide to the automatic restart says: "This procedure will
require manual authentication once a week" and "This security process occurs each Sunday at
1:00 am ET"
([Auto Restart Considerations](https://www.ibkrguides.com/traderworkstation/auto-restart-considerations.htm),
read on 2026-11-17). The sources do not name the same day: IBKR's page for third-party
integrations says "the weekly authentication cycle starts on every Monday"
([Daily & Weekly Reauthentication](https://www.interactivebrokers.com/docs/third-party-integrations/tws-settings/daily-weekly-reauthentication)),
and IBC's user guide says authentication is required "the first time during the week that
TWS or Gateway run after 01:00 ET on Sunday". Either way, once a week a person must approve a
prompt. The image behaves the same whichever day it comes, and no setting of this image
changes that: the image never answers, types or bypasses a second factor.

What happens: the phase becomes `2fa-pending` and the event `twofa_initiated` appears, with
`twofa_dialog` only where the Gateway opens a separate dialog (according to IBC's source,
Gateway 10.16 and later does not); both are recognised from the text IBC's code logs, not yet
seen in a real session of this image ([limitations](docs/limitations.md) L09). Approve the prompt in IBKR
Mobile. A prompt that is not answered
expires after about three minutes; with the defaults IBC then logs in again and asks again,
without limit. Each time the phase passes through `login` for a few seconds (event
`twofa_timeout`) before it is `2fa-pending` again, so anything that watches for a waiting
person must look at the events ("a prompt without a completed login since"), not at how long
one phase value has lasted. `TWOFA_MAX_PROMPTS` sets a limit,
after which the gateway stops asking and waits in phase `needs-human` until someone restarts
the container.

Plan it: decide who approves the prompt and when, and make sure that person learns that it is
waiting.

What IBKR has published about passkeys and IB Gateway, and what is not established:
[docs/passkeys.md](docs/passkeys.md).

## Several gateways on one host

IBKR allows one session per username and this image runs one session per container, so "live
and paper together" or "one gateway per desk" means several services.
[compose/docker-compose.multi.yml](compose/docker-compose.multi.yml) runs a `live` gateway
(host port 4001) and a `paper` gateway (4002) side by side, each with its own secrets, volumes
and instance label, and carries a commented block for further usernames and a cold standby:

```bash
scripts/check-compose-usernames.sh compose/secrets   # two gateways must never share a username
docker compose -f compose/docker-compose.multi.yml --profile live --profile paper up -d
```

Secrets layout, ports and the pattern for more usernames: [compose/README.md](compose/README.md).

## Connecting a strategy

The API relay listens only while the gateway is logged in, so "connection refused" means "not
ready yet": retry. [examples/README.md](examples/README.md) states the readiness rules in plain
words (wait for healthy, stop sending on IBKR code 1100, continue on 1102, re-subscribe on 1101,
expect the daily restart) and ships read-only samples that follow them: `wait-for-gateway.sh`,
a compose file with the strategy on a private network, and a Python and a C# client.
`wait-for-gateway.sh` and the Python client ran against a logged-in paper Gateway
(2026-11-15/16 UTC). The C# client and the compose file with the strategy did too on
2026-11-16 UTC, with IB Gateway 10.50.1g in the published stable image `7773ff7`: the C#
client, compiled against a `CSharpAPI.dll` built locally from IBKR's TWS API 10.48.01
source, logged `connected to 127.0.0.1:4002, client id 101` and then IBKR's server time
every 30 s (08:18:58 to 08:20:09 UTC); with the compose file the gateway was healthy after
12 s, then the strategy logged `ready: ib-gateway:4004 answered the API handshake (server
version 178) after 0 s`.

## Environment variables

Full reference with defaults and rationale: [docs/env-vars.md](docs/env-vars.md).

| Variable | Default | Meaning |
|---|---|---|
| `TWS_USERID_FILE`, `TWS_PASSWORD_FILE` | required | Files holding the IBKR credentials (Docker secrets). `TWS_USERID`/`TWS_PASSWORD` also work but keep secrets in the process table. |
| `TRADING_MODE` | `paper` | `live` or `paper`. One brokerage session per container; `both` is not supported. |
| `READ_ONLY_API` | `yes` | Read-Only API in IBC. Set `no` only for a host that must place orders. |
| `AUTO_RESTART_TIME` | empty | IBC `AutoRestartTime` in the Gateway's time zone, with a two-digit hour, e.g. `11:45 PM` or `01:05 AM`; keep it outside the IBKR reset windows. A value IBC would not apply stops the start. |
| `TIME_ZONE` | `Etc/UTC` | IANA zone written to `jts.ini` on first start. |
| `TWOFA_TIMEOUT_ACTION` / `RELOGIN_AFTER_TWOFA_TIMEOUT` / `TWOFA_EXIT_INTERVAL` | `restart` / `yes` / `60` | 2FA retry behaviour: re-prompt instead of giving up. |
| `TWOFA_MAX_PROMPTS` | `0` (no limit) | After this many unanswered second-factor prompts the gateway stops asking and waits for a person (phase `needs-human`). It never answers a prompt itself. |
| `LOGIN_LATCH` | `on` | After IBKR rejects the credentials, later starts with the same secret files do not log in again until a file is rewritten. `clear` removes the record once (for credentials passed as variables); `off` disables it. |
| `SCREENSHOTS` | `no` | `yes`: save a picture of the Gateway's screen to the log volume when an unknown window stays open or the login stalls. The picture can show the username. |
| `RELAY_MODE` | `gated` | `gated`: the relay on 4003/4004 listens only while the Gateway is logged in. `always`: it listens from container start. |
| `JAVA_HEAP_MB` | unset (768) | Gateway heap in megabytes, set at run time; `auto` takes half of the container memory limit (768 to 4096). |
| `DOCTOR_STRICT` | `yes` | `no` lets the container start although a preflight check failed (see `doctor` below). |
| `EXISTING_SESSION_DETECTED_ACTION` | `primary` | IBC action when another session of the same username appears. |
| `TWS_ACCEPT_INCOMING` | `reject` | IBC `AcceptIncomingConnectionAction`: API clients must be trusted. |
| `IBC_COMMAND_SERVER_PORT` | `7462` | IBC command server on `127.0.0.1`; `0` disables it. |
| `VNC_SERVER_PASSWORD_FILE` | unset | Enables the break-glass console: x11vnc on `127.0.0.1:5900` inside the container ([docs/console.md](docs/console.md)). |
| `VNC_VIEW_ONLY` | `yes` | The console is view-only; `no` lets a person click and type. Any other value stops the start. |
| `CUSTOM_CONFIG` | `no` | `yes` to supply your own `/run/brokersre/config.ini` instead of rendering one. |
| `IBC_LAUNCH` | `yes` | `no` starts everything except IBC (used by the offline tests). |

## Ports, volumes and the sidecar contract

- IB Gateway listens on **loopback only** (`4001` live / `4002` paper, `TrustedIPs=127.0.0.1`).
  `socat` relays that port to the container interface on **4003 / 4004**; publish the relay
  bound to a private address your strategy host can reach, never to the public internet.
- The relay **follows the login**: it listens only while the Gateway is logged in. Before the
  login and during the daily restart a client gets "connection refused" and should simply
  retry; it is never accepted and then dropped. `RELAY_MODE=always` restores a relay that
  listens from container start.
- The API has **no authentication**: whoever reaches the relay can use the account as far as
  `READ_ONLY_API` allows. The port binding and the host firewall decide who that is. When the
  strategy runs in a container on the same Docker network, `RELAY_ALLOW_CIDR` (one IPv4
  network) adds a second line: the relay closes every other peer and reports it. It cannot
  tell clients apart that arrive through a published port, because Docker can present those
  with its bridge address ([env-vars](docs/env-vars.md)).
- The IBC **command server** (`STOP`, `RESTART`, `RECONNECTDATA`, `RECONNECTACCOUNT`, ...) is on
  `127.0.0.1:7462`. A sidecar can use it only by sharing this container's network namespace
  (`network_mode: "service:ib-gateway"`), which is how the BrokerSRE agent does it. `ibc-cmd STOP`
  inside the container does the same.
- Volumes: `/home/ibgateway/Jts/settings` (Gateway settings, persist it) and
  `/var/log/ibgateway` (shared log volume; mount it read-only into a sidecar).

## Health, phases and logs

`HEALTHCHECK` is healthy only when the IBC/Gateway process is alive **and** the API port accepts a
connection; a pending 2FA is therefore honestly unhealthy, and nothing restarts the container on
unhealthy. The finer lifecycle lives in `/var/log/ibgateway/state/phase`:

| Phase | What it means | What to do |
|---|---|---|
| `starting`, `login` | starting up, logging in | wait |
| `2fa-pending` | IBKR waits for a second factor | approve it in IBKR Mobile |
| `logged-in` | login completed, API available | nothing |
| `restarting` | the daily restart | wait; clients retry |
| `existing-session` | the username is logged in elsewhere | close the other session |
| `needs-human` | nothing will change until a person acts (IBKR rejected the login, now or at an earlier start with the same secret files, or the second factor was not approved after `TWOFA_MAX_PROMPTS` prompts) | fix the cause, then restart the container |
| `stopping`, `stopped`, `exited`, `test-mode` | shutting down, stopped, IBC ended, offline test | |

**Events.** Every event is one JSON object on one line (`ts`, `src`, `level`, `event`, `msg`,
`boot_id`, `seq`; schema in [schemas/log-event.v2.schema.json](schemas/log-event.v2.schema.json)).
It goes to stdout and, as the identical line, to `/var/log/ibgateway/events/events.jsonl`, so a
sidecar that mounts only the log volume sees what `docker logs` shows. `seq` counts the events
of one container start without gaps: a reader can tell that it lost nothing. Raw IBC output
goes to `/var/log/ibgateway/ibc/ibc.log` and the Gateway's `launcher.log` is mirrored under
`/var/log/ibgateway/jts/` (its log after the login is encrypted by IBKR and stays in the
settings directory, [limitations](docs/limitations.md) L03), so a dialog that echoes a
username can never leak through an event.

**Resources.** `/var/log/ibgateway/metrics/metrics.jsonl` gets one sample every 30 s from the
container's own cgroup and `/proc` (memory, CPU, processes, the Gateway JVM, open files, disk).
The events `oom_kill`, `memory_high`, `disk_low` and `login_stalled` are derived from it.

**Preflight.** `docker compose -f compose/docker-compose.example.yml run --rm ib-gateway doctor`
checks the configuration without starting the gateway (secret files and their encoding, the
restart time, variables the image ignores, heap against the memory limit, disk space) and names
the fix for each problem; `--json` prints one document. The same checks run at every start: a
failed check stops the container before any login is attempted.

All log files on the volume are size-capped and rotated (`LOG_MAX_BYTES`, `LOG_KEEP`). The
contract is specified in [docs/log-contract.md](docs/log-contract.md).

## Break-glass console

When the Gateway is stuck behind a window that IBC does not handle, a person can look at its
screen: x11vnc inside the container, off by default, on the container's own loopback address,
**view-only** unless `VNC_VIEW_ONLY=no`. Every visit is an event (`vnc_client_connected`,
`vnc_client_disconnected`). Nothing in the image ever clicks or types, and nothing answers a
second factor.

```bash
docker compose -f compose/docker-compose.example.yml -f compose/docker-compose.console.yml up -d
```

Switching it on recreates the container, so the Gateway logs in again; so does the change
from view-only to input. The route from a VNC viewer to the console (a bridge you open and
close, an SSH tunnel), what a person may do there, and why no web console is shipped:
[docs/console.md](docs/console.md). It was tested offline with the image's real x11vnc and a
stand-in viewer, not during a real login.

## Shipping events to your own log system

`events/events.jsonl` and `metrics/metrics.jsonl` on the log volume are meant to be shipped;
the raw IBC and Gateway logs are not (they can hold the username).
[docs/recipes/](docs/recipes/README.md) has Vector configurations for Grafana Loki, an
OpenTelemetry collector and Datadog, with a compose file that runs the shipper as a non-root
user with the log volume read-only. They were validated offline against stand-in receivers,
not against the real services.

## Optional sidecar: API probe, status endpoints, alerts

[`sidecar/`](sidecar/README.md) is a separate, optional image. It runs next to the gateway in its
own container, reads the gateway's log volume read-only, probes the API through the relay port,
serves `/livez`, `/readyz`, `/status` and `/metrics` on port 9810, and notifies people (Teams,
Slack, Telegram, ntfy, PagerDuty, e-mail, webhook) when a person is needed: a pending second
factor, a rejected login, a gateway that stopped. It alerts and never acts: no orders, no
automated second factor, no restart of the gateway.

```bash
docker compose -f compose/docker-compose.example.yml -f compose/docker-compose.sidecar.yml up -d
```

Configure its dead-man ping as well: without one, nobody is told when the host itself dies.
Every alert links a one-page runbook ([docs/runbooks](docs/runbooks/README.md)): what it
means, what to check first, what to do and what not to do.
The sidecar is tested against the real gateway image with IBC not launched and against
stand-in API servers, and it ran against a logged-in paper Gateway in the sessions of
2026-11-15/16 UTC; [limitations](docs/limitations.md) L20 lists what those sessions left
unproven.

## Shipping to Azure Log Analytics

[`azure/`](azure/README.md) ships the gateway's events and resource samples (and, only when you
opt in, its raw logs with the username and account ids redacted) to **your own** Log Analytics
workspace. It is a Bicep template (tables, a data collection rule, three alert rules, a
workbook, a query pack) and a compose profile that runs a pinned Vector container next to the
gateway, reading the log volume read-only. The shipper authenticates with a managed identity or
a certificate, and its only permission is to publish to that one data collection rule. A second,
optional template starts the gateway on an Azure VM.

```bash
docker compose -f compose/docker-compose.example.yml -f compose/docker-compose.azure.yml --profile azure up -d
```

Every gateway needs its own `IBGW_INSTANCE` label: the alert rules tell gateways apart by it.
The pack is tested offline (the templates compile, the shipper runs on lines of a real gateway
run, the queries are type-checked against the schema). Nothing has been deployed to Azure yet,
so ingestion, authentication and the alert rules are unproven until you deploy;
[azure/README.md](azure/README.md) lists exactly what is and is not established.

## Security posture

No `sudo`, no SSH or telnet client; runs as uid 1000; works with `read_only: true` (tmpfs on
`/tmp` and `/run/brokersre` mounted with `uid=1000,gid=1000`, see [docs/env-vars.md](docs/env-vars.md));
credentials enter through `_FILE` variables, are rendered into
`/run/brokersre/config.ini` (tmpfs, mode 0600) and are removed from the environment before any
child process starts; every build input is verified at build time (the base image and IBC by
SHA-256, the Gateway installer by SHA-256 or, when IBKR has moved past the pin, by IBKR's own
build stamp before and after installation). RocketEdge's own image (private, for BrokerSRE) is
signed (keyless cosign), carries one CycloneDX SBOM per platform and GitHub build provenance,
and both platforms are scanned by Trivy v0.76.2 before any tag moves; an image you build has
none of that unless you add it. See [SECURITY.md](SECURITY.md).

## Verifying what you built

Four checks, each of which compares two independent records of the same fact. Here for the
`stable` build of 2026-11-17; put in your version.

**1. The labels**: what the build says it put into the image.

```bash
docker image inspect brokersre-ib-gateway:stable --format '{{json .Config.Labels}}'
```

You should see, among others, `"com.rocketedge.brokersre.ibkr.version":"10.50.1h"`,
`"com.rocketedge.brokersre.ibkr.build_stamp":"(.1h) 20261116 16:02:08"`,
`"com.rocketedge.brokersre.installer.sha256":"eb578b23...fe7aa"` and
`"com.rocketedge.brokersre.qualified":"no"`, the same values as the build's last lines.

**2. The installer**: the SHA-256 of the file in the installer cache equals the label.

```bash
sha256sum ~/.cache/brokersre-ib-gateway/installers/10.50.1h/x64/ibgateway-10.50.1h-standalone-linux-x64.sh
```

```powershell
(Get-FileHash "$env:LOCALAPPDATA\brokersre-ib-gateway\installers\10.50.1h\x64\ibgateway-10.50.1h-standalone-linux-x64.sh").Hash.ToLowerInvariant()
```

**3. The installed Gateway**: the stamp inside the image equals the label and IBKR's
announcement (the two slashes keep Git Bash from rewriting the path; PowerShell passes them
through unchanged):

```bash
docker run --rm --entrypoint cat brokersre-ib-gateway:stable //home/ibgateway/Jts/ibgateway/10.50.1h/.install4j/i4jparams.conf | grep -o 'applicationVersion="[^"]*"'
curl -fsS https://download2.interactivebrokers.com/installers/ibgateway/stable-standalone/version.json
```

```powershell
docker run --rm --entrypoint cat brokersre-ib-gateway:stable //home/ibgateway/Jts/ibgateway/10.50.1h/.install4j/i4jparams.conf | Select-String -Pattern 'applicationVersion="[^"]*"' | ForEach-Object { $_.Matches.Value }
curl.exe -fsS https://download2.interactivebrokers.com/installers/ibgateway/stable-standalone/version.json
```

You should see `applicationVersion="(.1h) 20261116 16:02:08"` and, while IBKR still serves that
build, `ibgatewaystable_callback({"buildVersion":"10.50.1h","buildDateTime":"20261116 16:02:08"});`.

**4. The running gateway**: its first event names the version it runs.

```bash
docker compose -f compose/docker-compose.example.yml logs ib-gateway | grep container_start
```

RocketEdge's own image, built from the same recipe for its BrokerSRE service, is private; its
signature, SBOMs and provenance are verified by BrokerSRE before a client pins a digest, and
are not available to the public.

## Evidence for due diligence

[docs/evidence.md](docs/evidence.md) maps the usual operational due-diligence questions (what
runs, what changed, who reaches the API, where the credentials are, how health is known, the
second factor, vulnerabilities, what is not covered) to the artefact that answers each and
the command that produces it. IBKR's bundled jars carry CVEs this image cannot patch; the
project's statement on each is
[security/vex/ibgateway-vendor-jars.openvex.json](security/vex/ibgateway-vendor-jars.openvex.json)
(`trivy image --vex security/vex/ibgateway-vendor-jars.openvex.json <image>`).

## Qualifying an image with a real paper login

Nothing started by a push or a pull request logs in to IBKR. To prove that an image can
really log in, run the qualification against a **paper** account of your own:

```bash
# two files, written as in the quick start: <dir>/ib-username and <dir>/ib-password
scripts/qualify-paper.sh --image brokersre-ib-gateway:10.50.1h --secrets-dir <dir>
```

Give it the image you built (by its version tag, as here, or by digest in your registry). This
is how a build that says `qualified_by_project: no` is qualified on your side.

It starts the image in the hardened reference configuration, makes **one** login attempt in
paper mode with the read-only API, and checks: the phase reaches `logged-in`, the health check
agrees, the API answers its handshake, the relay opens, the events are complete and numbered
without a gap, no window was left unhandled, and a stop logs out inside the grace period. The
result is written to `qualify-out/result.json` (`brokersre.qualification.v1`); it holds no
username, password or account id. Exit 0 means qualified.

It never answers a second factor: if IBKR asks for one, it prints that a person must approve
it and waits. It never retries, so a wrong password costs one failed login. Do not run it with
a username that another session is using.

In this repository the same script runs in the workflow `Qualify (paper login)`, which is
dispatched by hand, only from `main`, only for an image given by digest, behind a required
reviewer ([ADR 0014](docs/adr/0014-paper-login-qualification.md)). The digests
`7773ff7` (`stable`, 10.50.1g) and `cc3a6a9` (`latest`, 10.52.1d), published by RocketEdge
before its image became private, passed the script with a real paper account on 2026-11-16,
run by hand: those two Gateway builds are the ones `versions.json` pins. A digest that a channel tag moves to later,
after a rebuild for example, is not covered by those runs, and the workflow has not run yet
([limitations](docs/limitations.md), L16). The account you use must have its paper trading account enabled at IBKR;
credentials that work on IBKR's website are not proof of that.

## Get notified of new versions

Every new IB Gateway version this repository pins, and every OS-patch rebuild of RocketEdge's
own image, creates a [release](https://github.com/RocketEdge/brokersre-ib-gateway/releases).
For you a release means: pull this repository and build again. Its digests and assets
(`digests-<channel>.json`, the SBOMs, `ibgateway-vendor-jars.openvex.json`) describe
RocketEdge's private image; the VEX document applies to any image of the same Gateway version.
When an already released version is rebuilt (an image fix, no new IB Gateway), its release is
updated in place, which GitHub does not announce. Follow the releases in either of two ways:

- **E-mail from GitHub** (needs a GitHub account): on this repository click **Watch**, then
  **Custom**, tick **Releases** and click **Apply**. In your GitHub
  [notification settings](https://github.com/settings/notifications), under **Subscriptions >
  Watching**, make sure **Email** is ticked. GitHub then e-mails you each new release.
- **Feed, no account needed:** subscribe to
  `https://github.com/RocketEdge/brokersre-ib-gateway/releases.atom` in a feed reader, or post it
  to a team channel through the channel's RSS integration (for example Microsoft Teams Workflows
  or the Slack RSS app).

Release names carry the channel (`v10.50.1g-stable`, `v10.51.1e-latest`); look for `-stable` if
that is the channel you run. A release changes nothing you run. A release is not the only way
IBKR moves: IBKR publishes new Gateway builds on its own schedule, and the next section shows
how to see that.

## Is a newer IB Gateway available?

For an image you built, "newer" means IBKR's channel serves another Gateway build than the one
in your image. Compare the two; nothing is downloaded or built:

```bash
scripts/build-image.sh --print-plan | grep '^version:'
docker image inspect brokersre-ib-gateway:stable --format '{{index .Config.Labels "com.rocketedge.brokersre.ibkr.version"}}'
```

In PowerShell (Windows PowerShell 5.1 drops the inner double quotes of the `--format` above,
so the label is read as JSON):

```powershell
pwsh -NoProfile -File scripts/build-image.ps1 -PrintPlan | Select-String '^version:'
(docker image inspect brokersre-ib-gateway:stable --format '{{json .Config.Labels}}' | ConvertFrom-Json).'com.rocketedge.brokersre.ibkr.version'
```

The first line is what IBKR serves now (`version: 10.50.1h` on 2026-11-17), the second what
your image holds. When they differ, a rebuild brings the new Gateway
([Upgrading and rolling back](#upgrading-and-rolling-back)); `--print-plan` also says whether
that version is the one `versions.json` pins (`pinned: yes`) and therefore qualified.
[docs/upgrade-check.md](docs/upgrade-check.md) has a cron and a Task Scheduler example that
only notify. For an image in a registry (yours), `scripts/check-upgrade.sh` compares the digest
a gateway runs with the digest a channel tag points at in that registry; it answers exit 2
for an image that was built locally and never pushed.

## Building and testing

The build is [Build the image](#build-the-image) (`scripts/build-image.sh`, `.ps1`). Its
options in short: `--channel stable|latest`, `--strict`, `--installer FILE`,
`--platform linux/amd64|linux/arm64`, `--tag NAME`, `--no-smoke` (skip the offline IBC test),
`--cache-dir DIR`, `--print-plan`, `--help`. Exit codes: `0` built, `1` download, check, build
or smoke test failed, `2` usage, `3` IBKR unreachable and nothing usable cached, `4` `--strict`
and IBKR serves another version. The decision is
[ADR 0018](docs/adr/0018-private-image-public-build-recipe.md); the interface is in
[the spec](docs/specs/2026-11-17-private-image-public-recipe.md).

Tests:

```bash
git clone --config core.autocrlf=false --config core.eol=lf --depth 1 -b v1.14.0 https://github.com/bats-core/bats-core tests/.bats-core  # LF matters inside the image
tests/bats/run-in-image.sh brokersre-ib-gateway:stable                    # unit suite inside the image
IMAGE=brokersre-ib-gateway:stable tests/container/run.sh                   # offline container tests
IMAGE=brokersre-ib-gateway:stable tests/container/run.sh --only ibc-smoke  # the IBC smoke test alone
IMAGE=brokersre-ib-gateway:stable tests/compose/run.sh                     # compose files as shipped: several gateways, gateway + strategy
tests/recipes/run.sh                                                       # log-shipper recipes: validate, then run against a stand-in (needs only Docker)
```

The container tests never log in: the IBC smoke test runs with `--network none` and proves that
IBC starts, the command server listens and `STOP` shuts the Gateway down tidily.

Maintainers build the pinned versions for both platforms with `docker buildx bake` (variables
from `versions.json` through `eval "$(scripts/bake-env.sh)"`, which needs jq); that path builds
only the pins and fails while IBKR serves another version, unless the pinned installer is in
`downloads/`.

## Upgrade policy

For you: the image changes only when you build it. Rebuild when IBKR serves a newer Gateway
([Is a newer IB Gateway available?](#is-a-newer-ib-gateway-available)) and now and then for
Ubuntu's security fixes, keep the previous image until the new one has logged in, and run an
image name that cannot move ([Upgrading and rolling back](#upgrading-and-rolling-back)).

For the project and RocketEdge's own image, see [docs/upgrade-policy.md](docs/upgrade-policy.md).
Summary: `detect-releases.yml` checks IBKR daily and opens a pull request when IBKR publishes a
build, which moves the pins in `versions.json` (what `qualified_by_project: yes` refers to); a
`stable` update merges itself once CI passes, a `latest` update waits for a human (ADR 0009);
`publish.yml` builds RocketEdge's image, pushes it by digest, scans both platforms of that
digest, signs, and only then moves tags; OS packages are refreshed with `-rYYYYMMDD` tags
monthly, and within a day of a fixable CRITICAL/HIGH finding (a target, not a guarantee:
GitHub can delay or drop a scheduled run). That image is private from Phase 4 of
[the spec](docs/specs/2026-11-17-private-image-public-recipe.md) on.

## Automatic updates and repository secrets

For maintainers. Every day at 06:00 UTC `detect-releases.yml` reads IBKR's manifest for both
channels, downloads both installers and lets `scripts/release-decision.sh` decide:

| IBKR serves | What happens |
|---|---|
| A newer `stable` version, both installers changed | Installers archived, pull request opened with auto-merge: it merges once `lint` and `build-test` pass, then `publish.yml` publishes and the release notifies watchers |
| Any other new label (`latest`, a lower version, an installer unchanged) | Installers archived, pull request opened; a human merges it |
| The pinned version with different bytes | New bytes archived under `ibgateway-<channel>@<version>-<8 hex of x64><8 hex of arm>`, one `ibkr-reupload` issue per set of bytes; nothing changes |
| The pinned version, same bytes | Nothing |

To hold one `stable` update, disable auto-merge on its pull request and leave the pull request
open: the daily run enables auto-merge only on the run that creates the pull request, so it stays
off. Do not close it: the next daily run would open a new one with auto-merge. To skip a version
or stop all automatic merges:
`gh variable set STABLE_AUTOMERGE --body false -R RocketEdge/brokersre-ib-gateway` (delete the
variable to resume).

Repository settings this needs (both on): **Settings > General > Pull Requests > Allow
auto-merge**, and **Settings > Actions > General > Allow GitHub Actions to create and approve
pull requests**.

Repository secrets (fine-grained personal access tokens; GitHub adds **Metadata: Read-only** to
each by itself):

| Secret | Used by | Repository access | Repository permissions |
|---|---|---|---|
| `BOT_TOKEN` | `detect-releases.yml`: opens the pull request and enables auto-merge | `RocketEdge/brokersre-ib-gateway` | Contents: Read and write; Pull requests: Read and write |
| `ARCHIVE_WRITE_TOKEN` | `detect-releases.yml`: archives the installers | `RocketEdge/brokersre-ib-gateway-archive` | Contents: Read and write |
| `ARCHIVE_READ_TOKEN` | `ci.yml`, `publish.yml`: pre-fetch archived installers | `RocketEdge/brokersre-ib-gateway-archive` | Contents: Read-only |

Without `BOT_TOKEN` the pull request is opened with `GITHUB_TOKEN`: GitHub does not start its CI
by itself (it skips the runs or holds them for approval), it is not set to auto-merge, and a
merge made with `GITHUB_TOKEN` would not start `publish.yml`. Without the archive tokens a pinned
version stops building on the day IBKR moves past it.

To create and store each token:

1. Open [New fine-grained token](https://github.com/settings/personal-access-tokens/new).
2. **Token name:** for example `brokersre-ib-gateway-bot`. **Resource owner:** `RocketEdge`.
   **Expiration:** at most a year; put a reminder in the calendar two weeks before it expires.
   An expired `BOT_TOKEN` or `ARCHIVE_WRITE_TOKEN` fails only the run that needs it (the day IBKR
   publishes); an expired `ARCHIVE_READ_TOKEN` fails nothing and only logs an archive miss, so
   the reminder is the only warning.
3. **Repository access:** *Only select repositories*, then the repository from the table.
4. **Permissions > Repository permissions:** exactly the permissions in the table, nothing else.
5. **Generate token** and copy it once. If the organisation requires approval, approve the
   request under **RocketEdge > Settings > Personal access tokens > Pending requests**.
6. Store it, pasting the value at the prompt (never on the command line, where shell history
   keeps it):

   ```bash
   gh secret set BOT_TOKEN -R RocketEdge/brokersre-ib-gateway
   gh secret set ARCHIVE_WRITE_TOKEN -R RocketEdge/brokersre-ib-gateway
   gh secret set ARCHIVE_READ_TOKEN -R RocketEdge/brokersre-ib-gateway
   ```

7. Check: `gh secret list -R RocketEdge/brokersre-ib-gateway` lists all three. `ARCHIVE_READ_TOKEN`
   is proven by the next CI run: its "Pre-fetch archived stable installers" step logs
   `from ibgateway-stable@<version> (sha256 ok)`. `BOT_TOKEN` and `ARCHIVE_WRITE_TOKEN` are first
   used when IBKR publishes: that day's pull request shows CI checks and auto-merge, and the
   archive gains a release.

A GitHub App installation token would avoid tying the bot to a person; it needs an app with the
same permissions and `actions/create-github-app-token` in the workflow.

## Differences from gnzsnz/ib-gateway-docker

See [docs/migrating-from-gnzsnz.md](docs/migrating-from-gnzsnz.md) for the variable-by-variable
mapping. Removed: SSH tunnel, `TRADING_MODE=both`, the TWS desktop image, `telnet`, `sudo`.
Renamed: `JAVA_HEAP_SIZE` is `JAVA_HEAP_MB` (megabytes, or `auto`). Added: `HEALTHCHECK`, phase
file, JSON event contract on stdout and on the log volume, a preflight (`doctor`) that names
variables carried over from gnzsnz which this image ignores, a relay that follows the login,
resource samples, command server on loopback, checksum pinning of every input, a build helper
that checks IBKR's installer against IBKR's own build stamp, read-only filesystem support.
gnzsnz publishes an image; this project does not ([why](#why-there-is-no-public-image)): build
yours with [Build the image](#build-the-image).
`scripts/migrate-from-gnzsnz.sh old.env > new.env` converts a gnzsnz `.env` file and reports
every variable it dropped or renamed on stderr, without printing a value.

## Documentation

[docs/architecture.md](docs/architecture.md) (Mermaid), [docs/adr/README.md](docs/adr/README.md),
[docs/changes.md](docs/changes.md), [docs/limitations.md](docs/limitations.md),
[docs/env-vars.md](docs/env-vars.md), [docs/log-contract.md](docs/log-contract.md),
[docs/upgrade-policy.md](docs/upgrade-policy.md), [compose/README.md](compose/README.md),
[examples/README.md](examples/README.md), [azure/README.md](azure/README.md),
[sidecar/README.md](sidecar/README.md), [docs/sidecar.md](docs/sidecar.md),
[docs/runbooks/README.md](docs/runbooks/README.md),
[docs/evidence.md](docs/evidence.md), [SECURITY.md](SECURITY.md),
[windows/README.md](windows/README.md), [docs/console.md](docs/console.md),
[docs/upgrade-check.md](docs/upgrade-check.md), [docs/passkeys.md](docs/passkeys.md),
[docs/recipes/README.md](docs/recipes/README.md), design notes under [docs/specs/](docs/specs/).

## License

MIT, see [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md). IBC is GPL-3.0 and is aggregated, not
linked; its licence text ships at `/usr/share/doc/ibc/LICENSE.txt` and its complete source is the
tagged release in [RocketEdge/ibc](https://github.com/RocketEdge/ibc). IB Gateway is Interactive
Brokers' software, fetched from IBKR at build time under IBKR's terms; it is not redistributed
from this repository, and RocketEdge publishes no image that contains it
([why](#why-there-is-no-public-image)).
