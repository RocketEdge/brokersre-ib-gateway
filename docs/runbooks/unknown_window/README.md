# The gateway shows a dialog that is not recognised

Alert class `unknown_window` · default severity warning · [all runbooks](../README.md)

## What it means

In the last 15 minutes the Gateway opened a window whose title is on none of the gateway's
lists, and the gateway is not logged in. The window may block the login, or it may be
harmless: the lists come from IBC's source and one real start, so a harmless window that is
missing from them raises this alert too ([limitations](../../limitations.md), L10).

## Check first

- The phase. `logged-in` means the window did not block anything.
- The title (on the host only, the log can show the username):
  `docker compose ... exec ib-gateway grep -a entitled /var/log/ibgateway/ibc/ibc.log`,
  last lines.
- A picture of the screen, when the gateway runs with `SCREENSHOTS=yes`: the event
  `screenshot_saved` names a file under `screens/` on the log volume (XWD format; GIMP and
  ImageMagick open it).

## What to do

1. If the phase reaches `logged-in`, nothing is blocked. Go to step 3.
2. If the phase stays `login`, the window blocks the login and
   [login_stalled](../login_stalled/README.md) follows after `LOGIN_STALL_S`. Look at the
   window, and if needed handle it, through the [break-glass console](../../console.md): off
   unless the gateway was started with it, view-only unless `VNC_VIEW_ONLY=no`, and each of
   those two changes takes a new start of the container, which is a new login.
3. Report the title of the window (the title only) in an issue of this repository, so that
   it can be classified and stops alerting.

## What not to do

- Do not restart at once: a harmless window needs nothing, and every start is a login.
- Do not attach the screenshot or the raw IBC log to the report.

## When it clears

When a login completes, or 15 minutes after the last such window. The second case does not
mean the window is gone: check the phase.
