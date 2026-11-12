# Environment variables

| Variable | Default | Values | Effect and rationale |
|---|---|---|---|
| `TWS_USERID`, `TWS_USERID_FILE` | required (one of) | string / path | IBKR username. Prefer the `_FILE` form (Docker secret). Setting both is refused. |
| `TWS_PASSWORD`, `TWS_PASSWORD_FILE` | required (one of) | string / path | IBKR password. Prefer `_FILE`. Rendered into `/run/brokersre/config.ini` (tmpfs, 0600), then unset. |
| `TRADING_MODE` | `paper` | `live`, `paper` | Selects the IBC trading mode and the API port (4001/4002) and relay port (4003/4004). `both` is not supported: one brokerage session per container. |
| `READ_ONLY_API` | `yes` | `yes`, `no` | IBC `ReadOnlyApi`. Least privilege by default; a host that places orders sets `no`. |
| `TWOFA_TIMEOUT_ACTION` | `restart` | `restart`, `exit` | `--on2fatimeout` for IBC: after a 2FA timeout, restart (re-prompt) rather than exit. |
| `RELOGIN_AFTER_TWOFA_TIMEOUT` | `yes` | `yes`, `no` | IBC `ReloginAfterSecondFactorAuthenticationTimeout`. |
| `TWOFA_EXIT_INTERVAL` | `60` | seconds | IBC `SecondFactorAuthenticationExitInterval`. |
| `TWOFA_DEVICE` | empty | IBC device name | IBC `SecondFactorDevice` when the account has several. |
| `EXISTING_SESSION_DETECTED_ACTION` | `primary` | `primary`, `primaryoverride`, `secondary`, `manual` | IBC behaviour when another session of the same username exists. |
| `AUTO_RESTART_TIME` | empty | `hh:mm AM` or `hh:mm PM` with a two-digit hour, e.g. `11:45 PM`, `01:05 AM` | IBC `AutoRestartTime` in the Gateway's time zone. IBC parses it with the pattern `hh:mm a` and does not apply a value in another form (`1:05 AM` is rejected), so the preflight refuses such a value. Keep outside IBKR reset windows (NA 00:15-01:45 ET, Europe 06:25-07:45 CET, APAC 04:45-06:05 and 20:15-21:15 HKT). |
| `AUTO_LOGOFF_TIME` | empty | same form | IBC `AutoLogoffTime`. Prefer restart over logoff: a logoff forces a daily login. IBC ignores it when `AUTO_RESTART_TIME` is also set. |
| `TIME_ZONE` | `Etc/UTC` | IANA zone | Written to `jts.ini` `[Logon] TimeZone` on first start only. The preflight warns, and never fails, when the value is not `UTC`, `GMT` or an `Area/City` name: the image has no time-zone database to verify it. |
| `TWS_SETTINGS_PATH` | `/home/ibgateway/Jts/settings` | path | Gateway settings directory (persist as a volume). |
| `TWS_ACCEPT_INCOMING` | `reject` | `accept`, `reject`, `manual` | IBC `AcceptIncomingConnectionAction`. Reject: API clients must be in Trusted IPs. |
| `ALLOW_BLIND_TRADING` | `no` | `yes`, `no` | IBC `AllowBlindTrading`. |
| `BYPASS_WARNING` | `yes` | `yes`, `no` | Sets every IBC `Bypass*` precaution flag so API orders are not held by dialogs. |
| `SAVE_TWS_SETTINGS` | empty | IBC schedule | IBC `SaveTwsSettingsAt`. |
| `TWS_MASTER_CLIENT_ID` | empty | integer | IBC `OverrideTwsMasterClientID`. |
| `IBC_COMMAND_SERVER_PORT` | `7462` | port, `0` | IBC command server bound to `127.0.0.1`; `0` disables. |
| `IBC_SUPPRESS_INFO_MESSAGES` | `no` | `yes`, `no` | IBC `SuppressInfoMessages`; `no` keeps the lines the classifier needs. |
| `VNC_SERVER_PASSWORD`, `VNC_SERVER_PASSWORD_FILE` | unset | string / path | Enables x11vnc on `127.0.0.1:5900` (break-glass). Unset keeps VNC off. |
| `CUSTOM_CONFIG` | `no` | `yes`, `no` | `yes`: use an operator-mounted `/run/brokersre/config.ini`; nothing is rendered. |
| `IBC_LAUNCH` | `yes` | `yes`, `no` | `no`: start Xvfb, relay and log mirror but not IBC (offline tests). |
| `SOCAT_RESTART_DELAY` | `5` | seconds | Pause before the relay is restarted after it exits. |
| `JAVA_USER_HOME` | `<TWS_SETTINGS_PATH>/.java-home` | path without spaces | The Gateway JVM's `user.home`. The Gateway writes its hardware id (`.hwid`) and Java caches there during login and cannot log in when it is not writable. On the settings volume by default so it survives a restart. |
| `_JAVA_OPTIONS` | unset | JVM options | Extra options for the Gateway JVM. Appended after the image's own `-Duser.home=...`, so a value given here wins. Options written to `ibgateway.vmoptions` or `JAVA_TOOL_OPTIONS` do not reach the JVM (IBC drops them). |
| `JAVA_HEAP_MB` | unset (the image's 768) | megabytes (256 or more), `auto` | Gateway heap, set at run time through `_JAVA_OPTIONS`. `auto`: half of the container memory limit, between 768 and 4096; without a limit the built-in heap stays. The preflight fails when the heap is as large as the container memory limit and warns above 75 % of it; without a limit it skips the comparison. |
| `LOG_MAX_BYTES` | `10485760` | bytes | Size at which each log file on the volume is rotated (`ibc/ibc.log`, the mirrored Gateway logs, `events/events.jsonl`, `metrics/metrics.jsonl`). |
| `LOG_KEEP` | `3` | count | Rotated generations kept per log file (`.1` is the newest). |
| `RELAY_MODE` | `gated` | `gated`, `always` | `gated`: the relay on 4003/4004 listens only while the phase is `logged-in`. `always`: from container start. |
| `RELAY_ALLOW_CIDR` | (unset) | one IPv4 network, for example `172.18.0.0/16` | The relay serves peers in this network only; any other peer is closed without a byte of the API and reported (`relay_refused`). Exactly one network; anything else stops the start (`config_invalid`). The relay judges the address it sees: a connection that arrives through a published port can show Docker's bridge gateway instead of the client (observed on Docker Desktop), so this is for clients on a shared Docker network and never replaces the host's port binding and firewall. |
| `RELAY_REFUSED_REPORT_S` | `60` | seconds | The first refused peer is reported at once; further ones are counted and reported at most once per this interval. |
| `TWOFA_MAX_PROMPTS` | `0` | count | `0`: IBC re-prompts for the second factor without limit. `n`: after more than `n` prompts without a login the gateway stops IBC and stays up in phase `needs-human`. It never answers a prompt. |
| `IBGW_INSTANCE` | `default` | label | Name of this gateway in the `container_start` event; give each gateway its own when you run several. |
| `DOCTOR_STRICT` | `yes` | `yes`, `no` | `no`: a failed preflight check (`doctor`) is logged as `doctor_failed` with level `warn` and the container starts anyway. By default a failed check stops the start with exit 1. A check fails only when the gateway cannot work or would send a wrong login: `TRADING_MODE` is not `live` or `paper`; a credential is missing, given twice or in an unusable secret file; a restart or logoff time IBC rejects; a directory the gateway cannot write; a heap as large as the container memory limit; less than 16 MiB free on the log or settings volume; an ignored variable when `STRICT_ENV=yes`. Everything else is a warning. A defect of the preflight itself never stops a start. |
| `DOCTOR_RESULT_FILE` | `<RUN_DIR>/doctor.result` | path | Where the preflight of a container start writes its verdict: one line, `fail`, `warn` or `pass`. The entrypoint stops the start only when the preflight exits 1 and this file says `fail`, so an abort of the preflight is never mistaken for a failed check. |
| `STRICT_ENV` | `no` | `yes`, `no` | `yes`: a variable the image ignores (carried over from gnzsnz, or a likely typo of a known name) fails the preflight instead of warning (`config_deprecated`). |
| `SAMPLE_INTERVAL_S` | `30` | seconds, 1 or more | Pause between two resource samples in `metrics/metrics.jsonl`. |
| `DISK_MIN_FREE_PCT` | `10` | 0-100 | `disk_low` (and a preflight warning) when the log or the settings volume has less than this share free; `disk_ok` when it is back. It never stops a start; independently of it, the preflight fails when less than 16 MiB is free. |
| `LOGIN_STALL_S` | `300` | seconds | `login_stalled` when the phase has been `login` without interruption for longer than this; `login_resumed` when it then leaves `login`. |
| `MEM_HIGH_PCT` | `85` | 0-100 | `memory_high` threshold: working set as a share of the container memory limit. Never fires without a limit. |
| `MEM_HIGH_FOR_S` | `600` | seconds | How long the working set must stay above `MEM_HIGH_PCT` before `memory_high`; `memory_ok` when it is no longer above. |
| `HEALTHCHECK_API` | `port` | `port`, `handshake` | What the Docker health check requires of the API: an open port (default), or also an answer to the TWS API handshake (`api-handshake.sh`), which catches a Gateway that still accepts connections but no longer responds. The handshake takes no client id and makes no request. Opt-in until its effect on a logged-in Gateway has been observed over a real session. |

`JAVA_HEAP_MB` is also a build argument of the Dockerfile (the heap written into the image,
768 by default); the run-time variable wins.

## Secret files

A `_FILE` secret holds one value as UTF-8 text. Files written on Windows are accepted as they
come: a trailing CR/LF and a UTF-8 byte-order mark are removed. A UTF-16 file (what Windows
PowerShell 5.1 `>` and `Out-File` write) or an empty file stops the container before any login:
the preflight reports it as `doctor_failed` (check `credentials`), and with `DOCTOR_STRICT=no`
the reader itself still refuses it with `secret_unreadable`. A corrupted password sent to IBKR
would count as a failed login.
Characters inside the value are kept exactly, including spaces, `$`, `\` and non-ASCII text;
the username and password are escaped for IBC's `.properties` parser when `config.ini` is
rendered.

## Read-only root filesystem

The image runs with `read_only: true`. The paths it writes are:

| Path | Mount | Notes |
|---|---|---|
| `/tmp` | tmpfs | Xvfb socket and `java.io.tmpdir`. World-writable by default (mode 1777). |
| `/run/brokersre` | tmpfs with `uid=1000,gid=1000,mode=0750` | Rendered `config.ini` (mode 0600). A tmpfs is root-owned 0755 unless the mount options say otherwise, and the gateway runs as uid 1000. |
| `/home/ibgateway/Jts/settings` | named volume (or a tmpfs with the same uid/gid options) | Gateway settings, including the auto-restart session token, and `.java-home` (the JVM's `user.home`: hardware id, Java and Mesa caches). Without a writable `user.home` the Gateway cannot log in. |
| `/var/log/ibgateway` | named volume | Raw IBC and Gateway logs and the phase file, shared read-only with sidecars. |

The entrypoint checks these paths before starting anything and exits with the structured stdout
event `dirs_not_writable` when one is not writable by uid 1000.
