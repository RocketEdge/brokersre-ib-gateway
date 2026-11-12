"""Tests for ``ResilientClient`` against a scriptable session: no socket, no IBKR, no waiting.

They cover what strategy code must get right around a gateway: a refused connection means
"not ready, try again"; 1100 means stop sending and keep the connection; 1101 means
re-subscribe; the daily restart closes the socket and the client must come back by itself.
"""

import asyncio
import datetime as dt
import logging
import random
from collections.abc import Callable, Coroutine
from typing import Any

import pytest

from fakes import SERVER_TIME, FakeSession
from resilient_client import (
    BackoffPolicy,
    ClientConfig,
    Readiness,
    ResilientClient,
    configure_logging,
)

POLL_INTERVAL_S = 30.0


class RecordingSleep:
    """Stand-in for ``asyncio.sleep``: records every pause and returns at once.

    ``events`` maps the index of a pause (0 for the first) to a callback run during that
    pause, which is how a test lets the gateway do something "while the client sleeps".
    After ``stop_after`` pauses the next one raises ``CancelledError``, the way a real client
    is stopped.
    """

    def __init__(
        self, stop_after: int | None = None, events: dict[int, Callable[[], None]] | None = None
    ) -> None:
        """Create the recorder; see the class docstring for the two parameters."""
        self.delays: list[float] = []
        self._stop_after = stop_after
        self._events = events or {}

    async def __call__(self, seconds: float) -> None:
        """Record ``seconds``, run the scripted callback for this pause, maybe cancel."""
        index = len(self.delays)
        self.delays.append(seconds)
        if index in self._events:
            self._events[index]()
        if self._stop_after is not None and len(self.delays) >= self._stop_after:
            raise asyncio.CancelledError
        await asyncio.sleep(0)


def make_client(
    session: FakeSession,
    sleep: RecordingSleep | None = None,
    resubscribed: list[str] | None = None,
    max_missed_polls: int = 3,
) -> ResilientClient:
    """Build a client on ``session`` with a seeded generator and a recording sleep."""
    config = ClientConfig(
        host="gateway.test",
        port=4004,
        client_id=7,
        poll_interval_s=POLL_INTERVAL_S,
        connect_timeout_s=10.0,
        request_timeout_s=5.0,
        max_missed_polls=max_missed_polls,
        backoff=BackoffPolicy(base_s=1.0, cap_s=30.0, jitter=0.25),
    )
    hook: Callable[[], None] | None = None
    if resubscribed is not None:
        hook = lambda: resubscribed.append("resubscribe")  # noqa: E731
    return ResilientClient(
        session,
        config,
        sleep=sleep or RecordingSleep(),
        rng=random.Random(42),
        on_resubscribe=hook,
    )


def run[T](coroutine: Coroutine[Any, Any, T]) -> T:
    """Run one coroutine to completion on a fresh event loop."""
    return asyncio.run(coroutine)


def test_a_successful_connection_uses_the_configured_endpoint_and_makes_the_client_ready() -> None:
    """Host, port, client id and timeout reach the session unchanged."""
    session = FakeSession()
    client = make_client(session)

    connected = run(client.connect_once())

    assert connected is True
    assert session.connect_calls == [("gateway.test", 4004, 7, 10.0)]
    assert client.state.readiness is Readiness.READY


@pytest.mark.parametrize(
    "failure",
    [
        ConnectionRefusedError("refused"),
        TimeoutError("handshake not answered"),
        ConnectionError("Socket connection broken while connecting"),
        OSError("Network is unreachable"),
    ],
    ids=["refused", "timeout", "broken-while-connecting", "unreachable"],
)
def test_a_gateway_that_is_not_ready_is_not_an_error(failure: BaseException) -> None:
    """Refused, timed out or cut off: the attempt reports False and nothing is raised."""
    session = FakeSession(connect_script=[failure])
    client = make_client(session)

    connected = run(client.connect_once())

    assert connected is False
    assert client.state.readiness is Readiness.DISCONNECTED


def test_a_programming_error_during_connect_is_not_swallowed() -> None:
    """Only network conditions mean "retry"; anything else must surface."""
    session = FakeSession(connect_script=[ValueError("bad argument")])
    client = make_client(session)

    with pytest.raises(ValueError, match="bad argument"):
        run(client.connect_once())


def test_connecting_retries_with_growing_jittered_pauses_until_the_gateway_answers() -> None:
    """Three refusals, then success: three pauses, each inside its back-off band."""
    session = FakeSession(
        connect_script=[
            ConnectionRefusedError("refused"),
            ConnectionRefusedError("refused"),
            TimeoutError("handshake not answered"),
            None,
        ]
    )
    sleep = RecordingSleep()
    client = make_client(session, sleep)

    run(client.connect_until_ready())

    assert len(session.connect_calls) == 4
    assert client.state.readiness is Readiness.READY
    assert len(sleep.delays) == 3
    assert 0.75 <= sleep.delays[0] <= 1.0
    assert 1.5 <= sleep.delays[1] <= 2.0
    assert 3.0 <= sleep.delays[2] <= 4.0


def test_the_pause_never_exceeds_the_cap_however_long_the_gateway_stays_away() -> None:
    """Twelve refusals in a row: every pause is at most the 30 s cap."""
    refusals: list[BaseException | None] = [ConnectionRefusedError("refused") for _ in range(12)]
    session = FakeSession(connect_script=[*refusals, None])
    sleep = RecordingSleep()
    client = make_client(session, sleep)

    run(client.connect_until_ready())

    assert len(sleep.delays) == 12
    assert max(sleep.delays) <= 30.0
    assert sleep.delays[-1] >= 22.5


def test_the_back_off_starts_again_from_the_base_after_a_successful_connection() -> None:
    """A later outage is retried quickly at first, not at the cap reached last time."""
    session = FakeSession(
        connect_script=[
            ConnectionRefusedError("refused"),
            ConnectionRefusedError("refused"),
            ConnectionRefusedError("refused"),
            None,
            ConnectionRefusedError("refused"),
            None,
        ]
    )
    sleep = RecordingSleep()
    client = make_client(session, sleep)

    run(client.connect_until_ready())
    session.drop()
    run(client.connect_until_ready())

    assert len(sleep.delays) == 4
    assert 0.75 <= sleep.delays[3] <= 1.0


def test_a_ready_client_asks_for_the_server_time_and_keeps_the_answer() -> None:
    """The one request of the sample: the IBKR server time, with the request timeout."""
    session = FakeSession()
    client = make_client(session)
    run(client.connect_once())

    answer = run(client.poll_once())

    assert answer == SERVER_TIME
    assert client.last_server_time == SERVER_TIME
    assert session.time_requests == [5.0]


def test_a_disconnected_client_sends_nothing() -> None:
    """Without a connection a poll is skipped, not attempted."""
    session = FakeSession()
    client = make_client(session)

    answer = run(client.poll_once())

    assert answer is None
    assert session.time_requests == []


def test_1100_stops_the_requests_and_keeps_the_connection() -> None:
    """Connectivity lost: no request goes out, and the socket is neither closed nor reopened."""
    session = FakeSession()
    client = make_client(session)
    run(client.connect_once())

    session.emit_error(1100, "Connectivity between IBKR and the gateway has been lost")
    answer = run(client.poll_once())

    assert answer is None
    assert session.time_requests == []
    assert client.state.readiness is Readiness.CONNECTIVITY_LOST
    assert session.disconnect_calls == 0
    assert session.connected is True
    assert len(session.connect_calls) == 1


def test_1102_lets_the_requests_continue_without_resubscribing() -> None:
    """Connectivity restored, data maintained: polling resumes on the same connection."""
    session = FakeSession()
    resubscribed: list[str] = []
    client = make_client(session, resubscribed=resubscribed)
    run(client.connect_once())
    session.emit_error(1100, "lost")

    session.emit_error(1102, "Connectivity restored - data maintained")
    answer = run(client.poll_once())

    assert answer == SERVER_TIME
    assert client.state.readiness is Readiness.READY
    assert resubscribed == ["resubscribe"]
    assert len(session.connect_calls) == 1


def test_1101_lets_the_requests_continue_and_resubscribes() -> None:
    """Connectivity restored, data lost: the re-subscribe hook runs a second time."""
    session = FakeSession()
    resubscribed: list[str] = []
    client = make_client(session, resubscribed=resubscribed)
    run(client.connect_once())
    session.emit_error(1100, "lost")

    session.emit_error(1101, "Connectivity restored - data lost")
    answer = run(client.poll_once())

    assert answer == SERVER_TIME
    assert resubscribed == ["resubscribe", "resubscribe"]
    assert client.resubscriptions == 2
    assert len(session.connect_calls) == 1


@pytest.mark.parametrize("code", [2103, 2105, 2157])
def test_a_broken_data_farm_does_not_stop_the_requests(code: int) -> None:
    """Farm codes describe market-data routes; the API connection is still usable."""
    session = FakeSession()
    client = make_client(session)
    run(client.connect_once())

    session.emit_error(code, "A data farm connection is broken:usfarm")
    answer = run(client.poll_once())

    assert answer == SERVER_TIME
    assert client.state.broken_farms == ("usfarm",)
    assert session.disconnect_calls == 0


@pytest.mark.parametrize("code", [2104, 2106, 2158])
def test_a_farm_ok_code_clears_the_broken_farm(code: int) -> None:
    """The OK code of each farm kind removes that farm from the broken list."""
    session = FakeSession()
    client = make_client(session)
    run(client.connect_once())
    session.emit_error(code - 1, "A data farm connection is broken:usfarm")

    session.emit_error(code, "A data farm connection is OK:usfarm")

    assert client.state.broken_farms == ()


def test_a_closed_socket_makes_the_client_disconnected() -> None:
    """The peer closing the connection (daily restart) is noticed without a request."""
    session = FakeSession()
    client = make_client(session)
    run(client.connect_once())

    session.drop()

    assert client.state.readiness is Readiness.DISCONNECTED


def test_a_request_cut_off_by_a_disconnect_closes_the_session_and_reports_nothing() -> None:
    """ib_async fails a pending request with ConnectionError when the socket closes."""
    session = FakeSession(time_script=[ConnectionError("Socket disconnect")])
    client = make_client(session)
    run(client.connect_once())

    answer = run(client.poll_once())

    assert answer is None
    assert client.state.readiness is Readiness.DISCONNECTED
    assert session.disconnect_calls == 1


def test_three_unanswered_requests_in_a_row_drop_a_connection_that_looks_dead() -> None:
    """A half-open socket never reports a disconnect; silence is the only signal."""
    session = FakeSession(time_script=[TimeoutError(), TimeoutError(), TimeoutError()])
    client = make_client(session, max_missed_polls=3)
    run(client.connect_once())

    answers = [run(client.poll_once()) for _ in range(3)]

    assert answers == [None, None, None]
    assert session.disconnect_calls == 1
    assert client.state.readiness is Readiness.DISCONNECTED


def test_an_answer_resets_the_count_of_unanswered_requests() -> None:
    """Two misses, an answer, two misses: never three in a row, so the connection stays."""
    session = FakeSession(
        time_script=[TimeoutError(), TimeoutError(), SERVER_TIME, TimeoutError(), TimeoutError()]
    )
    client = make_client(session, max_missed_polls=3)
    run(client.connect_once())

    for _ in range(5):
        run(client.poll_once())

    assert session.disconnect_calls == 0
    assert client.state.readiness is Readiness.READY


def test_a_programming_error_during_a_request_is_not_swallowed() -> None:
    """Only a timeout or a lost connection is expected from a request."""
    session = FakeSession(time_script=[ValueError("bad state")])
    client = make_client(session)
    run(client.connect_once())

    with pytest.raises(ValueError, match="bad state"):
        run(client.poll_once())


def test_error_326_is_logged_with_the_way_out(caplog: pytest.LogCaptureFixture) -> None:
    """A client id that is already in use is a configuration problem worth a clear line."""
    session = FakeSession()
    client = make_client(session)
    run(client.connect_once())

    with caplog.at_level(logging.ERROR, logger="resilient_client"):
        session.emit_error(326, "Unable to connect as the client id is already in use")

    assert client.state.readiness is Readiness.READY
    assert any("client id 7" in record.getMessage() for record in caplog.records)


def test_the_raw_text_of_an_ibkr_message_is_never_logged(caplog: pytest.LogCaptureFixture) -> None:
    """IBKR's message text can name an account: the client logs codes and farm names only."""
    session = FakeSession()
    client = make_client(session)
    run(client.connect_once())

    with caplog.at_level(logging.DEBUG, logger="resilient_client"):
        session.emit_error(1100, "CANARY_ACCOUNT_TEXT lost")
        session.emit_error(1102, "CANARY_ACCOUNT_TEXT restored")
        session.emit_error(2103, "CANARY_ACCOUNT_TEXT broken:usfarm")
        session.emit_error(326, "CANARY_ACCOUNT_TEXT in use")
        session.emit_error(200, "CANARY_ACCOUNT_TEXT no security definition")

    messages = [record.getMessage() for record in caplog.records]
    assert len(messages) >= 4
    assert not [message for message in messages if "CANARY_ACCOUNT_TEXT" in message]
    assert any("usfarm" in message for message in messages)


def test_logging_setup_silences_ib_async_which_would_log_raw_ibkr_text() -> None:
    """ib_async logs every IBKR message verbatim; the sample reports them itself, by code."""
    ib_async_logger = logging.getLogger("ib_async")
    level_before = ib_async_logger.level
    try:
        configure_logging()

        assert logging.getLogger("ib_async.wrapper").getEffectiveLevel() == logging.CRITICAL
        assert logging.getLogger("ib_async.client").getEffectiveLevel() == logging.CRITICAL
    finally:
        ib_async_logger.setLevel(level_before)


def test_run_waits_for_a_gateway_that_is_not_up_yet_then_polls() -> None:
    """Start before the gateway: two refusals, a connection, one server time, then stop."""
    session = FakeSession(
        connect_script=[ConnectionRefusedError("refused"), ConnectionRefusedError("refused"), None]
    )
    sleep = RecordingSleep(stop_after=3)
    client = make_client(session, sleep)

    with pytest.raises(asyncio.CancelledError):
        run(client.run())

    assert len(session.connect_calls) == 3
    assert session.time_requests == [5.0]
    assert 0.75 <= sleep.delays[0] <= 1.0
    assert 1.5 <= sleep.delays[1] <= 2.0
    assert sleep.delays[2] == POLL_INTERVAL_S


def test_run_reconnects_after_the_daily_restart_and_resubscribes() -> None:
    """The gateway closes the socket, refuses once while it restarts, then is back."""
    session = FakeSession(connect_script=[None, ConnectionRefusedError("refused"), None])
    resubscribed: list[str] = []
    # Pause 0 is the first poll interval: the gateway restarts during it.
    sleep = RecordingSleep(stop_after=3, events={0: session.drop})
    client = make_client(session, sleep, resubscribed=resubscribed)

    with pytest.raises(asyncio.CancelledError):
        run(client.run())

    assert len(session.connect_calls) == 3
    assert session.time_requests == [5.0, 5.0]
    assert resubscribed == ["resubscribe", "resubscribe"]
    assert sleep.delays[0] == POLL_INTERVAL_S
    assert 0.75 <= sleep.delays[1] <= 1.0
    assert sleep.delays[2] == POLL_INTERVAL_S


def test_run_does_not_poll_during_an_outage_and_resumes_after_it() -> None:
    """1100 during the first pause, 1102 during the second: one poll is skipped."""
    session = FakeSession()
    sleep = RecordingSleep(
        stop_after=3,
        events={
            0: lambda: session.emit_error(1100, "lost"),
            1: lambda: session.emit_error(1102, "restored"),
        },
    )
    client = make_client(session, sleep)

    with pytest.raises(asyncio.CancelledError):
        run(client.run())

    # Polls: before pause 0 (answered), before pause 1 (skipped), before pause 2 (answered).
    assert session.time_requests == [5.0, 5.0]
    assert len(session.connect_calls) == 1


def test_run_closes_the_connection_when_it_is_stopped() -> None:
    """Stopping the client disconnects, which frees the client id at once."""
    session = FakeSession()
    client = make_client(session, RecordingSleep(stop_after=1))

    with pytest.raises(asyncio.CancelledError):
        run(client.run())

    assert session.disconnect_calls == 1
    assert session.connected is False


def test_a_requested_stop_is_not_logged_as_a_lost_connection(
    caplog: pytest.LogCaptureFixture,
) -> None:
    """An operator who stops the client must not read "will reconnect" in its last line."""
    session = FakeSession()
    client = make_client(session, RecordingSleep(stop_after=1))

    with (
        caplog.at_level(logging.INFO, logger="resilient_client"),
        pytest.raises(asyncio.CancelledError),
    ):
        run(client.run())

    messages = [record.getMessage() for record in caplog.records]
    assert not [message for message in messages if "will reconnect" in message]
    assert any("client stopped" in message for message in messages)


@pytest.mark.parametrize(
    ("field", "value", "message"),
    [
        ("port", 0, "port must be between 1 and 65535"),
        ("port", 70000, "port must be between 1 and 65535"),
        ("client_id", -1, "client_id must not be negative"),
        ("poll_interval_s", 0.0, "poll_interval_s must be positive"),
        ("connect_timeout_s", 0.0, "connect_timeout_s must be positive"),
        ("request_timeout_s", -1.0, "request_timeout_s must be positive"),
        ("max_missed_polls", 0, "max_missed_polls must be at least 1"),
    ],
)
def test_an_impossible_configuration_is_refused(field: str, value: float, message: str) -> None:
    """A configuration that could never work fails when it is built, not at 3 a.m."""
    arguments: dict[str, Any] = {field: value}

    with pytest.raises(ValueError, match=message):
        ClientConfig(**arguments)


def test_the_server_time_is_reported_in_utc() -> None:
    """Whatever zone the session answers in, the client keeps and logs UTC."""
    eastern = dt.datetime(2026, 11, 12, 9, 30, 0, tzinfo=dt.timezone(dt.timedelta(hours=-5)))
    session = FakeSession(time_script=[eastern])
    client = make_client(session)
    run(client.connect_once())

    answer = run(client.poll_once())

    assert answer == SERVER_TIME
    assert answer is not None
    assert answer.utcoffset() == dt.timedelta(0)
