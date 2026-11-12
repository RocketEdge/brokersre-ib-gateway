"""Delivery: bounded outboxes, per-send timeout, retries, isolation between channels."""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import timedelta

import pytest

from brokersre_sidecar.notify import DeliveryError, Dispatcher, Message, MessageFactory
from brokersre_sidecar.redaction import SecretRegistry
from brokersre_sidecar.vocab import AlertClass, MessageKind
from testkit import T0, FakeClock, RecordingSleep


def make_message(detail: str = "d", kind: MessageKind = MessageKind.FIRING) -> Message:
    return MessageFactory("desk-1", "Etc/UTC", None, SecretRegistry()).build(
        kind,
        AlertClass.API_UNHEALTHY,
        detail=detail,
        escalation_step=0,
        since=T0,
        phase="logged-in",
        api_status="down",
        now=T0,
    )


class ScriptedChannel:
    """A channel whose ``send`` follows a script of outcomes (None = success)."""

    def __init__(self, name: str, *outcomes: DeliveryError | None, heartbeat: bool = True) -> None:
        self.name = name
        self.sent: list[Message] = []
        self.attempts = 0
        self._outcomes = list(outcomes)
        self._heartbeat = heartbeat
        self.gate: asyncio.Event | None = None

    def wants(self, message: Message) -> bool:
        return self._heartbeat or message.kind != MessageKind.HEARTBEAT

    async def send(self, message: Message) -> None:
        self.attempts += 1
        if self.gate is not None:
            await self.gate.wait()
        outcome = self._outcomes.pop(0) if self._outcomes else None
        if outcome is not None:
            raise outcome
        self.sent.append(message)


@asynccontextmanager
async def running(dispatcher: Dispatcher) -> AsyncIterator[None]:
    """Run one worker task per channel for the duration of the block."""
    tasks = [
        asyncio.ensure_future(dispatcher.run_channel(name)) for name in dispatcher.channel_names()
    ]
    try:
        yield
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)


def dispatcher_for(*channels: ScriptedChannel, **options: object) -> tuple[Dispatcher, FakeClock]:
    clock = FakeClock()
    dispatcher = Dispatcher(
        {channel.name: channel for channel in channels},
        clock,
        RecordingSleep(clock),
        rand=lambda: 0.5,
        **options,  # type: ignore[arg-type]
    )
    return dispatcher, clock


async def test_a_message_reaches_every_named_channel_and_is_counted() -> None:
    teams, slack, unused = ScriptedChannel("teams"), ScriptedChannel("slack"), ScriptedChannel("x")
    dispatcher, _ = dispatcher_for(teams, slack, unused)
    async with running(dispatcher):
        dispatcher.enqueue(make_message(), ["teams", "slack", "not-configured"])
        await dispatcher.drain()
    assert len(teams.sent) == len(slack.sent) == 1
    assert unused.sent == []
    stats = {channel.name: channel for channel in dispatcher.snapshot()}
    assert stats["teams"].sent_total == 1
    assert stats["teams"].failures_total == 0
    assert stats["teams"].last_success_at == T0
    assert stats["teams"].queue_depth == 0
    assert stats["x"].sent_total == 0


async def test_retryable_failures_are_retried_three_times_with_exponential_back_off() -> None:
    flaky = ScriptedChannel(
        "teams",
        DeliveryError("http_503", retryable=True),
        DeliveryError("timeout", retryable=True),
    )
    clock = FakeClock()
    sleep = RecordingSleep(clock)
    dispatcher = Dispatcher({"teams": flaky}, clock, sleep, rand=lambda: 0.5)
    async with running(dispatcher):
        dispatcher.enqueue(make_message(), ["teams"])
        await dispatcher.drain()
    assert flaky.attempts == 3
    assert sleep.calls == [1.0, 2.0]
    (stats,) = dispatcher.snapshot()
    assert (stats.sent_total, stats.failures_total, stats.last_error) == (1, 0, None)


async def test_after_the_last_retry_the_failure_is_recorded_and_the_worker_moves_on() -> None:
    dead = ScriptedChannel("teams", *[DeliveryError("http_503", retryable=True)] * 4)
    clock = FakeClock()
    sleep = RecordingSleep(clock)
    dispatcher = Dispatcher({"teams": dead}, clock, sleep, rand=lambda: 0.5)
    async with running(dispatcher):
        dispatcher.enqueue(make_message("first"), ["teams"])
        dispatcher.enqueue(make_message("second"), ["teams"])
        await dispatcher.drain()
    assert dead.attempts == 5  # 1 + 3 retries for the first, 1 for the second
    assert sleep.calls == [1.0, 2.0, 4.0]
    (stats,) = dispatcher.snapshot()
    assert (stats.sent_total, stats.failures_total, stats.last_error) == (1, 1, "http_503")
    assert stats.last_failure_at == T0 + timedelta(seconds=7)
    assert [message.detail for message in dead.sent] == ["second"]


async def test_a_final_error_is_not_retried() -> None:
    rejected = ScriptedChannel("slack", DeliveryError("http_401", retryable=False))
    dispatcher, _ = dispatcher_for(rejected)
    async with running(dispatcher):
        dispatcher.enqueue(make_message(), ["slack"])
        await dispatcher.drain()
    assert rejected.attempts == 1
    assert dispatcher.snapshot()[0].last_error == "http_401"


async def test_a_channel_that_hangs_does_not_delay_another_channel() -> None:
    stuck, healthy = ScriptedChannel("webhook"), ScriptedChannel("teams")
    stuck.gate = asyncio.Event()
    dispatcher, _ = dispatcher_for(stuck, healthy)
    async with running(dispatcher):
        dispatcher.enqueue(make_message(), ["webhook", "teams"])
        async with asyncio.timeout(5):
            # Yield to the loop until the healthy worker has run (bounded by the timeout).
            while not healthy.sent:  # noqa: ASYNC110
                await asyncio.sleep(0)
        assert stuck.sent == []
        assert stuck.attempts == 1
        stuck.gate.set()
        await dispatcher.drain()
    assert len(stuck.sent) == 1


async def test_a_send_that_exceeds_the_per_send_timeout_counts_as_a_timeout() -> None:
    stuck = ScriptedChannel("webhook")
    stuck.gate = asyncio.Event()
    dispatcher, _ = dispatcher_for(stuck, send_timeout_s=0.01, retries=0)
    async with running(dispatcher):
        dispatcher.enqueue(make_message(), ["webhook"])
        await dispatcher.drain()
    (stats,) = dispatcher.snapshot()
    assert (stats.failures_total, stats.last_error) == (1, "timeout")


async def test_a_full_outbox_drops_the_oldest_message_and_counts_it() -> None:
    channel = ScriptedChannel("teams")
    dispatcher, _ = dispatcher_for(channel, outbox_size=2)
    for number in range(5):
        dispatcher.enqueue(make_message(f"m{number}"), ["teams"])
    (stats,) = dispatcher.snapshot()
    assert (stats.queue_depth, stats.dropped_total) == (2, 3)
    async with running(dispatcher):
        await dispatcher.drain()
    assert [message.detail for message in channel.sent] == ["m3", "m4"]


async def test_a_channel_only_receives_the_kinds_it_wants() -> None:
    pager = ScriptedChannel("pagerduty", heartbeat=False)
    dispatcher, _ = dispatcher_for(pager)
    dispatcher.enqueue(make_message(kind=MessageKind.HEARTBEAT), ["pagerduty"])
    assert dispatcher.snapshot()[0].queue_depth == 0


async def test_send_now_makes_one_attempt_and_reports_the_category() -> None:
    good = ScriptedChannel("teams")
    bad = ScriptedChannel("slack", DeliveryError("http_404", retryable=False))
    dispatcher, _ = dispatcher_for(good, bad)
    assert await dispatcher.send_now("teams", make_message()) is None
    assert await dispatcher.send_now("slack", make_message()) == "http_404"
    assert await dispatcher.send_now("absent", make_message()) == "not_configured"
    stats = {channel.name: channel for channel in dispatcher.snapshot()}
    assert stats["teams"].sent_total == 1
    assert stats["slack"].failures_total == 1


async def test_a_bug_in_a_channel_is_counted_and_surfaces_to_the_supervisor() -> None:
    class Broken(ScriptedChannel):
        async def send(self, message: Message) -> None:
            raise RuntimeError("bug with CANARY text")

    dispatcher, _ = dispatcher_for(Broken("teams"))
    dispatcher.enqueue(make_message(), ["teams"])
    with pytest.raises(RuntimeError):
        await dispatcher.run_channel("teams")
    (stats,) = dispatcher.snapshot()
    assert (stats.failures_total, stats.last_error, stats.queue_depth) == (1, "internal_error", 0)


class Outcomes:
    """Collects what ``on_done`` reports."""

    def __init__(self) -> None:
        self.reported: list[bool] = []

    def __call__(self, accepted: bool) -> None:
        self.reported.append(accepted)


async def test_the_caller_learns_that_at_least_one_channel_accepted_the_message() -> None:
    dead = ScriptedChannel("teams", DeliveryError("http_401", retryable=False))
    alive = ScriptedChannel("slack")
    dispatcher, _ = dispatcher_for(dead, alive)
    outcome = Outcomes()
    async with running(dispatcher):
        dispatcher.enqueue(make_message(), ["teams", "slack", "teams"], outcome)
        await dispatcher.drain()
    assert outcome.reported == [True]  # once, although two channels were involved


async def test_the_caller_learns_that_no_channel_accepted_the_message() -> None:
    first = ScriptedChannel("teams", *[DeliveryError("connect", retryable=True)] * 4)
    second = ScriptedChannel("slack", DeliveryError("http_404", retryable=False))
    dispatcher, _ = dispatcher_for(first, second)
    outcome = Outcomes()
    async with running(dispatcher):
        dispatcher.enqueue(make_message(), ["teams", "slack"], outcome)
        await dispatcher.drain()
    assert outcome.reported == [False]
    assert first.attempts == 4  # the retries happened before the verdict


async def test_a_message_no_channel_is_eligible_for_is_reported_as_not_delivered_at_once() -> None:
    pager = ScriptedChannel("pagerduty", heartbeat=False)
    dispatcher, _ = dispatcher_for(pager)
    outcome = Outcomes()
    dispatcher.enqueue(make_message(), ["not-configured"], outcome)
    dispatcher.enqueue(make_message(kind=MessageKind.HEARTBEAT), ["pagerduty"], outcome)
    assert outcome.reported == [False, False]


async def test_a_message_dropped_from_a_full_outbox_is_reported_as_not_delivered() -> None:
    channel = ScriptedChannel("teams")
    dispatcher, _ = dispatcher_for(channel, outbox_size=1)
    first, second = Outcomes(), Outcomes()
    dispatcher.enqueue(make_message("old"), ["teams"], first)
    dispatcher.enqueue(make_message("new"), ["teams"], second)
    assert first.reported == [False]
    async with running(dispatcher):
        await dispatcher.drain()
    assert second.reported == [True]
    assert dispatcher.snapshot()[0].dropped_total == 1


async def test_a_bug_in_a_channel_is_reported_as_not_delivered() -> None:
    class Broken(ScriptedChannel):
        async def send(self, message: Message) -> None:
            raise RuntimeError("bug")

    dispatcher, _ = dispatcher_for(Broken("teams"))
    outcome = Outcomes()
    dispatcher.enqueue(make_message(), ["teams"], outcome)
    with pytest.raises(RuntimeError):
        await dispatcher.run_channel("teams")
    assert outcome.reported == [False]
