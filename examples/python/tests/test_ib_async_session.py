"""Tests for ``IbAsyncSession``, the thin adapter between ``ResilientClient`` and ib_async.

``FakeIB`` records what the adapter asks of ib_async; its events are real eventkit events. A
last group of tests builds a real ``ib_async.IB`` without connecting it, to prove that the
attributes and parameters the adapter relies on exist in the pinned ib_async release.
"""

import asyncio
import datetime as dt
import inspect
from typing import Any, cast

import ib_async
import pytest

from fakes import FakeIB
from resilient_client import IbAsyncSession


def adapter_on(fake: FakeIB) -> IbAsyncSession:
    """Wrap ``fake`` in the adapter (the cast stands in for the real ``ib_async.IB`` type)."""
    return IbAsyncSession(cast(ib_async.IB, fake))


def test_connect_is_read_only_and_asks_ib_async_for_no_startup_data() -> None:
    """readonly=True and an empty startup-fetch flag: no order or account sync on connect."""
    fake = FakeIB()
    session = adapter_on(fake)

    asyncio.run(session.connect("gateway.test", 4004, 7, 12.5))

    assert fake.connect_calls == [
        {
            "host": "gateway.test",
            "port": 4004,
            "clientId": 7,
            "timeout": 12.5,
            "readonly": True,
            "fetchFields": ib_async.StartupFetchNONE,
        }
    ]
    assert session.is_connected() is True


def test_an_ib_async_error_event_reaches_the_handler_without_the_contract() -> None:
    """ib_async 2.1.0 emits (reqId, errorCode, errorString, contract); three are passed on."""
    fake = FakeIB()
    session = adapter_on(fake)
    received: list[tuple[int, int, str]] = []
    session.on_error(lambda req_id, code, message: received.append((req_id, code, message)))

    fake.errorEvent.emit(-1, 1100, "Connectivity between IBKR and the gateway has been lost", None)

    assert received == [(-1, 1100, "Connectivity between IBKR and the gateway has been lost")]


def test_a_disconnect_event_reaches_the_handler() -> None:
    """The peer closing the socket surfaces as ib_async's disconnectedEvent."""
    fake = FakeIB()
    session = adapter_on(fake)
    calls: list[str] = []
    session.on_disconnected(lambda: calls.append("disconnected"))

    fake.disconnectedEvent.emit()

    assert calls == ["disconnected"]


def test_the_server_time_is_requested_once_and_returned_in_utc() -> None:
    """ib_async answers in its configured zone; the adapter always hands out UTC."""
    fake = FakeIB()
    session = adapter_on(fake)

    answer = asyncio.run(session.server_time(5.0))

    assert fake.time_requests == 1
    assert answer == dt.datetime(2026, 11, 12, 14, 30, 0, tzinfo=dt.UTC)
    assert answer.utcoffset() == dt.timedelta(0)


def test_an_unanswered_server_time_request_times_out() -> None:
    """Every request has a deadline: a gateway that stays silent raises TimeoutError."""
    fake = FakeIB()
    fake.time_answer = None
    session = adapter_on(fake)

    with pytest.raises(TimeoutError):
        asyncio.run(session.server_time(0.01))


def test_a_connection_attempt_that_hangs_ends_at_the_timeout_and_is_cleaned_up() -> None:
    """The timeout bounds the whole attempt, and nothing half-connected is left behind.

    ib_async applies its timeout to each step of connecting separately, so an attempt can
    take several times as long; the adapter puts one deadline around all of it.
    """
    fake = FakeIB()
    fake.connect_hangs = True
    session = adapter_on(fake)

    with pytest.raises(TimeoutError):
        asyncio.run(session.connect("gateway.test", 4004, 7, 0.01))

    assert fake.disconnect_calls == 1
    assert session.is_connected() is False


def test_disconnect_and_is_connected_are_passed_through() -> None:
    """The adapter keeps no connection state of its own."""
    fake = FakeIB()
    session = adapter_on(fake)
    asyncio.run(session.connect("gateway.test", 4004, 7, 5.0))

    session.disconnect()

    assert fake.disconnect_calls == 1
    assert session.is_connected() is False


def test_the_pinned_ib_async_has_what_the_adapter_uses() -> None:
    """Guards a version bump: parameters, events and the empty startup flag must exist."""
    parameters = inspect.signature(ib_async.IB.connectAsync).parameters

    assert {"host", "port", "clientId", "timeout", "readonly", "fetchFields"} <= set(parameters)
    assert ib_async.StartupFetchNONE == ib_async.StartupFetch(0)
    assert inspect.signature(ib_async.IB.reqCurrentTimeAsync).return_annotation is not None


def test_the_adapter_builds_a_real_unconnected_ib_async_session() -> None:
    """Without an argument the adapter owns a real ib_async.IB; nothing is connected."""

    async def build() -> bool:
        return IbAsyncSession().is_connected()

    assert asyncio.run(build()) is False


def test_ib_async_s_own_reaction_to_1102_is_switched_off(monkeypatch: pytest.MonkeyPatch) -> None:
    """ib_async 2.1.0 opens a new account-summary subscription on every 1102.

    IBKR allows two such subscriptions (error 322 after that), and this client asks for the
    server time only, so the adapter detaches that handler. The error event of a real
    ``ib_async.IB`` is emitted with 1102 and the request method must not be called.
    """
    requests: list[str] = []

    async def scenario() -> None:
        ib = ib_async.IB()

        def record_request(*_args: Any, **_kwargs: Any) -> asyncio.Future[None]:
            requests.append("account summary")
            future: asyncio.Future[None] = asyncio.get_running_loop().create_future()
            future.set_result(None)
            return future

        monkeypatch.setattr(ib, "reqAccountSummaryAsync", record_request)
        IbAsyncSession(ib)
        ib.errorEvent.emit(-1, 1102, "Connectivity restored - data maintained", None)
        await asyncio.sleep(0)

    asyncio.run(scenario())

    assert requests == []
