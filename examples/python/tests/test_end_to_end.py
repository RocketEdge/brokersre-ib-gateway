"""End-to-end tests: the sample, the real ib_async and a stand-in gateway on loopback.

The unit tests script a fake session; these prove that the assumptions behind that fake hold
for the pinned ib_async release: what a read-only connection really sends, how IBKR message
codes and a closed socket really arrive, and that the client comes back after a restart.
Nothing leaves this machine: the gateway is ``fake_gateway.FakeGateway`` on 127.0.0.1.

Waits are on state with a deadline, never fixed pauses. A refused loopback connection takes
about two seconds on Windows, which is why the restart test allows a generous deadline.
"""

import asyncio
import contextlib
import datetime as dt
from collections.abc import Callable

from fake_gateway import FakeGateway
from resilient_client import (
    BackoffPolicy,
    ClientConfig,
    IbAsyncSession,
    Readiness,
    ResilientClient,
)

#: 2026-11-12 14:30:00 UTC, the server time the stand-in reports.
FIXED_EPOCH = 1_794_493_800

#: Request ids on the wire (TWS API): start API, positions, server time.
START_API = 71
POSITIONS = 61
CURRENT_TIME = 49


async def wait_until(condition: Callable[[], bool], timeout_s: float = 10.0) -> None:
    """Return as soon as ``condition()`` is true; raise ``TimeoutError`` after ``timeout_s``."""
    async with asyncio.timeout(timeout_s):
        # The conditions are states of other components (the client, the gateway), not events
        # this test owns, so they are polled.
        while not condition():  # noqa: ASYNC110
            await asyncio.sleep(0.01)


def client_for(port: int) -> ResilientClient:
    """Build a client on a real ib_async session, with pauses short enough for a test."""
    config = ClientConfig(
        host="127.0.0.1",
        port=port,
        client_id=7,
        poll_interval_s=0.05,
        connect_timeout_s=5.0,
        request_timeout_s=5.0,
        backoff=BackoffPolicy(base_s=0.05, cap_s=0.2, jitter=0.25),
    )
    return ResilientClient(IbAsyncSession(), config)


def test_a_read_only_connection_sends_start_api_positions_and_the_server_time_only() -> None:
    """The whole conversation of the sample with a gateway, message by message."""
    gateway = FakeGateway(clock=lambda: FIXED_EPOCH)
    answers: list[dt.datetime | None] = []

    async def scenario() -> None:
        client = client_for(await gateway.start())
        try:
            assert await client.connect_once()
            answers.append(await client.poll_once())
        finally:
            await asyncio.shield(gateway.stop())

    asyncio.run(scenario())

    assert gateway.hellos == ["v157..178"]
    assert gateway.requests[0] == ["71", "2", "7", ""]
    assert gateway.request_ids == [START_API, POSITIONS, CURRENT_TIME]
    assert answers == [dt.datetime(2026, 11, 12, 14, 30, 0, tzinfo=dt.UTC)]


def test_1100_and_1102_from_the_wire_pause_and_resume_without_any_extra_request() -> None:
    """Codes pushed by the gateway reach the state machine; ib_async adds no request of its own."""
    gateway = FakeGateway(clock=lambda: FIXED_EPOCH)
    during_outage: list[dt.datetime | None] = []
    after_outage: list[dt.datetime | None] = []

    async def scenario() -> None:
        client = client_for(await gateway.start())
        try:
            assert await client.connect_once()
            await gateway.send_error(
                1100, "Connectivity between IBKR and the gateway has been lost"
            )
            await wait_until(lambda: client.state.readiness is Readiness.CONNECTIVITY_LOST)
            during_outage.append(await client.poll_once())
            await gateway.send_error(1102, "Connectivity restored - data maintained")
            await wait_until(lambda: client.state.readiness is Readiness.READY)
            after_outage.append(await client.poll_once())
        finally:
            await asyncio.shield(gateway.stop())

    asyncio.run(scenario())

    assert during_outage == [None]
    assert after_outage == [dt.datetime(2026, 11, 12, 14, 30, 0, tzinfo=dt.UTC)]
    # One server-time request in total: none during the outage, and nothing else after 1102
    # (ib_async's own account-summary request on 1102 is switched off by the adapter).
    assert gateway.request_ids == [START_API, POSITIONS, CURRENT_TIME]


def test_1101_from_the_wire_asks_for_subscriptions_again() -> None:
    """Connectivity restored with data lost: the re-subscribe count goes from one to two."""
    gateway = FakeGateway(clock=lambda: FIXED_EPOCH)
    counts: list[int] = []

    async def scenario() -> None:
        client = client_for(await gateway.start())
        try:
            assert await client.connect_once()
            counts.append(client.resubscriptions)
            await gateway.send_error(1100, "lost")
            await wait_until(lambda: client.state.readiness is Readiness.CONNECTIVITY_LOST)
            await gateway.send_error(1101, "Connectivity restored - data lost")
            await wait_until(lambda: client.state.readiness is Readiness.READY)
            counts.append(client.resubscriptions)
        finally:
            await asyncio.shield(gateway.stop())

    asyncio.run(scenario())

    assert counts == [1, 2]


def test_a_farm_code_from_the_wire_is_recorded_by_farm_name() -> None:
    """The farm name is read from IBKR's message text as ib_async delivers it."""
    gateway = FakeGateway(clock=lambda: FIXED_EPOCH)
    farms: list[tuple[str, ...]] = []

    async def scenario() -> None:
        client = client_for(await gateway.start())
        try:
            assert await client.connect_once()
            await gateway.send_error(2103, "Market data farm connection is broken:usfarm")
            await wait_until(lambda: client.state.broken_farms != ())
            farms.append(client.state.broken_farms)
            await gateway.send_error(2104, "Market data farm connection is OK:usfarm")
            await wait_until(lambda: client.state.broken_farms == ())
            farms.append(client.state.broken_farms)
        finally:
            await asyncio.shield(gateway.stop())

    asyncio.run(scenario())

    assert farms == [("usfarm",), ()]


def test_the_client_reconnects_by_itself_after_the_gateway_restarts() -> None:
    """Stop the gateway (socket closed, port refused), start it again: the client is back."""
    gateway = FakeGateway(clock=lambda: FIXED_EPOCH)
    observed: dict[str, int] = {}

    async def scenario() -> None:
        port = await gateway.start()
        client = client_for(port)
        task = asyncio.create_task(client.run())
        try:
            await wait_until(lambda: client.last_server_time is not None)
            await gateway.stop()
            await wait_until(lambda: client.state.readiness is Readiness.DISCONNECTED)
            observed["requests_before_restart"] = len(gateway.requests)
            await gateway.start(port=port)
            await wait_until(
                lambda: gateway.request_ids[observed["requests_before_restart"] :].count(
                    CURRENT_TIME
                )
                >= 1,
                timeout_s=30.0,
            )
            observed["resubscriptions"] = client.resubscriptions
            observed["start_api_messages"] = gateway.request_ids.count(START_API)
        finally:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task
            await asyncio.shield(gateway.stop())

    asyncio.run(scenario())

    assert observed["start_api_messages"] == 2
    assert observed["resubscriptions"] == 2


def test_a_port_that_refuses_is_not_ready_for_the_real_session_either() -> None:
    """ib_async raises an OSError for a refused connection; the client reports False."""
    results: list[bool] = []

    async def scenario() -> None:
        gateway = FakeGateway()
        port = await gateway.start()
        await gateway.stop()
        results.append(await client_for(port).connect_once())

    asyncio.run(scenario())

    assert results == [False]
