"""CLOSE_WAIT counting from /proc and the IBKR reset-window table."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

from brokersre_sidecar.probe import (
    NamespaceWatch,
    active_reset_window,
    count_close_wait,
    count_foreign_listeners,
    farm_name,
)
from testkit import FakeClock

HEADER4 = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
HEADER6 = "  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"


def row4(local: str, remote: str, state: str) -> str:
    return f"   0: {local} {remote} {state} 00000000:00000000 00:00000000 00000000  1000        0 12345 1 0000000000000000 100 0 0 10 0\n"


def proc(tmp_path: Path, tcp: str | None, tcp6: str | None) -> Path:
    net = tmp_path / "net"
    net.mkdir()
    if tcp is not None:
        (net / "tcp").write_text(tcp, encoding="ascii")
    if tcp6 is not None:
        (net / "tcp6").write_text(tcp6, encoding="ascii")
    return tmp_path


def test_close_wait_sockets_on_the_api_port_are_counted_in_both_families(tmp_path: Path) -> None:
    # 4002 is 0x0FA2; state 08 is CLOSE_WAIT, 01 ESTABLISHED, 0A LISTEN.
    tcp = HEADER4 + "".join(
        [
            row4("0100007F:0FA2", "00000000:0000", "0A"),
            row4("0100007F:0FA2", "0100007F:C001", "08"),
            row4("0100007F:0FA2", "0100007F:C002", "08"),
            row4("0100007F:0FA2", "0100007F:C003", "01"),
            row4("0100007F:1D26", "0100007F:C004", "08"),  # another port
            row4("0100007F:C005", "0100007F:0FA2", "08"),  # the client side of a connection
        ]
    )
    tcp6 = HEADER6 + row4(
        "00000000000000000000000001000000:0FA2", "00000000000000000000000001000000:C006", "08"
    )
    assert count_close_wait(4002, proc(tmp_path, tcp, tcp6)) == 3


def test_no_socket_in_close_wait_is_zero_not_unmeasured(tmp_path: Path) -> None:
    assert count_close_wait(4002, proc(tmp_path, HEADER4, None)) == 0


def test_without_proc_net_the_count_is_not_measured(tmp_path: Path) -> None:
    assert count_close_wait(4002, tmp_path / "no-proc") is None


def test_malformed_rows_are_skipped(tmp_path: Path) -> None:
    tcp = HEADER4 + "garbage\n\n   1: nonsense\n" + row4("0100007F:0FA2", "0100007F:C001", "08")
    assert count_close_wait(4002, proc(tmp_path, tcp, None)) == 1


def at(zone: str, year: int, month: int, day: int, hour: int, minute: int) -> datetime:
    return datetime(year, month, day, hour, minute, tzinfo=ZoneInfo(zone)).astimezone(UTC)


@pytest.mark.parametrize(
    ("region", "instant", "expected"),
    [
        ("america", at("America/New_York", 2026, 11, 12, 0, 14), None),
        ("america", at("America/New_York", 2026, 11, 12, 0, 15), "north_america"),
        ("america", at("America/New_York", 2026, 11, 12, 1, 44), "north_america"),
        ("america", at("America/New_York", 2026, 11, 12, 1, 45), None),
        ("america", at("America/New_York", 2026, 7, 15, 0, 30), "north_america"),  # daylight time
        # Another region's window never counts for the chosen one.
        ("america", at("Europe/Zurich", 2026, 3, 16, 7, 40), None),
        ("america", at("Asia/Hong_Kong", 2026, 7, 15, 5, 0), None),
        ("europe", at("Europe/Zurich", 2026, 11, 12, 6, 24), None),
        ("europe", at("Europe/Zurich", 2026, 11, 12, 6, 25), "europe"),
        ("europe", at("Europe/Zurich", 2026, 7, 15, 7, 44), "europe"),
        ("europe", at("Europe/Zurich", 2026, 11, 12, 7, 45), None),
        # Mid-March the US is on daylight time and Europe is not: 00:20 in New York is
        # 05:20 in Zurich, outside the Europe window.
        ("europe", at("America/New_York", 2026, 3, 16, 0, 20), None),
        # Asia: the published Hong Kong times hold while North America is on daylight time...
        ("asia", at("Asia/Hong_Kong", 2026, 7, 15, 4, 44), None),
        ("asia", at("Asia/Hong_Kong", 2026, 7, 15, 4, 45), "asia"),
        ("asia", at("Asia/Hong_Kong", 2026, 7, 15, 6, 5), None),
        ("asia", at("Asia/Hong_Kong", 2026, 7, 15, 20, 15), "asia"),
        ("asia", at("Asia/Hong_Kong", 2026, 7, 15, 21, 15), None),
        # ...and are one hour later while it is not (the footnote on IBKR's page).
        ("asia", at("Asia/Hong_Kong", 2026, 11, 12, 4, 45), None),
        ("asia", at("Asia/Hong_Kong", 2026, 11, 12, 5, 45), "asia"),
        ("asia", at("Asia/Hong_Kong", 2026, 11, 12, 7, 4), "asia"),
        ("asia", at("Asia/Hong_Kong", 2026, 11, 12, 7, 5), None),
        ("asia", at("Asia/Hong_Kong", 2026, 11, 12, 20, 15), None),
        ("asia", at("Asia/Hong_Kong", 2026, 11, 12, 21, 15), "asia"),
        ("asia", at("Asia/Hong_Kong", 2026, 11, 12, 22, 15), None),
        # The weekly window applies to every region.
        ("america", at("America/New_York", 2026, 11, 14, 0, 5), "saturday"),  # a Saturday
        ("europe", at("America/New_York", 2026, 11, 14, 1, 50), "saturday"),
        ("asia", at("America/New_York", 2026, 11, 14, 0, 0), "saturday"),
        ("asia", at("America/New_York", 2026, 11, 14, 2, 0), None),
        ("america", at("America/New_York", 2026, 11, 13, 0, 5), None),  # a Friday
        # No region: no window at all, not even the weekly one.
        ("none", at("America/New_York", 2026, 11, 12, 0, 30), None),
        ("none", at("America/New_York", 2026, 11, 14, 0, 30), None),
        ("mars", at("America/New_York", 2026, 11, 12, 0, 30), None),
    ],
)
def test_reset_windows_follow_the_chosen_region(
    region: str, instant: datetime, expected: str | None
) -> None:
    assert active_reset_window(instant, region) == expected


@pytest.mark.parametrize("region", ["america", "europe", "asia", "none"])
@pytest.mark.parametrize("month", [1, 7])
def test_no_region_has_a_window_over_the_us_close(region: str, month: int) -> None:
    # The reviewer's finding: with fixed Hong Kong times the Asia window covered
    # 15:45-17:05 New York time in winter, the close included.
    for minute in range(0, 60, 5):
        closing = at("America/New_York", 2026, month, 14, 15, 30) + timedelta(minutes=minute)
        assert active_reset_window(closing, region) is None, closing


def test_listeners_other_than_the_sidecars_own_port_are_counted(tmp_path: Path) -> None:
    # 9810 is 0x2652 (the sidecar itself); 4004 is 0x0FA4 and 7462 is 0x1D26 (the gateway).
    tcp = HEADER4 + "".join(
        [
            row4("00000000:2652", "00000000:0000", "0A"),
            row4("00000000:0FA4", "00000000:0000", "0A"),
            row4("0100007F:1D26", "00000000:0000", "0A"),
            row4("0100007F:0FA4", "0100007F:C001", "01"),  # an established connection
        ]
    )
    assert count_foreign_listeners(9810, proc(tmp_path, tcp, HEADER6)) == 2


def test_only_the_own_listener_is_zero_and_no_proc_is_not_measured(tmp_path: Path) -> None:
    own = HEADER4 + row4("00000000:2652", "00000000:0000", "0A")
    assert count_foreign_listeners(9810, proc(tmp_path, own, None)) == 0
    assert count_foreign_listeners(9810, tmp_path / "no-proc") is None


class WatchHarness:
    def __init__(self) -> None:
        self.clock = FakeClock()
        self.listeners: int | None = 0
        self.boot: str | None = "00000000000000aa"
        self.watch = NamespaceWatch(self.clock, listeners=lambda: self.listeners, grace_s=60.0)

    def observe(self, seconds: float, *, alive: bool = True) -> bool:
        """Observe once per second for ``seconds``; return the last verdict."""
        orphaned = False
        for _ in range(int(seconds)):
            orphaned = self.watch.observe(gateway_alive=alive, boot_id=self.boot)
            self.clock.advance(1.0)
        return orphaned


def test_a_namespace_that_never_had_a_foreign_listener_is_never_called_orphaned() -> None:
    # A sidecar that does not share the gateway's network namespace at all.
    h = WatchHarness()
    assert h.observe(300) is False
    h.boot = "00000000000000bb"
    assert h.observe(300) is False
    assert h.watch.suspect is False


def test_listeners_gone_after_a_gateway_restart_mean_the_namespace_is_orphaned() -> None:
    h = WatchHarness()
    h.listeners = 2
    assert h.observe(30) is False
    # The gateway container restarted into a new namespace: a new boot id on the volume,
    # and nothing listening here any more.
    h.listeners = 0
    h.boot = "00000000000000bb"
    assert h.observe(59) is False
    assert h.watch.suspect is True
    assert h.observe(3) is True


def test_listeners_gone_without_a_gateway_restart_are_not_an_orphan() -> None:
    # needs-human with the command server off: the gateway listens on nothing, by design.
    h = WatchHarness()
    h.listeners = 2
    h.observe(30)
    h.listeners = 0
    assert h.observe(600) is False
    assert h.watch.suspect is False
    h.boot = None  # a gateway that writes no boot ids gives no evidence either
    assert h.observe(600) is False


def test_a_stopped_gateway_or_a_short_gap_is_not_an_orphan() -> None:
    h = WatchHarness()
    h.listeners = 1
    h.observe(5)
    h.listeners = 0
    h.boot = "00000000000000bb"
    assert h.observe(600, alive=False) is False  # the gateway is down: nothing to rejoin
    assert h.observe(30) is False
    h.listeners = 1  # listeners came back before the grace period ended
    assert h.observe(5) is False
    assert h.watch.suspect is False
    h.listeners = 0  # same boot as when they were last seen: no evidence
    assert h.observe(600) is False


def test_an_unreadable_proc_never_triggers() -> None:
    h = WatchHarness()
    h.listeners = 1
    h.observe(5)
    h.listeners = None
    h.boot = "00000000000000bb"
    assert h.observe(600) is False


@pytest.mark.parametrize(
    ("message", "expected"),
    [
        ("Market data farm connection is OK:usfarm", "usfarm"),
        ("Market data farm connection is OK:usfarm.nj", "usfarm.nj"),
        ("Market data farm connection is OK:USFARM", "usfarm"),
        ("Market data farm connection is OK:usfuture", "usfuture"),
        ("Market data farm connection is OK:usopt", "usopt"),
        ("HMDS data farm connection is OK:ushmds", "ushmds"),
        ("Sec-def data farm connection is OK:secdefnj", "secdefnj"),
        (
            "Market data farm connection is inactive but should be available upon demand.cashfarm",
            "cashfarm",
        ),
        # Anything that does not look like an IBKR farm name is not shown at all: the text
        # comes from the gateway, and a token such as a username is alphanumeric too.
        ("Market data farm connection is broken:jdoe123", "other"),
        ("Market data farm connection is broken:CANARYUSER", "other"),
        ("Market data farm connection is broken:DU1234567", "other"),
        ("Market data farm connection is broken:has space", "other"),
        ("Market data farm connection is broken:" + "farm" * 10, "other"),
        ("", "other"),
    ],
)
def test_a_farm_name_is_shown_only_when_it_looks_like_an_ibkr_farm(
    message: str, expected: str
) -> None:
    assert farm_name(message) == expected
