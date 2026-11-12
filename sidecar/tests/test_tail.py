"""Following the gateway's append-only files and its phase file."""

from __future__ import annotations

import os
import tempfile
from datetime import UTC, datetime
from pathlib import Path

from hypothesis import given, settings
from hypothesis import strategies as st

from brokersre_sidecar.tail import LineFollower, read_phase


def append(path: Path, data: bytes) -> None:
    with open(path, "ab") as handle:
        handle.write(data)


def rotate(path: Path) -> None:
    """Rotate like the gateway does: rename to ``.1``, then start a new file."""
    os.replace(path, path.with_name(path.name + ".1"))
    path.write_bytes(b"")


def test_a_missing_file_yields_nothing_until_it_appears(tmp_path: Path) -> None:
    follower = LineFollower(tmp_path / "events.jsonl")
    assert follower.poll() == []
    assert follower.seen is False
    append(tmp_path / "events.jsonl", b"one\n")
    assert follower.poll() == ["one"]
    assert follower.seen is True


def test_existing_content_is_read_from_the_start_and_then_only_new_lines(tmp_path: Path) -> None:
    path = tmp_path / "events.jsonl"
    append(path, b"one\ntwo\n")
    follower = LineFollower(path)
    assert follower.poll() == ["one", "two"]
    assert follower.poll() == []
    append(path, b"three\n")
    assert follower.poll() == ["three"]


def test_a_partial_last_line_is_held_back_until_its_newline_arrives(tmp_path: Path) -> None:
    path = tmp_path / "events.jsonl"
    append(path, b'{"a":1}\n{"b":')
    follower = LineFollower(path)
    assert follower.poll() == ['{"a":1}']
    append(path, b"2}\n")
    assert follower.poll() == ['{"b":2}']


def test_rotation_is_followed_by_inode_and_the_old_file_is_drained_first(tmp_path: Path) -> None:
    path = tmp_path / "events.jsonl"
    append(path, b"one\n")
    follower = LineFollower(path)
    assert follower.poll() == ["one"]
    append(path, b"two\n")
    rotate(path)
    append(path, b"three\n")
    assert follower.poll() == ["two", "three"]
    assert follower.stats.rotations == 1
    assert follower.stats.lost_rotations == 0


def test_a_rotation_seen_while_the_new_file_does_not_exist_yet_loses_nothing(
    tmp_path: Path,
) -> None:
    path = tmp_path / "events.jsonl"
    append(path, b"one\n")
    follower = LineFollower(path)
    assert follower.poll() == ["one"]
    append(path, b"two\n")
    os.replace(path, path.with_name("events.jsonl.1"))
    assert follower.poll() == []
    path.write_bytes(b"three\n")
    assert follower.poll() == ["two", "three"]


def test_two_rotations_between_polls_are_counted_as_lost(tmp_path: Path) -> None:
    path = tmp_path / "events.jsonl"
    append(path, b"one\n")
    follower = LineFollower(path)
    follower.poll()
    append(path, b"lost\n")
    rotate(path)
    append(path, b"kept in .1 but skipped\n")
    rotate(path)
    append(path, b"current\n")
    assert follower.poll() == ["current"]
    # A file system that hands the freed inode number to the new file makes this look like
    # a rewrite in place; either way the follower restarts on the current file.
    assert follower.stats.lost_rotations + follower.stats.truncations == 1


def test_truncation_in_place_restarts_from_the_beginning(tmp_path: Path) -> None:
    path = tmp_path / "metrics.jsonl"
    append(path, b"one\ntwo\npartial")
    follower = LineFollower(path)
    assert follower.poll() == ["one", "two"]
    with open(path, "r+b") as handle:
        handle.truncate(0)
    append(path, b"new\n")
    assert follower.poll() == ["new"]
    assert follower.stats.truncations == 1


def test_an_oversized_line_is_dropped_and_the_next_line_survives(tmp_path: Path) -> None:
    path = tmp_path / "events.jsonl"
    follower = LineFollower(path, max_line_bytes=16)
    append(path, b"x" * 100)
    assert follower.poll() == []
    append(path, b"x" * 100 + b"\nok\n")
    assert follower.poll() == ["ok"]
    assert follower.stats.dropped_lines == 1


def test_bytes_that_are_not_utf8_and_crlf_endings_do_not_break_the_follower(
    tmp_path: Path,
) -> None:
    path = tmp_path / "events.jsonl"
    append(path, b"caf\xff\r\n\r\n\nnext\r\n")
    assert LineFollower(path).poll() == ["caf�", "next"]


def test_a_large_existing_file_is_entered_near_its_end_on_a_line_boundary(tmp_path: Path) -> None:
    path = tmp_path / "events.jsonl"
    append(path, b"".join(b"line-%04d\n" % number for number in range(1000)))
    follower = LineFollower(path, initial_tail_bytes=35)
    assert follower.poll() == ["line-0997", "line-0998", "line-0999"]


def test_the_rotated_predecessor_is_replayed_once_at_first_sight(tmp_path: Path) -> None:
    path = tmp_path / "events.jsonl"
    append(path, b"old-1\nold-2\n")
    rotate(path)
    append(path, b"new-1\n")
    follower = LineFollower(path, replay_rotated=True)
    assert follower.poll() == ["old-1", "old-2", "new-1"]
    assert follower.poll() == []


def test_one_poll_reads_a_bounded_amount_and_the_next_continues(tmp_path: Path) -> None:
    path = tmp_path / "events.jsonl"
    append(path, b"aaaa\nbbbb\ncccc\n")
    follower = LineFollower(path, max_read_bytes=6)
    assert follower.poll() == ["aaaa"]
    assert follower.poll() == ["bbbb"]
    assert follower.poll() == ["cccc"]


OPERATIONS = st.lists(
    st.one_of(
        st.tuples(st.just("append"), st.text(alphabet="ab\n", min_size=1, max_size=12)),
        st.tuples(st.just("rotate"), st.just("")),
        st.tuples(st.just("truncate"), st.just("")),
        st.tuples(st.just("poll"), st.just("")),
    ),
    max_size=40,
)


@settings(max_examples=60, deadline=None)
@given(operations=OPERATIONS)
def test_every_complete_line_is_delivered_exactly_once_and_in_order(
    operations: list[tuple[str, str]],
) -> None:
    """Model check: appends, single rotations and polled truncations never lose or repeat a line."""
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "events.jsonl"
        # replay_rotated: a rotation before the first poll must not hide what was written.
        follower = LineFollower(path, replay_rotated=True)
        expected: list[str] = []
        delivered: list[str] = []
        pending = ""
        rotated_since_poll = False
        for operation, text in operations:
            if operation == "append":
                append(path, text.encode())
                for character in text:
                    if character == "\n":
                        if pending:
                            expected.append(pending)
                        pending = ""
                    else:
                        pending += character
            elif operation == "rotate":
                if not path.exists():
                    continue
                if rotated_since_poll:
                    delivered += follower.poll()
                rotate(path)
                rotated_since_poll = True
                if pending:
                    expected.append(pending)
                pending = ""
            elif operation == "truncate":
                if not path.exists():
                    continue
                delivered += follower.poll()
                rotated_since_poll = False
                with open(path, "r+b") as handle:
                    handle.truncate(0)
                pending = ""
                delivered += follower.poll()
            else:
                delivered += follower.poll()
                rotated_since_poll = False
        delivered += follower.poll()
        assert delivered == expected


# --- phase file ---------------------------------------------------------------------------


def test_the_phase_file_yields_its_token_and_modification_time(tmp_path: Path) -> None:
    path = tmp_path / "phase"
    path.write_bytes(b"logged-in\n")
    os.utime(path, (1_800_000_000, 1_800_000_000))
    reading = read_phase(path)
    assert reading is not None
    assert reading.token == "logged-in"
    assert reading.known is True
    assert reading.modified == datetime.fromtimestamp(1_800_000_000, UTC)


def test_a_missing_phase_file_is_none(tmp_path: Path) -> None:
    assert read_phase(tmp_path / "phase") is None


def test_an_unknown_empty_or_oversized_token_is_unknown_never_healthy(tmp_path: Path) -> None:
    path = tmp_path / "phase"
    for content in (b"CANARY_USER-is-typing\n", b"", b"\n", b"logged-in " * 50, b"\xff\xfe"):
        path.write_bytes(content)
        reading = read_phase(path)
        assert reading is not None
        assert reading.token == "unknown"
        assert reading.known is False


def test_windows_line_endings_and_padding_are_tolerated(tmp_path: Path) -> None:
    path = tmp_path / "phase"
    path.write_bytes(b"  2fa-pending\r\n")
    reading = read_phase(path)
    assert reading is not None
    assert reading.token == "2fa-pending"
