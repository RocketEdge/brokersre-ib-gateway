# ADR 0009 — Stable IB Gateway updates merge themselves; latest and re-uploads stay human

- **Status:** Accepted (2026-11-11, owner decision); supersedes the "human merge" step of
  [upgrade-policy.md](../upgrade-policy.md) for the `stable` channel

## Context

IBKR serves each channel from an unversioned URL that only ever returns the newest build. On
2026-11-11 IBKR moved `stable` to 10.50.1g; the pinned 10.50.1f was never archived, so every
build of `main` failed until a human merged the bump. On 2026-11-05 IBKR also replaced the
10.51.1e installers without changing the version label. Consumers (BrokerSRE) pin image digests
and promote a new digest only after their own paper regression, so a published image reaches no
production system by itself.

## Decision

`detect-releases.yml` runs daily and hands the policy to `scripts/release-decision.sh`:

- a new version opens a pull request. Auto-merge is enabled, once and only when the run creates
  the pull request, if the version is on `stable`, sorts higher than the pin (`sort -V`) and
  both installers changed; the pull request then merges once the required checks (`lint`,
  `build-test`: build, bats, offline container tests, Trivy gate) pass, and `publish.yml`
  publishes;
- anything else with a new label (a `latest` version, a lower version, an unchanged installer)
  waits for a human (CI builds and tests `stable` only);
- different bytes under the pinned version are archived under their own release and open one
  `ibkr-reupload` issue per set of bytes; nothing changes.

Installers are archived privately, and CI and publish pre-fetch them, keeping only copies that
match the pin (`scripts/prefetch-installers.sh`).

Stopping it: a human disables auto-merge on one pull request (the daily run never re-enables
it), or sets the repository variable `STABLE_AUTOMERGE` to `false` to stop every automatic merge.

## Consequences

### Positive

`main` stays buildable and current without a daily human step; a silent IBKR re-upload is
caught instead of breaking or slipping into a build.

### Negative

A bad IBKR `stable` build that passes the offline tests is published publicly without review
(the tests never log in). Consumers are protected by digest pinning, not by this repository.
Auto-merge needs the `BOT_TOKEN` secret: GitHub does not start CI by itself for a pull request
opened with `GITHUB_TOKEN`, and a merge made with it would not start `publish.yml`.

## Revisit trigger

An auto-merged `stable` build is found broken after publishing (the offline tests passed but a
consumer's paper regression failed), or CI starts building `latest`, which would allow
auto-merging that channel too.
