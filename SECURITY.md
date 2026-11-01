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
  Published images are signed with Sigstore cosign (keyless, GitHub Actions identity), carry a
  CycloneDX SBOM and GitHub build provenance, and are scanned by Trivy before any tag moves.

## Supported images

The `stable` and `latest` channel tags and their version tags from the current `versions.json`.
Older digests remain available but receive no rebuilds.
