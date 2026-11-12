"""Shared, deterministic test helpers: a hand-driven clock and a recording sleep.

Nothing in the suite sleeps or reads the wall clock: components take a ``Clock`` and a
``Sleep`` and the tests drive both by hand.
"""

from __future__ import annotations

import asyncio
import os
import socket
import time
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

from brokersre_sidecar.model import GatewayEvent, GatewaySnapshot, MetricsSample
from brokersre_sidecar.model.health import ProbeSnapshot
from brokersre_sidecar.vocab import ProbeStatus

T0 = datetime(2026, 11, 12, 15, 0, 0, tzinfo=UTC)
"""Default start instant: a Thursday, 10:00 in New York, outside every IBKR reset window."""


class FakeClock:
    """A clock that moves only when a test says so.

    ``now()`` (aware UTC) and ``monotonic()`` advance together through ``advance``; ``set``
    jumps the wall clock alone, which is how a test models a wall-clock step.
    """

    def __init__(self, start: datetime = T0) -> None:
        self._now = start
        self._mono = 1000.0

    def now(self) -> datetime:
        """Return the current fake wall-clock instant (aware, UTC)."""
        return self._now

    def monotonic(self) -> float:
        """Return the current fake monotonic reading in seconds."""
        return self._mono

    def advance(self, seconds: float) -> None:
        """Move both clocks forward by ``seconds``."""
        self._now += timedelta(seconds=seconds)
        self._mono += seconds

    def set(self, instant: datetime) -> None:
        """Jump the wall clock to ``instant`` without touching the monotonic clock."""
        self._now = instant


class RecordingSleep:
    """An awaitable ``sleep`` replacement that takes no real time and advances a ``FakeClock``.

    ``calls`` lists every requested delay, so a test can assert on back-off schedules. It
    yields to the event loop once, as a real sleep does, so a retry loop under test cannot
    starve the other tasks of the test.
    """

    def __init__(self, clock: FakeClock | None = None) -> None:
        self.calls: list[float] = []
        self._clock = clock

    async def __call__(self, seconds: float) -> None:
        """Record the delay, advance the fake clock by it and yield once."""
        self.calls.append(seconds)
        if self._clock is not None:
            self._clock.advance(seconds)
        await asyncio.sleep(0)


def iso(instant: datetime) -> str:
    """Render ``instant`` the way the gateway writes timestamps (UTC, milliseconds, ``Z``)."""
    return (
        instant.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%S.")
        + f"{instant.microsecond // 1000:03d}Z"
    )


def gateway_snapshot(now: datetime = T0, **overrides: Any) -> GatewaySnapshot:
    """Build a ``GatewaySnapshot`` of a healthy, logged-in gateway; override any field."""
    fields: dict[str, Any] = {
        "taken_at": now,
        "phase": "logged-in",
        "phase_since": now - timedelta(hours=1),
        "boot_id": "00000000000000aa",
        "boots_30m": 0,
        "last_login": now - timedelta(hours=1),
        "last_events": {},
        "last_metrics": None,
        "last_event_at": now - timedelta(seconds=20),
        "last_activity_at": now - timedelta(seconds=20),
        "feeds_seen": True,
        "memory_ratio": 0.5,
        "memory_high_since": None,
        "last_oom_at": None,
        "rejected_lines": 0,
    }
    fields.update(overrides)
    return GatewaySnapshot(**fields)


def probe_snapshot(now: datetime = T0, **overrides: Any) -> ProbeSnapshot:
    """Build a ``ProbeSnapshot`` of a ready API; override any field."""
    fields: dict[str, Any] = {
        "status": ProbeStatus.READY,
        "reason": "time round trip ok, connectivity up, no farm broken",
        "status_since": now - timedelta(hours=1),
        "connectivity": "ok",
        "farms": (),
        "last_probe_at": now - timedelta(seconds=30),
        "last_probe_ok": True,
        "last_rtt_s": 0.05,
        "last_error": None,
        "consecutive_failures": 0,
        "clock_skew_s": -0.4,
        "close_wait_sockets": 0,
        "zombie": False,
        "in_reset_window": False,
    }
    fields.update(overrides)
    return ProbeSnapshot(**fields)


def gateway_event(name: str, at: datetime) -> GatewayEvent:
    """Build a ``GatewayEvent`` as the parser would produce it."""
    return GatewayEvent(
        ts=at, event=name, src="ibc", level="info", boot_id="00000000000000aa", seq=1
    )


def metrics_sample(at: datetime, **values: float) -> MetricsSample:
    """Build a ``MetricsSample`` with the given measured values."""
    return MetricsSample(ts=at, boot_id="00000000000000aa", seq=1, phase="logged-in", values=values)


def free_port() -> int:
    """Return a TCP port that was free on 127.0.0.1 a moment ago."""
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port: int = probe.getsockname()[1]
        return port


async def http_get(port: int, path: str) -> tuple[int, dict[str, str], bytes]:
    """GET ``path`` from 127.0.0.1:``port`` and return status, lower-cased headers and body."""
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    try:
        writer.write(f"GET {path} HTTP/1.1\r\nHost: localhost\r\n\r\n".encode())
        await writer.drain()
        raw = await asyncio.wait_for(reader.read(), 5)
    finally:
        writer.close()
    head, _, body = raw.partition(b"\r\n\r\n")
    lines = head.decode("ascii").split("\r\n")
    headers = {
        name.lower(): value.strip() for name, value in (line.split(":", 1) for line in lines[1:])
    }
    return int(lines[0].split(" ")[1]), headers, body


async def until(condition: Callable[[], bool], timeout_s: float = 5.0) -> None:
    """Wait (yielding to the loop) until ``condition`` holds; fail after ``timeout_s``."""
    async with asyncio.timeout(timeout_s):
        # Polling is the point here: the condition is arbitrary test state, not an event.
        while not condition():  # noqa: ASYNC110
            await asyncio.sleep(0.005)


def replace_file(source: Path, target: Path) -> None:
    """Rename ``source`` over ``target``, retrying the Windows-only "access denied".

    On Windows a rename is refused while any process (a reader thread of the code under
    test, the antivirus, the indexer) has either file open. On Linux a rename never fails
    for that reason, so the retry only ever runs on a Windows development host.
    """
    for _ in range(400):
        try:
            os.replace(source, target)
            return
        except PermissionError:
            time.sleep(0.005)
    raise AssertionError(f"could not rename {source.name} to {target.name}")
