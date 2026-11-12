# Architecture Decision Records

| ADR | Title | Status |
|---|---|---|
| [0001](0001-derive-from-gnzsnz-under-mit.md) | Derive from gnzsnz/ib-gateway-docker under MIT with attribution | Accepted (2026-11-01) |
| [0002](0002-single-dockerfile-bake-versions-json.md) | One Dockerfile + docker-bake + versions.json; every input verified by SHA-256 | Accepted (2026-11-01) |
| [0003](0003-no-sudo-read-only-filesystem.md) | No sudo, uid 1000, read-only root filesystem | Accepted (2026-11-01) |
| [0004](0004-remove-ssh-dual-mode-tws.md) | Remove SSH tunnel, dual mode and the TWS desktop image | Accepted (2026-11-01) |
| [0005](0005-command-server-on-loopback.md) | IBC command server enabled on loopback for a namespace-sharing sidecar | Accepted (2026-11-01) |
| [0006](0006-json-log-contract-and-phase-file.md) | JSON log contract on stdout, raw logs on a volume, phase file | Accepted (2026-11-01) |
| [0007](0007-ibc-from-rocketedge-fork-no-ibkr-redistribution.md) | IBC from the RocketEdge fork; IBKR binaries never redistributed | Accepted (2026-11-01) |
| [0008](0008-tagging-and-rebuild-policy.md) | Tagging: channel + version tags, no Docker latest, monthly -rDATE rebuilds | Accepted (2026-11-01) |
| [0009](0009-stable-updates-merge-themselves.md) | Stable IB Gateway updates merge themselves; latest and re-uploads stay human | Accepted (2026-11-11) |
| [0010](0010-sidecar-for-probe-status-and-alerts.md) | A separate sidecar image for the API probe, the status API and alerts | Proposed (2026-11-12) |
| [0012](0012-azure-log-analytics-pack.md) | Azure Log Analytics pack: Vector on the host, a Direct data collection rule, redaction before shipping | Proposed (2026-11-12) |
| [0013](0013-log-contract-v2-needs-human-gated-relay.md) | Log contract v2: events on the volume, a `needs-human` phase and a relay that follows the login | Accepted (2026-11-12) |
| [0014](0014-paper-login-qualification.md) | A paper-login qualification that is not a test: one attended login, behind a reviewer | Accepted (2026-11-12) |
| [0016](0016-rejected-login-latch.md) | A rejected login is not repeated: the latch on the log volume | Accepted (2026-11-12) |

Numbers 0011 and 0015 belong to records that arrive with their own changes (the Windows host
kit, the login controller succession).

Template: Status, Context (with sources), Decision, Consequences (positive and negative),
Revisit trigger. Never renumber or delete; supersede with a new record.
