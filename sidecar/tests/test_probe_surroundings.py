"""CLOSE_WAIT counting from /proc and the IBKR reset-window table."""

from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

from brokersre_sidecar.probe import active_reset_window, count_close_wait

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
