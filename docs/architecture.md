# Architecture

## Build pipeline

```mermaid
flowchart LR
  vj["versions.json\n(base digest, Gateway versions + SHA-256, IBC tag + SHA-256)"] --> env["scripts/bake-env.sh"]
  env --> bake["docker buildx bake (docker-bake.hcl)"]
  bake --> df["Dockerfile stage 1: fetch-installer.sh verifies SHA-256, installs Gateway; downloads IBC from RocketEdge/ibc, verifies SHA-256"]
  df --> rt["Dockerfile stage 2: ubuntu:26.04@digest + tini, Xvfb, socat, x11vnc, Java libs; uid 1000; rootfs/"]
  vj --> plan["plan: channel list (publish-channels.sh), no tag in both channels (check-bake-tags.sh)"]
  rt --> push["multi-arch build, no cache, pushed BY DIGEST (no tag)"]
  push --> scan["Trivy v0.76.2 gate on linux/amd64 and linux/arm64 of that digest; each report checked for its platform"]
  scan --> sbom["one SBOM per platform, attested to that platform's manifest"]
  sbom --> sign["cosign sign + VEX attestation + build provenance on the index"]
  sign --> tags["scripts/promote-tags.sh: tags -> the scanned digest"]
  tags --> rel["git tag v<version>-<channel>, release with digests-<channel>.json, two SBOMs, VEX"]
  daily["rebuild.yml (daily): scan the published images"] -. "fixable CRITICAL/HIGH -> issue, rebuild request" .-> plan
  ibkr["IBKR version.json (daily)"] -. "detect-releases.yml -> PR" .-> vj
  ibc["RocketEdge/ibc releases (daily)"] -. "detect-ibc-release.yml -> PR" .-> vj
```

## Runtime process tree

```mermaid
flowchart TB
  tini["tini (PID 1)"] --> ep["entrypoint.sh"]
  ep --> doctor["doctor.sh --startup: preflight; a failed check stops the start before any login"]
  ep --> latch["login-latch.sh: IBKR rejected these secret files before? Then no IBC: phase needs-human, container held"]
  ep --> render["render-config.sh: _FILE secrets -> /run/brokersre/config.ini (0600); jts.ini on first start"]
  ep --> javaenv["java-env.sh: _JAVA_OPTIONS (writable user.home, heap)"]
  ep --> xvfb["Xvfb :1"]
  ep --> vnc["x11vnc -localhost -noremote, view-only unless VNC_VIEW_ONLY=no (only with VNC_SERVER_PASSWORD)"]
  vnc -- "-afteraccept / -gone" --> vnchook["vnc-hook.sh: vnc_client_connected, vnc_client_disconnected"]
  ep --> relay["relay supervisor: socat 0.0.0.0:4003|4004 -> 127.0.0.1:4001|4002, only while the phase is logged-in"]
  ep --> tail["tail-gateway-logs.sh -> /var/log/ibgateway/jts/ (resumes after a restart)"]
  ep --> sampler["sampler.sh -> /var/log/ibgateway/metrics/metrics.jsonl (cgroup v2, /proc)"]
  ep --> ibc["ibcstart.sh (IBC) -> IB Gateway JVM"]
  ibc -- "stdout" --> rot["rotating-append.sh -> /var/log/ibgateway/ibc/ibc.log (size-capped)"]
  rot --> classify["classify-ibc-log.sh -> events; /var/log/ibgateway/state/phase"]
  relay -. "reads" .-> phase["state/phase"]
  classify --> phase
  ibc -- "127.0.0.1:7462" --> cmd["IBC command server (STOP, RESTART, RECONNECTDATA, RECONNECTACCOUNT)"]
  ep -. "SIGTERM: ibc-cmd STOP, wait, last sample, then stop helpers" .-> cmd
  hc["HEALTHCHECK healthcheck.sh: process alive AND API port open"] -.-> ibc
```

## Events: one writer function, two destinations

Every component emits events through `log_event` (`log.sh`). Under a file lock it gives the
event the next sequence number of this container start and writes the identical line to stdout
and to `events/events.jsonl`.

```mermaid
flowchart LR
  ep["entrypoint"] --> le
  doctor["doctor"] --> le
  classify["classifier"] --> le
  relay["relay supervisor"] --> le
  sampler["sampler"] --> le
  vnchook["console hook"] --> le
  le[["log_event: flock, boot_id, seq"]] --> out["stdout (docker logs)"]
  le --> file["events/events.jsonl (size-capped)"]
  file --> reader["sidecar or shipper (read-only mount; docs/recipes)"]
```

## Contract with a sidecar

A sidecar shares the network namespace (`network_mode: "service:ib-gateway"`) and mounts
`/var/log/ibgateway` read-only. It reads `state/phase`, `events/events.jsonl` and
`metrics/metrics.jsonl`, and can connect to the Gateway on `127.0.0.1:4001|4002`. The raw logs
(`ibc/ibc.log`, `jts/*.log`) may contain the username and must not leave the host unredacted.
A sidecar never mounts the settings volume (which holds the auto-restart session token).
The IBC command server on `127.0.0.1:7462` is reachable from the shared namespace; a sidecar
that only observes never sends it anything. Specified in [log-contract.md](log-contract.md).
