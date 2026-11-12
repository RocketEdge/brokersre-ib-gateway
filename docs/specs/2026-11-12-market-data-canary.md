# Design note: an opt-in market data canary for the sidecar

Status: **proposal, nothing built**. Date: 2026-11-12. IBKR quotations were fetched on that
day; "not established" means no IBKR page was found that says it.

## Problem

A gateway can be logged in, healthy and answering the API while no market data arrives: a
data farm is disconnected, a subscription lapsed, another session took the data. Nothing in
the image sees that: the health check proves an open port (or, opt-in, an answered handshake),
and the events come from IBC's log. The question "is market data still flowing?" needs an
API client, so it belongs to the optional sidecar, never to the gateway image.

## What exists today

- The image makes no API request. `api-handshake.sh` stops after the handshake and takes no
  client id ([log contract](../log-contract.md)); even that is opt-in until it has been
  watched on a real session ([limitations](../limitations.md) L15).
- The sample clients under `examples/` are read-only and already follow IBKR's connectivity
  codes.

According to IBKR:

| Fact | IBKR's words | Source |
|---|---|---|
| Data farm state is announced | 2103 "A market data farm is disconnected."; 2104 "Market data farm connection is OK"; 2108 "A market data farm connection has become inactive but should be available upon demand." | [M1] |
| After a reconnect, subscriptions may be gone | 1101: "Your market data requests have been lost and need to be re-submitted." | [M1] |
| A request can go unanswered early | "If a request is made prior to full establishment of connection, denoted by a returned 2104 or 2106 error code, there may not be a response from the request." | [M1] |
| Market data lines are one pool per user | "Market data lines dictate how much market data can be retrieved simultaneously from a given user." | [M2] |
| The message rate is limited | With the default 100 lines: "50 requests per second" | [M3] |
| A snapshot is not instant | "Snapshots return the most recent available data from the past 11 seconds" | [M4] |
| A regulatory snapshot costs money | "Each regulatory snapshot made will incur a fee of 0.01 USD to the account." | [M4] |
| The last trade has a timestamp | Tick 45, Last Timestamp: "Time of the last trade (in UNIX time)." | [M4] |
| Delayed data needs no paid subscription | Type 3: "Free, delayed data is 15 – 20 minutes delayed." Otherwise "a paid data subscription is required to receive market data through the API". | [M5], [M6] |
| A closed market looks different | Frozen data "is the last data recorded at market close"; on a closed market "-1 values will commonly be returned for the bid and ask prices". | [M5] |
| Trading hours can be asked | `reqContractDetails` returns "the trading schedule of an instrument via the TradingHours and LiquidHours fields" | [M7] |
| The clock request is a connection check | `reqCurrentTime` can be used "to verify the connection with the application" | [M8] |

Not established: whether a snapshot or a delayed subscription uses a market data line;
whether tick 45 repeats when nobody trades; whether the schedule reflects every exchange
holiday; which of this a paper account without subscriptions gets through the API.

## Options: which read-only request

| Option | Cost | What it proves |
|---|---|---|
| 1. Listen only (farm and connectivity codes) | a client id; no line, no request | the Gateway's own view of its data farms. A quiet client may only ever see "inactive", which IBKR calls normal |
| 2. `reqCurrentTime` on a timer | a client id; a few requests a minute | the API session answers. Nothing about market data |
| 3. One streaming subscription (`reqMktData`) to an instrument the operator chooses, delayed data allowed | a client id, one request, one market data line of the pool the strategy also uses; re-subscribe after 1101 | ticks arrive, and the age of the last trade (tick 45, or its delayed twin 88) |
| 4. A snapshot on a timer | a request and up to 11 seconds each; needs a subscription | a quote existed in the last seconds |
| 5. Regulatory snapshots, historical or real-time bars | a fee per request; strict pacing | excluded |

## What "stale" means

Stale is "the last trade is older than a threshold **while the instrument's liquid hours say
the market is open**". Outside those hours, while the phase is not `logged-in`, and between a
1100 and the next 1101 or 1102, the answer is "not measured": the key is absent from the
sample, never 0 and never "fresh" (the rule of the metrics file). With delayed data the
threshold has to include the delay. The schedule comes from one `reqContractDetails` a day; a
holiday the schedule does not show would be a false alarm, which is one reason for the opt-in.

## Why opt-in

It takes a client id and, in option 3, a market data line from the pool the strategy uses; it
needs an instrument and possibly a subscription that only the operator can choose; a second
API client is a change to what the Gateway does that nobody has watched yet; and a false
"stale" at night would page a person.

## Recommendation

Off by default, in the sidecar. Options 1 and 2 as "the API answers and the farm is
connected"; option 3 as the canary proper, on one operator-chosen instrument with delayed
data allowed. Results as a sample key (for example `md_last_trade_age_s`) and a pair of
events when the condition starts and ends, like the sampler's.

## What has to be observed first

On a logged-in paper session: which farm codes a quiet read-only client receives; whether
delayed ticks and tick 88 arrive without a subscription; whether tick 45 or 88 repeats
without trades; whether a second client id causes a dialog or log noise in the Gateway; what
1101 and 1102 look like across the daily restart; whether a subscription or a snapshot shows
up in the line count.

## Not built

No canary, no change to the sidecar or the image, no new variable. Never part of it: an
order, a cancel, a what-if request, or a regulatory snapshot.

## Sources

- [M1] IBKR, TWS API documentation, "Error Codes" (system message codes):
  <https://www.interactivebrokers.com/docs/tws-api/doc/error/codes>
- [M2] "Market Data Lines":
  <https://www.interactivebrokers.com/docs/general/market-data-subscriptions/market-data-lines/introduction>
- [M3] "Pacing Limitations": <https://www.interactivebrokers.com/docs/tws-api/doc/pacing-limitations>
- [M4] "Streaming Data": <https://www.interactivebrokers.com/docs/tws-api/doc/md/streaming-data>
- [M5] "Delayed Data" (market data types): <https://www.interactivebrokers.com/docs/tws-api/doc/md/delayed-data>
- [M6] "Market Data Limitations": <https://www.interactivebrokers.com/docs/tws-api/doc/md/market-data-limitations>
- [M7] "Contract Details": <https://www.interactivebrokers.com/docs/tws-api/doc/contracts/details>
- [M8] "Current Time" (synchronous wrapper): <https://www.interactivebrokers.com/docs/tws-api/sync-doc/current-time>
