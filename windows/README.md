# Windows host kit

Run IB Gateway (the `brokersre-ib-gateway` image) on Windows 10 22H2 or Windows 11 without
knowing Docker, and keep it running through restarts, sleep and Windows Update.

- [What you get](#what-you-get)
- [What the kit never does](#what-the-kit-never-does)
- [Before you start](#before-you-start)
- [Choose where the container runs](#choose-where-the-container-runs)
- [Step by step](#step-by-step)
- [What can interrupt the gateway on Windows](#what-can-interrupt-the-gateway-on-windows)
- [Start after a restart](#start-after-a-restart)
- [The weekly Sunday login](#the-weekly-sunday-login)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Files the kit creates](#files-the-kit-creates)
- [To validate on your computer](#to-validate-on-your-computer)
- [How the kit is tested](#how-the-kit-is-tested)
- [Sources](#sources)

## What you get

Five PowerShell scripts. They run on Windows PowerShell 5.1 (built into Windows) and PowerShell 7.

| Script | What it does | Changes the computer? |
|---|---|---|
| `setup.ps1` | Checks the computer, stores your IBKR credentials as two protected files, writes `compose.yaml`, starts the gateway and tells you when to approve the login on your phone | Creates one folder; starts one container |
| `doctor.ps1` | Reports everything that can interrupt the gateway: `PASS`, `WARN`, `FAIL` or `SKIP` per check, with the fix | No, read-only |
| `harden.ps1` | Applies the fixes `doctor.ps1` recommends, one switch each; `-Undo` reverts all of them | Yes, only what you ask for, recorded with the previous value |
| `start.ps1` | Starts the stack without asking anything (used by the scheduled tasks) | Starts a stopped stack; never touches a running one |
| `uninstall.ps1` | Removes the container and the kit's scheduled tasks; with `-RemoveData` also the data | Yes, after asking |

Every script that changes something accepts `-WhatIf` (show what would happen, change nothing).

## What the kit never does

- It never automates or bypasses two-factor authentication. You approve every login on your phone.
- It never restarts a running gateway. A restart forces a new login.
- It never retries a rejected login. After one rejection it stops the gateway, because repeated failures can lock an IBKR account.
- It never places, changes or cancels an order. The API is read-only unless you pass `-AllowApiOrders`.
- It never puts your username or password in `compose.yaml`, on a command line, in a log or on the screen.
- It never sets up Windows auto-logon and never stores a Windows password.
- It sends nothing anywhere. The only network use is Docker pulling images and one time query to `time.windows.com`.

## Before you start

| You need | How to check |
|---|---|
| Windows 10 22H2 (build 19045) or Windows 11, 64-bit. Windows 10 is past its end of support (2025-10-14) | `winver` |
| Hardware virtualization enabled in the UEFI/BIOS | Task Manager > Performance > CPU > "Virtualization: Enabled" |
| WSL 2, version 2.1.5 or later (Docker Desktop's documented minimum) | `wsl --version`; install with `wsl --install`, update with `wsl --update` |
| A container runtime, see the next section | `docker version` |
| 8 GB RAM or more, 10 GB free disk | |
| An IBKR username with IBKR Mobile (IB Key) enrolled for two-factor authentication | Log in once to Client Portal |
| For paper trading: the paper trading username, not the live one | |

`doctor.ps1` checks the first four for you.

## Choose where the container runs

| Option | Use it for | Comes back after a Windows restart | Notes |
|---|---|---|---|
| A. Docker Desktop (WSL 2 backend) | Trying it out; a computer you sit at | Only after someone signs in to Windows | Docker's terms: free for personal use, education, non-commercial open source and small businesses with fewer than 250 employees AND less than USD 10 million annual revenue; other commercial and government use needs a paid subscription |
| B. Docker Engine inside a WSL 2 distribution | An unattended computer; organisations above the Docker Desktop limits | At startup, without sign-in (see [To validate](#to-validate-on-your-computer)) | No Docker Desktop involved. The kit drives `docker` inside the distribution through `wsl.exe` |
| C. A Linux virtual machine in Hyper-V | A server that must simply stay up | With the VM ("Automatic Start Action: Always start") | The most robust choice on Windows Pro or Server. This kit is not needed inside the VM: use the Linux compose example in the repository root |

Windows containers are not an option: IB Gateway is a graphical Java application and the image
runs it under a Linux X server.

For option B, install a distribution (`wsl --install -d Ubuntu-24.04`), install Docker Engine in
it by following Docker's own instructions for that distribution, make sure `docker info` works
for your Linux user without `sudo`, then use `-Runtime WslEngine` in step 4.

## Step by step

Download the repository (green "Code" button > "Download ZIP", then extract) or clone it. Keep
the folder where it is afterwards: the scheduled tasks call `start.ps1` from it.

### Step 1: open PowerShell in the kit folder

Press Start, type `PowerShell`, press Enter, then:

```powershell
cd C:\path\to\brokersre-ib-gateway\windows
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

You should see: nothing, and the prompt returns. The second line allows scripts in this window
only; it changes nothing on the computer.

### Step 2: check the computer

```powershell
.\doctor.ps1
```

You should see: a table of about 25 lines starting with `PASS`, `WARN`, `FAIL` or `SKIP`, and a
summary such as `15 PASS, 2 WARN, 0 FAIL, 8 SKIP`. Fix every `FAIL` using the `Fix:` line under
it. `SKIP` on the secret and compose lines is normal before setup.

### Step 3: preview the installation

```powershell
.\setup.ps1 -WhatIf
```

You should see: eight `PASS` lines, then lines starting with `What if:`. Nothing is created.

### Step 4: install and log in

Have your phone with IBKR Mobile next to you.

```powershell
.\setup.ps1
```

You should see, in this order:

1. `IBKR username (typing is hidden):` and `IBKR password (typing is hidden):` Type each and press Enter. Nothing is shown while you type.
2. `Only your account can read the folder, and a container can still read the files.`
3. Docker downloading the image (about 1 GB, first time only).
4. `Logging in...`
5. `Approve the IBKR Mobile prompt on your phone now` Approve it on the phone.
6. `Logged in. API ready on 127.0.0.1:4002`

Variants: `.\setup.ps1 -Live` for live trading (port 4001, use another folder with `-Path`),
`-AllowApiOrders` if your programs must place orders, `-Runtime WslEngine -Distro Ubuntu-24.04`
for option B, `-ImageRef ghcr.io/rocketedge/brokersre-ib-gateway@sha256:<digest>` to pin the
image (recommended; the digest is in the release notes).

If you were too slow with the phone, run `.\setup.ps1` again: it keeps your secrets, changes
nothing that is already right and follows the login again. The gateway keeps prompting by itself.

### Step 5: connect your program

```python
from ib_async import IB
ib = IB()
ib.connect("127.0.0.1", 4002, clientId=1, readonly=True)
print(ib.reqCurrentTime())
ib.disconnect()
```

You should see: the current date and time printed. `setup.ps1` prints this snippet and a C#
one with the right port.

### Step 6: remove what can interrupt it

```powershell
.\doctor.ps1
```

You should see: the secret and compose lines now `PASS`. For each remaining `WARN` or `FAIL`
the `Fix:` line names a `harden.ps1` switch. Preview first, then apply, for example:

```powershell
.\harden.ps1 -DisableSleep -ResumeClockFix -WhatIf
.\harden.ps1 -DisableSleep -ResumeClockFix
```

You should see: one line per change, then
`Every change is recorded in ...\harden-journal.json; revert with: harden.ps1 -Undo`.

### Step 7: decide what happens after a restart

Read [Start after a restart](#start-after-a-restart), then run one of:

```powershell
.\harden.ps1 -StartAtBoot DockerDesktop
.\harden.ps1 -StartAtBoot WslEngine
```

You should see: `Scheduled task "\BrokerSRE\Gateway paper - start ..."` and a note about what
to validate.

## What can interrupt the gateway on Windows

| Hazard | What happens | `doctor.ps1` check | What the kit does about it |
|---|---|---|---|
| Sleep or hibernate | The gateway freezes, the IBKR session drops | `SleepOnAc` | `harden.ps1 -DisableSleep`: "sleep after" and "hibernate after" set to never on AC power |
| Windows Update restarts | Windows restarts outside active hours; the gateway needs a new login with 2FA | `UpdateActiveHours`, `UpdatePendingReboot`, `UpdateAutoRestart` | `harden.ps1 -SetActiveHours 6,23` sets the documented policy values (at most 18 hours); it moves restarts, it cannot prevent them. Restart on purpose at the weekend |
| No sign-in after a restart | Docker Desktop runs only in a signed-in session, so nothing starts | `StartAtBoot` (also reports the detected mode) | `harden.ps1 -StartAtBoot ...`; see the next section |
| WSL idle shutdown (option B) | WSL stops a distribution shortly after its last `wsl.exe` session ends, even while `dockerd` runs | `WslIdleShutdown` | The start task keeps one session open (`-KeepAlive`); `harden.ps1 -WslConfig` sets `[general] instanceIdleTimeout=-1` |
| Mirrored networking | `networkingMode=mirrored` in `.wslconfig` is known to break published container ports and exposes Linux listeners to the LAN | `WslNetworkingMode` | `harden.ps1 -WslConfig` sets `networkingMode=nat` (backup kept). Takes effect after `wsl --shutdown`, which stops the gateway |
| Firewall and port proxies | An allow rule or a `netsh interface portproxy` entry can put the trading API on the network | `FirewallExposure`, `ComposePortBinding` | The compose file binds the API to `127.0.0.1`; `harden.ps1 -FirewallLoopbackOnly` adds a block rule for 4001, 4002 and 9810 (loopback is not affected) |
| Clock drift after resume | The clock inside the container VM can lag by the time the computer slept | `ContainerClock`, `HostClock` | `harden.ps1 -ResumeClockFix`: a task that runs `wsl -u root hwclock -s` after every resume |
| Secret file encoding | A byte-order mark, UTF-16 or a Windows line ending becomes part of the password and the login fails | `SecretEncodingUsername`, `SecretEncodingPassword`, `SecretFolderAccess` | `setup.ps1` writes the files itself, byte-exact, and restricts the folder to your account |
| Docker Desktop updates | Applying an update restarts the engine and the gateway | `DockerDesktopAutoUpdate`, `DockerDesktopVersion` | Reported only. Leave "Always download updates" off and update on purpose |
| Too little memory for the VM | The gateway's Java process is killed | `WslMemory` | `harden.ps1 -WslConfig -WslMemoryGB 4` |
| Short stop timeout | Docker kills the gateway after 10 s, before it saved its settings | `ComposeStopGrace` | The compose file sets `stop_grace_period: 90s` |

Why the kit writes the secret files itself (bytes written for the text `ab`, observed on
Windows PowerShell 5.1.26100 and PowerShell 7.6.10):

| Command | Windows PowerShell 5.1 | PowerShell 7 |
|---|---|---|
| `'ab' > file`, `'ab' \| Out-File file` | `FF FE 61 00 62 00 0D 00 0A 00` (UTF-16, mark, CRLF) | `61 62 0D 0A` (CRLF) |
| `'ab' \| Set-Content -Encoding UTF8 file` | `EF BB BF 61 62 0D 0A` (mark, CRLF) | `61 62 0D 0A` (CRLF) |
| `[System.IO.File]::WriteAllText(file, 'ab', (New-Object System.Text.UTF8Encoding($false)))` | `61 62` | `61 62` |

Only the last form gives the two bytes the container expects, on both editions.

## Start after a restart

After any restart IBKR asks for two-factor authentication again. The kit cannot and will not
change that. What you can decide is whether the gateway gets as far as sending the prompt to
your phone without anyone touching the computer.

**Docker Desktop (option A).** Docker Desktop's documented start option is "Start Docker Desktop
when you sign in to your computer": it needs a signed-in Windows session.

1. Tick that option in Docker Desktop > Settings > General.
2. `.\harden.ps1 -StartAtBoot DockerDesktop` registers a task that, after you sign in, waits for
   Docker and runs `docker compose up -d --no-recreate` (starts a stopped stack, never replaces a
   running one).
3. For a computer nobody sits at, Windows must also sign in by itself. The kit does not
   configure this. If you decide to, use Microsoft's Sysinternals
   [Autologon](https://learn.microsoft.com/sysinternals/downloads/autologon), which stores the
   password as an encrypted LSA secret instead of plain text in the registry.

   The trade-off: with auto-logon, anyone who can switch the computer on, or reach its keyboard
   and screen, is signed in as you. Use it only on a computer in a locked room, with disk
   encryption (BitLocker), a Windows account used for nothing else, and the screen locked right
   after sign-in (Docker Desktop keeps running behind the lock screen). If that is not
   acceptable, use option B or C.

**Docker Engine inside WSL (option B).** `.\harden.ps1 -StartAtBoot WslEngine` (elevated
PowerShell) registers a task at system startup that runs as your account whether you are signed
in or not, starts the distribution, runs `docker compose up -d --no-recreate` and keeps one
session open so WSL does not shut the distribution down. Windows asks for your account password
when the task is registered (Task Scheduler stores it, the kit never sees it); add
`-TaskLogonType S4U` to store none. If WSL does not start without a sign-in on your computer,
use `.\harden.ps1 -StartAtBoot WslEngine -AfterSignIn` and treat it like option A.

Check the result with `.\doctor.ps1` (line `StartAtBoot`) and in `kit.log` in the gateway folder.

## The weekly Sunday login

IBKR requires one full login with two-factor authentication every week. During the week the
gateway's own daily restart (11:45 PM New York time by default) is designed to continue the
session without a new prompt; after IBKR's weekly reset at the weekend it cannot. The kit never
automates this login.

A routine that works:

1. Sunday, before your markets open, have the phone ready.
2. If Windows wants a restart (`.\doctor.ps1`, line `UpdatePendingReboot`), restart it now.
3. Wait for the IBKR Mobile prompt and approve it. The gateway keeps prompting until you do.
4. Confirm:

```powershell
docker exec brokersre-ib-gateway-paper cat /var/log/ibgateway/state/phase
```

You should see: `logged-in`. (For live the container is `brokersre-ib-gateway-live`.)

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `running scripts is disabled on this system` | PowerShell's execution policy | In that window: `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force` |
| `FAIL ContainerRuntime: No container runtime answered` | Docker Desktop is not running, or Docker Engine in WSL does not answer | Start Docker Desktop and wait for "Engine running"; for option B run `wsl -d <distribution> -- docker info` |
| `FAIL ContainerRuntime: Docker is set to Windows containers` | Docker Desktop is in Windows-container mode | Tray icon > "Switch to Linux containers..." |
| `FAIL Port4002: Another program is listening` | Trader Workstation or another gateway uses the port | Close it, or find it: `Get-NetTCPConnection -LocalPort 4002 -State Listen` |
| No prompt arrives on the phone | IBKR Mobile is not enrolled for this username, or notifications are off | Open IBKR Mobile; enrol IB Key for the username; the gateway prompts again by itself |
| `IBKR rejected the username or password` and the gateway was stopped | Wrong credentials, or the live username used for paper trading | `.\setup.ps1 -ResetSecrets` (the kit stopped the gateway so the rejection is not repeated) |
| `Another session is using this IBKR username` | TWS, the mobile app or another gateway is logged in with the same username | Log that session out, or use a second username for the gateway |
| `Logged in`, but your program cannot connect | Wrong port, or the program is on another computer | Paper is `127.0.0.1:4002`, live `127.0.0.1:4001`; the API is reachable from this computer only |
| Your program connects but orders are refused | The API is read-only by default | `.\setup.ps1 -AllowApiOrders -Force` (recreates the container: new login) |
| `compose.yaml exists and differs from what these options generate` | You ran setup with other options than before (for example without `-Live`) | Use the same options, or add `-Force` to replace the file (a backup is kept) |
| After a Windows restart nothing is running | Docker Desktop needs a sign-in | [Start after a restart](#start-after-a-restart) |
| The gateway stops a minute after you close the terminal (option B) | WSL shut the idle distribution down | `.\harden.ps1 -StartAtBoot WslEngine`, or `.\start.ps1 -KeepAlive` in a window you leave open |
| `WARN ContainerClock` or `FAIL ContainerClock` after the computer slept | The container VM's clock lags | Now: `wsl -u root hwclock -s`. For good: `.\harden.ps1 -ResumeClockFix` and `-DisableSleep` |
| `FAIL SecretEncodingPassword` | The secret file was edited with Notepad or written with `>` | `.\setup.ps1 -ResetSecrets` |
| `WARN WslNetworkingMode: networkingMode=mirrored` | Mirrored networking breaks published ports | `.\harden.ps1 -WslConfig`, then `wsl --shutdown` in a maintenance window |
| `FAIL FirewallExposure: A port proxy publishes the gateway API` | A `netsh interface portproxy` entry forwards the API port | Run the `netsh ... delete` command shown in the `Fix:` line, elevated |
| A `harden.ps1` switch says it `needs an elevated PowerShell` | The change is machine-wide | Start PowerShell with "Run as administrator" and repeat the command |
| The gateway restarted after a Docker Desktop update | Applying the update restarts the engine | Update on purpose at the weekend; leave "Always download updates" off |
| `docker logs brokersre-ib-gateway-paper` shows `dirs_not_writable` or `secret_unreadable` | The compose file or the secrets folder was changed by hand | `.\setup.ps1 -Force` |

Where to look: `docker logs <container>` shows the gateway's events as JSON lines (never a
credential); `kit.log` in the gateway folder shows what the scheduled tasks did.

## Uninstall

```powershell
.\harden.ps1 -Undo
.\uninstall.ps1
```

You should see: one `Reverted:` line per change, then the container and the scheduled tasks
removed, and `Kept C:\BrokerSRE\gateway with your secret files and the Docker volumes`.

To delete the gateway settings, the logs, the folder and the secret files as well:

```powershell
.\uninstall.ps1 -RemoveData
```

PowerShell asks before each removal. While changes made by `harden.ps1` are still in place,
`-RemoveData` refuses to delete the folder, because it holds the journal that can revert them.

## Files the kit creates

In the gateway folder (default `C:\BrokerSRE\gateway`):

| File | Content |
|---|---|
| `secrets\ib-username`, `secrets\ib-password` | Your credentials, UTF-8 without byte-order mark and without newline; the folder's access list names only your account |
| `compose.yaml` | The stack: image, API on `127.0.0.1`, read-only root file system, no capabilities, 90 s stop timeout, log size limits. Generated; change it through `setup.ps1` options |
| `kit-state.json` | What setup detected: runtime, trading mode, container name, port. No secret |
| `harden-journal.json` | Every host change made by `harden.ps1` with its previous value |
| `kit.log`, `kit.log.1` | What the scheduled tasks did; at most 256 KB each |

Elsewhere: scheduled tasks in the Task Scheduler folder `\BrokerSRE`; with `-SetActiveHours`
three values under `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate`; with `-WslConfig`
keys in `%UserProfile%\.wslconfig` (a `.brokersre-backup-<time>` copy is kept); with
`-FirewallLoopbackOnly` the rule `BrokerSRE-Gateway-Block-Api-Ports`; with `-DisableSleep` two
values of the active power scheme.

## To validate on your computer

These parts could not be proven on the development computer (Windows 11 build 26300, Docker
Desktop 4.99.0, WSL 3.0.5, no elevation, no second distribution) and are therefore stated as
intentions, not facts. `doctor.ps1` tells you the outcome on your computer.

| Item | Why it is open | How to validate |
|---|---|---|
| Option B as a whole (Docker Engine inside WSL) | Exercised with mocked `wsl.exe` only | Run `.\setup.ps1 -Runtime WslEngine` and `.\doctor.ps1` |
| The boot task starting WSL with nobody signed in | Microsoft tracks "Store WSL isn't accessible from Session 0" as open (microsoft/WSL#9231); reports differ by WSL version | Restart, do not sign in, wait for the phone prompt; otherwise use `-AfterSignIn` |
| `hwclock -s` correcting the clock after a real resume | Only a dry run (`hwclock -s --test`) was observed, in Docker Desktop's distribution | Sleep the computer, resume, run `.\doctor.ps1` (line `ContainerClock`) |
| Registering the sign-in and resume tasks without elevation | No task was registered during development; the task definitions were checked against the Task Scheduler schema only | If `harden.ps1` reports a `schtasks` error, repeat it elevated |
| `-SetActiveHours` on Windows Home | Policy registry values may be ignored on Home | Settings > Windows Update > Advanced options > Active hours |
| The reading "Windows adjusts active hours automatically" | The value `SmartActiveHoursState = 1` is described by community sources, not by Microsoft | Compare with Settings > Windows Update > Advanced options |
| `DockerDesktopAutoUpdate` | Docker does not document the key names of `settings-store.json`; the check reads `AutoDownloadUpdates` and reports `SKIP` when it is absent | Docker Desktop > Settings > Updates |
| `cap_drop: ALL` with the gateway image during a real login | No gateway was started during development | Step 4; if the container fails to start, report it |
| The C# snippet | Not compiled by this repository | Build it against IBKR's TWS API client |

## How the kit is tested

```powershell
Invoke-Pester windows/tests
Invoke-ScriptAnalyzer -Path windows -Recurse -Settings windows/PSScriptAnalyzerSettings.psd1
```

The tests run under both PowerShell editions (`.github/workflows/windows-kit.yml`). External
commands are mocked at one wrapper each; file handling is real. Among the things they prove:
secret files are byte-exact under both editions, the password appears in no output stream and
in no other file, `-WhatIf` changes nothing, the rendered compose file passes
`docker compose config`, every check has its PASS, WARN, FAIL and SKIP path, every hardening
change round-trips through undo, and the login follower never restarts anything and stops at
the first rejected login.

## Sources

- Microsoft Learn, "Advanced settings configuration in WSL" (`.wslconfig` keys and defaults: `memory`, `vmIdleTimeout`, `instanceIdleTimeout`, `networkingMode`, `autoMemoryReclaim`), read 2026-11-12.
- Microsoft Learn, "Troubleshooting Windows Subsystem for Linux" (known issue with published container ports in mirrored networking mode); moby/moby issue 48056.
- Microsoft Learn, "Manage device restarts after updates" (active hours, at most 18 hours; policy registry values).
- microsoft/WSL issues 9231 (session 0) and 10006 (clock skew after resume).
- Docker documentation: "Install Docker Desktop on Windows" (requirements), "Change settings" (start at sign-in, updates), "Docker Desktop license agreement".
- Microsoft Sysinternals, "Autologon".

Interactive Brokers, IBKR, IB Gateway and Trader Workstation are trademarks of Interactive
Brokers LLC. This project is not affiliated with, endorsed by or sponsored by Interactive Brokers.
