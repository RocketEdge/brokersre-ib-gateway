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
`config_conflict`, `config_invalid`, `secret_unreadable`, `dirs_not_writable`, `jts_ini_written`,
`jts_ini_kept`, `xvfb_started`, `xvfb_failed`, `vnc_disabled`, `vnc_enabled`, `socat_started`,
`ibc_starting`, `ibc_not_launched`, `ibc_exited`, `shutdown_requested`, `shutdown_complete`.
(`config_invalid` and `dirs_not_writable` were emitted by the code before this document listed
them; they are not new.) Events classified from IBC's output
(`rootfs/etc/brokersre/ibc-patterns.tsv`):

| Event | Level | Phase set | Source line pattern | Evidence |
|---|---|---|---|---|
| `twofa_initiated` | warn | `2fa-pending` | `IBC: Second Factor Authentication initiated` | IBC sources |
| `twofa_dialog` | warn | `2fa-pending` | `detected dialog entitled: Second Factor Authentication; event=Opened\|Activated` | IBC sources |
| `login_completed` | info | `logged-in` | `IBC: Login has completed` | IBC sources |
| `login_failed` | error | `login` | `IBC: Login failed` | IBC sources |
| `login_failed_dialog` | error | `login` | `detected dialog entitled: Unrecognized Username or Password; event=Opened` | real log, 10.50.1g |
| `existing_session` | warn | `existing-session` | `detected dialog entitled: Existing session detected; event=Opened` | IBC sources |
| `relogin_required` | warn | `login` | `detected dialog entitled: Re-login is required` / `Re-login to session`, `event=Opened` | IBC sources |
| `daily_restart` | info | `restarting` | `IBC: autorestart file found` | IBC sources |
| `login_dialog` | info | `login` | `IBC: Login dialog WINDOW_OPENED` | real log, 10.50.1g |
| `ibc_version` | info | `login` | `IBC: version` | real log, 10.50.1g |

"Real log" means the line was seen in this image's IBC output and is covered by
`tests/fixtures/ibc-real-failed-login.log`; "IBC sources" rows are not yet confirmed by a real
log ([limitations](limitations.md), L01). IBC reports every dialog as `event=Opened`, then
`Activated`, then `Focused`; dialog rows match `Opened` only, so one dialog is one event. The
event names, levels and phases are unchanged from the first release of contract v1; only the
matching became exact.

## Shared log volume `/var/log/ibgateway`

| Path | Writer | Content |
|---|---|---|
| `state/phase` | entrypoint + classifier (atomic rename) | one token: `starting`, `login`, `2fa-pending`, `logged-in`, `restarting`, `existing-session`, `stopping`, `stopped`, `exited`, `test-mode` |
| `ibc/ibc.log` | `rotating-append.sh` behind IBC's stdout | raw IBC log, appended across restarts |
| `jts/ibgateway.current.log`, `jts/launcher.log` | `tail-gateway-logs.sh` | mirror of the Gateway's own logs from the settings volume (`launcher.log` seen with 10.50.1g; the `ibgateway.*.log` source name is unverified, L03) |
| `jts/.mirror/` | `tail-gateway-logs.sh` | the mirror's own position records; not part of the contract |

Each of the three log files is size-capped: when it would grow past `LOG_MAX_BYTES` (default
10 MiB) it is renamed to `<name>.1` (older generations shift to `.2`, `.3`; `LOG_KEEP`, default
3, are kept) and a new file is started. Rotation happens between two lines, never inside one.
A reader must follow the file by name and reopen it when the inode changes. The mirror copies
each source line once: a container restart continues after the last line already mirrored.

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
