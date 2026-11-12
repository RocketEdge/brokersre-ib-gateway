# ADR 0017 — The break-glass console: view-only, logged, no web console

- **Status:** Accepted (2026-11-12)

## Context

The image has carried an optional x11vnc on the container's loopback address since its first
version, enabled by a VNC password. It is the only way a person can deal with a window on the
Gateway's screen that IBC does not handle. Before this record it had three weaknesses:

- a viewer could click and type as soon as it connected, so a look at a stuck window could
  change something by accident;
- nothing recorded that anybody had been on the console;
- measured with the image's x11vnc 0.9.17 on 2026-11-12: any process that can reach the display
  can switch an x11vnc's view-only mode off while it runs (`x11vnc -R noviewonly`), unseen.

The roadmap also asked for a browser console (noVNC) with an idle shutdown. Findings, checked
on 2026-11-12:

- x11vnc has no option that disconnects an idle client. Its `-timeout` is about the first
  connection after start, `-readtimeout` about a stalled transfer.
- The noVNC project publishes a snap and an npm package, no container image; websockify's own
  Dockerfile is for local builds (unpinned base, no `USER`). The community images examined
  mostly run as root, and the closest fit comes from a publisher this project cannot vouch
  for. A web console would put a second, unvetted image next to the IBKR session.

Constraints: no new package in the gateway image (invariant 4); nothing in the image may act
on the Gateway's screen or answer a second factor (invariant 6); only events may reach the
container's stdout (invariant 3); a credential never appears in an argument list
(invariant 2).

## Decision

1. **View-only by default.** `VNC_VIEW_ONLY=yes` unless set to `no`. Any other value stops the
   start with `config_invalid` before a login, judged only when the console is on: a typo in a
   setting that decides who may act must not be found one login too late.
2. **The mode cannot change while the container runs.** x11vnc is started with `-noremote`.
   Input therefore takes a new start of the container, which is a new login.
3. **Every visit is an event.** x11vnc's `-afteraccept` and `-gone` hooks run `vnc-hook.sh`,
   which emits `vnc_client_connected` and `vnc_client_disconnected` through the one event
   writer. Every value is checked against a strict form or dropped; nothing a client can
   shape is echoed.
4. **No idle limit and no web console are shipped**, because neither can be done honestly
   with what exists (above). The route to the console is documented instead
   (`docs/console.md`): a compose override with the VNC secret and a loopback port, a bridge
   the person opens and closes, an SSH tunnel.
5. **The log-shipper recipes use the image the Azure pack already pins.** `docs/recipes/`
   names the Vector image in one file, and its test fails when that pin differs from
   `compose/docker-compose.azure.yml`. This follows invariant 1's rule for a companion that
   runs next to the gateway; it adds no second Vector version to the repository.

## Consequences

Positive: a look cannot click; the log shows who was on the console, from where and for how
long; the mode shown in the events is the mode in force; no unvetted image is recommended.

Negative:

- A window seen view-only cannot be answered in the same session. Switching to input
  recreates the container and starts a new login, so the window may not come back, or the
  login may ask for a second factor.
- While the bridge is open, other containers on the same Docker network can reach the
  console port behind the VNC password, which the protocol limits to eight characters. The
  guide says so; the bridge is meant to be open for minutes.
- A session that is open when the container stops leaves no `vnc_client_disconnected`
  (x11vnc is ended with the other helpers before its hook runs).
- A connection that never authenticated is not an event.
- Nobody is disconnected for being idle.

Not established: the console during a real login, the SSH tunnel and a desktop VNC viewer
(the tests use the image's real x11vnc and a stand-in viewer written in bash).

## Revisit trigger

- The noVNC or websockify project, or another publisher this project can verify, releases a
  maintained non-root image: reconsider a browser console as a separate, optional container.
- A first attended paper login shows that view-only costs a login in practice: consider a
  switch to input at run time, as an event of its own and still never automated.
- Restrict the bridge to the Docker host (a `socat` `range=` on the bridge gateway's address)
  once the peer address through a published port is established on Linux and on Docker
  Desktop (the same open point as `RELAY_ALLOW_CIDR`, limitation L17).
