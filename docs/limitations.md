# Limitations

| # | Limitation | What resolves it |
|---|---|---|
| L01 | Dialog titles and log wording in `ibc-patterns.tsv` come from IBC 3.24.x documentation and public logs, not from this image on Gateway 10.50.1f; the test fixture is synthetic and marked. | Scrubbed real logs from a paper login (BrokerSRE Phase 0); replace the fixture and adjust patterns. |
| L02 | Gateway write paths after a real login are unknown, so `read_only: true` may need an extra tmpfs or volume (observed candidates: Java preferences, redirected to `/run/brokersre/prefs`; `java.io.tmpdir`, redirected to `/tmp`). | Paper login on a read-only container; record the paths. |
| L03 | The Gateway's own log file names mirrored by `tail-gateway-logs.sh` (`launcher.log`, `ibgateway.*.log`) are from observation of 10.x and unverified on 10.50.1f. | Same as L02. |
| L04 | Nothing in CI logs in (by design), so a Gateway UI change that breaks IBC's login automation is only detected by a consumer's paper environment. | BrokerSRE regression on the paper sandbox before promoting a digest. |
| L05 | arm64 images rely on Ubuntu's `openjdk-25-jre` because IBKR ships no ARM JRE; untested on real hardware. | An arm64 paper login. |
| L06 | IBKR's installer URL is unversioned and unsigned; the SHA-256 is RocketEdge-computed at detection time, so it proves consistency with what RocketEdge saw, not authenticity from IBKR. | IBKR publishing checksums or signatures. |
| L07 | The first `publish.yml` run needs the GHCR package made public by the owner (the workflow token cannot change package visibility). | Owner action in the Packages UI. |
