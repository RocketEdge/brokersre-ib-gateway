# IBKR login failed

Alert class `login_failed` · default severity error · [all runbooks](../README.md)

## What it means

The gateway reported a failed login (event `login_failed`) in the last 15 minutes and has
not logged in since. The gateway has not given up: its phase is not `needs-human`. When IBKR
shows its "Unrecognized Username or Password" window the gateway goes to `needs-human`
instead, this alert closes, and [needs_human](../needs_human/README.md) carries the cause.

## Check first

- The phase, and how many `login_failed` events there are:
  `docker compose ... logs --since 30m ib-gateway`.
- The lines around the failure in the raw IBC log (on the host only, it can show the
  username): `docker compose ... exec ib-gateway tail -n 50 /var/log/ibgateway/ibc/ibc.log`.

## What to do

1. If the phase is `needs-human`, continue on [that page](../needs_human/README.md).
2. If a second `login_failed` event appears, stop the gateway so that no further attempt is
   sent: `docker compose ... stop ib-gateway`.
3. Check the secret files: the username belongs to the trading mode, the password is the
   current one, and the files were written with the commands of the
   [quick start](../../../README.md#1-store-the-two-secrets-as-files).
4. Find out whether the account is locked or the password has expired. With the gateway
   stopped you can try the same username and password once in IBKR's own login; if that
   fails too, the cause is the credentials or the account, not the gateway.
5. Start the gateway once: `docker compose ... up -d ib-gateway`, and approve the second
   factor if IBKR asks.

## What not to do

- Do not restart in a loop: every start is a login attempt, and repeated failed logins can
  lock the account.
- Do not repeat a failing attempt by hand either.
- Do not set `LOGIN_LATCH=off`.

## When it clears

- A login completes.
- The phase becomes `needs-human`: this alert closes and `needs_human` takes over.
- 15 minutes pass after the last `login_failed` event. **Nothing was fixed in that case:**
  check the phase before you trust the `resolved` message.
