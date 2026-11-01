# Upgrade policy

1. **Detection.** `detect-releases.yml` reads IBKR's `version.json` for each channel daily. A new
   build produces a pull request that bumps `versions.json` with RocketEdge-computed SHA-256 for
   both architectures. `detect-ibc-release.yml` does the same for RocketEdge/ibc releases.
2. **Human merge.** Nothing merges automatically. The pull request shows the version and digests.
3. **Publish.** `publish.yml` builds amd64, scans with Trivy (fail on fixable CRITICAL/HIGH),
   then builds and pushes multi-arch, signs with cosign, attests the SBOM and provenance, tags
   `v<version>-<channel>` and creates a release with `digests-<channel>.json`.
4. **Rebuild.** `rebuild.yml` runs monthly: the same pinned Gateway and IBC on a refreshed base
   layer, tagged `<version>-rYYYYMMDD`; channel and version tags re-point. Consumers pinning
   digests see the change through their own image-pin process (BrokerSRE: `image-pin.yml`,
   cosign-verified, operator-run paper regression before merge).
5. **Rollback.** Every published digest stays in the registry; pin the previous
   `digests-<channel>.json` value. Channel tags are moved back only by re-running `publish.yml`
   on the previous `versions.json` commit.

Not covered by this repository: whether a given Gateway build logs in correctly with IBC. That is
proven on the consumer's paper environment before the digest is promoted.
