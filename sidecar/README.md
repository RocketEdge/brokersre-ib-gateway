# brokersre-ib-gateway-sidecar

An optional companion container for [`brokersre-ib-gateway`](../README.md). It watches one
IB Gateway container and tells people and monitoring systems what it sees:

- **follows the gateway's state** from the shared log volume (no network involved);
- **probes the API read-only**: one persistent connection, one server-time request per minute;
- **serves** `/livez`, `/readyz`, `/status` (JSON) and `/metrics` (Prometheus) on port 9810;
- **notifies humans** (Teams, Slack, Telegram, ntfy, PagerDuty, e-mail, generic webhook) and
  escalates when a person is needed, for example to approve the IBKR Mobile prompt.

It **alerts and never acts**: it places no orders, requests no market or account data,
never automates or bypasses two-factor authentication, sends nothing to the IBC command
server and never restarts the gateway. The gateway does not depend on it: stop the sidecar
and the gateway keeps running.

## Table of contents

- [How it fits](#how-it-fits)
- [Quick start](#quick-start)
- [Endpoints](#endpoints)
- [Status model](#status-model)
- [Environment variables](#environment-variables)
- [Notification channels](#notification-channels)
- [Alert classes](#alert-classes)
- [Escalation and de-duplication](#escalation-and-de-duplication)
- [Metrics](#metrics)
- [Command line](#command-line)
- [Security posture](#security-posture)
- [Limitations](#limitations)
- [Development](#development)

## How it fits

```mermaid
flowchart LR
  subgraph ns["network namespace of the ib-gateway container"]
    gw["IB Gateway API<br/>127.0.0.1:4002 paper / 4001 live"]
    sc["sidecar<br/>0.0.0.0:9810"]
  end
  vol[("log volume<br/>state/phase, events/, metrics/")]
  gw -- "writes" --> vol
  vol -- "read-only" --> sc
  sc -- "time request, client id 999" --> gw
  sc -- "HTTPS" --> ch["Teams / Slack / Telegram / ntfy / PagerDuty / SMTP / webhook"]
  mon["Prometheus, load balancer, operator"] -- "GET :9810" --> sc
```

Architecture, task model and data flow: [docs/sidecar.md](../docs/sidecar.md). Decision
record: [ADR 0010](../docs/adr/0010-sidecar-for-probe-status-and-alerts.md).

## Quick start

The sidecar shares the gateway's network namespace, so **port 9810 is published on the
`ib-gateway` service**, not on the sidecar. Use the override file next to the reference
compose file:

```bash
cd compose
mkdir -p secrets
printf '%s' 'https://prod-00.westeurope.logic.azure.com/workflows/...' > secrets/notify-teams-url
docker compose -f docker-compose.example.yml -f docker-compose.sidecar.yml up -d
curl -s http://127.0.0.1:9810/status
```

The essential part of [`compose/docker-compose.sidecar.yml`](../compose/docker-compose.sidecar.yml):

```yaml
services:
  ib-gateway:
    ports:
      - "127.0.0.1:9810:9810"   # sidecar endpoints, published here: shared network namespace
  sidecar:
    image: ghcr.io/rocketedge/brokersre-ib-gateway-sidecar:0.1.0   # pin by digest in production
    restart: unless-stopped      # required: the sidecar exits to rejoin a restarted gateway
    network_mode: "service:ib-gateway"
    read_only: true
    user: "1000:1000"
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    tmpfs: ["/tmp:size=16m"]
    environment:
      TRADING_MODE: paper
      IBGW_INSTANCE: desk-1
      TIME_ZONE: America/New_York
      NOTIFY_TEAMS_URL_FILE: /run/secrets/notify-teams-url
    secrets: [notify-teams-url]
    volumes:
      - ibgw-logs:/var/log/ibgateway:ro    # the gateway's log volume, read-only
      - sidecar-state:/var/lib/sidecar     # de-duplication state across restarts
```

Check a configuration without starting anything, and test the channels:

```bash
docker compose run --rm sidecar check-config
docker compose run --rm sidecar notify test
```

## Endpoints

All endpoints answer `GET` only; any other method is 405, any other path 404. A request
body is never parsed.

| Path | Answer |
|---|---|
| `/livez` | 200 `ok` while the sidecar's task supervisor runs. Use it for the container health check. |
| `/readyz` | 200 `ready` only when the status is `ready`; otherwise 503 and one line `<status>: <reason>`. `not_measured` is 503: absence is never healthy. |
| `/status` | JSON document `brokersre.sidecar.status.v1` ([schema](schemas/status.v1.schema.json)). Never contains a username or a full account id. |
| `/metrics` | Prometheus text exposition, see [Metrics](#metrics). |

## Status model

| Status | Meaning | `/readyz` |
|---|---|---|
| `ready` | The last time round trip succeeded, IBKR connectivity is up and no data farm is broken. | 200 |
| `degraded` | The API answers, but a data farm is broken (codes 2103/2105/2157) or IBKR connectivity was lost (1100) and not yet restored (1101/1102). | 503 |
| `down` | No API handshake, the round trip timed out, or the gateway holds half-closed API sockets for five minutes and does not answer ("zombie"). | 503 |
| `client_id_in_use` | The gateway refused the probe's client id (error 326). Another client uses it: stop that client or set `HEALTH_CLIENT_ID`. Retried every five minutes, never in a tight loop. | 503 |
| `not_measured` | The probe is disabled, the gateway is not in phase `logged-in`, or no probe has completed yet. | 503 |

The probe runs only while the gateway's phase is `logged-in`. A failed attempt closes the
connection; the next attempts back off (15 s, 30 s, 60 s ... up to 5 minutes at the default
interval) and a new login probes at once.

## Environment variables

Secrets are accepted **only as files** (`*_FILE`). The same name without `_FILE` is refused
at start, so a URL or token can never sit in a compose file or in `docker inspect` output.

| Variable | Default | Values | Effect |
|---|---|---|---|
| `TRADING_MODE` | `paper` | `paper`, `live` | Selects the API port: 4002 paper, 4001 live. Pass the gateway's value. |
| `API_PORT` | from `TRADING_MODE` | port | Overrides the API port (a gateway with a non-standard port). |
| `IBGW_INSTANCE` | `default` | letters, digits, `.`, `_`, `-` | Label of this gateway in every notification and in `/status`. Must not be an account id. |
| `TIME_ZONE` | `Etc/UTC` | IANA zone | Local time shown in notifications (next to UTC) and zone of `HEARTBEAT_TIME`. |
| `GATEWAY_LOG_DIR` | `/var/log/ibgateway` | path | Where the gateway's log volume is mounted (read-only). |
| `SIDECAR_STATE_DIR` | `/var/lib/sidecar` | path | Writable directory for the notifier's state file. When it is not writable the sidecar keeps the state in memory and says so in `/status`. |
| `SIDECAR_BIND` | `0.0.0.0` | IP address | Address the endpoints bind to, inside the shared network namespace. |
| `SIDECAR_PORT` | `9810` | port | Port of the endpoints. Publish it on the `ib-gateway` service. |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` | Verbosity of the JSON log on stdout. |
| `PROBE_ENABLED` | `yes` | `yes`, `no` | `no` turns the API probe off; the status is then always `not_measured`. |
| `HEALTH_CLIENT_ID` | `999` | 1 to 2147483647 | API client id reserved for the probe. No other API client may use it. |
| `PROBE_INTERVAL_S` | `60` | 5 to 3600 | Seconds between time round trips while healthy. |
| `PROBE_TIMEOUT_S` | `10` | 1 to 60 | Bound of the handshake and of each round trip. |
| `EXIT_WHEN_ORPHANED` | `yes` | `yes`, `no` | Exit (code 75) when the gateway container restarted and left the sidecar in its old network namespace, so the restart policy rejoins it. See [Limitations](#limitations). |
| `ESCALATE_AFTER_S` | `600` | 60 to 86400 | Delay from the first notification to the first escalation. |
| `ESCALATE_AGAIN_AFTER_S` | `1800` | above `ESCALATE_AFTER_S` | Delay from the first notification to the second, last escalation. |
| `HEARTBEAT_TIME` | unset | `HH:MM` | Enables the daily heartbeat at this local time. |
| `NOTIFY_RUNBOOK_BASE` | unset | `https://...` | Adds `runbook: <base>/<alert class>` to every notification. No credentials or query string. |
| `NOTIFY_ALLOW_HTTP` | `no` | `yes`, `no` | Allows `http://` channel URLs. Only for a receiver on a private network, such as a local ntfy. |
| `NOTIFY_CHANNELS` | all configured | list of channel names | Channels for first notifications, resolutions and heartbeats. |
| `NOTIFY_ESCALATION_CHANNELS` | all configured | list of channel names | Channels for escalations. |
| `NOTIFY_DISABLE_CLASSES` | none | list of alert classes | Alert classes that are never notified. |
| `NOTIFY_WEBHOOK_URL_FILE` | unset | path | Generic JSON webhook URL. |
| `NOTIFY_WEBHOOK_SECRET_FILE` | unset | path | Shared secret: adds `X-BrokerSRE-Signature: sha256=<HMAC-SHA256 of the body>`. |
| `NOTIFY_TEAMS_URL_FILE` | unset | path | Microsoft Teams Workflows webhook URL. |
| `NOTIFY_SLACK_URL_FILE` | unset | path | Slack incoming-webhook URL. |
| `NOTIFY_TELEGRAM_TOKEN_FILE` | unset | path | Telegram bot token. Needs `NOTIFY_TELEGRAM_CHAT_ID`. |
| `NOTIFY_TELEGRAM_CHAT_ID` | unset | chat id or `@channel` | Telegram destination (not a secret). |
| `NOTIFY_NTFY_URL_FILE` | unset | path | ntfy topic URL. |
| `NOTIFY_NTFY_TOKEN_FILE` | unset | path | ntfy access token, sent as a bearer token. |
| `NOTIFY_PAGERDUTY_KEY_FILE` | unset | path | PagerDuty Events API v2 routing key. |
| `NOTIFY_SMTP_URL_FILE` | unset | path | `smtps://user:pass@host:465` (implicit TLS) or `smtp://user:pass@host:587` (STARTTLS required). |
| `NOTIFY_SMTP_FROM` | unset | address | Sender of e-mail notifications. |
| `NOTIFY_SMTP_TO` | unset | addresses, comma separated | Recipients of e-mail notifications. |

Outbound HTTPS honours the standard `HTTPS_PROXY`, `NO_PROXY` and `SSL_CERT_FILE` variables.

## Notification channels

The notifier is **opt-in**: it runs only when at least one channel is configured.

| Channel | Name | What is sent |
|---|---|---|
| Generic webhook | `webhook` | JSON `brokersre.sidecar.alert.v1`, optionally HMAC-signed. |
| Microsoft Teams | `teams` | An Adaptive Card in the Workflows envelope ("When a Teams webhook request is received"). Office 365 connectors are retired and are not supported. |
| Slack | `slack` | Text plus Block Kit sections. |
| Telegram | `telegram` | Plain text through the Bot API. |
| ntfy | `ntfy` | Text with title, priority (urgent for critical), tag and click-through headers. |
| PagerDuty | `pagerduty` | `trigger` with a `dedup_key`; `resolve` when the condition clears. Heartbeats are not sent. |
| E-mail | `smtp` | Plain-text mail over TLS. |

**Secret files.** Each file holds one line. A UTF-8 byte-order mark and trailing CR/LF are
stripped, so a file written on Windows works. UTF-16 (what PowerShell's `>` writes), NUL
bytes, an empty file and a value with a line break inside are refused with a message that
names the variable and never the content. On Windows write the file with:

```powershell
Set-Content -Path secrets\notify-teams-url -Value $url -Encoding utf8NoBOM -NoNewline
```

**What a message contains.** Instance label, alert class, severity, gateway phase, API
status, UTC time and the local time of `TIME_ZONE`, a short instruction, and the runbook
link when configured. **Never** a username, a password, a webhook URL, a token or a full
account id: messages are assembled from fixed text and numbers only, and a test plants
canary strings in every input and checks every channel's payload for them.

URLs must be `https://`. Redirects are not followed. Each send has a 10 second timeout and
up to three retries with exponential back-off; each channel has its own bounded queue, so a
channel that is down delays only itself. Failures are counted per channel in `/status` and
in `ibgw_notify_failures_total`.

## Alert classes

| Class | Default severity | Fires when | What to do |
|---|---|---|---|
| `twofa_pending` | critical | From the first second-factor prompt until a login completes. It stays active while the gateway times out a prompt and logs in again to prompt anew (phase `login` between two prompts). | Approve the IBKR Mobile prompt now. Nothing approves it for you. |
| `needs_human` | critical | The phase is `needs-human`. | Open the gateway screen (VNC) or its log and resolve what it waits on. |
| `login_failed` | error | The gateway reported a failed login in the last 15 minutes and has not logged in since. Silent while the phase is `needs-human` (that alert carries the cause). | Check the username and password secrets and whether the account is locked. |
| `existing_session` | error | The phase is `existing-session`. | Log out the other session or give this gateway its own username. |
| `login_stalled` | error | The gateway reports `login_stalled` (its own `LOGIN_STALL_S`) and has not reported `login_resumed`. | Look at the gateway screen and log. |
| `unknown_window` | warning | The gateway reported a dialog it does not recognise while not logged in. | Handle the dialog and report its title. |
| `gateway_exited` | critical | The phase is `exited` (IBC ended on its own), or the gateway's boot id changed without a `shutdown_requested` event (the container was killed or crashed; reported for 15 minutes). | Read the container log, then start the container when it is safe (new login and 2FA). |
| `gateway_stopped` | info | The phase is `stopping` or `stopped`: a shutdown was requested. | Nothing, if the stop was intended. |
| `api_unhealthy` | error | The status has been `down`, `degraded` or `client_id_in_use` for 5 minutes, outside IBKR's reset windows. | Read `/status` for the reason. Do not restart blindly. |
| `restart_storm` | error | 3 or more gateway starts within 30 minutes. | Stop the restart loop and read the first error. |
| `resource_alert` | error | The gateway reports `memory_high` (until `memory_ok`), or an `oom_kill` in the last 15 minutes. | Raise the memory limit or lower the Java heap. |
| `disk_low` | warning | The gateway reports `disk_low` and has not reported `disk_ok`. | Free space on the log or settings volume. |
| `clock_skew` | warning | The host clock provably differs from IBKR time by more than 1 second. | Fix time synchronisation on the host. |
| `gateway_silent` | error | No event and no metrics sample for 5 minutes while the volume is mounted and the gateway is not stopped. | Check that the gateway container runs and the volume is mounted. |
| `heartbeat` | info | Once a day at `HEARTBEAT_TIME` while no alert is active. | Nothing. A missing heartbeat means the sidecar is down or an alert is active. |
| `resolved` (a message kind) | info | A condition that was notified has cleared. | Nothing. |

IBKR reset windows, during which API disconnects are normal and `api_unhealthy` stays
quiet: North America 00:15-01:45 ET, Europe 06:25-07:45 CET, Asia 04:45-06:05 and
20:15-21:15 HKT, Saturday 00:00-02:00 ET.

A condition that cannot be decided (a value was not measured, a duration has not elapsed
yet) neither raises nor resolves an alert.

For a stalled login, low disk space and memory pressure the gateway is the single source of
truth: it reports each as a pair of events (`login_stalled`/`login_resumed`,
`disk_low`/`disk_ok`, `memory_high`/`memory_ok`) from its own thresholds (`LOGIN_STALL_S`,
`DISK_MIN_FREE_PCT`, `MEM_HIGH_PCT` of the gateway image), and the sidecar only relays the
pair. It has no threshold of its own for them, so the two cannot disagree.

## Escalation and de-duplication

- A new condition is notified at once on `NOTIFY_CHANNELS`.
- `twofa_pending` and `needs_human` are repeated on `NOTIFY_ESCALATION_CHANNELS`
  `ESCALATE_AFTER_S` (10 minutes) and once more `ESCALATE_AGAIN_AFTER_S` (30 minutes)
  after the condition began, which for a second factor is the FIRST prompt. Then the
  ladder is silent until the condition clears.
- When the gateway gives up on a second factor (`needs-human`) or exits, the
  `twofa_pending` alert is closed with a message that says "Superseded", not "Resolved",
  and names the alert that took over.
- A class is announced at most once per 15 minutes. A condition that flaps is held back
  and announced when the 15 minutes end, if it is still active.
- An alert counts as notified only when at least one channel accepted the message. Until
  then it is sent again (after 30 s, doubling to every 5 minutes) for as long as the
  condition lasts; `/status` shows `notified: false` and the number of failed attempts.
- When a notified condition clears, a `resolved` message goes to every channel that heard
  about it. A condition nobody was told about clears silently.
- The state, including what was not delivered yet, is kept in `notifier-state.json` under
  `SIDECAR_STATE_DIR` (written atomically). After a restart a delivered alert is not
  repeated and an undelivered one is announced, not forgotten.

## Metrics

Metric names are frozen. A value that was not measured is **omitted**, never exported as 0.

| Metric | Type | Meaning |
|---|---|---|
| `ibgw_phase{phase}` | gauge | 1 for the current gateway phase. |
| `ibgw_api_ready` | gauge | 1 when `ready`, 0 when `degraded`, `down` or `client_id_in_use`; absent when `not_measured`. |
| `ibgw_api_rtt_seconds` | gauge | Round-trip time of the last successful time request. |
| `ibgw_clock_offset_seconds` | gauge | IBKR time minus host time (IBKR reports whole seconds). |
| `ibgw_api_close_wait_sockets` | gauge | Half-closed sockets on the API port. |
| `ibgw_boots_30m` | gauge | Gateway container starts in the last 30 minutes. |
| `ibgw_memory_working_set_bytes`, `ibgw_memory_limit_bytes` | gauge | Gateway container memory (re-exported from the gateway's sampler). |
| `ibgw_oom_kills_total` | counter | Out-of-memory kills in the gateway container. |
| `ibgw_cpu_usage_seconds_total`, `ibgw_cpu_throttled_seconds_total` | counter | Gateway container CPU. |
| `ibgw_pids`, `ibgw_java_rss_bytes`, `ibgw_java_threads`, `ibgw_open_fds` | gauge | Gateway process figures. |
| `ibgw_notify_failures_total{channel}` | counter | Notifications given up on after all retries. |
| `ibgw_notify_sent_total{channel}` | counter | Notifications delivered. |
| `ibgw_notify_dropped_total{channel}` | counter | Notifications discarded because the channel's outbox was full. |
| `ibgw_notify_undelivered_alerts` | gauge | Active alerts that no channel has accepted yet. They are sent again with a capped back-off. |
| `ibgw_sidecar_task_restarts_total{task}` | counter | Restarts of a sidecar task after a crash. |
| `ibgw_sidecar_info{version}` | gauge | Constant 1. |

Sampler values are re-exported only while the gateway's sample is younger than two minutes.

## Command line

```text
brokersre-sidecar run                     run the sidecar (the image's default command)
brokersre-sidecar status                  print /status; exit 0 only when ready (1 not ready, 3 not reachable)
brokersre-sidecar healthcheck             exit 0 when /livez answers 200 (the image's HEALTHCHECK)
brokersre-sidecar check-config            validate the configuration without starting
brokersre-sidecar notify test             send a test message to every configured channel
brokersre-sidecar print-schema status     print the JSON Schema of /status
brokersre-sidecar support-bundle --out D  write a redacted tar.gz of recent state into directory D
```

The support bundle holds the last event and metrics lines (contract fields only), the
phase, the status document, versions and non-secret settings. Account ids are cut to their
last three characters; of the raw IBC log only the lines marked `IBC:` are included, after
redaction. Review it before sharing.

## Security posture

- uid 1000, read-only root file system, `cap_drop: [ALL]`, `no-new-privileges`; the only
  writable paths are a tmpfs `/tmp` and the state volume.
- No Docker socket, no privileged mode, no shell access into the gateway.
- The gateway's log volume is mounted read-only; the settings volume is not mounted at all.
- Credentials only as files; never in the environment, the image, the log or `/status`.
- The API connection is read-only by construction: the code references a single API
  request (the server time), and a test scans the package for any other.
- The image's base and the `uv` build tool are pinned by digest; Python dependencies are
  locked with hashes in `uv.lock`.

## Limitations

- **Gateway container restarts.** A container that shares another container's network
  namespace keeps the old namespace when that container restarts. The sidecar detects this
  (the gateway's listening sockets are gone while its log volume shows it alive) and exits
  with code 75 so that its restart policy starts it in the new namespace. This needs
  `restart: unless-stopped` (or `always`/`on-failure`) on the sidecar. A restart of the
  Gateway process inside its container, such as IBC's daily auto-restart, is not affected.
- **Log contract v2.** Events, metrics, boot counting and several alert classes need the
  gateway's `events/` and `metrics/` feeds. With a gateway that writes only `state/phase`
  those values are reported as not measured and their alerts stay silent.
- **Clock skew resolution.** IBKR answers the time request in whole seconds, so
  `clock_skew` fires only when the difference is provably above one second (in practice
  from about 1.5 to 2 seconds).
- **Not verified against a live gateway.** The probe is tested against an in-process
  server that speaks the IB API wire protocol, and against a scriptable fake; nothing in
  this repository logs in to IBKR. Channel payloads are tested against local receivers,
  not against the real services.
- **One gateway per sidecar.**

## Development

```bash
cd sidecar
uv sync                               # Python 3.14, everything pinned in uv.lock
uv run ruff check . && uv run black --check . && uv run mypy
uv run pytest --cov                   # coverage gate: 90 %
docker build -t brokersre-ib-gateway-sidecar:dev .
IMAGE=brokersre-ib-gateway-sidecar:dev tests/container/run.sh
```

Layers and import rules are in [docs/sidecar.md](../docs/sidecar.md) and enforced by
`tests/test_architecture.py`.

Interactive Brokers, IBKR, IB Gateway and Trader Workstation are trademarks of Interactive Brokers LLC. This project is not affiliated with, endorsed by or sponsored by Interactive Brokers.
