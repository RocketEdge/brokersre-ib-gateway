"""IBKR's scheduled server resets, during which a lost IBKR link is normal.

Source: IBKR's system status page, section "Server Reset Times",
https://brokerage.ibkr.com/en/software/systemStatus.php (the same table is served by IBKR's
regional sites, for example https://www.interactivebrokers.com.hk/en/software/systemStatus.php),
checked on 2026-11-12:

================  ==========================================================
region            reset window
================  ==========================================================
North America     daily (Sunday to Friday) 00:15 ET - 01:45 ET
Europe            daily (Sunday to Friday) 06:25 CET - 07:45 CET
APAC              daily (Sunday to Friday), first reset 04:45 HKT - 06:05 HKT,
                  second reset 20:15 HKT - 21:15 HKT (*)
every region      Saturday 00:00 ET - 02:00 ET
================  ==========================================================

(*) The page's footnote: "APAC reset time in Hong Kong Time (HKT) is one hour later when
Daylight Savings Time (DST) in North America is not in effect." Hong Kong has no daylight
saving time, so the two windows are fixed in New York time: 16:45 - 18:05 ET and
08:15 - 09:15 ET. They are stored that way. Storing the Hong Kong times as published would be
wrong for the months of North American standard time, and wrong in the worst direction:
04:45 HKT is then 15:45 in New York, a window that would cover the US close.

Each window is evaluated in the local time of its zone with ``zoneinfo``, so daylight-saving
changes are followed. The daily windows are applied on every day of the week: the page does
not say in which zone "Sunday to Friday" is counted, and the extra hours fall on a weekend.

Which region serves an account is not visible to the sidecar, so the operator names it
(``IBKR_REGION``). The default is ``none``: no window, nothing is ever excused. An alert that
IBKR's schedule would have explained is better than silence when it matters.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, time
from zoneinfo import ZoneInfo

_SATURDAY = 5

REGIONS: tuple[str, ...] = ("america", "europe", "asia", "none")
"""Accepted values of ``IBKR_REGION``."""


@dataclass(frozen=True, slots=True)
class ResetWindow:
    """One recurring window: ``[start, end)`` in the local time of ``zone``.

    Attributes:
        name: Label of the window (several windows may share one).
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


_WEEKLY = ResetWindow("saturday", "America/New_York", time(0, 0), time(2, 0), weekday=_SATURDAY)

RESET_WINDOWS: dict[str, tuple[ResetWindow, ...]] = {
    "america": (
        _WEEKLY,
        ResetWindow("north_america", "America/New_York", time(0, 15), time(1, 45)),
    ),
    "europe": (
        _WEEKLY,
        # "CET" in IBKR's table is Central European local time; Zug, Switzerland hosts it.
        ResetWindow("europe", "Europe/Zurich", time(6, 25), time(7, 45)),
    ),
    "asia": (
        _WEEKLY,
        # Published in Hong Kong time with a daylight-saving footnote; fixed in New York time.
        ResetWindow("asia", "America/New_York", time(16, 45), time(18, 5)),
        ResetWindow("asia", "America/New_York", time(8, 15), time(9, 15)),
    ),
    "none": (),
}
"""The windows of each region; the weekly window applies to every region but ``none``."""


def active_reset_window(instant: datetime, region: str) -> str | None:
    """Return the name of the reset window of ``region`` that contains ``instant``.

    Args:
        instant: An aware datetime in any zone.
        region: One of ``REGIONS``. An unknown value has no window (nothing is excused).

    Returns:
        ``saturday``, ``north_america``, ``europe`` or ``asia``; None outside the region's
        windows, and always None for ``none``. The weekly window wins over a daily one.
    """
    for window in RESET_WINDOWS.get(region, ()):
        local = instant.astimezone(ZoneInfo(window.zone))
        if window.weekday is not None and local.weekday() != window.weekday:
            continue
        if window.start <= local.time() < window.end:
            return window.name
    return None
