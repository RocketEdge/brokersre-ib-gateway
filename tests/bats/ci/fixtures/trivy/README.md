# Trivy fixtures

Real Trivy reports, reduced with [`trim.jq`](trim.jq). Nothing here was written by hand: each
file is the output of the command below, or a selection of entries from such an output. They
feed `tests/bats/ci/rebuild-decision.bats`, `tests/bats/ci/check-report-arch.bats` and
`tests/bats/ci/check-vex.bats`.

Produced on 2026-11-12 with `aquasec/trivy:0.76.2`, the version the workflows pin
(`version: v0.76.2` on every scanner step), and that day's vulnerability database. Reports
made with 0.70.0 the same day (OS packages of an image built from the same Debian base, both
platforms; the jars of this image) were fed to the scripts and gave the same answers; both
versions write SchemaVersion 2.

Every report keeps `Metadata.ImageConfig.os` and `.architecture`: the scripts refuse a report
that does not say which platform it scanned.

| File | Source | Command (then `jq -f trim.jq`) |
|---|---|---|
| `debian-os-gate.json` | `debian@sha256:050f00e8…c116d` (`debian:bookworm-20230904-slim`), linux/amd64 | `trivy image --platform linux/amd64 --pkg-types os --severity CRITICAL,HIGH --ignore-unfixed --format json` |
| `debian-os-gate-arm64.json` | same image, linux/arm64 | the same with `--platform linux/arm64` |
| `debian-os-full.json` | same image, linux/amd64 | `trivy image --platform linux/amd64 --pkg-types os --format json` (every severity, unfixed included: 365 findings) |
| `debian-os-unfixable-only.json` | `debian-os-full.json` | entries with severity CRITICAL or HIGH and no `FixedVersion` |
| `debian-os-one-fixable-high.json` | `debian-os-gate.json` | the entry `CVE-2026-109518` of package `apt` |
| `debian-os-one-fixable-high-arm64.json` | `debian-os-gate-arm64.json` | the entry `CVE-2026-109518` of package `apt` |
| `debian-os-mix.json` | `debian-os-full.json` | every entry of `CVE-2026-33845`, `CVE-2023-45853`, `CVE-2023-4911`, `CVE-2026-109518`, `CVE-2026-41992`, `CVE-2026-53613`, `CVE-2026-2219`, `CVE-2024-28085` |
| `gateway-os-clean.json` | this image, built from the branch (IB Gateway 10.50.1g, linux/amd64, `docker save`) | `trivy image --input <tar> --pkg-types os --severity CRITICAL,HIGH --ignore-unfixed --format json` |
| `gateway-os-clean-jars-vulnerable.json` | same image | `trivy image --input <tar> --pkg-types os,library --severity CRITICAL,HIGH --ignore-unfixed --format json` |
| `gateway-library.json` | same image | `trivy image --input <tar> --pkg-types library --list-all-pkgs --format json` (what `ci.yml` feeds to `scripts/check-vex.sh`) |
| `gateway-arm64-full.json` | the published image `ghcr.io/rocketedge/brokersre-ib-gateway@sha256:693bd630…e869ea` (stable, 10.50.1g), linux/arm64 | `trivy image --image-src remote --platform linux/arm64 --pkg-types os,library --format json` (every severity, unfixed included) |

`../vex/in-sync.openvex.json` is a copy of `security/vex/ibgateway-vendor-jars.openvex.json` as
it was when `gateway-library.json` was made. The two belong together: refresh both, or neither.

The sibling directories hold the real output of other tools: `../bake/` is
`docker buildx bake --print stable latest` of this repository's `docker-bake.hcl` (with the
pinned versions, with a rebuild suffix, and with the latest channel's version variables set to
the stable minor and to the stable version); `../imagetools/` is
`docker buildx imagetools inspect <ref> --format '{{json .Manifest}}'` for the published
stable index and for one of its platform manifests.

To refresh: run the commands with the Trivy version of the day, reduce with `trim.jq`, and
update the expected ids in the bats files (they are listed there on purpose, as a second
statement of what the scripts must print).
