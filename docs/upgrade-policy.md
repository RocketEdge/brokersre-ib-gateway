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
3. **Publish.** `publish.yml` builds `linux/amd64` and `linux/arm64` once and pushes the image
   index by digest only, so no tag points at it. Trivy then scans both platforms of that digest
   (fail on a CRITICAL or HIGH finding in OS packages that has a fixed package). Only a digest
   that passed is signed with cosign and gets the SBOM, VEX and provenance attestations; then
   `scripts/promote-tags.sh` moves the tags to it and checks that each resolves to it, and the
   workflow tags `v<version>-<channel>` and creates a release with `digests-<channel>.json`, the
   SBOM and the VEX document. What is scanned and what a tag serves are the same bytes.
4. **Rebuild.** The same pinned Gateway and IBC with refreshed OS packages, tagged
   `<version>-rYYYYMMDD`; channel and version tags re-point. `rebuild.yml` starts one in two
   cases:
   - **monthly**, both channels, whatever the scanners say;
   - **when a fix exists** (a target, not a guarantee): every day the workflow scans the
     digest each channel tag points at, both platforms, with the gate's flags.
     `scripts/rebuild-decision.sh` requests a rebuild of a channel when it has a CRITICAL or
     HIGH finding in OS packages with a fixed package, and `scripts/rebuild-issue.sh` keeps one
     issue per channel (label `os-vulnerability`) naming the CVE ids until the published image
     scans clean. So the daily job requests a rebuild within one day of such a finding
     appearing in the scanner's database; nothing measures the time to a published image, and
     no number of hours is promised.

   A person merges nothing in either case: a rebuild changes no file, and it publishes only
   after the gates of step 3. When a rebuild cannot pick a fix up (the fixed package is not
   installable from the image's package sources), its gate fails, nothing is published, the
   request is repeated daily and the issue stays open until a person decides. Findings without
   a fixed package and findings in IBKR's bundled jars never start a rebuild: a rebuild would
   change neither ([limitations](limitations.md), L08). Consumers pinning digests see a new
   digest through their own image-pin process (BrokerSRE: `image-pin.yml`, cosign-verified,
   operator-run paper regression before merge).
5. **Rollback.** Every published digest stays in the registry; pin the previous
   `digests-<channel>.json` value. Channel tags are moved back only by re-running `publish.yml`
   on the previous `versions.json` commit.

Not covered by this repository: whether a given Gateway build logs in correctly with IBC. That is
proven on the consumer's paper environment before the digest is promoted.
