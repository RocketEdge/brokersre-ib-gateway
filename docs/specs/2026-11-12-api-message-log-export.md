# Design note: exporting the Gateway's API message log and its own logs

Status: **proposal, nothing built**. Date: 2026-11-12. IBKR quotations were fetched on that
day; "not established" means no IBKR page was found that says it.

## Problem

When an API client and the Gateway disagree, the evidence is in two logs the Gateway keeps:
the API message log (what clients sent and what they got back) and the Gateway's own log.
Operators want them off the host for diagnosis. Both can hold account identifiers, and IBKR
stores both encrypted, so "ship the files" is neither safe nor, as they stand, useful.

## What exists today

In this image (verified in the repository):

- `tail-gateway-logs.sh` mirrors `launcher.log` (seen with 10.50.1g) and a dated
  `ibgateway.*.log` name (never seen, [limitations](../limitations.md) L03) from the settings
  volume to `jts/` on the log volume, size-capped.
- The raw logs never leave the host unredacted; only events and resource samples are meant
  to be shipped ([log contract](../log-contract.md), [recipes](../recipes/README.md)).
- Which files the Gateway writes after a successful login is unknown: no login has succeeded
  on this image yet (L02).

According to IBKR:

| Fact | IBKR's words | Source |
|---|---|---|
| The API log is off by default | "This log is not enabled by default; but needs to be enabled by the Global Configuration setting." In IB Gateway: Configure, Settings, API, Settings, "Create API message log file", "Logging Level" set to "Detail" | [L1] |
| Both logs are encrypted on disk | "Both the API and TWS logs are encrypted locally. Unless decrypted through Trader Workstation or IB Gateway, the logs are illegible." "Due to privacy regulations, logs are encrypted before they are saved to disk." | [L1], [L2] |
| Reading them goes through the Gateway's window | "In IBG, both "API Logs" and "Gateway Logs" are accessible directly from the File menu." "Click "Export Today Logs…" to decrypt the logs and save them in plaintext" | [L3] |
| Two different file names in IBKR's own pages | "The API logs are named api.[clientId].[day].log" in the settings folder; another page shows files "labeled like "api.0.20250110.105733.ibgzenc", "tws.20250110.105733.ibgzenc" or "ibgateway.20250110.105733.ibgzenc"" | [L1], [L4] |
| They are kept for a week and stay local | "These logs will recycle every 7 days." "These files are stored on the clients machine and are only sent to Interactive Brokers by client request." | [L1] |
| The API can switch the API log on, but not with a read-only API | "The Read-Only setting within TWS must be manually disabled before any configuration updates will be permitted." | [L5] |

Not established: any command-line or API way to export or decrypt the logs without the
window; what exactly the API log contains (IBKR says "a record of exchanged messages between
API applications and TWS/IB Gateway", from which account identifiers and order details are
an inference); `launcher.log`, which no IBKR page mentions.

## Options

| Option | What it gives | Cost and risk |
|---|---|---|
| A. Leave it as it is | `launcher.log` mirrored; raw logs stay on the host | No API-level trace off the host |
| B. Copy the encrypted files as they are, on demand | Something IBKR's support could read | Nobody else can read or mask them; their content is unknown to us; IBKR's own route for this is its Upload Diagnostics window |
| C. A person exports through the Gateway's window, then a masking step | Readable text, on demand, with a person deciding | Needs the [break-glass console](../console.md) with input; plaintext with account identifiers sits on a volume until it is masked and removed; the masking rules must be proven on real samples |
| D. Record the API conversation in front of the Gateway (in the relay) | A trace without the Gateway's help | It would copy everything clients send, orders and account identifiers included, into a new place; a parser for the API's wire format; the client can log the same itself ([strategy telemetry](2026-11-12-strategy-telemetry.md)) |
| E. Switch the API log on through the API | Nothing readable: the file is still encrypted | Requires the read-only API to be off |

## Recommendation

Stay at A. Prepare C as the only route that yields readable content with a person in
control, and reject B (opaque), D (a new place for sensitive data to leak from) and E (no
gain). A masking step, if it is ever built, keeps at most the last three characters of an
account identifier, refuses to export when a line does not parse, and is developed against
scrubbed real samples, never against a guess of the format.

## What has to be observed first

With one logged-in paper session, attended:

1. which log files appear, under which names (`.ibgzenc` or not) and in which directory of the
   settings volume;
2. whether "Export Today Logs…" works in this container (read-only root filesystem), where it
   writes, and what the exported text looks like;
3. what the exported API log contains: account identifiers, usernames, order fields;
4. how large a day at "Detail" is.

## Not built

No exporter, no masking filter, no switch for the API log, no capture in the relay, and no
attempt to decrypt IBKR's files: those are read through IBKR's own application or not at all.

## Sources

- [L1] IBKR, TWS API documentation, "API Logs":
  <https://www.interactivebrokers.com/docs/tws-api/doc/troubleshooting-support/log-files/api-logs>
- [L2] "Location of Interactive Brokers Logs":
  <https://www.interactivebrokers.com/docs/tws-api/doc/troubleshooting-support/log-files/location-of-interactive-brokers-logs>
- [L3] "Exporting Logs":
  <https://www.interactivebrokers.com/docs/tws-api/doc/troubleshooting-support/log-files/exporting-logs>
- [L4] "How to Delete Logs":
  <https://www.interactivebrokers.com/docs/tws-api/doc/troubleshooting-support/log-files/how-to-delete-logs>
- [L5] "Setting Management": <https://www.interactivebrokers.com/docs/tws-api/doc/setting-management>
