"""The feed that carries the gateway's files into the in-memory model."""

from __future__ import annotations

import json
from pathlib import Path

from brokersre_sidecar.model import GatewayFeed, GatewayState
from testkit import T0, FakeClock, iso


def write_volume(root: Path) -> None:
    (root / "state").mkdir(parents=True)
    (root / "events").mkdir()
    (root / "metrics").mkdir()
    (root / "state" / "phase").write_bytes(b"logged-in\n")
    events = [
        {"ts": iso(T0), "src": "ibc", "level": "info", "event": "login_completed", "msg": "x"},
        "this line is not json",
        {"ts": iso(T0), "src": "ibc", "level": "info", "event": "Bad Name", "msg": "x"},
    ]
    (root / "events" / "events.jsonl").write_text(
        "".join((line if isinstance(line, str) else json.dumps(line)) + "\n" for line in events),
        encoding="utf-8",
        newline="\n",
    )
    (root / "metrics" / "metrics.jsonl").write_text(
        json.dumps({"ts": iso(T0), "src": "metrics", "pids": 41}) + "\n",
        encoding="utf-8",
        newline="\n",
    )


def test_one_poll_loads_phase_events_and_metrics_and_counts_rejected_lines(tmp_path: Path) -> None:
    write_volume(tmp_path)
    state = GatewayState(FakeClock())
    feed = GatewayFeed(tmp_path, state)
    feed.poll()
    snapshot = state.snapshot()
    assert snapshot.phase == "logged-in"
    assert snapshot.last_login == T0
    assert snapshot.last_metrics is not None
    assert snapshot.last_metrics.values["pids"] == 41.0
    assert snapshot.rejected_lines == 2
    assert feed.volume_present is True


def test_an_empty_or_missing_volume_is_tolerated_and_reported(tmp_path: Path) -> None:
    state = GatewayState(FakeClock())
    feed = GatewayFeed(tmp_path / "not-mounted", state)
    feed.poll()
    assert feed.volume_present is False
    assert state.snapshot().phase is None
    empty = GatewayFeed(tmp_path, state)
    empty.poll()
    assert empty.volume_present is True
    assert state.snapshot().feeds_seen is False


def test_files_that_appear_later_are_picked_up(tmp_path: Path) -> None:
    state = GatewayState(FakeClock())
    feed = GatewayFeed(tmp_path, state)
    feed.poll()
    write_volume(tmp_path)
    feed.poll()
    assert state.snapshot().phase == "logged-in"
    assert state.snapshot().feeds_seen is True
