"""Time sources and UTC timestamp helpers (leaf module: imports nothing from the package).

Every component takes a ``Clock`` and, where it waits, a ``Sleep``; production wires
``SystemClock`` and ``asyncio.sleep``, tests wire hand-driven fakes. All instants inside the
sidecar are timezone-aware UTC; a local zone is applied only when a message is rendered.
"""

from __future__ import annotations

import time
from collections.abc import Awaitable, Callable
from datetime import UTC, datetime
from typing import Protocol

Sleep = Callable[[float], Awaitable[None]]
"""Awaitable delay in seconds (``asyncio.sleep`` in production)."""


class Clock(Protocol):
    """Source of wall-clock and monotonic time.

    Contract: ``now()`` returns an aware UTC datetime and may jump (NTP step); ``monotonic()``
    never goes backwards and is the only reading used to measure durations and deadlines.
    """

    def now(self) -> datetime:
        """Return the current instant as an aware UTC datetime."""
        ...

    def monotonic(self) -> float:
        """Return a monotonic reading in seconds with an arbitrary origin."""
        ...


class SystemClock:
    """The real clock: ``datetime.now(UTC)`` and ``time.monotonic()``."""

    def now(self) -> datetime:
        """Return the current instant as an aware UTC datetime."""
        return datetime.now(UTC)

    def monotonic(self) -> float:
        """Return ``time.monotonic()``."""
        return time.monotonic()


def format_utc(instant: datetime) -> str:
    """Render an aware datetime as ``YYYY-MM-DDTHH:MM:SS.mmmZ`` (the gateway's log format).

    Args:
        instant: Aware datetime in any zone; converted to UTC.

    Returns:
        ISO-8601 text with millisecond precision and a ``Z`` suffix.
    """
    utc = instant.astimezone(UTC)
    return utc.strftime("%Y-%m-%dT%H:%M:%S.") + f"{utc.microsecond // 1000:03d}Z"


def parse_utc(value: object) -> datetime | None:
    """Parse a timestamp written by the gateway into an aware UTC datetime.

    Accepts ISO-8601 with a ``Z`` suffix or an explicit offset. A naive timestamp is refused
    (returns ``None``) rather than guessed: every timestamp in the log contract is UTC and
    says so.

    Args:
        value: Anything read from a JSON line; non-strings yield ``None``.

    Returns:
        The instant in UTC, or ``None`` when the value is not a zone-qualified ISO timestamp.
    """
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(UTC)
