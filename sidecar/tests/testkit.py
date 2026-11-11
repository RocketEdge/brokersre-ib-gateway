"""Shared, deterministic test helpers: a hand-driven clock and a recording sleep.

Nothing in the suite sleeps or reads the wall clock: components take a ``Clock`` and a
``Sleep`` and the tests drive both by hand.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

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
    """An awaitable ``sleep`` replacement that returns at once and advances a ``FakeClock``.

    ``calls`` lists every requested delay, so a test can assert on back-off schedules.
    """

    def __init__(self, clock: FakeClock | None = None) -> None:
        self.calls: list[float] = []
        self._clock = clock

    async def __call__(self, seconds: float) -> None:
        """Record the delay and advance the fake clock by it."""
        self.calls.append(seconds)
        if self._clock is not None:
            self._clock.advance(seconds)


def iso(instant: datetime) -> str:
    """Render ``instant`` the way the gateway writes timestamps (UTC, milliseconds, ``Z``)."""
    return (
        instant.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%S.")
        + f"{instant.microsecond // 1000:03d}Z"
    )
