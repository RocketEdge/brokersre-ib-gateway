# Change Log — brokersre-ib-gateway

Append-only; newest first. Fields: Date, What changed, Result, What did NOT work / root cause,
Next step.

## Change History

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
