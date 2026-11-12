# Trivy fixtures

Real Trivy reports, reduced with [`trim.jq`](trim.jq). Nothing here was written by hand: each
file is the output of the command below, or a selection of entries from such an output. They
feed `tests/bats/ci/rebuild-decision.bats` and `tests/bats/ci/check-vex.bats`.

Produced on 2026-11-12 with `aquasec/trivy:0.76.2` (the release current on that day) and that
day's vulnerability database. `aquasecurity/trivy-action@v0.36.0`, which the workflows use,
installs Trivy v0.70.0 unless told otherwise. Reports made with 0.70.0 the same day (OS
packages of an image built from the same Debian base, both platforms; the jars of this image)
were fed to the two scripts and gave the same answers as the 0.76.2 reports; both versions
write SchemaVersion 2.

| File | Source | Command (then `jq -f trim.jq`) |
|---|---|---|
| `debian-os-gate.json` | `debian@sha256:050f00e8…c116d` (`debian:bookworm-20230904-slim`, linux/amd64) | `trivy image --platform linux/amd64 --pkg-types os --severity CRITICAL,HIGH --ignore-unfixed --format json` |
| `debian-os-full.json` | same image | `trivy image --platform linux/amd64 --pkg-types os --format json` (every severity, unfixed included: 365 findings) |
| `debian-os-unfixable-only.json` | `debian-os-full.json` | entries with severity CRITICAL or HIGH and no `FixedVersion` |
| `debian-os-one-fixable-high.json` | `debian-os-gate.json` | the entry `CVE-2026-109518` of package `apt` |
| `debian-os-mix.json` | `debian-os-full.json` | every entry of `CVE-2026-33845`, `CVE-2023-45853`, `CVE-2023-4911`, `CVE-2026-109518`, `CVE-2026-41992`, `CVE-2026-53613`, `CVE-2026-2219`, `CVE-2024-28085` |
| `gateway-os-clean.json` | this image, built from the branch (IB Gateway 10.50.1g, linux/amd64, `docker save`) | `trivy image --input <tar> --pkg-types os --severity CRITICAL,HIGH --ignore-unfixed --format json` |
| `gateway-os-clean-jars-vulnerable.json` | same image | `trivy image --input <tar> --pkg-types os,library --severity CRITICAL,HIGH --ignore-unfixed --format json` |
| `gateway-library.json` | same image | `trivy image --input <tar> --pkg-types library --list-all-pkgs --format json` (what `ci.yml` feeds to `scripts/check-vex.sh`) |

`../vex/in-sync.openvex.json` is a copy of `security/vex/ibgateway-vendor-jars.openvex.json` as
it was when `gateway-library.json` was made. The two belong together: refresh both, or neither.

To refresh: run the commands with the Trivy version of the day, reduce with `trim.jq`, and
update the expected ids in the two bats files (they are listed there on purpose, as a second
statement of what the scripts must print).
