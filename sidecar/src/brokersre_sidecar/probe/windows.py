"""IBKR's daily reset windows, during which API disconnects are normal.

Source: the shared interface brief of this project (IBKR publishes the same table on its
system-status page): North America 00:15-01:45 ET, Europe 06:25-07:45 CET, Asia 04:45-06:05
and 20:15-21:15 HKT, and Saturday 00:00-02:00 ET. Each window is evaluated in the local time
of its region with ``zoneinfo``, so daylight-saving changes are followed. Which region
serves an account is not visible to the sidecar, so a time inside ANY window counts.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, time
from zoneinfo import ZoneInfo

_SATURDAY = 5


@dataclass(frozen=True, slots=True)
class ResetWindow:
    """One recurring window: ``[start, end)`` in the local time of ``zone``.

    Attributes:
        name: Region label reported in ``/status`` (several windows may share one).
        zone: IANA zone the window is defined in.
        start: Local start time (inclusive).
        end: Local end time (exclusive); always later than ``start`` on the same day.
        weekday: ``datetime.weekday()`` value the window is limited to, or None for daily.
    """

    name: str
    zone: str
    start: time
    end: time
    weekday: int | None = None


RESET_WINDOWS: tuple[ResetWindow, ...] = (
    ResetWindow("saturday", "America/New_York", time(0, 0), time(2, 0), weekday=_SATURDAY),
    ResetWindow("north_america", "America/New_York", time(0, 15), time(1, 45)),
    # "CET" in IBKR's table is Central European local time; Zug, Switzerland hosts it.
    ResetWindow("europe", "Europe/Zurich", time(6, 25), time(7, 45)),
    ResetWindow("asia", "Asia/Hong_Kong", time(4, 45), time(6, 5)),
    ResetWindow("asia", "Asia/Hong_Kong", time(20, 15), time(21, 15)),
)


def active_reset_window(instant: datetime) -> str | None:
    """Return the name of the reset window that contains ``instant``.

    Args:
        instant: An aware datetime in any zone.

    Returns:
        ``saturday``, ``north_america``, ``europe`` or ``asia``; None outside every window.
        The Saturday window wins over the daily North America window it overlaps.
    """
    for window in RESET_WINDOWS:
        local = instant.astimezone(ZoneInfo(window.zone))
        if window.weekday is not None and local.weekday() != window.weekday:
            continue
        if window.start <= local.time() < window.end:
            return window.name
    return None
