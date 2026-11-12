# Another session is using this IBKR username

Alert class `existing_session` · default severity error · [all runbooks](../README.md)

## What it means

The gateway's phase is `existing-session`: at login IBKR reported that the same username is
already logged in somewhere else. IBKR allows one session per username, so either the other
session or the gateway loses. What IBC does with IBKR's window is set by
`EXISTING_SESSION_DETECTED_ACTION` ([env-vars](../../env-vars.md)).

## Check first

Who else uses the username:

- a person in Client Portal or Trader Workstation;
- another gateway: a standby, a second copy of this compose project, a test on a laptop;
- a tool of a vendor or an administrator that logs in with the same username.

`docker compose ... ps` on every host that could run a gateway shows a forgotten copy.

## What to do

1. End the other session, or decide that it keeps the username and stop this gateway.
2. For good: give the gateway a username of its own and keep people on another one
   ([going live](../../../README.md#going-live)). A standby gateway needs a second username
   too.
3. When the other session is gone and the phase does not move on by itself, restart the
   gateway once: `docker compose ... restart ib-gateway`. Approve the second factor if IBKR
   asks.

## What not to do

- Do not restart the gateway while the other session is still there: the two sessions end
  each other in turn, and every start is a login.
- Do not start a second gateway with the same username "as a backup".
  `scripts/check-compose-usernames.sh` refuses that for the gateways of one host.

## When it clears

When the phase leaves `existing-session`: a login completes, or the gateway is stopped.
