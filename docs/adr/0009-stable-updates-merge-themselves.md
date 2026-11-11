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

- a new version opens a pull request; on `stable` it enables auto-merge, so the pull request
  merges once the required checks (`lint`, `build-test`: build, bats, offline container tests,
  Trivy gate) pass, and `publish.yml` publishes;
- a new `latest` version waits for a human (CI builds and tests `stable` only);
- different bytes under the pinned version open an `ibkr-reupload` issue and change nothing.

Installers are archived privately for every new version, and CI and publish pre-fetch them,
keeping only copies that match the pin (`scripts/prefetch-installers.sh`).

## Consequences

### Positive

`main` stays buildable and current without a daily human step; a silent IBKR re-upload is
caught instead of breaking or slipping into a build.

### Negative

A bad IBKR `stable` build that passes the offline tests is published publicly without review
(the tests never log in). Consumers are protected by digest pinning, not by this repository.
Auto-merge needs the `BOT_TOKEN` secret: a pull request opened with `GITHUB_TOKEN` runs no CI,
and a merge made with it would not start `publish.yml`.

## Revisit trigger

An auto-merged `stable` build is found broken after publishing (the offline tests passed but a
consumer's paper regression failed), or CI starts building `latest`, which would allow
auto-merging that channel too.
