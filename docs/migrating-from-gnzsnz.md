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
| `JAVA_HEAP_SIZE` (runtime, megabytes) | `JAVA_HEAP_MB` (runtime; megabytes or `auto`) | Renamed. `JAVA_HEAP_SIZE` is ignored and the preflight says so (`config_deprecated`). |
| `VNC_SERVER_PASSWORD` | same + `_FILE`; bound to `127.0.0.1` | gnzsnz bound VNC to all interfaces. |
| `SSH_TUNNEL`, `SSH_*` | removed | A sidecar sharing the network namespace or a private network replaces the tunnel. |
| `START_SCRIPTS`, `X_SCRIPTS`, `IBC_SCRIPTS` | removed in v1 | Hook directories may return if a concrete need appears (ADR 0004). |
| `CommandServerPort=0` (hard-coded) | `IBC_COMMAND_SERVER_PORT=7462` on loopback | `ibc-cmd` wrapper. |
| no `HEALTHCHECK` | `HEALTHCHECK` + `state/phase` | Unhealthy until logged in. |
| plain-text stdout | JSON log contract on stdout; raw logs on the `/var/log/ibgateway` volume | |
| `sudo` for `ibgateway` | none | |
| image `ghcr.io/gnzsnz/ib-gateway` | `ghcr.io/rocketedge/brokersre-ib-gateway` | Same tag scheme: `stable`, `latest`, `10.50`, `10.50.1f`. Pin digests. |
| `tws-rdesktop` image | not provided | |
| relay listens from container start | relay listens only while logged in | `RELAY_MODE=always` restores the old behaviour. A client that gets "connection refused" retries. |

Run `docker compose run --rm ib-gateway doctor` with your existing environment: it lists every
variable from this table that the image ignores, with its replacement. `STRICT_ENV=yes` makes
such a variable stop the start instead of warning.

## Converting a `.env` file

`scripts/migrate-from-gnzsnz.sh` applies the table above to a gnzsnz `.env` file (bash only; it
runs in Git Bash on Windows too):

```bash
scripts/migrate-from-gnzsnz.sh old.env > new.env
```

- stdout is the converted file, line for line; stderr is the report: what was dropped, renamed
  or is unknown, and the defaults that differ. The report never prints a value.
- `TRADING_MODE=both` is refused (exit 1, nothing converted): split the file and use
  `compose/docker-compose.multi.yml`.
- `TWS_USERID` and `TWS_PASSWORD` lines are carried over unchanged. Move them into secret files
  (README, Quick start) and delete the lines: the reference compose sets the `_FILE` variables,
  and the container refuses to start when both forms are set.
- With `compose/docker-compose.example.yml`, start with
  `docker compose --env-file new.env -f compose/docker-compose.example.yml up -d`: that applies
  `TRADING_MODE`, `READ_ONLY_API`, `AUTO_RESTART_TIME` and `TIME_ZONE`. Every other variable
  reaches the container only when the service also lists the file under `env_file:`.
- Exit status: 0 converted, 1 refused, 2 usage error.
