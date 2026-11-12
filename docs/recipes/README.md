# Recipes: the gateway's events and resource samples in your own log system

Three [Vector](https://vector.dev) configurations that read the two contract files of the
gateway's log volume and send them on. They are recipes to copy and adapt, not a product:
this repository does not build, publish or operate the shipper.

## Table of Contents

- [What is shipped, and what never is](#what-is-shipped-and-what-never-is)
- [The recipes](#the-recipes)
- [Use one](#use-one)
- [What arrives](#what-arrives)
- [Restarts, duplicates and what can be lost](#restarts-duplicates-and-what-can-be-lost)
- [How the shipper runs](#how-the-shipper-runs)
- [What was validated, and what was not](#what-was-validated-and-what-was-not)
- [The Vector version](#the-vector-version)

## What is shipped, and what never is

| Shipped | Never shipped |
|---|---|
| `events/events.jsonl`: the gateway's events, one JSON object per line | `ibc/ibc.log`: the raw IBC log |
| `metrics/metrics.jsonl`: one resource sample per line | `jts/`: the Gateway's own logs |

The raw logs can contain the IBKR username; events and samples never do
([log contract](../log-contract.md)). Each recipe names the two files and nothing else, and
the test fails a recipe that reads anything more.

## The recipes

| File | Destination | You edit | Secret files |
|---|---|---|---|
| [vector-loki.yaml](vector-loki.yaml) | Grafana Loki (push API) | `endpoint:`; the label `instance:` | `loki_username`, `loki_password` |
| [vector-otlp.yaml](vector-otlp.yaml) | an OpenTelemetry collector, OTLP over HTTP | `uri:`; the value of `service.instance.id` | `otlp_token` |
| [vector-datadog.yaml](vector-datadog.yaml) | Datadog Logs | `site:`; the tag `instance:default` | `datadog_api_key` |

Credentials are read from files only (`SECRET[files.<name>]`, one file per secret). The
recipes read **no environment variable**: this Vector version leaves `${...}` in a
configuration as text unless it is started with `--dangerously-allow-env-var-interpolation`,
so addresses are edited in your copy of the file. For a destination without authentication,
delete the `auth:` block and the `secret:` block of the recipe.

## Use one

From the repository folder, next to a gateway started from `compose/docker-compose.example.yml`.

1. Copy a recipe and edit the lines of the table above:

   ```bash
   cp docs/recipes/vector-loki.yaml docs/recipes/my-vector-loki.yaml
   ```

   Check: `grep -n 'endpoint:' docs/recipes/my-vector-loki.yaml` shows your address.

2. Write the secrets as files, in a folder of the shipper's own. The shipper must not see
   the gateway's IBKR credentials, so not `compose/secrets` itself:

   ```bash
   mkdir -p compose/secrets/vector
   read -r -s -p 'Loki password: ' p && printf '%s' "$p" > compose/secrets/vector/loki_password && echo
   unset p
   printf '%s' '<loki user>' > compose/secrets/vector/loki_username
   ```

   Check: the folder holds exactly the files the recipe names. On Windows write them as in
   the [quick start](../../README.md#quick-start) (UTF-8 without a byte-order mark).

3. Find the gateway's log volume:

   ```bash
   docker volume ls --format '{{.Name}}' | grep ibgw-logs
   ```

   Check: one name, `compose_ibgw-logs` for the reference compose started from `compose/`.
   Anything else goes into `IBGW_LOGS_VOLUME`.

4. Start the shipper (paths are relative to `docs/recipes/`):

   ```bash
   VECTOR_CONFIG=./my-vector-loki.yaml docker compose -f docs/recipes/docker-compose.vector.yml up -d
   docker compose -f docs/recipes/docker-compose.vector.yml logs log-shipper
   ```

   Check: the log says `Vector has started` and has no line with `ERROR`; within a minute the
   gateway's events are in your system (in Loki: `{job="ibgateway"} | json`). A container that
   keeps restarting has the reason in its last lines, most often a secret file that is missing.

In PowerShell set `$env:VECTOR_CONFIG = './my-vector-loki.yaml'` first. The other variables of
the compose file are `VECTOR_SECRETS_DIR` (default `../../compose/secrets/vector`),
`IBGW_LOGS_VOLUME` and `VECTOR_MEM_LIMIT` (default `256m`).

## What arrives

| Destination | Events | Resource samples |
|---|---|---|
| Loki | The JSON line unchanged, with the event's own time. Labels `job="ibgateway"`, `instance`, `stream="events"`, `src`, `level` | The JSON line unchanged. Labels `stream="metrics"`, `src="metrics"`, `level="info"` (a sample has no level) |
| OTLP | One log record: time, severity from `level`, body from `msg`; attributes `event.name`, `brokersre.src`, `brokersre.boot_id`, `brokersre.seq`, `brokersre.stream`, and `brokersre.data.<key>` for the event's `data`. Resource: `service.name="ib-gateway"`, `service.instance.id` | One log record whose body is the JSON line; attribute `brokersre.phase` |
| Datadog | A log with the gateway's keys as attributes, `status` from `level`, `message` from `msg`, `ddsource:ibgateway`, `service:ib-gateway`, tags `instance:<value>,stream:events` | A log with the sample's numbers as attributes, tag `stream:metrics` |

Samples travel as logs. Turning them into native metrics (a LogQL `unwrap`, a collector
processor, a log-based metric) is left to the destination.

`boot_id` and `seq` are never labels or tags with many values; they stay inside the record,
where they let you find a gap or a duplicate.

## Restarts, duplicates and what can be lost

- **Checkpoints.** Vector records how far it has read each file in its data directory
  (`data_dir`, a volume in the compose file). A restarted or re-created container continues
  there. Without that volume every new container starts at the beginning of the files.
- **At-least-once.** With `acknowledgements` on, a position is recorded only after the
  destination took the lines. A shipper that is killed between delivery and recording sends
  those lines again after it starts: **duplicates are possible, gaps are not**. Each line
  carries `boot_id` and `seq`, so a duplicate is recognisable.
- **Rotation.** The gateway renames a full file to `.1` and starts a new one. Vector keeps
  reading the renamed file to its end and then follows the new one; the recipes also list the
  rotated generations, so lines rotated away while the shipper was down are still read.
- **First start.** Everything the gateway still keeps is sent, oldest file first: the live
  file and up to `LOG_KEEP` generations of `LOG_MAX_BYTES` each.
- **What can be lost.** Lines in a generation that the gateway deleted before the shipper read
  it, which takes a destination that is down for longer than the gateway keeps its files; and
  a line that was cut short by a crash, which is dropped rather than sent as half a record.
- **While the destination is down** Vector retries, and with its default buffer (500 events
  in memory, block when full) it stops reading, so the files on the log volume are the
  buffer. That is Vector's default as its generated configuration shows it; an outage was not
  tested here.

## How the shipper runs

[docker-compose.vector.yml](docker-compose.vector.yml) is a compose project of its own:
uid 1000, read-only root filesystem, every capability dropped, no published port, the
gateway's log volume mounted read-only, its secrets from a folder of its own, a memory
limit. It needs no access to the gateway container or to the Docker socket.

The data directory is `/var/tmp` instead of Vector's usual `/var/lib/vector`: a new volume
takes owner and mode from the image directory it is mounted over, and `/var/tmp` is the one
a non-root user can write in this image.

## What was validated, and what was not

By `tests/recipes/run.sh`, offline, with the pinned image:

- **Configuration syntax and types:** every recipe passes `vector validate` as shipped (health
  checks skipped, warnings denied).
- **Behaviour against a stand-in receiver** (a second Vector, `tests/recipes/receiver.yaml`),
  each recipe started from the compose file as shipped with its one address line pointed at
  the stand-in: five sample events and two samples arrive; a line cut short does not; nothing
  is sent twice after a restart or after the container was re-created; new lines and a
  rotated file are followed; the credential from the secret file is sent; no credential is in
  the shipper's output.
- The stand-in is Vector's own OTLP receiver for the OTLP recipe. For Loki and Datadog it is
  an HTTP server that accepts the request and lets the test read it: for Loki the push body
  with its label set, for Datadog the JSON array of logs.

**Not validated:** delivery to a real Loki, a real OpenTelemetry collector or Datadog; their
authentication, limits and rejection rules (label limits, payload sizes, out-of-order
handling); TLS to a real endpoint; behaviour under load or during a long outage; a
multi-tenant Loki. Try a recipe against your own system before you rely on it.

## The Vector version

The image is pinned by tag and digest in one place, `docker-compose.vector.yml`; the test
reads it from there and fails when a second copy of the version appears. It is not in
`versions.json`, which pins what the gateway image is built from: the shipper is not part of
that image. When you move to another Vector version, run `tests/recipes/run.sh` again;
options and defaults change between versions.
