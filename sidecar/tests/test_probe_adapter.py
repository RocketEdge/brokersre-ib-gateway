"""The real ib_async client behind the adapter, against an in-process wire-level gateway."""

from __future__ import annotations

import asyncio
import socket
from collections.abc import AsyncIterator
from datetime import UTC, datetime

import pytest

from brokersre_sidecar.probe import IbConnectError, IbDisconnectedError, IbTimeoutError
from brokersre_sidecar.probe.adapter import IbAsyncClient
from fakes.fake_gateway_tcp import WireGateway

GENEROUS = 5.0
"""Bound for operations that are expected to succeed (only reached when a test fails)."""
SHORT = 0.3
"""Timeout for operations that are expected to time out."""


@pytest.fixture
async def gateway() -> AsyncIterator[WireGateway]:
    server = WireGateway()
    await server.start()
    yield server
    await server.stop()


@pytest.fixture
async def client() -> AsyncIterator[IbAsyncClient]:
    adapter = IbAsyncClient()
    yield adapter
    adapter.disconnect()


class Notices:
    """Collects API notices and lets a test wait for a specific code."""

    def __init__(self) -> None:
        self.codes: list[int] = []
        self._waiters: dict[int, asyncio.Event] = {}

    def __call__(self, code: int, message: str) -> None:
        self.codes.append(code)
        self._waiters.setdefault(code, asyncio.Event()).set()

    async def wait_for(self, code: int) -> None:
        await asyncio.wait_for(self._waiters.setdefault(code, asyncio.Event()).wait(), GENEROUS)


async def test_the_handshake_and_a_time_round_trip_send_nothing_but_start_api_and_the_time_request(
    gateway: WireGateway, client: IbAsyncClient
) -> None:
    await client.connect("127.0.0.1", gateway.port, 999, GENEROUS)
    assert client.is_connected() is True
    answer = await client.current_time(GENEROUS)
    assert answer == datetime.fromtimestamp(gateway.epoch, UTC)
    assert answer.tzinfo is UTC
    # startApi(version 2, client id 999, no optional capabilities), then reqCurrentTime:
    # no position, account, order or market-data request of any kind.
    assert gateway.received == [["71", "2", "999", ""], ["49", "1"]]


async def test_api_notices_reach_the_listener_and_a_restored_link_triggers_no_request(
    gateway: WireGateway, client: IbAsyncClient
) -> None:
    notices = Notices()
    client.set_error_listener(notices)
    await client.connect("127.0.0.1", gateway.port, 999, GENEROUS)
    await notices.wait_for(2158)
    assert notices.codes[:3] == [2104, 2106, 2158]
    gateway.push_error(1100, "Connectivity between IBKR and the gateway has been lost")
    gateway.push_error(1102, "Connectivity restored - data maintained")
    await notices.wait_for(1102)
    await client.current_time(GENEROUS)
    # ib_async's high-level IB class answers 1102 with an account-summary subscription; the
    # adapter must not: the only messages on the wire are still startApi and the time request.
    assert gateway.received == [["71", "2", "999", ""], ["49", "1"]]


async def test_a_gateway_that_accepts_tcp_but_never_answers_fails_the_handshake_in_time(
    gateway: WireGateway, client: IbAsyncClient
) -> None:
    gateway.mode = "silent"
    with pytest.raises(IbConnectError):
        await client.connect("127.0.0.1", gateway.port, 999, SHORT)
    assert client.is_connected() is False


async def test_an_unanswered_time_request_times_out(
    gateway: WireGateway, client: IbAsyncClient
) -> None:
    gateway.mode = "no_time_answer"
    await client.connect("127.0.0.1", gateway.port, 999, GENEROUS)
    with pytest.raises(IbTimeoutError):
        await client.current_time(SHORT)
    assert gateway.time_requested.is_set()


async def test_a_client_id_in_use_is_reported_as_error_326_and_a_failed_handshake(
    gateway: WireGateway, client: IbAsyncClient
) -> None:
    gateway.mode = "client_id_in_use"
    notices = Notices()
    client.set_error_listener(notices)
    # ib_async waits out the handshake timeout after the gateway closes the socket, so the
    # timeout here bounds the test's duration; the 326 itself arrives at once.
    with pytest.raises(IbConnectError):
        await client.connect("127.0.0.1", gateway.port, 999, 1.0)
    assert notices.codes == [326]
    assert client.is_connected() is False


async def test_a_dropped_socket_is_noticed_and_the_adapter_can_connect_again(
    gateway: WireGateway, client: IbAsyncClient
) -> None:
    await client.connect("127.0.0.1", gateway.port, 999, GENEROUS)
    gateway.drop_clients()
    async with asyncio.timeout(GENEROUS):
        # Yield to the loop until the client has processed the FIN (bounded by the timeout).
        while client.is_connected():  # noqa: ASYNC110
            await asyncio.sleep(0)
    with pytest.raises(IbDisconnectedError):
        await client.current_time(GENEROUS)
    await client.connect("127.0.0.1", gateway.port, 999, GENEROUS)
    assert (await client.current_time(GENEROUS)).timestamp() == gateway.epoch


async def test_a_socket_that_drops_during_the_round_trip_is_a_disconnect_not_a_timeout(
    gateway: WireGateway, client: IbAsyncClient
) -> None:
    gateway.mode = "no_time_answer"
    await client.connect("127.0.0.1", gateway.port, 999, GENEROUS)
    pending = asyncio.ensure_future(client.current_time(GENEROUS))
    await asyncio.wait_for(gateway.time_requested.wait(), GENEROUS)
    gateway.drop_clients()
    with pytest.raises(IbDisconnectedError):
        await pending


async def test_a_refused_connection_is_a_connect_error(client: IbAsyncClient) -> None:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        closed_port = probe.getsockname()[1]
    with pytest.raises(IbConnectError):
        await client.connect("127.0.0.1", closed_port, 999, GENEROUS)


async def test_disconnect_is_idempotent_and_safe_before_any_connection(
    client: IbAsyncClient,
) -> None:
    client.disconnect()
    client.disconnect()
    assert client.is_connected() is False
    with pytest.raises(IbDisconnectedError):
        await client.current_time(SHORT)


async def test_the_account_list_sent_by_the_gateway_is_not_exposed(
    gateway: WireGateway, client: IbAsyncClient
) -> None:
    await client.connect("127.0.0.1", gateway.port, 999, GENEROUS)
    assert "DU1234567" not in repr(client)
    assert "DU1234567" not in repr(vars(client))
