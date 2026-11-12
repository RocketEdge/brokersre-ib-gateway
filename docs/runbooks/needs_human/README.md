# The gateway is waiting for a human

Alert class `needs_human` · default severity critical · [all runbooks](../README.md)

## What it means

The gateway's phase is `needs-human`: nothing will change until a person acts. The container
stays up and reports unhealthy on purpose; it does not exit, so a restart policy cannot send
another login. The message names the cause when it is known. There are three:

| Event before the phase | Cause |
|---|---|
| `login_failed_dialog` | IBKR rejected the username or password in this start. |
| `login_rejected_latched` | IBKR rejected these credentials at an earlier start and the secret files have not changed since. This start did not log in at all (the rejected-login latch, [ADR 0016](../../adr/0016-rejected-login-latch.md)). |
| `needs_human` | The second factor was not approved after `TWOFA_MAX_PROMPTS` prompts. |

The alert is sent again on the escalation channels 10 and 30 minutes after it began.

## Check first

- Which of the three events came last:
  `docker compose ... logs --since 2h ib-gateway`.
- The preflight shows the latch and when IBKR refused:
  `docker compose ... run --rm ib-gateway doctor` (check `login_latch`).

## What to do

**IBKR rejected the credentials** (`login_failed_dialog` or `login_rejected_latched`):

1. Find out which value is wrong: the username belongs to the trading mode (a paper username
   with `TRADING_MODE=paper`, a live one with `live`), the password is the current one, the
   account is not locked.
2. Write the two secret files again with the commands of the
   [quick start](../../../README.md#1-store-the-two-secrets-as-files). A rewritten file
   releases the latch.
3. Start the gateway anew: `docker compose ... up -d --force-recreate ib-gateway`.
4. Approve the second factor if IBKR asks, and confirm the phase `logged-in`.

Credentials passed as plain variables have no file to rewrite: correct them and start once
with `LOGIN_LATCH=clear`, then remove that setting again.

**The second factor was not approved** (`needs_human`):

1. Make sure the person who approves the prompt is ready.
2. Restart the container: `docker compose ... restart ib-gateway`.
3. Approve the prompt.

## What not to do

- Do not restart without changing anything. With the latch the gateway holds again without
  a login; without it every restart sends the rejected credentials again, and repeated
  failed logins can lock the account.
- Do not set `LOGIN_LATCH=off` to get past this alert.
- Do not delete `state/login-rejected` or the log volume to "reset" the gateway: the record
  is what protects the account.

## When it clears

When the phase leaves `needs-human`, which takes a new start of the container. A `resolved`
message follows.
