# Design note: strategy telemetry in the shape of the gateway's log contract

Status: **proposal, nothing built**. Date: 2026-11-12.

## Problem

The gateway says whether it is logged in. The strategy host has a view of its own: is it
connected, how old is the last tick, how long does an order take to be acknowledged. Today
the two speak different shapes, so they need two pipelines and cannot be laid side by side.
"Gateway `logged-in`, strategy disconnected" is a network problem between them; "both fine,
last tick five minutes old" is a data problem. Neither shows unless one collector reads both.

## What exists today

Verified in the repository:

- [Log contract v2](../log-contract.md): one JSON object per line with `ts`, `src`, `level`,
  `event`, `msg`, `boot_id`, `seq` and an optional flat `data` of strings; the identical line
  on stdout and in `events/events.jsonl`; resource samples in `metrics/metrics.jsonl`, where a
  value that could not be measured is absent, never 0.
- The schema ([log-event.v2](../../schemas/log-event.v2.schema.json)) closes `src` to the
  gateway's own components. A strategy's event does not validate against it, on purpose.
- The gateway's log volume is written by the gateway only; `seq` is gap-free per gateway
  start because every writer is a process of that container.
- The sample clients under `examples/` follow the readiness rules (1100, 1101, 1102, the data
  farm codes) and print text for a person, not events.
- The [recipes](../recipes/README.md) read files of exactly this shape.

## Options

| Option | For | Against |
|---|---|---|
| A. The same shape in the strategy's own files, with a schema of its own | One collector configuration with one more path; the gateway contract stays closed; no coupling | Two schemas to keep alike |
| B. Add `strategy` to the gateway schema's `src` values | One schema | A contract change for every reader; the gateway's contract would describe events the gateway never emits |
| C. The strategy writes into the gateway's log volume | One place | Breaks the read-only rule and the gap-free `seq`; lets another process speak with the gateway's voice |
| D. A logging adapter per language | Convenient | Code to maintain in two languages before anyone has asked for it |

## Recommendation

Option A, as a description, without an adapter: the strategy host writes its own
`events/events.jsonl` and `metrics/metrics.jsonl` in a directory of its own, in the shape
below, and the collector gets one more path. A schema file follows when a first strategy
adopts it.

Event sketch (the keys of the contract; `src` is `strategy`, `boot_id` and `seq` belong to the
strategy process):

```json
{"ts":"2026-11-12T01:02:03.456Z","src":"strategy","level":"warn","event":"api_disconnected","msg":"lost the connection to ib-gateway:4004; retrying","boot_id":"89abcdef01234567","seq":7,"data":{"strategy":"example","gateway_instance":"default","reason":"connection reset"}}
```

Event names, each emitted when the condition starts or ends: `api_connected`,
`api_disconnected`, `connectivity_lost` (IBKR code 1100), `connectivity_restored` (1101 or
1102; `data.data_lost` says which), `market_data_stale` and `market_data_ok`.

Sample sketch (the metrics shape; a key that was not measured is absent):

```json
{"ts":"2026-11-12T01:02:30.000Z","src":"strategy","boot_id":"89abcdef01234567","seq":12,"connected":true,"last_tick_age_ms":180,"order_ack_ms_p50":41,"order_ack_ms_p99":180,"open_requests":2}
```

Rules carried over from the gateway's contract:

- one line per event, the identical line on stdout and in the file, `seq` gap-free per start;
- `data` is a flat object of strings; never a credential, a username or a full account
  identifier, and no order content (instrument, side, quantity, price): `order_ack_ms` is a
  duration the strategy measures between its own submission and the first acknowledgement,
  nothing more;
- absence is never zero: outside trading hours `last_tick_age_ms` is absent, not large;
- `data.gateway_instance` carries the gateway's `IBGW_INSTANCE`, so that the two streams can
  be joined; a strategy that mounts the gateway's log volume read-only may add the gateway's
  `boot_id` from `state/boot_id`;
- files are size-capped and rotated by renaming, like the gateway's.

## What has to be observed first

Real numbers from a paper session for tick age and acknowledgement time, to choose units and
alert thresholds; whether operators want the two streams as one in their backend or apart;
which of the event names the sample clients can emit without new state.

## Not built

No adapter, no schema file, no change to the sample clients, and no change to the gateway's
contract. The gateway's own events are unaffected.
