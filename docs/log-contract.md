# Log contract v1 (authoritative copy)

Consumers: the BrokerSRE agent (`RocketEdge/brokersre`) and any sidecar. A change to any item
below is a new contract version, announced in `docs/changes.md` and mirrored in the agent's
`docs/log-contract.md` before an image carrying it is tagged `stable`.

## Container stdout: one JSON object per line

```json
{"ts": "2026-11-01T09:03:07.000Z", "src": "ibc", "level": "info", "event": "login_completed", "msg": "login_completed"}
```

Schema: [`schemas/log-event.v1.schema.json`](../schemas/log-event.v1.schema.json). `src` is one of
`entrypoint`, `ibc`, `xvfb`, `vnc`, `socat`, `healthcheck`; `level` is `info`, `warn` or `error`.
`msg` is never a raw IBC or Gateway line and never a credential. Events emitted by the
entrypoint: `container_start`, `config_rendered`, `config_custom`, `config_missing`,
`config_conflict`, `secret_unreadable`, `jts_ini_written`, `jts_ini_kept`, `xvfb_started`,
`xvfb_failed`, `vnc_disabled`, `vnc_enabled`, `socat_started`, `ibc_starting`, `ibc_not_launched`,
`ibc_exited`, `shutdown_requested`, `shutdown_complete`. Events classified from IBC's output
(`rootfs/etc/brokersre/ibc-patterns.tsv`):

| Event | Level | Phase set | Source line pattern (IBC 3.24.x wording, VERIFY in Phase 0) |
|---|---|---|---|
| `twofa_initiated` | warn | `2fa-pending` | `IBC: Second Factor Authentication initiated` |
| `twofa_dialog` | warn | `2fa-pending` | `detected dialog entitled: Second Factor Authentication; event=Opened\|Activated` |
| `login_completed` | info | `logged-in` | `IBC: Login has completed` |
| `login_failed` | error | `login` | `IBC: Login failed` |
| `login_failed_dialog` | error | `login` | `detected dialog entitled: Unrecognized Username or Password` |
| `existing_session` | warn | `existing-session` | `detected dialog entitled: Existing session detected` |
| `relogin_required` | warn | `login` | `detected dialog entitled: Re-login is required` / `Re-login to session` |
| `daily_restart` | info | `restarting` | `IBC: autorestart file found` |
| `login_dialog` | info | `login` | `detected frame entitled: IB Gateway\|Login; event=Opened` |
| `ibc_version` | info | `login` | `IBC: version` |

## Shared log volume `/var/log/ibgateway`

| Path | Writer | Content |
|---|---|---|
| `state/phase` | entrypoint + classifier (atomic rename) | one token: `starting`, `login`, `2fa-pending`, `logged-in`, `restarting`, `existing-session`, `stopping`, `stopped`, `exited`, `test-mode` |
| `ibc/ibc.log` | `tee` of IBC stdout | raw IBC log, appended across restarts |
| `jts/ibgateway.current.log`, `jts/launcher.log` | `tail-gateway-logs.sh` | mirror of the Gateway's own logs from the settings volume (file names VERIFY in Phase 0) |

The volume is mounted read-only into sidecars. It may contain the IBKR username (IBC echoes
dialog contents); it never leaves the host unredacted.

## IBC command server

`127.0.0.1:${IBC_COMMAND_SERVER_PORT}` (default 7462; `0` disables). Commands: `STOP`,
`RESTART`, `PAUSE`, `RECONNECTDATA`, `RECONNECTACCOUNT`, `ENABLEAPI`; plain text, CRLF
terminated; `EXIT` closes the session. `ibc-cmd <COMMAND>` wraps this inside the container.

## Health

`HEALTHCHECK` exit 0 iff the IBC/Gateway process is alive and `127.0.0.1:<API_PORT>` accepts a
TCP connection (4001 live, 4002 paper). `--start-period=300s`. With `IBC_LAUNCH=no` health means
the socat relay listens.
