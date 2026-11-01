# Migrating from gnzsnz/ib-gateway-docker

| gnzsnz | brokersre-ib-gateway | Note |
|---|---|---|
| `TWS_USERID`, `TWS_PASSWORD`, `TWS_PASSWORD_FILE` | same (`TWS_USERID_FILE` added) | Prefer `_FILE` for both. |
| `TRADING_MODE=live\|paper\|both` | `live\|paper` only | One brokerage session per container; run two containers (two usernames) for live + paper. |
| `TWS_USERID_PAPER`, `TWS_PASSWORD_PAPER*` | removed | Consequence of dropping `both`. |
| `READ_ONLY_API` (unset) | default `yes` | Least privilege by default. |
| `TWOFA_TIMEOUT_ACTION=exit` default | default `restart` | Re-prompt instead of giving up. |
| `RELOGIN_AFTER_TWOFA_TIMEOUT`, `TWOFA_EXIT_INTERVAL`, `TWOFA_DEVICE`, `EXISTING_SESSION_DETECTED_ACTION`, `AUTO_RESTART_TIME`, `AUTO_LOGOFF_TIME`, `TIME_ZONE`, `TWS_SETTINGS_PATH`, `BYPASS_WARNING`, `TWS_ACCEPT_INCOMING`, `ALLOW_BLIND_TRADING`, `SAVE_TWS_SETTINGS`, `TWS_MASTER_CLIENT_ID`, `CUSTOM_CONFIG` | same names | Defaults differ where noted in `env-vars.md`. |
| `TWS_COLD_RESTART` | removed | Not needed with daily `AUTO_RESTART_TIME`. |
| `JAVA_HEAP_SIZE` (runtime) | build arg `JAVA_HEAP_MB` | The Gateway directory is read-only at runtime. |
| `VNC_SERVER_PASSWORD` | same + `_FILE`; bound to `127.0.0.1` | gnzsnz bound VNC to all interfaces. |
| `SSH_TUNNEL`, `SSH_*` | removed | A sidecar sharing the network namespace or a private network replaces the tunnel. |
| `START_SCRIPTS`, `X_SCRIPTS`, `IBC_SCRIPTS` | removed in v1 | Hook directories may return if a concrete need appears (ADR 0004). |
| `CommandServerPort=0` (hard-coded) | `IBC_COMMAND_SERVER_PORT=7462` on loopback | `ibc-cmd` wrapper. |
| no `HEALTHCHECK` | `HEALTHCHECK` + `state/phase` | Unhealthy until logged in. |
| plain-text stdout | JSON log contract on stdout; raw logs on the `/var/log/ibgateway` volume | |
| `sudo` for `ibgateway` | none | |
| image `ghcr.io/gnzsnz/ib-gateway` | `ghcr.io/rocketedge/brokersre-ib-gateway` | Same tag scheme: `stable`, `latest`, `10.50`, `10.50.1f`. Pin digests. |
| `tws-rdesktop` image | not provided | |
