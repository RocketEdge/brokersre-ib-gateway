# The gateway API is not healthy

Alert class `api_unhealthy` · default severity error · [all runbooks](../README.md)

## What it means

The gateway is logged in, but the sidecar's read-only probe has reported the status `down`,
`degraded` or `client_id_in_use` for five minutes. The message carries the reason. A lost
link to IBKR inside a [reset window](../../../sidecar/README.md#ibkr-reset-windows) of
`IBKR_REGION` is excused; a failed API handshake and a Gateway that holds half-closed
sockets never are.

## Check first

The status document says which case it is (`status`, `reason`, `in_reset_window`):
`docker compose ... exec sidecar brokersre-sidecar status`.

| Status and reason | Meaning |
|---|---|
| `degraded`, IBKR connectivity lost (code 1100) and not restored | The Gateway lost its link to IBKR: IBKR's side or the host's network. |
| `degraded`, a data farm is broken (codes 2103, 2105, 2157) | A market-data or historical-data farm is disconnected. |
| `down`, no API handshake or a time request without an answer | The Gateway does not serve the API on the probed port. |
| `down`, half-closed API sockets for five minutes ("zombie") | Clients disconnected and the Gateway did not close its side and no longer answers. |
| `client_id_in_use` | Another API client uses the probe's client id (`HEALTH_CLIENT_ID`, 999 by default). |

## What to do

1. **Connectivity lost.** Check IBKR's status page
   (<https://brokerage.ibkr.com/en/software/systemStatus.php>) and the host's network
   (`docker compose ... run --rm ib-gateway doctor --online`, check `ibkr_reachable`). The
   Gateway reconnects by itself. If this was IBKR's daily reset, set `IBKR_REGION` in the
   sidecar so that the window is excused next time.
2. **Data farm broken.** Usually IBKR's side; it often ends by itself. IBC's command
   `RECONNECTDATA` asks the Gateway to reconnect its data farms without a new login
   ([log contract](../../log-contract.md#ibc-command-server)).
3. **No handshake.** Check that the sidecar's `TRADING_MODE` is the gateway's (it selects
   the port), and look for `relay_refused` events: a `RELAY_ALLOW_CIDR` that does not
   include the sidecar's address closes the probe's connections.
4. **Zombie, or no answer although everything above is in order.** Only a restart of the
   Gateway ends it, and that is a new login. Plan it, have the person who approves the
   second factor ready, then `docker compose ... restart ib-gateway`.
5. **Client id in use.** Stop the client that uses the id, or give the probe another one
   with `HEALTH_CLIENT_ID`. The probe retries every five minutes.

## What not to do

- Do not restart blindly: a restart forces a new login and does nothing for a fault on
  IBKR's side.
- Do not turn the probe off to silence the alert: the status is then `not_measured`, which
  is not healthy either.

## When it clears

When the probe reports `ready` again. The probe runs only while the phase is `logged-in`.
