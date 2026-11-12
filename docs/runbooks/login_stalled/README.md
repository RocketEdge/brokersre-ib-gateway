# The gateway login has not completed

Alert class `login_stalled` · default severity error · [all runbooks](../README.md)

## What it means

The gateway reports that its phase has been `login` without interruption for longer than its
`LOGIN_STALL_S` (300 seconds by default). The usual causes are a window on the Gateway's
screen that IBC does not handle, or IBKR's login servers not answering. The threshold is the
gateway's own; the sidecar only relays the pair `login_stalled` / `login_resumed`.

## Check first

- The last window IBC saw (on the host only, the log can show the username):
  `docker compose ... exec ib-gateway grep -a entitled /var/log/ibgateway/ibc/ibc.log`,
  last lines.
- An `unknown_window` event shortly before: `docker compose ... logs --since 30m ib-gateway`.
- Whether IBKR's login servers are reachable from the container:
  `docker compose ... run --rm ib-gateway doctor --online` (check `ibkr_reachable`).
- A picture of the screen, when the gateway runs with `SCREENSHOTS=yes`: the event
  `screenshot_saved` names a file under `screens/` on the log volume. Copy it out with
  `docker compose ... cp ib-gateway:/var/log/ibgateway/screens ./screens` and open it with
  GIMP or ImageMagick. It can show the username: keep it on the host.

## What to do

1. IBKR is not reachable: fix the host's network or wait for IBKR
   (<https://brokerage.ibkr.com/en/software/systemStatus.php>). The gateway keeps trying.
2. A window blocks the login: handle it on the Gateway's screen through VNC. VNC is off
   unless the gateway was started with `VNC_SERVER_PASSWORD_FILE`; turning it on takes a new
   start of the container, which is a new login.
3. Report the title of the window (the title only) in an issue of this repository, so that
   it can be classified.
4. If neither applies, restart once, with the person who approves the second factor ready:
   `docker compose ... restart ib-gateway`.

## What not to do

- Do not restart repeatedly: every start is a login, and the window will be there again.
- Do not publish the screenshot or the raw IBC log.

## When it clears

- The gateway reports `login_resumed` (the phase left `login`) and is logged in or waiting
  for a second factor.
- The gateway gave up, exited or was stopped: the alert is closed with "Superseded" and the
  name of the alert that took over. Follow that page.
