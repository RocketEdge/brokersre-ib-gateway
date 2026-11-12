# ADR 0015 — Login controller succession: stay on the IBC fork behind a narrow contract

- **Status:** Proposed (2026-11-12)

## Context

IB Gateway has no headless mode: something must start it, type the credentials into its login
window and deal with its dialogs. In this image that is IBC, taken from the release named in
`versions.json` on [RocketEdge/ibc](https://github.com/RocketEdge/ibc)
([ADR 0007](0007-ibc-from-rocketedge-fork-no-ibkr-redistribution.md)).

**The dependency.** Upstream [IbcAlpha/IBC](https://github.com/IbcAlpha/IBC) is archived. Its
README says the project "has been retired, as of 1 September 2026", with "no further
development of IBC, other than completing work in progress at that date and fixing any
significant newly reported bugs", and invites others to "fork the project should you wish to
carry it forward" (README and repository state read through the GitHub API on 2026-11-12:
`archived: true`, last upstream release `3.24.2`). The fork's only release,
`3.24.2-rocketedge.1`, is byte-identical to that upstream release.

**Why it is a single point of failure.** IBC drives the Gateway through its Swing windows.
IBKR changes those windows without notice and publishes no contract for them. A Gateway build
that renames or reorders what IBC looks for cannot be logged in with by this image until the
fork is changed, and no one else maintains the code the fork tracks. Nothing in CI would
notice: the tests never log in ([limitations](../limitations.md), L04).

**What the image needs from a login controller.** Derived from the files that touch IBC, not
from IBC's feature list:

| # | Need | Where the image depends on it |
|---|---|---|
| 1 | Start the Gateway of a given version from given paths, as a child process whose exit status the entrypoint passes on | `rootfs/usr/local/lib/brokersre/start-ibc.sh` (`ibcstart.sh <version> -g --tws-path --tws-settings-path --ibc-path --ibc-ini`), `rootfs/usr/local/bin/entrypoint.sh` (`wait`, `ibc_exited`) |
| 2 | Read the username and password from a file and type them into the login window; never take them from the command line or the environment | `rootfs/etc/brokersre/ibc.config.ini.tmpl` (`IbLoginId`, `IbPassword`, `TradingMode`), `rootfs/usr/local/lib/brokersre/render-config.sh` (tmpfs file, mode 0600) |
| 3 | Never answer a second factor. On a timeout, either prompt again or exit, as configured | `start-ibc.sh` (`--on2fatimeout`), `ibc.config.ini.tmpl` (`ReloginAfterSecondFactorAuthenticationTimeout`, `SecondFactorAuthenticationExitInterval`, `ExitAfterSecondFactorAuthenticationTimeout`) |
| 4 | Write one recognisable line on stdout for each phase the classifier reports: controller version, login window shown, second factor started, second-factor window, re-login after a second-factor timeout, login completed, login failed, credentials rejected, existing session, re-login required, daily restart; and one line per window opened, with its title | `rootfs/etc/brokersre/ibc-patterns.tsv` (11 rows), `rootfs/etc/brokersre/known-windows.txt`, `rootfs/usr/local/lib/brokersre/classify-ibc-log.sh` |
| 5 | A command channel on loopback that accepts `STOP` (log out and exit tidily). `RESTART`, `PAUSE`, `RECONNECTDATA`, `RECONNECTACCOUNT` and `ENABLEAPI` are passed through for a sidecar ([ADR 0005](0005-command-server-on-loopback.md)) | `rootfs/usr/local/lib/brokersre/ibc-cmd.sh`, `entrypoint.sh` (shutdown), `classify-ibc-log.sh` (the second-factor prompt cap), `ibc.config.ini.tmpl` (`CommandServerPort`, `ControlFrom`, `BindAddress`) |
| 6 | Apply the session settings: read-only API, action on an incoming API connection, action on an existing session, a daily restart that needs no new login, auto-logoff | `ibc.config.ini.tmpl` (`ReadOnlyApi`, `AcceptIncomingConnectionAction`, `ExistingSessionDetectedAction`, `AutoRestartTime`, `AutoLogoffTime`) |
| 7 | A process the health check can find | `rootfs/usr/local/lib/brokersre/healthcheck.sh` (`pgrep -f 'ibcalpha\.ibc'`) |

Everything else in the image (events, phase file, relay, sampler, preflight) reads the
classifier's output or the phase file, never IBC itself.

**Other open-source login controllers.** Licences as reported by the GitHub API
(`GET /repos/{owner}/{repo}`, field `license.spdx_id`, and `GET /repos/{owner}/{repo}/license`
for the file) on 2026-11-12; descriptions are each repository's own. This list records that
they exist and under which terms. It does not compare them, and none was evaluated against
the table above.

| Project | Its own description | Licence (SPDX) | Licence file | Archived |
|---|---|---|---|---|
| [IbcAlpha/IBC](https://github.com/IbcAlpha/IBC) | "Automation of Interactive Brokers TWS." | GPL-3.0 | [LICENSE.txt](https://github.com/IbcAlpha/IBC/blob/master/LICENSE.txt) | yes |
| [RocketEdge/ibc](https://github.com/RocketEdge/ibc) (fork of the above, in use) | "RocketEdge maintenance fork of IBC" | GPL-3.0 | [LICENSE.txt](https://github.com/RocketEdge/ibc/blob/brokersre/LICENSE.txt) | no |
| [ib-controller/ib-controller](https://github.com/ib-controller/ib-controller) (IBC's README calls it its predecessor) | "Automation of Interactive Brokers TWS." | GPL-3.0 | [LICENSE.txt](https://github.com/ib-controller/ib-controller/blob/master/LICENSE.txt) | no |
| [QuantConnect/IBAutomater](https://github.com/QuantConnect/IBAutomater) | "Automates IB Gateway start, stopping and restarting." | Apache-2.0 | [LICENSE](https://github.com/QuantConnect/IBAutomater/blob/master/LICENSE) | no |
| [heshiming/ibga](https://github.com/heshiming/ibga) | "IB Gateway in a headless docker container." | Apache-2.0 | [LICENSE](https://github.com/heshiming/ibga/blob/master/LICENSE) | no |
| [Lcstyle/ibctl](https://github.com/Lcstyle/ibctl) | "IBC replacement for automated IB Gateway/TWS login, 2FA, and session management" | AGPL-3.0 | [LICENSE](https://github.com/Lcstyle/ibctl/blob/develop/LICENSE) | no |
| [code-hustler-ft3d/ibg-controller](https://github.com/code-hustler-ft3d/ibg-controller) | "Unattended IB Gateway in Docker: login, TOTP 2FA, API config and monitoring, driven from inside Gateway's JVM" | MIT | [LICENSE](https://github.com/code-hustler-ft3d/ibg-controller/blob/main/LICENSE) | no |
| [py-ib-controller](https://pypi.org/project/py-ib-controller/) (PyPI) | "Login/launch controller for TWS and IBKR Gateway, via an in-process Java agent" | Apache-2.0 (PyPI metadata `license_expression`; the metadata names no source repository) | not located | not applicable |

[Voyz/ibeam](https://github.com/Voyz/ibeam) (Apache-2.0) is not in the table: by its own
description it serves "the Interactive Brokers Client Portal Web API Gateway", a different IBKR
API from the one IB Gateway provides.

**Licence notes, without legal conclusions.** The image's own files are MIT. IBC is GPL-3.0
and is shipped as a separate, unmodified program with its licence text and a pointer to its
source ([ADR 0007](0007-ibc-from-rocketedge-fork-no-ibkr-redistribution.md)); that arrangement
is the baseline. MIT and Apache-2.0 are permissive licences with attribution and notice
duties. GPL-3.0 and AGPL-3.0 are copyleft licences; AGPL-3.0 adds terms for software used over
a network. Shipping a different program under either copyleft licence inside this image needs
legal review first; this record does not decide it.

## Decision

1. **Stay on the fork.** `RocketEdge/ibc` remains the login controller. Changes go to the
   fork as tagged releases and reach the image only through `versions.json` (tag and SHA-256).
2. **Keep the contract narrow and in one place.** The seven needs above are the whole
   interface. The image keeps using only them: no new dependency on an IBC option, log line or
   command without a row in that table. The text IBC prints is confined to
   `ibc-patterns.tsv` and `known-windows.txt`, the command names to `ibc-cmd.sh`, the start
   command to `start-ibc.sh`, the settings to `ibc.config.ini.tmpl`, the process name to
   `healthcheck.sh`. Swapping the controller would mean rewriting those files, the install
   step of the `Dockerfile`, the `ibc` block of `versions.json` and their tests, and nothing
   that consumes events or the phase file.
3. **Two things a replacement may never bring**, whatever else it offers: an answer to the
   second factor (the image alerts and waits; `SECURITY.md`), and credentials on a command
   line or in the environment. A controller that can do either must have it switched off, and
   a test must prove it is off.
4. **No replacement is chosen now.** The list above is a starting point for the day the
   trigger fires, to be re-read then: repositories, licences and the Gateway all move.

## Consequences

### Positive

The image keeps the controller that its tests and its only real login attempt so far were made
with. The dependency is written down with its exact surface, so a replacement is a bounded
piece of work instead of a rewrite. Licence facts are on record with their date and source.

### Negative

The single point of failure remains: when IBKR changes the login window, the image cannot log
in until the fork is fixed, and the fix depends on people who know IBC's code. Eight of the
eleven classifier rows are still taken from IBC's source rather than from a real log (header
of `ibc-patterns.tsv`; [limitations](../limitations.md), L01), so the fourth need is only
partly proven even for IBC. The list of other controllers will go stale; it is evidence of one
day.

## Revisit trigger

The first IB Gateway build, on either channel, that the fork cannot log in with, found by a
paper-account login against the new build before any consumer promotes its digest
([limitations](../limitations.md), L04). Also: IBKR publishes a supported way to start and log
in to IB Gateway without a window.
