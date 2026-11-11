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
| `AUTO_RESTART_TIME` | empty | e.g. `11:45 PM` | IBC `AutoRestartTime` in the Gateway's time zone. Keep outside IBKR reset windows (NA 00:15-01:45 ET, Europe 06:25-07:45 CET, APAC 04:45-06:05 and 20:15-21:15 HKT). |
| `AUTO_LOGOFF_TIME` | empty | e.g. `11:45 PM` | IBC `AutoLogoffTime`. Prefer restart over logoff: a logoff forces a daily login. |
| `TIME_ZONE` | `Etc/UTC` | IANA zone | Written to `jts.ini` `[Logon] TimeZone` on first start only. |
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
| `LOG_MAX_BYTES` | `10485760` | bytes | Size at which `ibc/ibc.log` and the mirrored Gateway logs are rotated. |
| `LOG_KEEP` | `3` | count | Rotated generations kept per log file (`.1` is the newest). |

Build arguments (not runtime): `JAVA_HEAP_MB` (default 768) replaces gnzsnz's runtime
`JAVA_HEAP_SIZE`, because the Gateway directory is read-only at runtime.

## Secret files

A `_FILE` secret holds one value as UTF-8 text. Files written on Windows are accepted as they
come: a trailing CR/LF and a UTF-8 byte-order mark are removed. A UTF-16 file (what Windows
PowerShell 5.1 `>` and `Out-File` write) or an empty file stops the container with the event
`secret_unreadable`, because a corrupted password sent to IBKR counts as a failed login.
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
