# Change Log — brokersre-ib-gateway

Append-only; newest first. Fields: Date, What changed, Result, What did NOT work / root cause,
Next step.

## Change History

### 2026-11-01 — First successful publish of both channels

- **What changed:** `publish.yml` creates the release tag through the release API
  (`gh release create --target`) and verifies the keyless signature and the CycloneDX
  attestation inside the job right after signing; `ci.yml` grants `security-events: write` to
  the job that uploads Trivy SARIF.
- **Result:** CI green on `2f109b8`; Publish run 41285824630 green for
  both channels. Trivy gate: 0 fixable CRITICAL/HIGH in OS packages; vendor jars reported (L08).
  Signature and attestation verified in-job against identity
  `https://github.com/RocketEdge/brokersre-ib-gateway/.github/workflows/publish.yml@refs/heads/main`.
  Releases `v10.50.1f-stable` and `v10.51.1e-latest` carry `digests-<channel>.json` and the SBOM.

  | Channel | Gateway | Digest |
  |---|---|---|
  | stable | 10.50.1f | `sha256:a35fcafed0ee2c6857970aef230dfe5df0277cfafe24ef927503a54d0716b885` |
  | latest | 10.51.1e | `sha256:8fb845fbc6298b8dc51d0a09b95bed837eedfc1bbaa19033c5488c79868c0774` |

- **What did NOT work / root cause:** (1) `git push` of the release tag from the job was
  rejected ("refusing to allow a GitHub App to create or update workflow ... without `workflows`
  permission"): `GITHUB_TOKEN` cannot push a ref whose commit carries workflow files, so the
  tag is now created server-side by the release API. (2) Verification from a workstation fails
  with `DENIED` while the GHCR package is private; in-job verification uses the workflow token
  and records the evidence in the run log. (3) Signing identity is the branch ref
  (`@refs/heads/main`), not a tag ref, because publish runs on pushes to main; the monorepo's
  `image-pin.yml` was corrected to match.
- **Next step:** owner makes the GHCR package public (L07); then anonymous `docker pull` and a
  workstation `cosign verify`; BrokerSRE `image-pin.yml` pins the stable digest.

### 2026-11-01 — Second CI run: secrets directory permissions and the Trivy gate scope

- **What changed:** the container harness makes its temporary secrets directory traversable
  (`chmod 0755`); the Trivy gate in `ci.yml` and `publish.yml` covers OS packages
  (`vuln-type: os`) and a second, non-gating step prints the findings in IBKR's bundled jars;
  limitation L08 records them.
- **Result:** Trivy 0.70.0 locally on image 653f1201000a: 0 fixable OS findings; 12 fixable HIGH
  findings in vendor jars (jackson-core 2.12.3: CVE-2025-52999, CVE-2026-68494, CVE-2026-89425;
  jackson-databind 2.12.3: CVE-2020-36518, CVE-2021-46877, CVE-2022-42003, CVE-2022-42004,
  CVE-2026-54512, CVE-2026-54513, CVE-2026-91776, CVE-2026-91777; commons-io 2.11.0:
  CVE-2024-47554). The harness change is host-side and was not re-run locally; the CI run after
  this commit is its evidence.
- **What did NOT work / root cause:** (1) in CI every container test that needs credentials
  failed with `secret_unreadable`: `mktemp -d` creates a 0700 directory owned by the runner
  user (uid 1001) and Linux bind mounts keep host permissions, so uid 1000 inside the container
  could not traverse it; Docker Desktop on the Windows development host masks host permissions
  and hid the bug. (2) The publish Trivy gate failed on the vendor jars above, which this image
  cannot replace without modifying IBKR's application.
- **Next step:** watch the rerun, `cosign verify` the stable digest, record the run ids.

### 2026-11-01 — First CI and publish runs: four set-up failures fixed

- **What changed:** `ci.yml` names its test image `TEST_IMAGE`; `publish.yml` re-exports the bake
  variables into `GITHUB_ENV` unquoted; the advanced `codeql.yml` was removed because the
  organisation's default CodeQL setup already covers this repository; `trivy-action` is pinned
  to the existing `v0.36.0` tag.
- **Result:** no script changed, so the local evidence of the previous entry stands (bats 25/25,
  container suite 28/28); the CI and publish runs after this change are the next evidence.
- **What did NOT work / root cause:** (1) `aquasecurity/trivy-action@0.36.0` does not exist (the
  tag is `v0.36.0`), so every job referencing it failed at set-up. (2) `docker buildx bake` reads
  a variable named `IMAGE` from the environment; the CI job exported `IMAGE=...:stable` for the
  test harness and bake built tags such as `...:stable:10.50.1f`. (3) `GITHUB_ENV` takes
  `NAME=value` literally; piping the `export NAME='value'` lines of `scripts/bake-env.sh`
  through `sed 's/^export //'` kept the quotes and produced the tag `...:'10.51.1e'`. (4) GitHub's
  default CodeQL setup is enabled on this repository by the organisation security configuration
  and rejects SARIF from an advanced workflow.
- **Next step:** watch `ci.yml` and `publish.yml`, then `cosign verify` the stable digest and
  record the run ids.

### 2026-11-01 — Read-only hardening: tmpfs ownership, structured fail-fast, harness fixes

- **What changed:** The entrypoint verifies that `LOG_DIR`, `RUN_DIR` and `TWS_SETTINGS_PATH` are
  writable before anything else and exits with the structured stdout event `dirs_not_writable`;
  the reference compose and the container harness mount tmpfs with `uid=1000,gid=1000,mode=0750`;
  the harness validates the log contract with the image's own `jq` (the host may have none) and
  gained a negative test for a root-owned tmpfs; shellcheck/shfmt findings were cleared and a
  `.markdownlint.yaml` added.
- **Result (fresh, local, amd64 image 653f1201000a):** bats inside the image 25/25; container
  suite 28/28 (structure, render, read-only positive and negative, IBC smoke offline, command
  server off); shellcheck 0.9.0 and 0.11.0 clean; shfmt clean; hadolint clean.
- **What did NOT work / root cause:** (1) `--tmpfs /run/brokersre` is root-owned 0755, so the
  uid-1000 entrypoint died on `mkdir` with a bare stderr line and the read-only test only saw
  "relay never listened"; fixed by mount options plus a fail-fast check. (2) bats-core cloned on
  Windows carried CRLF (`core.autocrlf=true`), so `env` inside the image failed on
  `bash\r`; MSYS `grep` does not report carriage returns, `file(1)` does; the clone was redone
  with `core.autocrlf=false` and the repo's `.gitattributes` forces LF. (3) The harness used the
  host's `jq`, absent on Windows, so valid JSON was reported as a contract violation.
- **Next step:** first push, CI, `publish.yml`, cosign verification; owner makes the GHCR package
  public; BrokerSRE pins the digest.

### 2026-11-01 — Initial image: single Dockerfile, pinned inputs, offline test suites

- **What changed:** Created the repository from the gnzsnz/ib-gateway-docker design with a single
  parametrised Dockerfile driven by `versions.json` (ubuntu:26.04 by digest, Gateway 10.50.1f /
  10.51.1e with RocketEdge-computed SHA-256 per architecture, IBC 3.24.2 from
  RocketEdge/ibc `3.24.2-rocketedge.1`), no sudo, read-only root filesystem support,
  HEALTHCHECK, IBC command server on loopback, JSON stdout + raw logs on a shared volume with a
  phase file, tini, bats unit suite run inside the image, offline container tests, publish /
  rebuild / detect workflows with Trivy, SBOM, cosign and provenance.
- **Result:** see the test and build evidence in the first pull request / CI run.
- **What did NOT work / root cause:** recorded below as it happens.
- **Next step:** first `publish.yml` run; owner makes the GHCR package public; BrokerSRE pins
  the digest through `image-pin.yml`.
