# ADR 0012 — Azure Log Analytics pack: Vector on the host, a Direct data collection rule, redaction before shipping

- **Status:** Proposed (2026-11-12); nothing has been deployed to Azure yet, see "Not verified" below

## Context

Desks that run the gateway want its events, metrics and logs queryable and alertable in their
own Azure subscription, on Windows (Docker Desktop), on-premises Linux and Azure VMs alike,
without giving anyone else access. The gateway writes JSON Lines files and raw IBC/launcher
text to a volume ([log-contract.md](../log-contract.md)); the raw text can contain the IBKR
user name, and an account id may leave the host only as its last three characters.

Facts checked on 2026-11-12 (sources in parentheses):

- The HTTP Data Collector API is retired; its replacement is the Logs Ingestion API, which
  needs a data collection rule (DCR) and Entra ID authentication (Microsoft Learn, Logs
  Ingestion API overview).
- A DCR of kind `Direct` has its own logs ingestion endpoint and needs no data collection
  endpoint (Microsoft Learn, "Add or delete tables and columns", REST tab).
- Limits: 1 MB per call, 64 KB per value, 12,000 calls per minute and DCR (Microsoft Learn,
  Azure Monitor service limits). A row whose `TimeGenerated` is more than two days old is
  stamped with its arrival time (Microsoft Learn, "Standard columns in Azure Monitor log
  records", TimeGenerated).
- Table plans: Analytics supports alert rules; Basic supports simple log alerts; Auxiliary
  supports none, accepts DCR-based custom tables with `transformKql: source`, and cannot change
  its plan after creation (Microsoft Learn, "Azure Monitor Logs" feature table and the
  Auxiliary table instructions).
- `ingestion_time()` is refused only in alert rules evaluated every minute (Microsoft Learn,
  "Create log search alert rules").
- List prices: Analytics ingestion $2.30/GB, Basic $0.50/GB, Auxiliary $0.05/GB; a log search
  alert rule $1.50 per month at 5 minutes and $0.50 at 15 minutes; a Standard NAT gateway
  $0.045 per hour and per GB (Azure Retail Prices API).
- Vector 0.61.0 (released 2026-10-29) has the `azure_logs_ingestion` sink with
  `auth.azure_credential_kind` values `managed_identity` and `client_certificate_credential`
  (PKCS#12 file); it sends uncompressed JSON arrays and writes `TimeGenerated` from the event
  timestamp; it no longer interpolates environment variables into its configuration unless
  started with `--dangerously-allow-env-var-interpolation`; its file source logs the start of a
  line it discards for exceeding `max_line_bytes` (field `truncated_bytes`, target
  `vector::internal_events::file::source`) (Vector source at tag v0.61.0 and the running image).
- A VM's `customData` cannot change after creation; its `userData` can, and the VM reads it
  from the instance metadata service (Microsoft Learn, "User data for Azure Virtual Machine").
- Ubuntu 26.04 LTS is published for Azure as `Canonical:ubuntu-26_04-lts:server` (Canonical's
  Azure image documentation), and Docker's apt repository carries the `resolute` suite.
- The gateway's log contract v2 is final: an event has `ts`, `src`, `level`, `event`, `msg`,
  `boot_id`, `seq` and an optional flat `data` object, nothing else; the phase is in every
  metrics sample; no component writes IB API connectivity codes to the volume.

## Decision

**Shipper: Vector, as an opt-in compose profile.** Alternatives considered:

| Option | Why not |
|---|---|
| Azure Monitor Agent | Azure VMs and Arc-enabled servers only; no Docker Desktop on Windows; reads files on the host, not a container volume; cannot redact before the data leaves the machine |
| Fluent Bit (`azure_logs_ingestion` output) | workable, but redaction and "absent, never 0" mapping need Lua; no built-in unit-test framework for the mapping |
| HTTP Data Collector API (shared key) | retired; the workspace shared key is a long-lived secret that authorises writing to any table of the workspace |
| Vector | one static binary, a tested mapping language with unit tests, end-to-end acknowledgements, managed-identity and certificate authentication built into the sink |

**Direct DCR, three streams, `transformKql: source`.** One rule, no data collection endpoint
unless the operator asks for private link. The rule passes rows through unchanged: mapping and
redaction happen in Vector on the host. The columns are literals in `tables.bicep` and
`dcr.bicep`; a test compares the compiled template with the rows the real container emits from
lines of a real gateway run, and fails on a fixture key the gateway does not emit.

**Events carry what the gateway writes, nothing invented.** `IbGwEvents_CL` has the columns
`Instance`, `Host`, `BootId`, `Seq`, `Src`, `Level`, `Event`, `Msg` and `Props` (the event's
`data` object plus any key the gateway adds later). There is no phase, code or account column,
because no producer exists for them.

**Redaction on the host, before shipping.** A DCR transformation would run after the data has
left the host and reached Microsoft's ingestion pipeline; the rule "an account id leaves the
container only as its last three characters" would then depend on a cloud-side query nobody
unit-tests. On the host the redaction is one tested VRL file applied to every string of every
event and raw row, and it protects every destination, not only Azure.

**Raw logs are opt-in.** Events and metrics never contain the user name; raw IBC text can. The
shipper therefore ships raw lines only when it is given the user-name file (the name becomes
`[USER]`, in any case) or the operator explicitly accepts shipping it (`SHIP_RAW_LOGS=yes`).
Every other state, including an inconsistent one or a user-name file that cannot be matched
(empty, UTF-16, more than one word), ships nothing or stops the shipper (fail closed). The
default table plan for raw lines is Auxiliary, the cheapest that a DCR can write to.

**Memory buffers with end-to-end acknowledgements, not disk buffers.** A file position is
checkpointed only after Azure accepted the rows up to it; the gateway's log files are the
backlog. Two reasons against Vector's disk buffer: rows that were already mapped would survive
a restart, so raw rows mapped under `SHIP_RAW_LOGS=yes` would still be shipped unredacted after
the operator tightened the setting (with memory buffers the lines are mapped again under the
setting in force; a test proves it on a blocked sink); and with disk buffers on Vector 0.61.0
the rows read at start-up sometimes stayed undelivered until the next row of the same stream
arrived (1 of 20 starts and twice more in the test suite; 0 of 40 starts with memory buffers).
The price is at-least-once delivery: a row can arrive twice.

**History older than 36 hours is dropped, visibly.** Azure would stamp such rows with their
arrival time; a replayed backlog would then appear as fresh events and mislead the alert rules.

**Vector's file-source log messages are switched off** (`VECTOR_LOG` set by the entrypoint).
They would print the start of a discarded over-long line, user name and account id included,
into `docker logs`. The counters the shipper prints every minute (`open_files`,
`component_errors_total` with `error_code`) carry the same information without content.

**Three consolidated alert rules.** Log search rules are billed per rule and frequency, so the
conditions share rules: A "human needed" and B "health" every 5 minutes, C "dead man" every
15 minutes, resolving by themselves. A and C split by `Instance`, `Host` and `Condition`, B by
`Instance` and `Condition`; the shipper refuses to start without a label of its own, because
two gateways with the same labels would hide each other. Rule A is defined on events (the
earliest second-factor prompt without a completed login after it), not on the duration of a
phase: an unanswered prompt times out and is renewed every three minutes, so no phase ever
lasts as long as the threshold. Alerts notify a human; nothing restarts the gateway or touches
the second factor.

**A small entrypoint script instead of environment interpolation.** Vector's `auth` block is a
tagged enum (one static file cannot serve both identity kinds) and environment interpolation
is behind a "dangerously" switch. A POSIX entrypoint validates the values (one line, no control
character), renders the sink template for the chosen identity and decides the raw-log mode;
hence the alpine image variant and two compose profiles (`azure`, `azure-cert`), the second
being the only one that mounts the certificate.

**The VM template takes no IBKR credential.** A deployment parameter is stored in the
deployment history and visible to everyone who can read the resource group. The template
creates a Key Vault; the operator sets `ib-username` and `ib-password` afterwards and the VM's
managed identity (Key Vault Secrets User, nothing more) reads them into tmpfs at start. The
template assigns roles only to the VM's identity and, when asked, to the operator.

**The VM's settings live in userData; customData is a fixed bootstrap.** Everything an
operator may change later (image digests, the commit of this repository, labels, the raw-log
switch, gateway settings) is in the userData document; the host scripts come from the pinned
commit. `apply-config.sh` on the VM re-reads the userData and applies it. It never restarts
the gateway on its own: a change that would re-create the gateway container is announced and
refused without `--restart-gateway`, and refused in any case while a second factor is pending.
The first-boot bootstrap is a systemd unit that retries with back-off, and the stack unit
`Wants=` the Docker unit instead of requiring it, so a Docker restart does not restart the
gateway (with `live-restore`).

## Consequences

### Positive

One shipper for Windows, Linux and Azure; no secret for managed identity, a certificate
elsewhere; redaction, mapping and schema are tested offline (unit tests, the real container on
real gateway lines, schema-drift check, static KQL analysis with scenario timelines, the host
scripts with fakes); the gateway never depends on the shipper, and a silent shipper is visible
through rule C.

### Negative

- A second container; the alpine image has a shell.
- Delivery is at least once (duplicates after a restart or an outage); what the gateway rotates
  away during an outage, and anything older than 36 hours, is lost.
- Alert latency is 5 to 15 minutes plus ingestion (rule C: 25 to 30 minutes in the worst case);
  a seconds-scale second-factor page needs the sidecar notifier.
- Two sink templates must stay identical except for `auth` (a test enforces it).
- The user name is held in the shipper's process environment while it runs (it must know the
  name to redact it); it is never printed, written to disk or shipped.
- With the file-source messages off, a file that cannot be watched or a discarded line shows
  only as a counter, without the file name.
- Vector measures batch size on the in-memory event, not on the JSON text; the 1 MB bound is
  therefore argued (short tokens; control characters removed; raw batches at 450 KB), not
  enforced byte-exactly. An oversized call is rejected by Azure, dropped and counted.
- From reading Vector's source, a request whose token cannot be obtained with an error other
  than a time-out (wrong client id, expired certificate) is not retried and its batch fails; a
  time-out is retried (observed). An expired certificate therefore stops delivery until it is
  renewed; rule C reports it.
- The alert queries are type-checked against the deployed schema together with eight scenario
  timelines, but not executed: running them needs Microsoft's Kusto emulator, whose licence the
  operator has to accept (`KUSTO_EMULATOR_EULA=accept azure/tests/run.sh kql-run`).
- Not verified, because nothing was deployed: ingestion end to end, managed-identity and
  certificate authentication in the sink, the role assignments, alert evaluation (the logic of
  rule A included) and notification, workbook and query-pack rendering, the deployment-time
  refusals (`fail()` for a malformed maintenance window, image or commit), and everything on
  the VM: first boot and the bootstrap unit, `apply-config.sh` against the real metadata
  service and Docker, the patch window, and that a Docker restart leaves the gateway running.

## Follow-ups

- **Probe results and IB API connectivity codes** (1100, 1101, 1102, farm codes). Only an API
  client sees them. When a component (the sidecar's probe) writes them to the log volume, add
  the stream or event, a `connectivity_lost` condition to rule B and a codes tile to the
  workbook. Until then the pack has neither, on purpose.
- Run the scenario timelines in the Kusto emulator in CI once its licence terms are accepted
  for this repository.

## Revisit trigger

Vector ships a sink option that selects the credential kind without a second file, drops the
`azure_logs_ingestion` sink, stops printing discarded lines or fixes the disk-buffer start-up
stall; Azure Monitor Agent learns to read container volumes on Docker Desktop; alert rules on
Auxiliary tables become available (raw-line alerts); or the first live deployment contradicts
one of the unverified items above.
