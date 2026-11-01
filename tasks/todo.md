# tasks/todo.md — brokersre-ib-gateway

- [x] Repository design per BrokerSRE plan section 5.3 (2026-11-01)
- [x] Dockerfile, bake, versions.json, rootfs scripts, templates, patterns, schema
- [x] bats unit suite (classify, render, healthcheck, ibc-cmd) and container test script
- [x] Workflows: ci, publish, rebuild, detect-releases, detect-ibc-release; CodeQL via GitHub default setup (advanced workflow removed 2026-11-01: default setup rejects it)
- [x] Docs: README, SECURITY, NOTICE, LICENSE, ADRs 0001-0008, env-vars, log-contract, upgrade policy, migration guide, limitations
- [x] Local build of stable (amd64) green: bats 25/25, container suite 28/28 (2026-11-01)
- [x] First push; `ci.yml` green on 2f109b8
- [x] First `publish.yml` run green (41285824630); in-job cosign verify of signature + SBOM attestation; stable sha256:a35fcafe..., latest sha256:8fb845fb...
- [ ] Operator-gated: make the GHCR package public; add `BOT_TOKEN`, `ARCHIVE_WRITE_TOKEN`, `ARCHIVE_READ_TOKEN` secrets; Phase-0 scrubbed logs to replace the synthetic fixture (limitations L01-L03)
