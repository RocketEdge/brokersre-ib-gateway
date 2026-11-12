# Break-glass console

A way for a **person** to see the Gateway's screen, and when that is not enough to click and
type on it. It is off by default. Nothing in this image ever looks, clicks or types by itself,
and nothing here answers a second factor for you.

## Table of Contents

- [When to use it](#when-to-use-it)
- [What it costs](#what-it-costs)
- [Step by step](#step-by-step)
- [If you must click or type](#if-you-must-click-or-type)
- [What the log shows](#what-the-log-shows)
- [Several gateways](#several-gateways)
- [What protects it, and what does not](#what-protects-it-and-what-does-not)
- [No idle limit](#no-idle-limit)
- [Why there is no web console](#why-there-is-no-web-console)
- [What was tested](#what-was-tested)

## When to use it

| The events say | The console lets a person |
|---|---|
| `unknown_window`, or `login_stalled` with the phase stuck in `login` | see which window the Gateway shows that IBC does not handle |
| `needs_human` (phase `needs-human`) | see what the Gateway shows before the container is restarted |
| a second factor that has to be typed into the Gateway's window (for example a code from a text message or a security device) | type it, with input switched on |

Do not use it for an approval on a phone (IB Key in IBKR Mobile): that happens on the phone,
and the console adds nothing. Do not leave input switched on.

## What it costs

The console's settings are read when the container starts. Switching the console on, switching
it off, or changing between view-only and input **recreates the container, and the Gateway
logs in again**, which can ask for the second factor. Two ways to live with that:

- Keep the console on and view-only all the time. Looking then costs nothing, every look is
  an event, and the port stays on the container's own loopback address.
- Switch it on only when needed, and accept the new login.

A dialog you saw in view-only mode is gone after the restart that switches input on; the new
login shows its own.

## Step by step

The commands use the single-gateway file and are run from the repository folder on the Docker
host. Every command names both compose files, so each can be copied on its own. They are
written for bash and zsh; in PowerShell replace `grep` with `Select-String`.

### 1. Store a VNC password as a file

The VNC protocol uses the first eight characters of a password, so make those eight count.

Linux, macOS, WSL or Git Bash:

```bash
read -r -s -p 'VNC password: ' p && printf '%s' "$p" > compose/secrets/vnc-password && echo
unset p
```

Windows (PowerShell 5.1 or 7):

```powershell
$secure = Read-Host 'VNC password' -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try { [IO.File]::WriteAllText("$PWD\compose\secrets\vnc-password", [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr), (New-Object System.Text.UTF8Encoding($false))) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
```

Check: the file `compose/secrets/vnc-password` exists and the password never appeared on
screen.

### 2. Start the gateway with the console

```bash
docker compose -f compose/docker-compose.example.yml -f compose/docker-compose.console.yml up -d
docker compose -f compose/docker-compose.example.yml -f compose/docker-compose.console.yml logs ib-gateway | grep '"event":"vnc_enabled"'
```

Check: one line with `"view_only":"yes"`. The gateway is logging in again; wait for the phase
you expect ([README](../README.md), "Check that it is logged in"). If the container stopped
instead, the last event names the reason; `config_invalid` means `VNC_VIEW_ONLY` is neither
`yes` nor `no`.

### 3. Open the bridge

x11vnc listens only on the container's own loopback address, which no published port can
reach. The bridge is one `socat` inside the container, started by you and running until you
stop it:

```bash
docker compose -f compose/docker-compose.example.yml -f compose/docker-compose.console.yml exec -d ib-gateway socat TCP-LISTEN:5901,fork,reuseaddr TCP:127.0.0.1:5900
docker compose -f compose/docker-compose.example.yml -f compose/docker-compose.console.yml exec ib-gateway bash -c 'exec 3<>/dev/tcp/127.0.0.1/5901 && echo bridge open'
```

Check: `bridge open`. The compose file publishes container port 5901 on the host's `127.0.0.1`
only (host port `IBGW_CONSOLE_PORT`, default 5901).

### 4. Tunnel to the Docker host

Skip this step when your VNC viewer runs on the Docker host itself. Otherwise, on your own
machine:

```bash
ssh -N -L 5901:127.0.0.1:5901 <user>@<docker-host>
```

Check, in a second terminal on your machine: `nc -z 127.0.0.1 5901 && echo open` (Linux,
macOS) or `Test-NetConnection 127.0.0.1 -Port 5901` (PowerShell, `TcpTestSucceeded : True`).
Leave the `ssh` command running.

### 5. Connect a VNC viewer

Point a desktop VNC viewer at `127.0.0.1`, port 5901, and enter the VNC password. Viewers
write a port in different ways; `127.0.0.1::5901` and `127.0.0.1:1` (display 1) are the two
common ones.

Check: you see the Gateway's screen, and the log has the visit:

```bash
docker compose -f compose/docker-compose.example.yml -f compose/docker-compose.console.yml logs ib-gateway | grep '"event":"vnc_client_connected"'
```

### 6. Leave, and close the bridge

Close the viewer, stop the `ssh` command with Ctrl+C, then:

```bash
docker compose -f compose/docker-compose.example.yml -f compose/docker-compose.console.yml exec ib-gateway pkill -f TCP-LISTEN:5901
docker compose -f compose/docker-compose.example.yml -f compose/docker-compose.console.yml logs ib-gateway | grep '"event":"vnc_client_disconnected"'
```

Check: the event is there with `"clients":"0"`, and the check of step 3 now ends with
`Connection refused`.

### 7. Switch the console off

Start the gateway again without the console file (a new login), and remove the password file:

```bash
docker compose -f compose/docker-compose.example.yml up -d
docker compose -f compose/docker-compose.example.yml logs ib-gateway | grep '"event":"vnc_disabled"'
rm compose/secrets/vnc-password
```

Check: the `vnc_disabled` event of the new start.

## If you must click or type

View-only is the default so that a look cannot click by accident. To act, start the container
with input allowed, do what only a person may do, and go back:

```bash
# A new login. In PowerShell set $env:VNC_VIEW_ONLY='no' first and remove it afterwards.
VNC_VIEW_ONLY=no docker compose -f compose/docker-compose.example.yml -f compose/docker-compose.console.yml up -d
# Steps 3 to 6, then back to view-only (or step 7):
docker compose -f compose/docker-compose.example.yml -f compose/docker-compose.console.yml up -d
```

Check: `vnc_enabled` and `vnc_client_connected` now say `"view_only":"no"`.

What a person does there is that person's act: dismissing a dialog, typing a code they hold.
Do not script the viewer, do not store a second factor, and do not build anything that types
or clicks for you: this image never does, and this repository will not help with it.

The setting cannot be changed while the container runs. x11vnc's remote-control channel, which
could switch view-only off unseen, is turned off (`-noremote`).

## What the log shows

| Event | Level | Meaning |
|---|---|---|
| `vnc_enabled` | warn | the console is on; `data.view_only` says how |
| `vnc_client_connected` | warn | a VNC client was let in after the password check; `data.client_ip`, `data.client_id`, `data.clients`, `data.view_only` |
| `vnc_client_disconnected` | info | that client left; `data.session_s` is how long it stayed |
| `vnc_disabled` | info | the console is off |

Through the bridge the client address is always `127.0.0.1`: the events say that someone was
there and for how long, not who. Who could reach it is decided by who can log in to the Docker
host. A connection that never passed the password check is not an event.
Details: [log-contract.md](log-contract.md).

## Several gateways

`compose/docker-compose.console.yml` extends the service `ib-gateway` of the single-gateway
file. For `compose/docker-compose.multi.yml` add the same three things to the service you need
the console for: the two environment lines, the secret, and one loopback port per gateway
(`127.0.0.1:5901:5901` for the first, `127.0.0.1:5902:5901` for the second).

## What protects it, and what does not

- x11vnc listens on `127.0.0.1` inside the container; port 5900 is never published.
- The bridge port is published on the host's `127.0.0.1` only, and nothing listens behind it
  until you open the bridge.
- While the bridge runs, other containers on the same Docker network can reach port 5901 of the
  gateway container too. The VNC password is then the only barrier, and it is a weak one:
  eight significant characters, and the session itself is not encrypted. That is why the route
  from your machine is an SSH tunnel, why the bridge is closed again, and why the port must
  never be published on a network address.
- The password is read from the secret file, handed to x11vnc in a private file that x11vnc
  deletes, and is in no argument list, environment or event afterwards.

## No idle limit

x11vnc 0.9.17 has no option that disconnects an idle client: `-timeout` is about the first
connection after startup and `-readtimeout` about a stalled transfer (`x11vnc -help` in this
image). So there is none here, and nothing pretends to be one. Close the viewer and the
bridge when you are done; `data.clients` in the last `vnc_client_disconnected` event shows
whether someone is still connected.

## Why there is no web console

A web console (noVNC in a browser, with websockify in front of the VNC port) would need a
second container image, and this repository ships third-party images only when they are
maintained by a publisher that can be trusted, pinned by digest and run as a non-root user on
a read-only filesystem. On 2026-11-12 no such image was found:

- The noVNC project publishes a snap and an npm package, no container image: its repository
  has no Dockerfile and its [README](https://github.com/novnc/noVNC/blob/master/README.md)
  describes the snap only.
- The websockify project has a
  [Dockerfile](https://github.com/novnc/websockify/blob/master/docker/Dockerfile) for local
  builds: no pinned base, no non-root user, the proxy without the noVNC files. No image is
  published; `novnc/websockify` does not exist on Docker Hub, and a maintainer wrote in 2022
  that publishing one is not planned
  ([pull request 516](https://github.com/novnc/websockify/pull/516)).
- The community images that were examined run as root, are years old, or come from publishers
  that give no assurance of upkeep. None met all the conditions above.

Building or vendoring one here would make this repository the maintainer of a browser-facing
component, so none is built. The route above needs nothing but `ssh` and a VNC viewer.
What would change this: an image published and kept current by the noVNC or websockify project
(or by another publisher that signs and maintains it) that runs as a non-root user on a
read-only filesystem.

## What was tested

- With the image's real x11vnc, offline (`tests/container/run.sh`): view-only discards a
  pointer event and `VNC_VIEW_ONLY=no` lets it through; a client that connects and leaves is
  two events on stdout and in `events/events.jsonl`; a wrong password gets nobody in and is no
  event; the password is in no argument list, environment, file or event; the remote-control
  channel cannot switch view-only off; any other `VNC_VIEW_ONLY` stops the start.
- With the compose files as shipped (`tests/compose/run.sh`): steps 2, 3, 5 and 6, a bash VNC
  client on the host standing in for the viewer.
- Not tested: the SSH tunnel of step 4, a desktop VNC viewer, and the console during a real
  login (no test logs in to IBKR).
