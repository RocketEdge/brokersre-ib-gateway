# tasks/todo.md — brokersre-ib-gateway

- [x] Repository design per BrokerSRE plan section 5.3 (2026-11-01)
- [x] Dockerfile, bake, versions.json, rootfs scripts, templates, patterns, schema
- [x] bats unit suite (classify, render, healthcheck, ibc-cmd) and container test script
- [x] Workflows: ci, publish, rebuild, detect-releases, detect-ibc-release, codeql
- [x] Docs: README, SECURITY, NOTICE, LICENSE, ADRs 0001-0008, env-vars, log-contract, upgrade policy, migration guide, limitations
- [ ] Local build of stable (amd64) green; bats and container tests green
- [ ] First push; `ci.yml` green
- [ ] First `publish.yml` run; cosign verify of the stable digest
- [ ] Operator-gated: make the GHCR package public; add `BOT_TOKEN`, `ARCHIVE_WRITE_TOKEN`, `ARCHIVE_READ_TOKEN` secrets; Phase-0 scrubbed logs to replace the synthetic fixture (limitations L01-L03)
