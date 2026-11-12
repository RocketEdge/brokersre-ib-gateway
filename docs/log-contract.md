# Log contract v2 (authoritative copy)

Consumers: a sidecar that shares the log volume, a log shipper, the BrokerSRE agent
(`RocketEdge/brokersre`) and anyone who reads `docker logs`. A change to any item below is a
new contract version, announced in `docs/changes.md` before an image carrying it is tagged
`stable`. Decision record: [ADR 0013](adr/0013-log-contract-v2-needs-human-gated-relay.md).

**What changed from v1** (a v1 reader that ignores unknown keys keeps working):

- every event is also written to `events/events.jsonl` on the volume, and gains `boot_id`,
  `seq` and, for a few events, `data`;
- new phase `needs-human`; new events (table below); new event sources `doctor` and `metrics`;
- `metrics/metrics.jsonl` (resource samples);
- every log file on the volume is size-capped and rotated;
- the relay on 4003/4004 listens only while the phase is `logged-in`.

## Events: one JSON object per line, on stdout and in `events/events.jsonl`

```json
{"ts":"2026-11-12T01:02:03.456Z","src":"ibc","level":"info","event":"login_completed","msg":"login_completed","boot_id":"0123456789abcdef","seq":17}
```

Schema: [`schemas/log-event.v2.schema.json`](../schemas/log-event.v2.schema.json)
(v1: [`log-event.v1.schema.json`](../schemas/log-event.v1.schema.json)).

| Key | Meaning |
|---|---|
| `ts` | UTC, ISO-8601 with milliseconds |
| `src` | `entrypoint`, `ibc`, `xvfb`, `vnc`, `socat`, `healthcheck`, `doctor`, `metrics` |
| `level` | `info`, `warn`, `error` |
| `event` | snake_case name (tables below) |
| `msg` | text for a person. Never a raw IBC or Gateway line, never a credential |
| `boot_id` | 16 hex characters: one container start. Also in `state/boot_id` |
| `seq` | 1, 2, 3 … per `boot_id`, across every process of the container, without gaps. A gap means a lost event |
| `data` | optional flat object of strings (see the schema); never a credential, username or full account id |

The two copies are the identical line. The stdout line is never lost: when the volume cannot be
written, the event is printed without `seq` (and without `boot_id` when none is known yet). A
reader must ignore keys and events it does not know.

### Events of the entrypoint and its helpers

`container_start` (data: versions, channel, mode, instance), `config_rendered` and
`config_custom` (data: `config_hash`, a fingerprint of the non-secret configuration),
`config_missing`, `config_conflict`, `config_invalid`, `secret_unreadable`, `dirs_not_writable`,
`jts_ini_written`, `jts_ini_kept`, `xvfb_started`, `xvfb_failed`, `vnc_disabled`, `vnc_enabled`,
`socat_started`, `relay_opened`, `relay_closed`, `ibc_starting`, `ibc_not_launched`,
`ibc_exited`, `needs_human`, `shutdown_requested`, `shutdown_complete`.

### Events classified from IBC's output (`rootfs/etc/brokersre/ibc-patterns.tsv`)

| Event | Level | Phase set | Source line pattern | Evidence |
|---|---|---|---|---|
| `twofa_initiated` | warn | `2fa-pending` | `IBC: Second Factor Authentication initiated` | IBC source |
| `twofa_dialog` | warn | `2fa-pending` | `detected dialog entitled: Second Factor Authentication; event=Opened\|Activated` | IBC source |
| `twofa_timeout` | warn | `login` | `IBC: Re-login after second factor authentication timeout in` | IBC source |
| `login_completed` | info | `logged-in` | `IBC: Login has completed` | IBC source |
| `login_failed` | error | `login` | `IBC: Login failed` | IBC source |
| `login_failed_dialog` | error | `needs-human` | `detected dialog entitled: Unrecognized Username or Password; event=Opened` | real log, 10.50.1g |
| `existing_session` | warn | `existing-session` | `detected dialog entitled: Existing session detected; event=Opened` | IBC source |
| `relogin_required` | warn | `login` | `detected dialog entitled: Re-login is required; event=Opened`, or `IBC: Re-login to session` | IBC source |
| `daily_restart` | info | `restarting` | `IBC: autorestart file found` | IBC source |
| `login_dialog` | info | `login` | `IBC: Login dialog WINDOW_OPENED` | real log, 10.50.1g |
| `ibc_version` | info | `login` | `IBC: version` | real log, 10.50.1g |
| `unknown_window` | warn | (none) | a window opened whose title is in neither this table nor `known-windows.txt` | real mechanism; list from IBC source |
| `needs_human` | error | `needs-human` | more than `TWOFA_MAX_PROMPTS` second-factor prompts without a login (off by default) | IBC source |

"Real log" means the line was seen in this image's IBC output and is covered by
`tests/fixtures/ibc-real-failed-login.log`. "IBC source" means the exact text IBC 3.24.2's code
logs, not yet confirmed by a real log: no login has succeeded on this image yet
([limitations](limitations.md), L01). IBC reports every window as `event=Opened`, then
`Activated`, then `Focused`; dialog rows match `Opened` only, so one dialog is one event.

### Events of the preflight (`src` = `doctor`)

| Event | Level | When |
|---|---|---|
| `doctor_ok` | info | once after the preflight when no check failed; msg `preflight passed: <n> passed, <n> warned, <n> skipped` |
| `doctor_failed` | error (warn with `DOCTOR_STRICT=no`) | once per failed check, which means a condition under which the gateway cannot work; msg `<check>: <detail> (fix: <fix>)`; the container exits 1 unless `DOCTOR_STRICT=no`. Never emitted for a defect of the preflight itself |
| `doctor_warning` | warn | once per warning of a check other than `ignored_variables` (for example a `TIME_ZONE` that cannot be verified, a heap above 75 % of the memory limit, free disk below `DISK_MIN_FREE_PCT`), once per check that crashed, and once when the preflight could not run at all. Never stops a start |
| `config_deprecated` | warn (error with `STRICT_ENV=yes`) | once per ignored or unknown variable; msg `ignored_variables: <NAME> is ignored: <reason> (fix: <replacement>)` |

Check names: `trading_mode`, `credentials`, `secret_values`, `auto_restart_time`,
`restart_window`, `time_zone`, `ignored_variables`, `writable_dirs`, `heap_vs_memory`,
`read_only_api`, `relay_exposure`, `disk_space`, and with `--online` `ibkr_reachable`.
`doctor --json` prints one document:
`{"schema":"brokersre.doctor.v1","result":"pass|warn|fail","checks":[{"name","status","detail","fix"}]}`.
Exit statuses of `doctor`: 0 no check failed, 1 a check failed, 2 usage error, 70 doctor itself
aborted. At a container start it also writes its verdict (`fail`, `warn` or `pass`) to
`${DOCTOR_RESULT_FILE}`; the entrypoint stops the start only for status 1 together with the
verdict `fail`.

### Events of the resource sampler (`src` = `metrics`)

Each is emitted once when its condition starts and once when it ends.

| Event | Level | When |
|---|---|---|
| `oom_kill` | error | the kernel's OOM-kill counter of this container rose (also reported on the last sample at shutdown) |
| `memory_high` / `memory_ok` | warn / info | working set above `MEM_HIGH_PCT` of the memory limit for `MEM_HIGH_FOR_S`; cleared |
| `disk_low` / `disk_ok` | warn / info | free space of the log or the settings volume below `DISK_MIN_FREE_PCT`; back above |
| `login_stalled` / `login_resumed` | warn / info | phase `login` without interruption for more than `LOGIN_STALL_S`; left `login` afterwards |

## Phase file `state/phase`

One token and a newline, written atomically (temporary file and rename).

| Phase | Meaning |
|---|---|
| `starting` | container start, before IBC |
| `login` | IBC is logging in (also after a second-factor timeout or a re-login request) |
| `2fa-pending` | IBKR waits for a second factor; a person must approve it |
| `logged-in` | login completed; the API is expected to be usable |
| `restarting` | daily restart in progress |
| `existing-session` | another session of the same username exists |
| `needs-human` | nothing will change until a person acts: IBKR rejected the login, or the second factor was not approved after `TWOFA_MAX_PROMPTS` prompts. The container stays up and unhealthy; it does not exit, so a restart policy cannot start another login |
| `stopping`, `stopped` | graceful shutdown |
| `exited` | IBC exited on its own |
| `test-mode` | `IBC_LAUNCH=no` |

A reader must treat a missing file or an unknown token as "unknown", never as healthy.

**The phase is a snapshot, not a duration.** With the defaults an unanswered second-factor
prompt times out after about three minutes, IBC logs in again (`twofa_timeout`, phase `login`
for a few seconds) and prompts again (`twofa_initiated`, phase `2fa-pending`), for as long as
nobody answers. A consumer that waits for "phase `2fa-pending` for more than N minutes" never
fires. Decide "a person is needed" from the events: a `twofa_initiated` without a
`login_completed` after it (same `boot_id`).

## Shared log volume `/var/log/ibgateway`

| Path | Writer | Content |
|---|---|---|
| `state/phase`, `state/boot_id` | entrypoint, classifier | see above |
| `events/events.jsonl` | every component, through `log.sh` | the events, identical to stdout |
| `metrics/metrics.jsonl` | `sampler.sh` | one resource sample per line (below) |
| `ibc/ibc.log` | `rotating-append.sh` behind IBC's stdout | raw IBC log, appended across restarts |
| `jts/ibgateway.current.log`, `jts/launcher.log` | `tail-gateway-logs.sh` | mirror of the Gateway's own logs from the settings volume (`launcher.log` seen with 10.50.1g; the `ibgateway.*.log` source name is unverified, L03) |
| `events/.seq`, `events/.lock`, `jts/.mirror/` | internal | not part of the contract |

Every `*.jsonl` and `*.log` file above is size-capped: before a line would take it past
`LOG_MAX_BYTES` (default 10 MiB) the file is renamed to `<name>.1` (older generations shift to
`.2`, `.3`; `LOG_KEEP`, default 3, are kept) and a new file is started. Rotation happens between
two lines, never inside one. A reader follows a file by name, reopens it when the inode changes,
and tolerates a partial last line. The mirror copies each source line once: a container restart
continues after the last line already mirrored.

The volume is mounted read-only into sidecars. The raw logs (`ibc/`, `jts/`) may contain the
IBKR username; they never leave the host unredacted. Events and metrics never contain it.

## Metrics file `metrics/metrics.jsonl`

One JSON object per line every `SAMPLE_INTERVAL_S` (default 30 s), read from the container's
own cgroup v2 files and `/proc` (no Docker socket). One more sample is written when the
container stops or IBC exits, outside the rhythm and without the disk keys.

| Key | Source | Notes |
|---|---|---|
| `ts`, `src`, `boot_id`, `seq`, `phase` | always present | `src` is `metrics`. `seq` starts at 1 when the sampler starts and counts every sample; it is a separate series from the events' `seq`. `phase` is the token in `state/phase`, or `unknown` |
| `mem_working_set_bytes` | `memory.current` minus `inactive_file` of `memory.stat` | the kubelet's working set |
| `mem_limit_bytes` | `memory.max` | absent when the container has no memory limit |
| `oom_kills` | `oom_kill` line of `memory.events` | counter since container start |
| `cpu_usage_usec`, `cpu_throttled_usec` | `cpu.stat` | counters |
| `pids` | `pids.current` | processes and threads |
| `java_rss_bytes`, `java_threads`, `open_fds` | `/proc/<pid>/status` and `/proc/<pid>/fd` of the Gateway JVM | absent when no JVM runs |
| `api_close_wait_sockets` | `/proc/net/tcp` and `tcp6`: sockets in CLOSE_WAIT on the API port | above zero for minutes means clients disconnected and the Gateway did not close its side |
| `disk_free_bytes_logs`, `disk_free_bytes_settings`, `disk_total_bytes_logs`, `disk_total_bytes_settings` | `df` of the two volumes | |

**A key that could not be measured is absent, never 0.** A reader must not treat a missing key
as a healthy value.

## Network

| Port | Listener | When |
|---|---|---|
| `127.0.0.1:4001` (live) / `4002` (paper) | IB Gateway API, loopback only | after login |
| `4003` (live) / `4004` (paper) | relay to the API port | only while the phase is `logged-in` (`RELAY_MODE=gated`, default); always with `RELAY_MODE=always` or `IBC_LAUNCH=no` |
| `127.0.0.1:7462` | IBC command server | while IBC runs (`IBC_COMMAND_SERVER_PORT=0` disables) |
| `127.0.0.1:5900` | VNC | only when a VNC password is set |

A client that gets "connection refused" on the relay port should retry: the Gateway is not
logged in yet, or is restarting.

## IBC command server

`127.0.0.1:${IBC_COMMAND_SERVER_PORT}` (default 7462; `0` disables). Commands: `STOP`,
`RESTART`, `PAUSE`, `RECONNECTDATA`, `RECONNECTACCOUNT`, `ENABLEAPI`; plain text, CRLF
terminated; `EXIT` closes the session. `ibc-cmd <COMMAND>` wraps this inside the container.

## Health

`HEALTHCHECK` exit 0 iff the IBC/Gateway process is alive and `127.0.0.1:<API_PORT>` accepts a
TCP connection (4001 live, 4002 paper). `--start-period=300s`. With `IBC_LAUNCH=no` health means
the relay listens. Nothing in the image restarts the Gateway on an unhealthy result.
