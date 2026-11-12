# Examples: clients that cope with a gateway that is not ready

An unattended gateway is not always ready: it logs in, it may wait for a second factor, it
loses connectivity to IBKR now and then, and it restarts once a day. Strategy code written
against a desktop Trader Workstation tends to treat all of that as fatal. These examples show
the handful of rules that make a client survive it. Every example is **read-only**: none of
them contains an order, cancel or what-if call, and a test scans this directory to keep it
that way.

## Table of Contents

- [What is here](#what-is-here)
- [The readiness rules in plain words](#the-readiness-rules-in-plain-words)
- [Run: wait-for-gateway.sh](#run-wait-for-gatewaysh)
- [Run: gateway and strategy in one compose file](#run-gateway-and-strategy-in-one-compose-file)
- [Run: the Python client](#run-the-python-client)
- [Run: the C# client](#run-the-c-client)
- [Try the clients without a gateway](#try-the-clients-without-a-gateway)
- [Tests](#tests)

## What is here

| File | What it shows |
|---|---|
| [wait-for-gateway.sh](wait-for-gateway.sh) | Waiting until the gateway really answers: a TCP connection **and** an answered API handshake, with retries. Usable by hand, as an entrypoint wrapper and as a health check |
| [compose-with-client.yml](compose-with-client.yml) | A gateway and a strategy container on a private network: the strategy starts after the gateway is healthy, then waits for the API; nothing is published on the host |
| [python/](python/README.md) | A client with `ib_async` that retries the connection, obeys 1100/1101/1102, tracks the data-farm codes and reconnects after the daily restart |
| [csharp/](csharp/README.md) | The same client for .NET 10 with IBKR's official C# client, which you supply yourself (it is not redistributed here); the logic is tested without it |

## The readiness rules in plain words

1. **Wait for healthy, then for the API.** The container is `healthy` when the gateway is
   logged in and its API port is open. Start your strategy after that
   (`depends_on: condition: service_healthy`), and still check that the API answers before
   the first request (`wait-for-gateway.sh`). Healthy is a moment, not a promise.
2. **"Connection refused" means "not ready yet", so retry.** The relay in front of the API
   listens only while the gateway is logged in. During login, while a second factor is
   pending and during the daily restart the port is closed and a connection is refused. That
   is normal. Try again with a growing pause (1 s, 2 s, 4 s, ... up to a cap of about 30 s)
   plus some randomness, and do not give up: a second factor can take a long time.
3. **1100 means stop sending.** IBKR code 1100 says the gateway has lost its connection to
   IBKR. Your connection to the gateway is still fine: keep it, send nothing, wait.
   Reconnecting does not help, because the gateway itself is cut off.
4. **1102 means continue.** Connectivity is back and nothing was lost. Carry on.
5. **1101 means continue and re-subscribe.** Connectivity is back but the data was lost:
   make every subscription again (market data, account updates).
6. **Farm codes are about data routes, not about your connection.** 2103, 2105 and 2157 say
   a data farm is broken (market data, historical data, security definitions); 2104, 2106
   and 2158 say it is fine again. Data from a broken farm is missing or stale; the API
   connection itself works.
7. **Never assume the relay is up during the restart window.** Once a day (at
   `AUTO_RESTART_TIME`) the gateway restarts: your socket is closed and the port refuses
   connections until the gateway is logged in again. Reconnect as in rule 2, then
   re-subscribe. IBKR's own reset windows (listed in [docs/env-vars.md](../docs/env-vars.md))
   cause 1100 or a closed socket too.
8. **A connection that stops answering is dead even if nobody said so.** A half-open socket
   never reports a disconnect. Put a timeout on every request and replace the connection
   after a few unanswered ones.
9. **Use a client id of your own.** Every client of one gateway needs a different id; IBKR
   code 326 means yours is taken. `wait-for-gateway.sh` takes no client id at all, so it
   cannot collide with your strategy.

## Run: wait-for-gateway.sh

Needs bash and coreutils. It sends the API handshake and nothing else: no client id, no
request.

```bash
examples/wait-for-gateway.sh --host 127.0.0.1 --port 4002 --timeout 300 && echo ready
examples/wait-for-gateway.sh --host ib-gateway --port 4004 -- python strategy.py   # start a command when ready
```

Exit status: 0 ready, 1 timeout, 2 usage error. `--help` lists the options and the
environment variables (`IBGW_HOST`, `IBGW_PORT`, `IBGW_WAIT_TIMEOUT`).

## Run: gateway and strategy in one compose file

Uses the two secret files of the repository's Quick start (`compose/secrets/`):

```bash
docker compose -f examples/compose-with-client.yml up -d
docker compose -f examples/compose-with-client.yml logs -f strategy
```

You should see `wait-for-gateway: ready: ib-gateway:4004 answered the API handshake` and then
the placeholder's line. Replace the `strategy` service with your own image and command. If
`up` stops with "dependency failed to start", the gateway was not healthy in time (usually a
second factor waiting for approval): approve it and run `up -d` again.

## Run: the Python client

```bash
cd examples/python
uv sync
uv run python resilient_client.py --host 127.0.0.1 --port 4002 --client-id 101
```

Details and options: [python/README.md](python/README.md).

## Run: the C# client

The logic builds and is tested without any IBKR file:

```bash
cd examples/csharp
dotnet build -warnaserror && dotnet test
```

The executable needs your own copy of IBKR's `CSharpAPI.dll`; where to get it and how to
build: [csharp/README.md](csharp/README.md).

## Try the clients without a gateway

`python/tests/fake_gateway.py` is a stand-in that speaks just enough of the API protocol for
both clients and never contacts IBKR. Start it, start a client against it, then type `1100`,
`1102`, `1101`, `2103`, `2104` or `drop` into it and watch the client react:

```bash
cd examples/python
uv run python tests/fake_gateway.py --port 4002
```

## Tests

| What | Command |
|---|---|
| `wait-for-gateway.sh` (bats, inside the image) | `tests/bats/run-in-image.sh <image>` |
| `compose-with-client.yml`, started as shipped | `IMAGE=<image> tests/compose/run.sh` |
| Python client | `cd examples/python && uv run pytest` (plus `ruff check .`, `black --check .`, `mypy`) |
| C# logic | `cd examples/csharp && dotnet test` |

Interactive Brokers, IBKR, IB Gateway and Trader Workstation are trademarks of Interactive
Brokers LLC. This project is not affiliated with, endorsed by or sponsored by Interactive
Brokers.
