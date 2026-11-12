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
  Azure Monitor service limits).
- Table plans: Analytics supports alert rules; Basic supports simple log alerts; Auxiliary
  supports none, accepts DCR-based custom tables with `transformKql: source`, and cannot change
  its plan after creation (Microsoft Learn, "Azure Monitor Logs" feature table and the
  Auxiliary table instructions).
- `ingestion_time()` is refused only in alert rules evaluated every minute (Microsoft Learn,
  "Create log search alert rules").
- List prices: Analytics ingestion $2.30/GB, Basic $0.50/GB, Auxiliary $0.05/GB; a log search
  alert rule $1.50 per month at 5 minutes and $0.50 at 15 minutes (Azure Retail Prices API,
  East US).
- Vector 0.61.0 (released 2026-10-29) has the `azure_logs_ingestion` sink with
  `auth.azure_credential_kind` values `managed_identity` and `client_certificate_credential`
  (PKCS#12 file); it sends uncompressed JSON arrays and writes `TimeGenerated` from the event
  timestamp; it no longer interpolates environment variables into its configuration unless
  started with `--dangerously-allow-env-var-interpolation` (Vector source at tag v0.61.0 and
  the running image).
- Ubuntu 26.04 LTS is published for Azure as `Canonical:ubuntu-26_04-lts:server` (Canonical's
  Azure image documentation), and Docker's apt repository carries the `resolute` suite.

## Decision

**Shipper: Vector, as an opt-in compose profile.** Alternatives considered:

| Option | Why not |
|---|---|
| Azure Monitor Agent | Azure VMs and Arc-enabled servers only; no Docker Desktop on Windows; reads files on the host, not a container volume; cannot redact before the data leaves the machine |
| Fluent Bit (`azure_logs_ingestion` output) | workable, but redaction and "absent, never 0" mapping need Lua; no built-in unit-test framework for the mapping |
| HTTP Data Collector API (shared key) | retired; the workspace shared key is a long-lived secret that authorises writing to any table of the workspace |
| Vector | one static binary, a tested mapping language with unit tests, disk buffers, managed-identity and certificate authentication built into the sink |

**Direct DCR, three streams, `transformKql: source`.** One rule, no data collection endpoint
unless the operator asks for private link. The rule passes rows through unchanged: mapping and
redaction happen in Vector on the host. The columns are literals in `tables.bicep` and
`dcr.bicep`; a test compares the compiled template with the rows the real container emits.

**Redaction on the host, before shipping.** A DCR transformation would run after the data has
left the host and reached Microsoft's ingestion pipeline; the rule "an account id leaves the
container only as its last three characters" would then depend on a cloud-side query nobody
unit-tests. On the host the redaction is a tested VRL mapping, and it protects every
destination, not only Azure.

**Raw logs are opt-in.** Events and metrics never contain the user name; raw IBC text can. The
shipper therefore ships raw lines only when it is given the user-name file (the name becomes
`[USER]`) or the operator explicitly accepts shipping it (`SHIP_RAW_LOGS=yes`). Every other
state, including an inconsistent one, ships nothing (fail closed). The default table plan for
raw lines is Auxiliary, the cheapest that a DCR can write to.

**Three consolidated alert rules.** Log search rules are billed per rule and frequency, so the
conditions share rules: A "human needed" and B "health" every 5 minutes, C "dead man" every
15 minutes, each split by `Instance` and `Condition` and resolving by itself. Alerts notify a
human; nothing restarts the gateway or touches the second factor.

**A small entrypoint script instead of environment interpolation.** Vector's `auth` block is a
tagged enum (one static file cannot serve both identity kinds) and environment interpolation
is behind a "dangerously" switch. A POSIX entrypoint validates four values, renders the sink
template for the chosen identity and decides the raw-log mode; hence the alpine image variant
and two compose profiles (`azure`, `azure-cert`), the second being the only one that mounts
the certificate.

**The VM template takes no IBKR credential.** A deployment parameter is stored in the
deployment history and visible to everyone who can read the resource group. The template
creates a Key Vault; the operator sets `ib-username` and `ib-password` afterwards and the VM's
managed identity (Key Vault Secrets User, nothing more) reads them into tmpfs at start. The
template assigns roles only to the VM's identity and, optionally, to the operator.

## Consequences

### Positive

One shipper for Windows, Linux and Azure; no secret for managed identity, a certificate
elsewhere; redaction, mapping and schema are tested offline (unit tests, the real container on
fixtures, schema-drift check, static KQL analysis); the gateway never depends on the shipper,
and a silent shipper is visible through rule C.

### Negative

- A second container and about 0.8 GB of disk for buffers; the alpine image has a shell.
- Alert latency is 5 to 15 minutes plus ingestion; a seconds-scale second-factor page needs
  the sidecar notifier.
- Two sink templates must stay identical except for `auth` (a test enforces it).
- The user name is held in the shipper's process environment while it runs (it must know the
  name to redact it); it is never printed, written to disk or shipped.
- Vector measures batch size on the in-memory event, not on the JSON text; the 1 MB bound is
  therefore argued (short tokens; control characters removed; raw batches at 450 KB), not
  enforced byte-exactly. An oversized call is rejected by Azure, dropped and counted.
- From reading Vector's source, a request whose token cannot be obtained with an error other
  than a time-out (wrong client id, expired certificate) is not retried and its batch is
  dropped; a time-out is retried (observed).
- Not verified, because nothing was deployed: ingestion end to end, managed-identity and
  certificate authentication in the sink, the role assignment, alert evaluation and
  notification, workbook rendering, the VM's first boot and patch window.

## Revisit trigger

Vector ships a sink option that selects the credential kind without a second file, or drops
the `azure_logs_ingestion` sink; Azure Monitor Agent learns to read container volumes on
Docker Desktop; alert rules on Auxiliary tables become available (raw-line alerts); or the
first live deployment contradicts one of the unverified items above.
