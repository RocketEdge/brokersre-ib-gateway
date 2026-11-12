# Runbooks: one page per alert

The optional [sidecar](../../sidecar/README.md) names an alert class in every notification.
Each class has a page here: what the alert means, what to check first, what to do, what not
to do, and when it clears. Set

```yaml
      NOTIFY_RUNBOOK_BASE: https://github.com/RocketEdge/brokersre-ib-gateway/tree/main/docs/runbooks
```

in the sidecar's environment and every notification carries the address of its page
(`runbook: <base>/<alert class>`). To keep the pages in step with the version you run, or to
add your own names and telephone numbers, copy this folder to your own wiki and point the
variable there: the sidecar only appends `/<alert class>` to the base.

## Table of contents

- [Three rules that hold on every page](#three-rules-that-hold-on-every-page)
- [Commands the pages use](#commands-the-pages-use)
- [The pages](#the-pages)
- [What these pages are based on](#what-these-pages-are-based-on)

## Three rules that hold on every page

1. **Every start of the gateway container is a login.** A restart never "just fixes it": it
   ends the session and sends the credentials again, and IBKR may ask for a second factor
   that a person must approve. Read first, restart last, and have the person who approves
   the prompt at hand before you restart.
2. **Nothing approves a second factor for you.** Neither the image nor the sidecar answers,
   types or bypasses a prompt, and no setting changes that.
3. **One session per username.** A login with the gateway's username anywhere else (Client
   Portal, Trader Workstation, another gateway) ends or blocks the gateway's session. Do
   your own checking with a different username.

## Commands the pages use

`docker compose ...` stands for your compose command with its files; for the reference setup
that is `docker compose -f compose/docker-compose.example.yml -f compose/docker-compose.sidecar.yml`.
The gateway's service is `ib-gateway`, the sidecar's is `sidecar`.

| To see | Command |
|---|---|
| The gateway's phase | `docker compose ... exec ib-gateway cat /var/log/ibgateway/state/phase` |
| The gateway's recent events | `docker compose ... logs --since 30m ib-gateway` |
| Whether the containers run | `docker compose ... ps` |
| The sidecar's status document | `docker compose ... exec sidecar brokersre-sidecar status`, or `GET http://127.0.0.1:9810/status` on the host |
| Every preflight check | `docker compose ... run --rm ib-gateway doctor` (starts no login) |
| The raw IBC log | `docker compose ... exec ib-gateway tail -n 50 /var/log/ibgateway/ibc/ibc.log` |

The raw IBC log and a screenshot can show the username. Read them on the host; do not paste
them into a chat, a ticket or an issue. Events, metrics and the status document never
contain it.

## The pages

| Alert class | Default severity | Page |
|---|---|---|
| `twofa_pending` | critical | [IBKR two-factor approval needed](twofa_pending/README.md) |
| `needs_human` | critical | [The gateway is waiting for a human](needs_human/README.md) |
| `login_failed` | error | [IBKR login failed](login_failed/README.md) |
| `existing_session` | error | [Another session is using this IBKR username](existing_session/README.md) |
| `login_stalled` | error | [The gateway login has not completed](login_stalled/README.md) |
| `unknown_window` | warning | [The gateway shows a dialog that is not recognised](unknown_window/README.md) |
| `gateway_exited` | critical | [The gateway stopped unexpectedly](gateway_exited/README.md) |
| `gateway_stopped` | info | [The gateway was stopped on request](gateway_stopped/README.md) |
| `api_unhealthy` | error | [The gateway API is not healthy](api_unhealthy/README.md) |
| `restart_storm` | error | [The gateway keeps restarting](restart_storm/README.md) |
| `resource_alert` | error | [Gateway memory pressure or an out-of-memory kill](resource_alert/README.md) |
| `disk_low` | warning | [Disk space is low on a gateway volume](disk_low/README.md) |
| `clock_skew` | warning | [The host clock differs from IBKR time](clock_skew/README.md) |
| `gateway_silent` | error | [The gateway has gone silent](gateway_silent/README.md) |
| `volume_missing` | error | [The sidecar cannot read the gateway's log volume](volume_missing/README.md) |
| `heartbeat` | info | [Daily heartbeat](heartbeat/README.md) |

A message of the kind `resolved` closes an alert that was announced. A message that says
"Superseded" closes it too, but names the alert that took over: nothing recovered, follow
the page of that alert. When and how alerts are repeated is described under
[Escalation and de-duplication](../../sidecar/README.md#escalation-and-de-duplication).

## What these pages are based on

Each page is written from what the code of the image and of the sidecar does: the conditions
are the ones in the sidecar's rules, the events and phases the ones in the
[log contract](../log-contract.md). They are not yet based on incidents: the second-factor
path and a logged-in session have not been observed with this image
([limitations](../limitations.md), L09 and L20). A test of the sidecar fails when an alert
class has no page here or a page has no class.

Interactive Brokers, IBKR, IB Gateway and Trader Workstation are trademarks of Interactive Brokers LLC. This project is not affiliated with, endorsed by or sponsored by Interactive Brokers.
