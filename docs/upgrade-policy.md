# Upgrade policy

1. **Detection.** `detect-releases.yml` reads IBKR's `version.json` for each channel daily. A new
   build produces a pull request that bumps `versions.json` with RocketEdge-computed SHA-256 for
   both architectures. `detect-ibc-release.yml` does the same for RocketEdge/ibc releases.
2. **Merge** ([ADR 0009](adr/0009-stable-updates-merge-themselves.md)). `scripts/release-decision.sh`
   decides: a newer `stable` version whose installers both changed merges itself once `lint` and
   `build-test` pass (needs `BOT_TOKEN`; hold one by disabling its auto-merge, stop all with the
   repository variable `STABLE_AUTOMERGE=false`); any other new label waits for a human; different
   bytes under the pinned version are archived and open one `ibkr-reupload` issue, changing
   nothing. Installers are archived privately (`ARCHIVE_WRITE_TOKEN`), and builds pre-fetch them
   when IBKR has moved on.
3. **Publish.** `publish.yml` first checks that the two channels claim no common tag
   (`scripts/check-bake-tags.sh`: if IBKR ever puts both channels on one `major.minor`, nothing
   is built until the tag scheme is decided). It then builds `linux/amd64` and `linux/arm64`
   once, without a build cache, and pushes the image index by digest only, so no tag points at
   it. Trivy (one pinned version) scans both platforms of that digest and fails on a CRITICAL
   or HIGH finding in OS packages that has a fixed package; each report must name the platform
   it was asked to read. Only a digest that passed is signed with cosign and gets its
   attestations: one SBOM per platform on that platform's manifest, the VEX document and the
   build provenance on the index. Then `scripts/promote-tags.sh` moves the tags to the digest
   and checks that each resolves to it, and the workflow tags `v<version>-<channel>` and
   creates a release with `digests-<channel>.json` (index and platform digests), the two SBOMs
   and the VEX document. What is scanned and what a tag serves are the same bytes. One publish
   runs per channel at a time; a request for one channel never displaces a pending publish of
   the other.
4. **Rebuild.** The same pinned Gateway and IBC with refreshed OS packages, tagged
   `<version>-rYYYYMMDD`; channel and version tags re-point. `rebuild.yml` starts one in two
   cases:
   - **monthly**, both channels, whatever the scanners say;
   - **when a fix exists** (a target, not a guarantee): a scheduled job scans the digest each
     channel tag points at, both platforms, with the gate's flags.
     `scripts/rebuild-decision.sh` asks for a rebuild of a channel when it has a CRITICAL or
     HIGH finding in OS packages with a fixed package, and `scripts/rebuild-issue.sh` keeps one
     issue per channel (label `os-vulnerability`) naming the CVE ids until the published image
     scans clean. The schedule is daily, so a rebuild is normally requested within a day of
     such a finding appearing in the scanner's database. "Normally" matters: GitHub may start a
     scheduled run late or drop it under load, and it disables schedules after 60 days without
     repository activity; nothing measures the time to a published image, and no number of
     hours is promised.

   A person merges nothing in either case: a rebuild changes no file, and it publishes only
   after the gates of step 3. When a rebuild cannot pick a fix up (the fixed package is not
   installable from the image's package sources), its gate fails and nothing is published.
   The scan then adds one comment a day to the issue, so that people are told, and requests a
   rebuild on the first three days with the same published image (repository variable
   `REBUILD_MAX_ATTEMPTS`). After that it requests none: a rebuild that failed three times
   will not pass by itself, and each attempt builds both platforms and leaves an untagged
   image in the registry. A person then decides; closing the issue, or a new published
   image, starts the count again. Findings without a fixed package and findings in IBKR's
   bundled jars never start a rebuild: a rebuild would change neither
   ([limitations](limitations.md), L08).

   When a fix-driven rebuild and the monthly rebuild fall on the same day, both carry the
   same `-rYYYYMMDD` suffix: the later one moves that tag and rewrites the release of that
   name in place; the earlier digest stays in the registry, signed, under no tag.

   A change to the VEX document does not start a publish; it reaches the attestation of an
   image with the next publish of that channel. Consumers pinning digests see a new digest
   through their own image-pin process (BrokerSRE: `image-pin.yml`, cosign-verified,
   operator-run paper regression before merge).
5. **Rollback.** Every published digest stays in the registry; pin the previous
   `digests-<channel>.json` value. Channel tags are moved back only by re-running `publish.yml`
   on the previous `versions.json` commit.

Not covered by this repository: whether a given Gateway build logs in correctly with IBC. That is
proven on the consumer's paper environment before the digest is promoted.
