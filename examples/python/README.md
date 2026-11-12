# Python sample: a read-only client that survives the gateway's bad moments

`resilient_client.py` connects to an IB Gateway with [ib_async](https://github.com/ib-api-reloaded/ib_async)
2.1.0, prints the IBKR server time every N seconds and keeps doing so across a gateway that
is not ready yet, lost connectivity (IBKR codes 1100, 1101, 1102) and the daily restart. The
rules it implements are in [../README.md](../README.md).

It is read-only by construction: `readonly=True`, no startup data requested from ib_async,
and the server time as its only request. It contains no order, cancel or what-if call and no
market-data subscription; a test scans every file under `examples/` to keep it that way.

## Run it

You need [uv](https://docs.astral.sh/uv/) (it installs Python 3.14 by itself) and a gateway
that is logged in, for example the Quick start of this repository in paper mode.

```bash
cd examples/python
uv sync
uv run python resilient_client.py --host 127.0.0.1 --port 4002 --client-id 101 --interval 30
```

| Option | Environment | Default | Meaning |
|---|---|---|---|
| `--host` | `IBGW_HOST` | `127.0.0.1` | Gateway host name or address |
| `--port` | `IBGW_PORT` | `4002` | API port: the host port of the relay (4001 live, 4002 paper), or 4003/4004 from another container |
| `--client-id` | `IB_CLIENT_ID` | `101` | TWS API client id; every client of one gateway needs its own (IBKR code 326 otherwise) |
| `--interval` | | `30` | Seconds between two server-time requests |

Stop it with Ctrl+C; it disconnects, which frees the client id at once.

## Try it without a gateway

`tests/fake_gateway.py` is a stand-in that speaks just enough of the API protocol. It never
contacts IBKR.

```bash
uv run python tests/fake_gateway.py --port 4002       # terminal 1
uv run python resilient_client.py --interval 2        # terminal 2
```

In terminal 1 type `1100` (the client stops asking), `1102` (it continues), `1101` (it
continues and re-subscribes), `2103` / `2104` (a data farm breaks and recovers), `drop` (the
socket closes, as in the daily restart; the client reconnects) or `quit`.

## What to copy into a strategy

- `BackoffPolicy`: capped exponential back-off with jitter for connection attempts.
- `GatewayState`: the state machine for 1100/1101/1102 and the data-farm codes. It is pure:
  no I/O, no clock.
- `ResilientClient`: the loop. Put your subscriptions into the `on_resubscribe` hook: it runs
  after every connection and after every 1101.
- `IbAsyncSession`: how to connect ib_async read-only, and why ib_async's own reaction to
  1102 (a new account-summary subscription each time) is switched off.

## Tests

```bash
uv run ruff check . && uv run black --check . && uv run mypy && uv run pytest
```

The unit tests use a scriptable session and need no network. `tests/test_end_to_end.py` runs
the real ib_async against the stand-in gateway on 127.0.0.1.

Interactive Brokers, IBKR, IB Gateway and Trader Workstation are trademarks of Interactive
Brokers LLC. This project is not affiliated with, endorsed by or sponsored by Interactive
Brokers.
