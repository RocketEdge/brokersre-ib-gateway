"""The feed that carries the gateway's files into the in-memory model."""

from __future__ import annotations

import json
import shutil
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


def test_the_real_gateway_output_is_read_without_a_rejected_line(tmp_path: Path) -> None:
    """Fixture: files written by the real gateway image (log contract v2), one short boot."""
    fixtures = Path(__file__).parent / "fixtures"
    for name in ("state", "events", "metrics"):
        (tmp_path / name).mkdir()
    (tmp_path / "state" / "phase").write_bytes(b"stopped\n")
    shutil.copy(fixtures / "real-events.jsonl", tmp_path / "events" / "events.jsonl")
    shutil.copy(fixtures / "real-metrics.jsonl", tmp_path / "metrics" / "metrics.jsonl")
    state = GatewayState(FakeClock())
    GatewayFeed(tmp_path, state).poll()
    snapshot = state.snapshot()
    assert snapshot.rejected_lines == 0
    assert snapshot.volume_present is True
    assert snapshot.phase == "stopped"
    assert snapshot.boot_id == "443d261aecbd4789"
    assert snapshot.boots_30m is not None
    # Events with a "data" object (container_start, config_rendered) are accepted.
    assert {"container_start", "config_rendered", "doctor_ok", "shutdown_complete"} <= set(
        snapshot.last_events
    )
    assert snapshot.last_events["shutdown_requested"].boot_id == "443d261aecbd4789"
    # The last sample is the one written at shutdown: no disk keys, no JVM keys.
    assert snapshot.last_metrics is not None
    assert snapshot.last_metrics.phase == "stopping"
    assert snapshot.last_metrics.values["api_close_wait_sockets"] == 0.0
    assert "disk_free_bytes_logs" not in snapshot.last_metrics.values
    assert "java_rss_bytes" not in snapshot.last_metrics.values
    assert dict(snapshot.pairs) == {}
