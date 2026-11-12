# IBKR two-factor approval needed

Alert class `twofa_pending` · default severity critical · [all runbooks](../README.md)

## What it means

IBKR asked for a second factor and no login has completed since. The gateway cannot log in
until a person approves the prompt in IBKR Mobile. Expect it about once a week
([the weekly login](../../../README.md#the-weekly-login)) and after a start of the container.

The alert is active from the first prompt. With the gateway's defaults a prompt that nobody
answers expires after about three minutes, the gateway logs in again and IBKR prompts again,
for as long as nobody answers; the alert stays active across those repeats. It is sent again
on the escalation channels 10 and 30 minutes after the first prompt (`ESCALATE_AFTER_S`,
`ESCALATE_AGAIN_AFTER_S`).

## Check first

- The instance label in the message: is it your gateway, and was a login expected now (the
  weekly login, a start or a restart somebody ordered)?
- The telephone with IBKR Mobile for the gateway's username is at hand and online.

## What to do

1. Approve the prompt in IBKR Mobile on the device registered for the gateway's username.
2. If the prompt has already expired, wait: the gateway asks again within a few minutes
   without anybody doing anything.
3. Confirm that the phase is `logged-in` and that the `resolved` message arrives.
4. If the prompt was not expected, find out why the gateway logged in: look for a
   `gateway_exited` or `restart_storm` alert and at the events before the prompt.

## What not to do

- Do not restart the container to get a new prompt. The gateway asks again by itself; a
  restart only adds a login.
- Do not log in with the gateway's username somewhere else to "check the account": one
  session per username.
- Do not look for a setting that answers the prompt. There is none, by design.

If nobody can approve for a long time, the prompts continue. With `TWOFA_MAX_PROMPTS` set
the gateway stops asking after that many prompts and waits in phase `needs-human`
([env-vars](../../env-vars.md)).

## When it clears

- A login completes (phase `logged-in`): a `resolved` message.
- The gateway gives up (`needs-human`), exits or is stopped: the alert is closed with
  "Superseded" and the name of the alert that took over. Follow that page.

The second-factor events are recognised from the text IBC's code logs; they have not yet
been seen in a real session of this image ([limitations](../../limitations.md), L09).
