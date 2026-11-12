"""The dead-man ping: a plain GET while everything it vouches for holds."""

from __future__ import annotations

import logging

import httpx
import pytest

from brokersre_sidecar.config import Secret
from brokersre_sidecar.notify import (
    Condition,
    DeadmanPinger,
    Evaluation,
    HttpTransport,
    alerting_classes,
)
from brokersre_sidecar.vocab import AlertClass
from testkit import FakeClock

URL = "https://hc.example.com/ping/CANARY_DEADMAN_ID"


class World:
    """A pinger wired to a recording HTTP endpoint and a settable reason to withhold."""

    def __init__(self, interval_s: float = 60.0) -> None:
        self.clock = FakeClock()
        self.requests: list[httpx.Request] = []
        self.answer = 200
        self.fault: type[Exception] | None = None
        self.reason: str | None = None
        client = httpx.AsyncClient(transport=httpx.MockTransport(self._handle))
        self.pinger = DeadmanPinger(
            Secret(URL),
            HttpTransport(client),
            self.clock,
            interval_s=interval_s,
            withhold=lambda: self.reason,
        )

    def _handle(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.fault is not None:
            raise self.fault("no route")
        return httpx.Response(self.answer)

    async def tick(self, advance: float = 0.0) -> None:
        self.clock.advance(advance)
        await self.pinger.tick()


async def test_a_ping_is_a_plain_get_of_exactly_the_configured_url() -> None:
    world = World()
    await world.tick()
    (request,) = world.requests
    assert request.method == "GET"
    assert str(request.url) == URL  # nothing appended: no query, no path
    assert request.content == b""
    # Only what an HTTP client sends by itself: nothing describes the gateway.
    assert set(request.headers) <= {
        "host",
        "accept",
        "accept-encoding",
        "connection",
        "user-agent",
        "content-length",
    }
    snapshot = world.pinger.snapshot()
    assert (snapshot.enabled, snapshot.pings_total, snapshot.failures_total) == (True, 1, 0)
    assert snapshot.last_ping_at == world.clock.now()
    assert snapshot.withheld is None


async def test_pings_follow_the_interval() -> None:
    world = World(interval_s=60.0)
    await world.tick()
    await world.tick(59)
    assert len(world.requests) == 1
    await world.tick(1)
    assert len(world.requests) == 2


async def test_nothing_is_sent_while_there_is_a_reason_and_at_once_when_it_is_gone() -> None:
    world = World()
    world.reason = "alert active: twofa_pending"
    await world.tick()
    await world.tick(600)
    assert world.requests == []
    assert world.pinger.snapshot().withheld == "alert active: twofa_pending"
    assert world.pinger.snapshot().last_ping_at is None
    world.reason = None
    await world.tick(1)
    assert len(world.requests) == 1
    assert world.pinger.snapshot().withheld is None


async def test_a_failed_ping_is_counted_and_tried_again_sooner_than_an_interval() -> None:
    world = World(interval_s=60.0)
    world.answer = 503
    await world.tick()
    snapshot = world.pinger.snapshot()
    assert (snapshot.pings_total, snapshot.failures_total, snapshot.last_error) == (
        0,
        1,
        "http_503",
    )
    await world.tick(14)
    assert len(world.requests) == 1
    world.fault = httpx.ConnectError
    await world.tick(1)
    assert len(world.requests) == 2
    assert world.pinger.snapshot().last_error == "connect"
    world.fault, world.answer = None, 200
    await world.tick(15)
    snapshot = world.pinger.snapshot()
    assert (snapshot.pings_total, snapshot.failures_total, snapshot.last_error) == (1, 2, None)
    await world.tick(59)
    assert len(world.requests) == 3  # back to the full interval


async def test_a_short_interval_is_not_stretched_by_the_retry_delay() -> None:
    world = World(interval_s=10.0)
    world.answer = 500
    await world.tick()
    await world.tick(10)
    assert len(world.requests) == 2


async def test_the_url_is_never_logged_or_shown(caplog: pytest.LogCaptureFixture) -> None:
    # httpx logs every request URL at INFO; the sidecar caps that logger at WARNING for
    # exactly this reason (see logsetup and its test). Here: what the sidecar itself logs.
    caplog.set_level(logging.DEBUG, logger="brokersre_sidecar")
    caplog.set_level(logging.WARNING, logger="httpx")
    world = World()
    world.answer = 404
    await world.tick()
    world.reason = "the gateway's phase cannot be read"
    await world.tick(60)
    world.reason, world.answer = None, 200
    await world.tick(60)
    logged = "\n".join(str(record.__dict__) for record in caplog.records)
    assert "deadman_ping_failed" in logged
    assert "deadman_withheld" in logged
    assert "CANARY" not in logged
    assert "CANARY" not in repr(world.pinger.snapshot())


def test_only_alerts_that_ask_a_person_to_act_withhold_the_ping() -> None:
    active = Evaluation(Condition.ACTIVE)
    evaluations = {
        AlertClass.DISK_LOW: active,  # a warning
        AlertClass.TWOFA_PENDING: active,  # critical
        AlertClass.GATEWAY_STOPPED: active,  # info: stopped on request, nobody needs to act
        AlertClass.CLOCK_SKEW: Evaluation(Condition.UNKNOWN),
        AlertClass.API_UNHEALTHY: Evaluation(Condition.INACTIVE),
    }
    assert alerting_classes(evaluations, frozenset()) == (
        AlertClass.TWOFA_PENDING,
        AlertClass.DISK_LOW,
    )
    assert alerting_classes(evaluations, frozenset({"twofa_pending"})) == (AlertClass.DISK_LOW,)
    assert alerting_classes({}, frozenset()) == ()
