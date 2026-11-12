"""CLOSE_WAIT counting from /proc and the IBKR reset-window table."""

from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

from brokersre_sidecar.probe import (
    NamespaceWatch,
    active_reset_window,
    count_close_wait,
    count_foreign_listeners,
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
    ("instant", "expected"),
    [
        (at("America/New_York", 2026, 11, 12, 0, 14), None),
        (at("America/New_York", 2026, 11, 12, 0, 15), "north_america"),
        (at("America/New_York", 2026, 11, 12, 1, 44), "north_america"),
        (at("America/New_York", 2026, 11, 12, 1, 45), None),
        (at("America/New_York", 2026, 7, 15, 0, 30), "north_america"),  # daylight time
        # Europe 06:25-07:45 is the same instant as 00:25-01:45 ET for most of the year, so
        # the North America window names it; the two differ only while the US and the EU
        # disagree about daylight time (here: mid-March).
        (at("Europe/Zurich", 2026, 11, 12, 6, 25), "north_america"),
        (at("Europe/Zurich", 2026, 11, 12, 7, 45), None),
        (at("Europe/Zurich", 2026, 3, 16, 6, 24), "north_america"),
        (at("Europe/Zurich", 2026, 3, 16, 7, 40), "europe"),
        (at("Europe/Zurich", 2026, 3, 16, 7, 45), None),
        (at("Asia/Hong_Kong", 2026, 11, 12, 4, 45), "asia"),
        (at("Asia/Hong_Kong", 2026, 11, 12, 6, 5), None),
        (at("Asia/Hong_Kong", 2026, 11, 12, 20, 15), "asia"),
        (at("Asia/Hong_Kong", 2026, 11, 12, 21, 14), "asia"),
        (at("Asia/Hong_Kong", 2026, 11, 12, 21, 15), None),
        (at("America/New_York", 2026, 11, 14, 0, 5), "saturday"),  # a Saturday
        (at("America/New_York", 2026, 11, 14, 1, 50), "saturday"),
        (at("America/New_York", 2026, 11, 14, 2, 0), None),
        (at("America/New_York", 2026, 11, 13, 0, 5), None),  # a Friday
        (at("America/New_York", 2026, 11, 12, 10, 0), None),
    ],
)
def test_reset_windows_follow_the_local_time_of_each_region(
    instant: datetime, expected: str | None
) -> None:
    assert active_reset_window(instant) == expected


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
        self.watch = NamespaceWatch(self.clock, listeners=lambda: self.listeners, grace_s=60.0)

    def observe(self, seconds: float, *, alive: bool = True) -> bool:
        """Observe once per second for ``seconds``; return the last verdict."""
        orphaned = False
        for _ in range(int(seconds)):
            orphaned = self.watch.observe(gateway_alive=alive)
            self.clock.advance(1.0)
        return orphaned


def test_a_namespace_that_never_had_a_foreign_listener_is_never_called_orphaned() -> None:
    # A sidecar that does not share the gateway's network namespace at all.
    assert WatchHarness().observe(600) is False


def test_listeners_that_vanish_while_the_gateway_is_alive_mean_the_namespace_is_orphaned() -> None:
    h = WatchHarness()
    h.listeners = 2
    assert h.observe(30) is False
    h.listeners = 0  # the gateway container restarted into a new namespace
    assert h.observe(59) is False
    assert h.observe(3) is True


def test_a_stopped_gateway_or_a_short_gap_is_not_an_orphan() -> None:
    h = WatchHarness()
    h.listeners = 1
    h.observe(5)
    h.listeners = 0
    assert h.observe(600, alive=False) is False  # the gateway is down: nothing to rejoin
    assert h.observe(30) is False
    h.listeners = 1  # listeners came back before the grace period ended
    assert h.observe(5) is False
    h.listeners = 0
    assert h.observe(59) is False


def test_an_unreadable_proc_never_triggers() -> None:
    h = WatchHarness()
    h.listeners = 1
    h.observe(5)
    h.listeners = None
    assert h.observe(600) is False
