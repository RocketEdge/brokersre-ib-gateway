# Security Policy

## Reporting

E-mail **security@rocketedge.com**; do not open a public issue. Acknowledgement within two
business days (Singapore time), remediation plan within ten.

## What this image does and does not protect

- Credentials arrive through `TWS_USERID_FILE` / `TWS_PASSWORD_FILE` (Docker secrets). They are
  rendered into `/run/brokersre/config.ini` (tmpfs, mode 0600, owned by uid 1000) because IBC
  reads them from that file, then removed from the environment before any child process starts.
  **The plaintext password exists in that tmpfs file while the container runs**; this is inherent
  to IBC and is the reason the image runs without `sudo`, without shell access tools and with a
  read-only root filesystem.
- The TWS API is unencrypted and unauthenticated by design. IB Gateway accepts loopback only;
  the `socat` relay exposes it on the container interface so a strategy host can connect. Publish
  that port only on a private network. Never on the public internet.
- The IBC command server (`127.0.0.1:7462`) can stop or restart the Gateway. It is reachable only
  from inside the container's network namespace.
- 2FA is never automated or bypassed. The image re-prompts (IBC relogin) and reports the pending
  state; a human acknowledges on the IB Key device.
- Every build input is verified by SHA-256 (base image digest, Gateway installer, IBC zip).
  Published images are signed with Sigstore cosign (keyless, GitHub Actions identity) and
  carry GitHub build provenance; both platforms are scanned by Trivy before any tag moves.
  The scanner (Trivy v0.76.2) and the actions of the publish and rebuild workflows are pinned
  inputs too: one version, and a commit per action.
- **What the SBOM covers.** The linux/amd64 and linux/arm64 images hold different software
  (arm64 runs Ubuntu's `openjdk-25-jre`, amd64 the JRE IBKR bundles). `publish.yml` makes one
  CycloneDX SBOM per platform and attests each to the manifest of the platform it describes;
  the two manifest digests are in `digests-<channel>.json` under `platforms`. Images published
  up to 2026-11-11 carry a single SBOM, attested to the multi-platform index, and that SBOM
  describes linux/amd64 only.
- **Which signature to accept.** Verify with the identity
  `https://github.com/RocketEdge/brokersre-ib-gateway/.github/workflows/publish.yml@refs/heads/main`
  (as a regular expression, anchored: `...publish.yml@refs/heads/main$`). A pattern that stops
  at `publish.yml@` would also accept a signature made by that workflow file on another branch.

## How vulnerabilities are handled

What an auditor can check for each point is listed in [docs/evidence.md](docs/evidence.md).

- **Gate before a tag moves.** `publish.yml` pushes a build by digest only, scans
  `linux/amd64` and `linux/arm64` of exactly that digest and moves tags only when neither has a
  CRITICAL or HIGH finding in OS packages for which a fixed package exists. Each scan report
  must name the platform it was asked to read, and the index must hold exactly one image per
  platform, or the publish stops. Pull requests are gated on the amd64 build (`ci.yml`). A
  build that fails the gate leaves an untagged, unsigned manifest in the registry and nothing
  else: no tag, no signature, no release. Trust a digest because its signature verifies, not
  because the registry serves it.
- **Rebuild when a fix exists (a target, not a guarantee).** `rebuild.yml` is scheduled to scan
  the published image of each channel every day. A CRITICAL or HIGH finding in OS packages
  that has a fixed package opens one issue (label `os-vulnerability`) that names the CVE ids,
  and the same run requests a rebuild of that channel. A person merges nothing: the rebuild
  publishes a `<version>-rYYYYMMDD` tag after the same gate, and the next scan closes the
  issue. When a rebuild cannot pick the fix up, its gate fails and nothing is published; the
  scan then adds one comment a day to the issue, requests a rebuild on the first three days
  with the same published image and after that stops requesting, so that a person decides
  (wait for the package, or accept the finding). What this does not promise:
  - no number of hours: nothing measures the time from an available fix to a published image;
  - not even "every day": GitHub may start a scheduled run late or drop it under load, and
    it disables schedules after 60 days without repository activity. A rebuild can always be
    started by hand (`publish.yml`, `rebuild=true`).

  Both channels are also rebuilt on the first day of every month, which picks up the OS
  updates below the gate's severity.
- **IBKR's bundled jars are not patched.** IB Gateway ships third-party jars (Jackson, Commons
  IO, Log4j) with known CVEs. This image must not modify IBKR's application, so it cannot
  replace them and the gate does not cover them. The project's position is published in
  [security/vex/ibgateway-vendor-jars.openvex.json](security/vex/ibgateway-vendor-jars.openvex.json)
  (OpenVEX v0.2.0): one statement per CVE that Trivy reports for those jars. Every statement is
  `under_investigation`: whether IB Gateway can reach the vulnerable code is known to IBKR, not
  to this project, and each statement says what triggers the CVE and what is unknown. Nothing
  is declared `not_affected` without evidence, and nothing is ever declared `fixed`.
  `scripts/check-vex.sh` reports a CVE without a statement and a statement without a CVE in
  every CI and publish run (a warning, not a gate). The document is attached to every release
  and attested to the image. A change to the document reaches the attestation of an image
  only with the next publish; the file in this repository is always the current one. To
  apply it:
  `trivy image --vex security/vex/ibgateway-vendor-jars.openvex.json <image>` (it hides no
  finding while the status is `under_investigation`; it tells your scanner that the finding is
  known and why it is open).
- **One finding outside both.** `/usr/bin/pebble`, a Go binary of the Ubuntu base image that
  belongs to no package, has a Go standard-library finding. The OS gate does not cover it,
  `apt-get upgrade` cannot replace it (only a new base image digest does), and the VEX
  document for the jars does not cover it. Nothing in the image starts it.
- **Arm64.** The arm64 image is scanned like the amd64 image. It has still never completed a
  login on real hardware ([docs/limitations.md](docs/limitations.md), L05).

## Supported images

The `stable` and `latest` channel tags and their version tags from the current `versions.json`.
Older digests remain available but receive no rebuilds.
