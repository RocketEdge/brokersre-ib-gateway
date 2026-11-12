# Change Log — brokersre-ib-gateway

Append-only; newest first. Fields: Date, What changed, Result, What did NOT work / root cause,
Next step.

## Change History

### 2026-11-12 — Supply chain: both platforms gated on the pushed digest, fix-driven rebuilds, VEX for the vendor jars

- **What changed:** `publish.yml` builds both platforms once without a cache, pushes the index
  by digest only, scans linux/amd64 and linux/arm64 of that digest, makes one SBOM per
  platform attested to that platform's manifest, signs and attests the index (VEX,
  provenance) and only then moves tags (`scripts/promote-tags.sh`). `rebuild.yml` scans the
  published images daily and requests a rebuild of a channel with a fixable CRITICAL/HIGH OS
  finding, with one issue per channel, one comment per day and no request after three days.
  The channel list, the tag overlap of the two channels, the platform of every scan report,
  the platform manifests of the index and the rebuild request are decided by tested scripts;
  the two workflows serialise per channel, hold no expression inside a script and pin every
  action by commit and Trivy to v0.76.2. `security/vex/ibgateway-vendor-jars.openvex.json`
  states the project's position on the 25 CVEs of IBKR's bundled jars (all
  `under_investigation`); `scripts/check-vex.sh` reports drift. New: `docs/evidence.md`, ADR
  0015. **Breaking for consumers of release assets:** `sbom-<channel>.cdx.json` becomes
  `sbom-<channel>-linux-amd64.cdx.json` and `-arm64.cdx.json`, the SBOM attestation is on the
  platform manifest digest, `digests-<channel>.json` gains `platforms`, and the documented
  verification identity ends in `@refs/heads/main$`.
- **Result:** CI-script suite green inside the image (counts in the pull request; 134 of its
  tests are new) and, in the builder's run, under gawk on Ubuntu 24.04. A manual scan of both
  platforms of the digests published on 2026-11-11 found no fixable OS finding of any
  severity. **No workflow has run yet**: they run only from `main`.
- **What did NOT work / root cause:**
  - *The gate was never "CRITICAL/HIGH".* trivy-action drops the severity input when the
    format is SARIF, so with `exit-code: 1` the gate failed on a fixable finding of any
    severity. Fixed with `limit-severities-for-sarif: "true"` where SARIF is the gate format.
  - *Scanning a local amd64 build never scanned what was pushed*, and arm64 not at all.
    Scanning an OCI layout before any push was rejected: it needs a second tool to push the
    scanned layout. Pushing by digest costs an untagged, unsigned manifest in the registry
    when a gate fails (L23).
  - *One SBOM for a two-platform image described one platform.* syft reads the runner's
    platform from an index: 9,776 components for amd64, 9,946 with `openjdk-25-jre` for arm64.
  - *A workflow-wide concurrency group lost work*: a request for one channel replaced a
    pending run for both.
  - *`inputs.channels` was pasted into shell*; the allow-list ran after the paste.
  - *The documented identity regexp accepted any branch.*
  - *`not_affected` was not defensible for any jar CVE.* Loopback exposure does not show that
    the Gateway never parses hostile input; two CVE texts exclude 2.12.3 but the advisory
    data disagrees.
  - *A bare `! command` in a bats test asserts nothing unless it is the last line.* Twelve
    such lines existed across the suites, several of them guarding "no secret appears here";
    all now end in `|| false` and still pass. A four-test probe showed the difference.
  - *jq's `^` and `$` match per line*, so an anchored check let a line break through.
  - Deleting the untagged image of a failed gate was rejected: only the index can be deleted
    safely, and the platform manifests hold the bulk.
- **Next step:** merge this change on its own; run `rebuild.yml` by hand with mode `scan`,
  then watch the publish run of the merge, and record the first run ids here.

### 2026-11-12 — Optional sidecar: API probe, status endpoints, alerts (`sidecar/`)

- **What changed:** a second, optional image. It reads the gateway's log volume read-only,
  probes the API through the relay port (handshake, server time, connectivity notices, clock
  skew; no order, cancel or what-if call exists in it), serves `/livez`, `/readyz`, `/status`
  and `/metrics` on port 9810, and notifies people through seven channels with an escalation
  ladder. It runs in its own network namespace by default, announces a gateway that stopped,
  exited or fell silent, can ping a dead-man check, and names the cause when the gateway
  holds because of the rejected-login latch. ADR 0010; workflows `sidecar.yml`,
  `sidecar-publish.yml`, `sidecar-rescan.yml`.
- **Result:** Python gates clean and the tests green (counts in the pull request); container
  smoke suite and the end-to-end run with the real gateway image green, including a
  notification delivered after `docker stop` of the gateway. Nothing ran against a logged-in
  Gateway (L20).
- **What did NOT work / root cause:**
  - *A sidecar inside the gateway's network namespace is mute exactly when it is needed*: when
    the gateway container stops it keeps only loopback and cannot send anything. The first
    design shared the namespace to reach the loopback API; the default is now its own
    namespace and the relay port, and the shared mode is an option that says what it cannot do.
  - *"Second factor pending" derived from the phase resolved itself every three minutes*: the
    phase flips to `login` on each prompt timeout. It is derived from events, holds across the
    flip and escalates from the first prompt.
  - *An alert was recorded as sent although no channel had accepted it*, and was later followed
    by "resolved". The dispatcher now reports back; an undelivered alert is retried and
    persisted.
  - *Reset windows stored in fixed Hong Kong time covered the US close in winter.* The Asia
    windows are anchored to New York time, as IBKR's footnote implies.
  - *Image pins held in a Dockerfile `ARG` are invisible to Dependabot*: both images are named
    in `FROM` lines.
  - *One failed save of the state file switched to memory for good*; it now retries.
  - *The end-to-end job failed on its first run in GitHub Actions and never locally.* After a
    stop of the gateway the sidecar said "No action needed. The condition has cleared." about
    a stalled login: the gateway's sampler closes that pair itself while stopping, and on a
    fast machine the sidecar read the closing event before the new phase. The model now
    records which event ended the gateway's attempt before the pair closed (the feed order is
    deterministic) and the rule hands over on that.
  - *Both test scripts ended pipelines in `grep -q` under `pipefail`*, which is false when the
    writer dies of SIGPIPE; for "a credential is in the payloads: fail, else pass" that is a
    false pass. Found through the Azure pack's first Linux run; a helper that reads all
    input replaces them.
  - Not established: everything in L20 and L21.
- **Next step:** a paper login with the sidecar attached; one real message per channel; the
  first runs of the three workflows.

### 2026-11-12 — Azure Log Analytics pack (`azure/`)

- **What changed:** a pack that ships the gateway's events and resource samples (and, opt-in
  and redacted, its raw logs) to the user's own Log Analytics workspace. Bicep: three tables,
  a Direct data collection rule, the publisher role on that rule only, an action group, three
  alert rules (a person is needed; health; dead man), a workbook and a query pack. A pinned
  Vector container reads the log volume read-only (`compose/docker-compose.azure.yml`,
  managed identity or certificate). An optional second template runs the gateway on an Azure
  VM whose settings can change after creation. ADR 0012, workflow `azure-pack.yml`.
- **Result:** the pack's offline suite passes (counts in the pull request): the templates
  compile, the shipper maps and redacts lines of a real gateway run, its rows match the schema
  the templates declare, queries and scenarios type-check, the VM's host scripts run against
  fakes. Nothing has been deployed to Azure.
- **What did NOT work / root cause:**
  - *Alerting on "phase `2fa-pending` for N minutes" never fires.* With the gateway's defaults
    an unanswered prompt times out after about three minutes and the phase flips to `login`
    and back for hours. The rule is built on events: the earliest prompt without a completed
    login after it.
  - *Vector's disk buffers* sometimes held rows read at start-up until the next row of that
    stream arrived (1 start in 20), and kept already-mapped rows across a change of the
    redaction mode. The shipper buffers in memory with end-to-end acknowledgements and saves a
    file position only after delivery: at least once, never zero times while the line is
    still in the gateway's files.
  - *Vector logs the start of every over-long line it discards*, raw text included, whether
    raw logs are shipped or not. Its file source's log target is switched off and counters
    are printed instead; a canary test guards it at every Vector bump.
  - *A byte-order mark in the username file disabled the redaction of the username*: the file
    is normalised on its bytes, as the gateway does, and anything else is refused.
  - *Settings in the VM's customData cannot change after creation*, and `Requires=docker.service`
    stops the gateway when Docker restarts: settings travel in userData and are applied by a
    script; the unit uses `Wants=` and Docker keeps containers alive across its own restart
    (by reading systemd's and Docker's rules; not observed on a VM).
  - *The suite passed on the development host and failed on its first run in GitHub Actions.*
    Several checks compare a tool's output together with its standard error; on a machine
    that has not pulled a helper image yet, Docker's "Unable to find image ... Pulling" notice
    lands in the compared value. Reproduced locally by removing the cached image; the suite
    now pulls every helper image before any check runs, and the workflow runs every group
    even after one failed, so one run shows all that is wrong.
  - *The second run failed on a counter that was there.* The suite runs under `pipefail`, and
    `docker logs | grep -q` fails when the quiet grep exits at its first match and the writer
    dies of SIGPIPE: the check reported "no such counter" 58 seconds into a 90-second wait,
    the moment the counter appeared. Shown on Linux (`seq | grep -q` under pipefail exits
    141); no pipeline in the pack ends in a quiet grep any more, including the Docker key
    check of the VM's `install.sh`, where the same race would have rejected the right key.
  - Not established: everything that needs Azure (L19). The alert queries were type-checked,
    not executed: the only local engine is Microsoft's Kusto emulator, whose licence must be
    accepted by a person first (`KUSTO_EMULATOR_EULA=accept azure/tests/run.sh kql-run`).
- **Next step:** one deployment to a test subscription with a gateway shipping for a day; run
  each alert rule's condition once; run the `kql-run` group.

### 2026-11-12 — A rejected login is not repeated: the latch on the log volume

- **What changed:** when IBKR rejects the credentials the classifier records it in
  `state/login-rejected` (`login_latch_set`). At every later start the entrypoint compares the
  record with the current secret files before IBC is started: unchanged files mean no login,
  phase `needs-human`, the container held (`login_rejected_latched`). A rewritten secret file,
  `LOGIN_LATCH=clear` or a completed login removes the record (`login_latch_cleared`). The
  preflight has a check `login_latch`. New setting `LOGIN_LATCH` (`on`, `clear`, `off`). ADR
  0016.
- **Result:** unit and container suites green (counts in the pull request). In the container
  suite a recorded rejection stops the next start before any Java process exists, the
  container stays up and unhealthy, the resource samples go on, and rewriting the password
  file lets IBC start again.
- **What did NOT work / root cause:** (1) *the hold in phase `needs-human` ended with the
  container.* A restart policy, a reboot or a start task made a new attempt with the same
  rejected credentials at every start; a review of the Windows host kit found the path, and
  it existed on every host. (2) *A hash of the password was not an option*, keyed or not: the
  key would lie next to it on the volume. The latch therefore identifies the secret FILES by
  their modification times, which is why credentials in plain variables need an explicit
  `LOGIN_LATCH=clear`. (3) *The preflight must not fail for a held latch*: a failed preflight
  makes the container exit, and the restart policy would then loop for ever. It warns; the
  entrypoint holds. (4) *Two container checks could not fail*: `pgrep -f ibcalpha.ibc` inside
  `bash -c` matches the shell that runs it. The new "no Java process" check failed for that
  reason, which showed that the older "IBC/Gateway Java process running" check had always
  passed for it. Both now look at a process named `java` and its command line.
- **Next step:** observe one real cycle of rejection, correction and login; collect real logs
  of other rejections (expired password, locked account) and decide whether they set the
  latch too (L18).

### 2026-11-12 — Client kit: several gateways per host, readiness samples, gnzsnz converter

- **What changed:** new files, plus their entries in the README, the migration guide, the
  variable reference and CI. `compose/docker-compose.multi.yml` (live and paper side by side, a
  commented block for further usernames) with `compose/README.md`;
  `scripts/check-compose-usernames.sh`; `examples/` (`wait-for-gateway.sh`,
  `compose-with-client.yml`, a Python and a C# read-only client, the readiness rules in plain
  words); `scripts/migrate-from-gnzsnz.sh`; `tests/compose/run.sh` and bats tests for all of it.
- **Result:** compose suite 57/57; CI-script suite 83/83; unit suite 411/411 inside the image;
  Python sample 136 tests with ruff, black and mypy strict clean; C# logic 88 tests, 0
  warnings. Measured with the real ib_async against a stand-in gateway: a read-only connection
  sends start-API, a positions request and the server time, nothing else.
- **What did NOT work / root cause:**
  - *ib_async is not silent by itself.* `connectAsync(readonly=True, fetchFields=StartupFetchNONE)`
    still requests positions; its error handler opens a new, never-cancelled account-summary
    subscription on every 1102 (IBKR allows two); its `timeout` applies to each connect step
    separately; its loggers print IBKR's message text verbatim. The sample detaches the handler,
    puts one deadline around the connect and silences those loggers.
  - *IBKR's C# client cannot be shipped.* It is IBKR's licensed software and not an official
    NuGet package, so the adapter project takes the path of the user's own `CSharpAPI.dll` and
    sits outside the solution; the logic is tested behind `IBrokerSession` without it. IBKR's
    threads still call back after a disconnect, so each connection has its own wrapper object.
  - *An `internal: true` network alone cuts the gateway off from IBKR*: the example gives the
    gateway a second network for its way out.
  - *A converted `.env` did not apply through `env_file:` alone*: the reference compose
    interpolates four variables from the compose env file and passes nothing else on.
  - *`docker compose down` without `--profile` stops nothing* for the multi-gateway file.
  - *A bash-only watchdog for the handshake probe was dropped*: killing the subshell leaves a
    blocked `dd` behind; `timeout` ends the whole group.
  - *The converter's copy of the preflight's variable names went stale within a day*: three
    branches added variables after it was written, and only its own test noticed. The copy
    stays (the converter must run outside the image); the test is the guard.
  - Not established: any of this against a real IB Gateway; the C# adapter against a TWS API
    release other than 10.48.01.
- **Next step:** run `wait-for-gateway.sh` and both clients against a logged-in paper gateway.

### 2026-11-12 — Optional allowlist for the relay (`RELAY_ALLOW_CIDR`)

- **What changed:** `RELAY_ALLOW_CIDR` (one IPv4 network) makes the relay serve peers in that
  network only (socat `range=`). A peer outside it is closed without a byte of the API and
  reported as `relay_refused`: the first at once, later ones as one count per
  `RELAY_REFUSED_REPORT_S` (60 s), so a port scan cannot flood the events. An unusable value
  stops the start (`config_invalid`; the preflight reports it as a failure of
  `relay_exposure`). Unset, the relay is started exactly as before.
- **Result:** unit tests green (counts in the pull request), two of them with the image's real
  socat: a peer inside the network is relayed, a peer outside gets nothing and is reported.
- **What did NOT work / root cause:** (1) several networks are not possible with socat: a
  second `range=` is silently ignored (measured with socat 1.8.1.1), so the option takes
  exactly one and refuses a comma. (2) The allowlist cannot separate clients that arrive
  through a published port on Docker Desktop: the relay sees the bridge gateway
  (`172.17.0.1` in the measurement), not the client. It is a second line for clients on a
  shared Docker network, not a replacement for the port binding (L17). (3) socat does not
  start at all with a log file it cannot open, so the relay tests the file first and runs
  without reports rather than without a relay. (4) A test of mine hung instead of failing:
  a start that should have been refused left a supervisor that held the pipe of bats' `run`;
  the test now writes to a file and the teardown ends stray supervisors.
- **Next step:** measure the peer address on Docker Engine with a remote client (L17).

### 2026-11-12 — Qualification: one real paper login per image, and an API-level health check

- **What changed:** (1) `api-handshake.sh` sends the TWS API version handshake to the loopback
  API port and reads the server version; it sends nothing else (no `startApi`, no client id, no
  request). (2) `HEALTHCHECK_API=handshake` makes the container health check use it; the
  default stays `port`. (3) `scripts/qualify-paper.sh` starts one image with paper credentials
  from secret files, waits for phase `logged-in`, checks health, the handshake through the
  relay, the event file, the resource samples and a graceful stop, and writes
  `qualify-out/result.json` (`brokersre.qualification.v1`). It makes one login attempt and
  never answers a second factor. (4) Workflow `qualify-paper.yml`: dispatched by hand, from
  `main`, for an image digest, in the environment `paper-qualification` (required reviewer);
  it can attach the result to the image as an attestation. ADR 0014; invariant 9 now names
  this one sanctioned login.
- **Result:** unit and container suites green (counts in the pull request). The script's
  failure path is proven offline (`--network none`: result `fail`, reason recorded, container
  removed, exit 1). The handshake is proven against stand-in servers (answer, silence, garbage,
  closed port). The success path is **not** proven: no login has succeeded on this image yet.
- **What did NOT work / root cause:** (1) the first real paper login was rejected by IBKR
  ("Unrecognized Username or Password"); the image passed the credentials through unaltered
  (compared byte for byte with the rendered configuration), so the attempt was not repeated: a
  second wrong attempt only moves the account towards a lockout. (2) A health check on the
  open port alone reports healthy for a Gateway whose API thread hangs; the handshake closes
  that gap, but it stays opt-in until a real session shows it is free of side effects (L15).
  (3) `qualify-paper.sh` was first written before its test ran; the test was then run with the
  script's checks removed and failed for the right reason before the checks went back in.
- **Next step:** a first qualified run with credentials IBKR accepts (L16); after three
  recorded passes, move `stable` only when a `qualified-paper` attestation exists (L04).

### 2026-11-12 — Pattern table corrected from IBC's source; phase writes serialised and held while the gateway ends

- **What changed:** (1) three rows of `ibc-patterns.tsv`: `login_completed` is anchored at the
  end of the line, `daily_restart` matches the start script's real line
  (`autorestart file found at <path>: authentication will not be required`), and
  `relogin_required` matches the dialog only. (2) `phase_write` in `log.sh` is now the only
  writer of `state/phase`: writes are serialised by a lock, each uses a temporary file of its
  own, and the classifier's writes are held back while the phase is `stopping`, `stopped` or
  `exited`. (3) Two timing-sensitive tests wait longer or for their own processes only.
- **Result:** unit suite green (counts in the pull request). A stop of a logged-in Gateway can
  no longer flip the phase back to `logged-in`, so the gated relay stays closed while the
  Gateway exits.
- **What did NOT work / root cause:** the first v2 table was written from single lines of
  IBC's source without searching for every place that writes similar text. (a) `StopTask.java`
  logs `Login has completed: exiting via [File, Close] menu` when it stops a logged-in
  Gateway; the unanchored row read that as a login and set `logged-in` during shutdown, which
  would have reopened the relay. (b) The autorestart line is an `echo` of `ibcstart.sh` with
  no `IBC:` prefix, so the `daily_restart` row could never match. (c) IBC logs the Re-login
  dialog and its own `Re-login to session`, so one re-login was two events. All three were
  found by the paired change in the BrokerSRE agent, which re-read the source; none could show
  in the tests here, because the synthetic fixture had been written from the same wrong
  assumptions. Separately, the entrypoint and the classifier wrote the phase through the same
  temporary file name without a lock: a rename of one writer could publish the half-written
  file of the other. Also learned: a unit run through the Windows file share took an hour
  (listing 500 files: 42 s), and one relay test missed its 5 s budget under that load.
- **Next step:** real lines for these rows from a successful session (L01, L09); the agent's
  vendored copy of the table is refreshed after this merges.

### 2026-11-12 — Log contract v2: events on the volume, `needs-human`, gated relay, preflight, resource samples

- **What changed:** (1) every event is written to stdout and, as the identical line, to
  `events/events.jsonl`, with a per-start `boot_id` and a gap-free `seq`; `container_start` and
  `config_rendered` carry structured `data` (versions; a fingerprint of the non-secret
  configuration). (2) New phase `needs-human` for a rejected login and for the optional
  second-factor cap `TWOFA_MAX_PROMPTS`; the entrypoint holds the container up in that phase.
  (3) `unknown_window` for a window that neither the pattern table nor the list of titles IBC
  handles knows. (4) The relay listens only while the phase is `logged-in`
  (`RELAY_MODE=gated`). (5) `JAVA_HEAP_MB` sets the heap at run time (number or `auto`); the
  JVM exits on OutOfMemoryError. (6) `doctor`: a preflight as a command and at every start.
  (7) `sampler.sh`: `metrics/metrics.jsonl` from the container's own cgroup and `/proc`, with
  the events `oom_kill`, `memory_high`, `disk_low`, `login_stalled`. ADR 0013, schema
  `log-event.v2.schema.json`, `docs/log-contract.md` rewritten for v2.
- **Result:** unit suite and container suite green (counts in the pull request); in a real
  offline run the events are numbered 1..13 without a gap across the entrypoint, the preflight,
  the classifier and the relay, the Gateway itself reports the 1024 MB heap that
  `JAVA_HEAP_MB=1024` asked for, the relay refuses connections before a login, and the last
  resource sample is written at shutdown.
- **What did NOT work / root cause:**
  - *The first heap resolver printed its result and was called with a redirect*, so its error
    event would have gone into a temporary file instead of stdout; it now sets a variable.
  - *The time-format rule first given to the preflight was wrong.* IBC parses the restart time
    with the pattern `hh:mm a`: `1:05 AM` is rejected and `00:15 AM` accepted, the opposite of
    the lenient pattern in the brief. Found by running IBC's own parser from the image's
    `IBC.jar` instead of trusting the documentation.
  - *A preflight that can stop a working gateway is worse than none.* Three checks (an
    unverifiable time zone, a percentage-only disk rule, a crashed check) could have stopped a
    container that runs today; they are warnings now, and a failure is reserved for conditions
    under which the gateway cannot work or would send IBKR a wrong login.
  - *An out-of-memory kill of the Gateway would not have been reported*: IBC exits, the
    container ends and its cgroup is gone before the next 30 s sample. The sampler now takes a
    last sample when it is stopped, and the entrypoint waits for it (bounded, then SIGKILL).
  - *A suspected "zombie child" bug in the relay supervisor was not real.* The failing test had
    a race of its own (it read a counter once instead of polling); both liveness checks passed
    every time once the test was fixed, so the extra helper was removed again.
  - *A fingerprint of the configuration that included the credentials* would let a reader of the
    events test password guesses offline; the fingerprint leaves them out, and a test proves it.
  - Not established: everything that needs a successful login (see `docs/limitations.md` L09
    to L13).
- **Next step:** the qualification script and workflow (ADR 0014), then the sidecar, which reads
  exactly this contract.

### 2026-11-12 — First real login attempt: read-only login hang fixed, Windows-written secrets, real log patterns

- **What changed:** the image met IBKR's login servers for the first time (IB Gateway 10.50.1g,
  paper mode, operator-run on a workstation; CI still never logs in). Seven fixes, each with
  tests written first: (1) `java-env.sh` gives the Gateway JVM a writable `user.home` on the
  settings volume through `_JAVA_OPTIONS`; (2) `file_env` accepts secret files written on
  Windows (trailing CR/LF and a UTF-8 byte-order mark removed; UTF-16 and empty files refused
  with `secret_unreadable`); (3) the username and password are escaped for IBC's `.properties`
  parser; (4) `ibc-patterns.tsv` matches what IBC really logs; (5) the VNC password no longer
  appears in a process argument list; (6) `rotating-append.sh` caps `ibc.log` and the mirrored
  Gateway logs, and the mirror resumes after a restart instead of copying everything again;
  (7) the reference compose is hardened (`cap_drop: [ALL]`, `stop_grace_period: 90s`, open-file,
  process, memory and log-size limits, image and secrets directory overridable) and is now
  started as shipped by the container suite. The README quick start is rewritten (PowerShell
  5.1/7 and bash, secrets under `compose/secrets/`), and its version table is generated from
  `versions.json` by `scripts/readme-versions.sh` (checked in CI, regenerated by the detect
  workflows).
- **Result:** unit suite 73/73 inside the image, container suite 37/37, CI-script suite 31/31.
  A login with a made-up username under `read_only: true` and `cap_drop: ALL` reaches IBKR's
  "Unrecognized Username or Password" dialog (before the fix it never got that far); a graceful
  stop took 2 s. The credential escaping round-trips byte for byte through
  `java.util.Properties.load` in a JDK 25 container. The secret-writing commands of the quick
  start produce the exact UTF-8 bytes under Windows PowerShell 5.1 and PowerShell 7.6.
- **What did NOT work / root cause:**
  - *Login never completed under a read-only root filesystem, and nothing was logged.* The
    Gateway writes `.hwid` into the JVM's `user.home` during login; the image home is read-only,
    so the Gateway opened a modal "directory not accessible" warning that IBC does not handle
    and the login thread waited behind it forever (thread dump: `warnDirectoryNotAccessible`).
    The Dockerfile's two `-D` lines in `ibgateway.vmoptions` were meant to redirect Java's
    paths, but `ibcstart.sh` drops every `-D` line and clears `JAVA_TOOL_OPTIONS`, so they never
    reached the JVM (`/proc/<pid>/cmdline`). They are removed; `_JAVA_OPTIONS` is the mechanism
    that works. The offline smoke test could not have caught this: the write happens only after
    the Gateway has connected to IBKR.
  - *`login_dialog` never fired and one rejected login produced three events.* The login window
    is titled "IBKR Gateway", not "IB Gateway", and IBC logs each dialog as Opened, Activated
    and Focused. The synthetic fixture had encoded the same wrong assumptions as the patterns.
  - *The quick start could not work on any system:* it wrote the secrets to `./secrets/` while
    the compose file reads `compose/secrets/`; Docker then mounted empty directories as secrets
    and the container restarted in a loop with `config_missing`.
  - *A first rotation design (copy and truncate behind `tee`) was dropped* because lines written
    between the copy and the truncate are lost; the writer now owns the file and renames it
    between two lines.
  - Not established: a successful login. The paper credentials supplied for the test were
    rejected by IBKR (the image passed them unaltered, verified by hash), so the patterns for
    second factor, login completion, daily restart and competing session, and the paths written
    after login, are still unconfirmed (L01 to L03 are "partly resolved").
- **Release records superseded by this merge** (it changes `rootfs/**` and the Dockerfile, so
  `publish.yml` republishes both channels): `v10.50.1g-stable` image
  `sha256:693bd6306d94708a87e5b0c43180874f671010a5edf142796eb8f46f51e869ea`, assets
  `digests-stable.json` `68c4f964…0556` / `sbom-stable.cdx.json` `be3cbe4e…5111`;
  `v10.51.1e-latest` image
  `sha256:275717e7466f30e5615cc79f7b301171da3bdb740d39a72625dd5b0c567c8052`, assets
  `digests-latest.json` `eb4f0af6…f1de` / `sbom-latest.cdx.json` `a55c6104…5c43`.
- **Next step:** repeat the login with working paper credentials and record a successful
  session (closes L01 to L03); then contract v2 (events on the log volume, `needs-human`
  phase, preflight `doctor`), tracked in `tasks/todo.md`.

### 2026-11-11 — Stable updates merge themselves; archive pre-fetch in CI; re-uploads reported

- **What changed:** `detect-releases.yml` hashes both installers daily and hands the policy to
  `scripts/release-decision.sh` (bats-tested): a new `stable` version's pull request gets
  auto-merge (with `BOT_TOKEN`), a new `latest` version waits for a human, and different bytes
  under the pinned version open an `ibkr-reupload` issue. `ci.yml` and `publish.yml` pre-fetch
  archived installers through `scripts/prefetch-installers.sh`, which keeps only copies matching
  the pin. Auto-merge is allowed on the repository; the private archive got its first commit and
  the installers pinned today (`ibgateway-stable@10.50.1g`, `ibgateway-latest@10.51.1e`). README
  sections for following releases and for creating the tokens; ADR 0009 (owner decision).
- **Result:** 23 bats tests (release policy, archive pre-fetch) pass; actionlint, shellcheck and
  shfmt clean.
- **Independent review of PR #7, fixed before merge:** (1) the daily run re-enabled auto-merge a
  human had turned off (create-pull-request returns the number of an existing PR), so auto-merge
  is now requested only when the run creates the PR, with the kill switch `STABLE_AUTOMERGE=false`;
  (2) a lower version, or a new label over unchanged bytes, would have merged itself, so
  auto-merge now needs a higher version (`sort -V`) and both installers changed; (3) a closed
  re-upload issue would reopen daily and the new bytes were never archived, so issues are keyed
  by the bytes (any state) and the bytes are archived under `ibgateway-<channel>@<version>-<8 hex
  of x64><8 hex of arm>` (both hashes, so an arm-only re-upload cannot overwrite another), which
  the pre-fetch also reads, and an unchanged archive is not uploaded again each day; (4) a
  republished version kept stale release notes,
  so `publish.yml` now rewrites them. Also: refusals go to stderr only (stdout feeds
  `GITHUB_OUTPUT`), `add-paths: versions.json`, and a missing pre-fetch destination is refused.
- **Release records superseded by this merge** (it changes `publish.yml`, which republishes both
  channels): `v10.50.1g-stable` image
  `sha256:2479cc941831a5ba9f3b810a118b8677fd082fbe2b1b8172ce142a84297439a4` (created
  2026-11-11T06:57:14Z), assets `3dafe62f…eb721` / `c8dd6a37…a9c67`; `v10.51.1e-latest` image
  `sha256:5eecf3a8fefd09908437dd6879135eda55642d38fb6c8a39bf19d0ca6cead78e` (created
  2026-11-11T06:56:31Z), assets `78899cb6…21d8f` / `8e955347…c3e1`.
- **What did NOT work / root cause:** the archive could never have worked: the repository had no
  commit, so creating a release failed with "Repository is empty" (found while seeding it by
  hand). `fetch-installer.sh` aborts the build when a pre-fetched copy does not match the pin, so
  a stale archive copy would have failed builds instead of falling back to IBKR's URL; the
  pre-fetch now drops such copies. CI never pre-fetched at all, which is why PR #6 failed once
  IBKR moved `stable`.
- **Next step:** the owner creates `BOT_TOKEN`, `ARCHIVE_WRITE_TOKEN` and `ARCHIVE_READ_TOKEN`
  (README); until then pull requests are opened with `GITHUB_TOKEN`, run no CI and do not
  auto-merge, and nothing is archived automatically.

### 2026-11-11 — `stable` moves to IBKR 10.50.1g

- **What changed:** PR #5 (opened by `detect-releases.yml`, merged by owner decision) pins
  `stable` to 10.50.1g (build `20261109 16:10:13`; x64
  `13dc8bb05cbcec8d1b0bb0b25748447cf85863fb4b94361f57fcd350f35c7a9c`, arm
  `cbd1e3f9368dcc9d517e23dd72cf10db4d045e58b46882d01ab528a0d1f8e343`, both re-checked with
  `fetch-installer.sh` against IBKR on 2026-11-11).
- **Result:** publish run 42974878793 created release `v10.50.1g-stable`, image
  `sha256:2479cc941831a5ba9f3b810a118b8677fd082fbe2b1b8172ce142a84297439a4`, and republished
  `latest` 10.51.1e as `sha256:5eecf3a8fefd09908437dd6879135eda55642d38fb6c8a39bf19d0ca6cead78e`;
  both pass `cosign verify`, the CycloneDX attestation check and the Trivy OS gate. The
  `v10.50.1f-stable` release is kept.
- **What did NOT work / root cause:** once IBKR's unversioned `stable` URL served 10.50.1g, `main`
  could no longer build its pinned 10.50.1f (CI of PR #6: `SHA-256 MISMATCH`, actual = the
  10.50.1g hash), and the 10.50.1f installer was never archived. Moving `stable` was the only fix.
- **Release record superseded:** the push also republished `latest`, overwriting the assets of
  `v10.51.1e-latest`: image `sha256:2083e887f4d982ab302b26702104b3f38c69eea817c923e417671c77ece6d37a`
  (created 2026-11-09T20:22:13Z), asset SHA-256 `f4e511b0…9ecc` (`digests-latest.json`) /
  `2d0c0503…5fed` (`sbom-latest.cdx.json`).
- **Next step:** the archive tokens would have kept 10.50.1f buildable; BrokerSRE's `image-pin.yml`
  proposes the new `stable` digest, which waits for the operator-run paper regression (R10).

### 2026-11-11 — GitHub Actions may open pull requests in this repository

- **What changed:** the repository setting "Allow GitHub Actions to create and approve pull
  requests" is on (owner decision 2026-11-11; the default workflow token stays read-only).
- **Result:** "Detect IB Gateway releases" run 42969621084 went green on attempt 3 and updated
  pull request #5 (stable 10.50.1f to 10.50.1g, both SHA-256 values re-checked against IBKR).
- **What did NOT work / root cause:** IBKR shipped stable 10.50.1g; `detect-releases.yml` pushed
  `update-stable-to-10.50.1g` but failed on 2026-11-10 and 2026-11-11 with "GitHub Actions is not
  permitted to create or approve pull requests": `BOT_TOKEN` is not set, so it used
  `GITHUB_TOKEN`, which the setting forbade. Opening #5 by hand did not make the job green:
  peter-evans/create-pull-request tries to create before it updates, and that call was refused.
- **Next step:** a pull request opened with `GITHUB_TOKEN` starts no workflows, so a release PR
  the job opens needs a close and reopen before CI runs; `BOT_TOKEN` (fine-grained PAT) avoids
  that.

### 2026-11-10 — `latest` re-pinned to IBKR's re-upload of 10.51.1e

- **What changed:** `versions.json` `channels.latest.sha256` moves to the installers IBKR serves
  since 2026-11-05 (x64 `e57858252ae21da7395e5c08884639cc45dfc15eed24a7ccd6cf4383d2826ec0`, was
  `b4d57815…0703`; arm `6aa611348ec6709b59a4a966494aa54969c7848249579dccdca0d3a333e908f6`, was
  `f1c29317…fcc5`); version and build time are unchanged because IBKR's manifest still reports
  `10.51.1e`, `20261026 16:53:53`. Owner decision 2026-11-10.
- **Result:** `scripts/fetch-installer.sh` against IBKR's live `latest` URL passes the checksum for
  amd64 and arm64 (2026-11-10); the x64 file hashed the same on two downloads.
- **What did NOT work / root cause:** the publish of PR #3 (run 42686705729) built `stable` but
  failed `latest` with `SHA-256 MISMATCH`: IBKR replaced both `latest` installers on
  2026-11-05 (`Last-Modified` 04:22:15 and 04:23:23 GMT) without changing the version label.
  `detect-releases.yml` compares only `buildVersion`, so it saw no change; the original bytes
  cannot be rebuilt because the private archive is empty (`ARCHIVE_WRITE_TOKEN` was never set).
  Trust is unchanged: the original pin was also taken from IBKR over HTTPS, and IBKR publishes no
  checksums.
- **Release record superseded:** a push publishes both channels (`publish.yml` plan defaults to
  `stable latest`), so this merge also republishes `stable` and overwrites its release assets.
  The record it replaces: `v10.50.1f-stable`, image
  `sha256:aefa03c37b90e5d897854d82a403bc7374d63e4e8af8aa9e325a5a6574b1fb6b` (created
  2026-11-09T19:55:39Z by the publish of PR #3, nothing pins it yet), asset SHA-256
  `9c13c2bd…13d4` (`digests-stable.json`) / `3610bb0a…4d13` (`sbom-stable.cdx.json`).
- **Next step:** merging publishes `latest`; set the archive tokens so installers are kept, and
  make `detect-releases.yml` also compare the installers' SHA-256, so a same-version re-upload
  opens a pull request instead of breaking a publish. A push should publish only the channels
  whose `versions.json` entry changed.

### 2026-11-10 — Runtime stage runs `apt-get upgrade`, so rebuilds patch base packages

- **What changed:** the runtime stage runs `apt-get upgrade -y --no-install-recommends` before
  installing its packages; the Dockerfile header now states that the monthly rebuild patches
  base packages too.
- **Result:** on the pinned `ubuntu:26.04` digest the upgrade moves four packages (apt and
  libapt-pkg7.0 3.2.0 to 3.2.1ubuntu0.1, base-files, libpcre2-8-0), and Trivy 0.70.0 with the
  gate's flags (`--pkg-types os`, CRITICAL/HIGH, `--ignore-unfixed`) goes from 2 HIGH to 0.
- **What did NOT work / root cause:** the Trivy gate failed from 2026-11-09 (Dependabot PR #2,
  run 42595391755) on apt CVE-2026-109518 (HIGH), and the published `stable` digest
  `sha256:a35fcafe…` carries it. A base digest bump was not possible: Docker Hub had not rebuilt
  `ubuntu:26.04` since 2026-10-29, so the pinned digest was already current. The documented
  design ("the monthly rebuild picks them up") did not hold for packages that ship inside the
  base image: `apt-get install` of other packages never upgrades them.
- **Release records superseded by this publish:** a push-triggered publish adds no
  `-rYYYYMMDD` suffix, so it re-uploads the assets of the existing releases with `--clobber`
  (ADR 0008 expects a suffixed tag for a rebuild; follow-up in `tasks/todo.md`). The records it
  replaces, downloaded 2026-11-10 before merge (the images, their keyless signatures and the
  CycloneDX attestations stay in GHCR under these digests):

  | Release | Image digest | Created | Asset SHA-256 (`digests-*.json` / `sbom-*.cdx.json`) |
  |---|---|---|---|
  | `v10.50.1f-stable` | `sha256:a35fcafed0ee2c6857970aef230dfe5df0277cfafe24ef927503a54d0716b885` | 2026-11-01T07:59:03Z | `e55d58bd…6bd28` / `288d8f20…26914` |
  | `v10.51.1e-latest` | `sha256:8fb845fbc6298b8dc51d0a09b95bed837eedfc1bbaa19033c5488c79868c0774` | 2026-11-01T08:00:23Z | `6e7a7f95…91c84` / `5d31c182…2135` |

  Both were built with IBC `3.24.2-rocketedge.1` on `ubuntu:26.04@sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c`.
- **Next step:** after merge, `publish.yml` publishes both channels with the fix; the monorepo
  `image-pin.yml` then opens a pin PR that waits for the operator-run `regression-paper` check
  (C6). Independent review of PR #3 also found that the Buildx GitHub Actions cache is not in
  effect today (0 cached steps); if it is ever repaired, the unchanged apt layer would be reused
  and rebuilds would silently stop patching, so a rebuild must then bust that layer.

### 2026-11-01 — First successful publish of both channels

- **What changed:** `publish.yml` creates the release tag through the release API
  (`gh release create --target`) and verifies the keyless signature and the CycloneDX
  attestation inside the job right after signing; `ci.yml` grants `security-events: write` to
  the job that uploads Trivy SARIF.
- **Result:** CI green on `2f109b8`; Publish run 41285824630 green for
  both channels. Trivy gate: 0 fixable CRITICAL/HIGH in OS packages; vendor jars reported (L08).
  Signature and attestation verified in-job against identity
  `https://github.com/RocketEdge/brokersre-ib-gateway/.github/workflows/publish.yml@refs/heads/main`.
  Releases `v10.50.1f-stable` and `v10.51.1e-latest` carry `digests-<channel>.json` and the SBOM.

  | Channel | Gateway | Digest |
  |---|---|---|
  | stable | 10.50.1f | `sha256:a35fcafed0ee2c6857970aef230dfe5df0277cfafe24ef927503a54d0716b885` |
  | latest | 10.51.1e | `sha256:8fb845fbc6298b8dc51d0a09b95bed837eedfc1bbaa19033c5488c79868c0774` |

- **What did NOT work / root cause:** (1) `git push` of the release tag from the job was
  rejected ("refusing to allow a GitHub App to create or update workflow ... without `workflows`
  permission"): `GITHUB_TOKEN` cannot push a ref whose commit carries workflow files, so the
  tag is now created server-side by the release API. (2) Verification from a workstation fails
  with `DENIED` while the GHCR package is private; in-job verification uses the workflow token
  and records the evidence in the run log. (3) Signing identity is the branch ref
  (`@refs/heads/main`), not a tag ref, because publish runs on pushes to main; the monorepo's
  `image-pin.yml` was corrected to match.
- **Next step:** owner makes the GHCR package public (L07); then anonymous `docker pull` and a
  workstation `cosign verify`; BrokerSRE `image-pin.yml` pins the stable digest.

### 2026-11-01 — Second CI run: secrets directory permissions and the Trivy gate scope

- **What changed:** the container harness makes its temporary secrets directory traversable
  (`chmod 0755`); the Trivy gate in `ci.yml` and `publish.yml` covers OS packages
  (`vuln-type: os`) and a second, non-gating step prints the findings in IBKR's bundled jars;
  limitation L08 records them.
- **Result:** Trivy 0.70.0 locally on image 653f1201000a: 0 fixable OS findings; 12 fixable HIGH
  findings in vendor jars (jackson-core 2.12.3: CVE-2025-52999, CVE-2026-68494, CVE-2026-89425;
  jackson-databind 2.12.3: CVE-2020-36518, CVE-2021-46877, CVE-2022-42003, CVE-2022-42004,
  CVE-2026-54512, CVE-2026-54513, CVE-2026-91776, CVE-2026-91777; commons-io 2.11.0:
  CVE-2024-47554). The harness change is host-side and was not re-run locally; the CI run after
  this commit is its evidence.
- **What did NOT work / root cause:** (1) in CI every container test that needs credentials
  failed with `secret_unreadable`: `mktemp -d` creates a 0700 directory owned by the runner
  user (uid 1001) and Linux bind mounts keep host permissions, so uid 1000 inside the container
  could not traverse it; Docker Desktop on the Windows development host masks host permissions
  and hid the bug. (2) The publish Trivy gate failed on the vendor jars above, which this image
  cannot replace without modifying IBKR's application.
- **Next step:** watch the rerun, `cosign verify` the stable digest, record the run ids.

### 2026-11-01 — First CI and publish runs: four set-up failures fixed

- **What changed:** `ci.yml` names its test image `TEST_IMAGE`; `publish.yml` re-exports the bake
  variables into `GITHUB_ENV` unquoted; the advanced `codeql.yml` was removed because the
  organisation's default CodeQL setup already covers this repository; `trivy-action` is pinned
  to the existing `v0.36.0` tag.
- **Result:** no script changed, so the local evidence of the previous entry stands (bats 25/25,
  container suite 28/28); the CI and publish runs after this change are the next evidence.
- **What did NOT work / root cause:** (1) `aquasecurity/trivy-action@0.36.0` does not exist (the
  tag is `v0.36.0`), so every job referencing it failed at set-up. (2) `docker buildx bake` reads
  a variable named `IMAGE` from the environment; the CI job exported `IMAGE=...:stable` for the
  test harness and bake built tags such as `...:stable:10.50.1f`. (3) `GITHUB_ENV` takes
  `NAME=value` literally; piping the `export NAME='value'` lines of `scripts/bake-env.sh`
  through `sed 's/^export //'` kept the quotes and produced the tag `...:'10.51.1e'`. (4) GitHub's
  default CodeQL setup is enabled on this repository by the organisation security configuration
  and rejects SARIF from an advanced workflow.
- **Next step:** watch `ci.yml` and `publish.yml`, then `cosign verify` the stable digest and
  record the run ids.

### 2026-11-01 — Read-only hardening: tmpfs ownership, structured fail-fast, harness fixes

- **What changed:** The entrypoint verifies that `LOG_DIR`, `RUN_DIR` and `TWS_SETTINGS_PATH` are
  writable before anything else and exits with the structured stdout event `dirs_not_writable`;
  the reference compose and the container harness mount tmpfs with `uid=1000,gid=1000,mode=0750`;
  the harness validates the log contract with the image's own `jq` (the host may have none) and
  gained a negative test for a root-owned tmpfs; shellcheck/shfmt findings were cleared and a
  `.markdownlint.yaml` added.
- **Result (fresh, local, amd64 image 653f1201000a):** bats inside the image 25/25; container
  suite 28/28 (structure, render, read-only positive and negative, IBC smoke offline, command
  server off); shellcheck 0.9.0 and 0.11.0 clean; shfmt clean; hadolint clean.
- **What did NOT work / root cause:** (1) `--tmpfs /run/brokersre` is root-owned 0755, so the
  uid-1000 entrypoint died on `mkdir` with a bare stderr line and the read-only test only saw
  "relay never listened"; fixed by mount options plus a fail-fast check. (2) bats-core cloned on
  Windows carried CRLF (`core.autocrlf=true`), so `env` inside the image failed on
  `bash\r`; MSYS `grep` does not report carriage returns, `file(1)` does; the clone was redone
  with `core.autocrlf=false` and the repo's `.gitattributes` forces LF. (3) The harness used the
  host's `jq`, absent on Windows, so valid JSON was reported as a contract violation.
- **Next step:** first push, CI, `publish.yml`, cosign verification; owner makes the GHCR package
  public; BrokerSRE pins the digest.

### 2026-11-01 — Initial image: single Dockerfile, pinned inputs, offline test suites

- **What changed:** Created the repository from the gnzsnz/ib-gateway-docker design with a single
  parametrised Dockerfile driven by `versions.json` (ubuntu:26.04 by digest, Gateway 10.50.1f /
  10.51.1e with RocketEdge-computed SHA-256 per architecture, IBC 3.24.2 from
  RocketEdge/ibc `3.24.2-rocketedge.1`), no sudo, read-only root filesystem support,
  HEALTHCHECK, IBC command server on loopback, JSON stdout + raw logs on a shared volume with a
  phase file, tini, bats unit suite run inside the image, offline container tests, publish /
  rebuild / detect workflows with Trivy, SBOM, cosign and provenance.
- **Result:** see the test and build evidence in the first pull request / CI run.
- **What did NOT work / root cause:** recorded below as it happens.
- **Next step:** first `publish.yml` run; owner makes the GHCR package public; BrokerSRE pins
  the digest through `image-pin.yml`.
