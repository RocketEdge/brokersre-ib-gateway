"""Parsing gateway lines and the in-memory model of the gateway."""

from __future__ import annotations

import json
from datetime import timedelta

import pytest

from brokersre_sidecar.model import GatewayState, parse_event, parse_metrics
from brokersre_sidecar.tail import PhaseReading
from testkit import T0, FakeClock, iso

BOOT_A = "00000000000000aa"
BOOT_B = "00000000000000bb"
BOOT_C = "00000000000000cc"


def event_line(name: str, at: object = T0, boot: str | None = BOOT_A, **extra: object) -> str:
    body: dict[str, object] = {
        "ts": iso(at) if not isinstance(at, str) else at,  # type: ignore[arg-type]
        "src": "ibc",
        "level": "info",
        "event": name,
        "msg": "CANARY_USER logged in to DU1234567",
        "seq": 1,
    }
    if boot is not None:
        body["boot_id"] = boot
    body.update(extra)
    return json.dumps(body)


def metrics_line(at: object = T0, boot: str | None = BOOT_A, **values: object) -> str:
    body: dict[str, object] = {"ts": iso(at), "src": "metrics", "seq": 7, "phase": "logged-in"}  # type: ignore[arg-type]
    if boot is not None:
        body["boot_id"] = boot
    body.update(values)
    return json.dumps(body)


def test_an_event_line_is_parsed_and_its_message_is_not_kept() -> None:
    event = parse_event(event_line("login_completed", extra_key={"nested": "CANARY"}))
    assert event is not None
    assert (event.event, event.src, event.level, event.boot_id, event.seq) == (
        "login_completed",
        "ibc",
        "info",
        BOOT_A,
        1,
    )
    assert event.ts == T0
    assert "CANARY" not in repr(event)
    assert "DU1234567" not in repr(event)


@pytest.mark.parametrize(
    "line",
    [
        "",
        "not json",
        "[1,2,3]",
        '{"ts":"2026-11-12T15:00:00.000Z"}',
        '{"event":"login_completed"}',
        '{"ts":"yesterday","event":"login_completed"}',
        '{"ts":"2026-11-12T15:00:00.000Z","event":"Login Completed"}',
        '{"ts":"2026-11-12T15:00:00.000Z","event":42}',
        '{"ts":"2026-11-12T15:00:00.000Z","event":"' + "x" * 200 + '"}',
    ],
)
def test_lines_that_are_not_contract_events_are_rejected(line: str) -> None:
    assert parse_event(line) is None


def test_optional_event_fields_degrade_to_safe_values() -> None:
    line = '{"ts":"2026-11-12T15:00:00.000Z","event":"x_y","src":"CANARY SRC","level":"loud","boot_id":"zz","seq":"7"}'
    event = parse_event(line)
    assert event is not None
    assert (event.src, event.level, event.boot_id, event.seq) == ("unknown", "info", None, None)


def test_a_metrics_line_keeps_only_measured_known_numeric_keys() -> None:
    sample = parse_metrics(
        metrics_line(
            mem_working_set_bytes=900,
            mem_limit_bytes=1000,
            oom_kills=0,
            pids=True,
            open_fds="12",
            java_threads=-1,
            cpu_usage_usec=1.5e6,
            surprise="CANARY",
        )
    )
    assert sample is not None
    assert dict(sample.values) == {
        "mem_working_set_bytes": 900.0,
        "mem_limit_bytes": 1000.0,
        "oom_kills": 0.0,
        "cpu_usage_usec": 1.5e6,
    }
    assert sample.phase == "logged-in"
    assert sample.boot_id == BOOT_A


def test_a_metrics_line_without_a_timestamp_is_rejected_and_bad_phase_is_dropped() -> None:
    assert parse_metrics('{"src":"metrics","pids":3}') is None
    sample = parse_metrics(metrics_line(phase="CANARY", pids=float("inf")))
    assert sample is not None
    assert sample.phase is None
    assert dict(sample.values) == {}


def reading(token: str, at: object) -> PhaseReading:
    return PhaseReading(token=token, known=token != "unknown", modified=at)  # type: ignore[arg-type]


def test_before_anything_is_observed_nothing_is_claimed() -> None:
    snapshot = GatewayState(FakeClock()).snapshot()
    assert snapshot.phase is None
    assert snapshot.phase_since is None
    assert snapshot.boot_id is None
    assert snapshot.boots_30m is None
    assert snapshot.last_login is None
    assert snapshot.last_metrics is None
    assert snapshot.feeds_seen is False


def test_phase_since_is_the_file_time_at_first_sight_and_survives_rewrites_of_the_same_token() -> (
    None
):
    clock = FakeClock()
    state = GatewayState(clock)
    state.observe_phase(reading("login", T0 - timedelta(seconds=90)))
    assert state.snapshot().phase == "login"
    assert state.snapshot().phase_since == T0 - timedelta(seconds=90)
    clock.advance(30)
    state.observe_phase(reading("login", clock.now()))  # same token rewritten
    assert state.snapshot().phase_since == T0 - timedelta(seconds=90)
    clock.advance(30)
    state.observe_phase(reading("2fa-pending", clock.now() - timedelta(seconds=1)))
    assert state.snapshot().phase == "2fa-pending"
    assert state.snapshot().phase_since == T0 + timedelta(seconds=59)


def test_a_phase_time_in_the_future_is_clamped_and_a_vanished_file_is_unmeasured() -> None:
    clock = FakeClock()
    state = GatewayState(clock)
    state.observe_phase(reading("logged-in", T0 + timedelta(hours=1)))
    assert state.snapshot().phase_since == T0
    state.observe_phase(None)
    assert state.snapshot().phase is None
    assert state.snapshot().phase_since is None


def feed_event(state: GatewayState, line: str) -> None:
    event = parse_event(line)
    assert event is not None
    state.observe_event(event)


def test_last_event_per_name_login_time_and_current_boot_are_tracked() -> None:
    clock = FakeClock()
    state = GatewayState(clock)
    feed_event(state, event_line("login_completed", T0 - timedelta(hours=2)))
    feed_event(state, event_line("login_completed", T0 - timedelta(minutes=5), boot=BOOT_B))
    feed_event(state, event_line("twofa_initiated", T0 - timedelta(minutes=6), boot=BOOT_B))
    snapshot = state.snapshot()
    assert snapshot.last_login == T0 - timedelta(minutes=5)
    assert snapshot.boot_id == BOOT_B
    assert snapshot.last_events["twofa_initiated"].ts == T0 - timedelta(minutes=6)
    assert snapshot.last_event_at == T0 - timedelta(minutes=5)
    assert snapshot.feeds_seen is True


def test_boots_in_the_last_thirty_minutes_count_distinct_boot_ids_by_first_appearance() -> None:
    clock = FakeClock()
    state = GatewayState(clock)
    feed_event(state, event_line("container_start", T0 - timedelta(minutes=50), boot=BOOT_A))
    feed_event(state, event_line("container_start", T0 - timedelta(minutes=20), boot=BOOT_B))
    feed_event(state, event_line("login_dialog", T0 - timedelta(minutes=19), boot=BOOT_B))
    sample = parse_metrics(metrics_line(T0 - timedelta(minutes=2), boot=BOOT_C))
    assert sample is not None
    state.observe_metrics(sample)
    assert state.snapshot().boots_30m == 2
    assert state.snapshot().boot_id == BOOT_C
    clock.advance(11 * 60)
    assert state.snapshot().boots_30m == 1
    clock.advance(30 * 60)
    assert state.snapshot().boots_30m == 0


def test_lines_without_a_boot_id_never_count_as_a_boot() -> None:
    state = GatewayState(FakeClock())
    feed_event(state, event_line("login_completed", boot=None))
    assert state.snapshot().boot_id is None
    assert state.snapshot().boots_30m is None


def test_event_names_and_boot_ids_are_bounded() -> None:
    state = GatewayState(FakeClock())
    for number in range(600):
        feed_event(state, event_line(f"made_up_{number}", boot=f"{number:016x}"))
    snapshot = state.snapshot()
    assert len(snapshot.last_events) <= 256
    assert "made_up_599" in snapshot.last_events
    assert snapshot.boots_30m is not None
    assert snapshot.boots_30m <= 64


def feed_metrics(state: GatewayState, line: str) -> None:
    sample = parse_metrics(line)
    assert sample is not None
    state.observe_metrics(sample)


def test_memory_pressure_starts_when_the_working_set_passes_85_percent_and_clears_below() -> None:
    state = GatewayState(FakeClock())
    feed_metrics(state, metrics_line(T0, mem_working_set_bytes=800, mem_limit_bytes=1000))
    assert state.snapshot().memory_high_since is None
    assert state.snapshot().memory_ratio == pytest.approx(0.8)
    feed_metrics(
        state,
        metrics_line(T0 + timedelta(seconds=30), mem_working_set_bytes=900, mem_limit_bytes=1000),
    )
    feed_metrics(
        state,
        metrics_line(T0 + timedelta(seconds=60), mem_working_set_bytes=950, mem_limit_bytes=1000),
    )
    assert state.snapshot().memory_high_since == T0 + timedelta(seconds=30)
    feed_metrics(
        state,
        metrics_line(T0 + timedelta(seconds=90), mem_working_set_bytes=100, mem_limit_bytes=1000),
    )
    assert state.snapshot().memory_high_since is None


def test_memory_pressure_is_unmeasured_without_a_limit() -> None:
    state = GatewayState(FakeClock())
    feed_metrics(state, metrics_line(T0, mem_working_set_bytes=900, mem_limit_bytes=1000))
    feed_metrics(state, metrics_line(T0 + timedelta(seconds=30), mem_working_set_bytes=900))
    snapshot = state.snapshot()
    assert snapshot.memory_ratio is None
    assert snapshot.memory_high_since is None
    feed_metrics(
        state,
        metrics_line(T0 + timedelta(seconds=60), mem_working_set_bytes=900, mem_limit_bytes=0),
    )
    assert state.snapshot().memory_ratio is None


def test_an_oom_kill_is_an_increase_of_the_counter_or_the_event_never_the_first_reading() -> None:
    state = GatewayState(FakeClock())
    feed_metrics(state, metrics_line(T0, oom_kills=2))
    assert state.snapshot().last_oom_at is None
    feed_metrics(state, metrics_line(T0 + timedelta(seconds=30), oom_kills=2))
    assert state.snapshot().last_oom_at is None
    feed_metrics(state, metrics_line(T0 + timedelta(seconds=60), oom_kills=3))
    assert state.snapshot().last_oom_at == T0 + timedelta(seconds=60)
    feed_event(state, event_line("oom_kill", T0 + timedelta(seconds=120)))
    assert state.snapshot().last_oom_at == T0 + timedelta(seconds=120)


def test_last_activity_is_the_newest_line_of_either_feed() -> None:
    state = GatewayState(FakeClock())
    feed_event(state, event_line("login_dialog", T0 - timedelta(minutes=9)))
    feed_metrics(state, metrics_line(T0 - timedelta(minutes=4), pids=40))
    snapshot = state.snapshot()
    assert snapshot.last_activity_at == T0 - timedelta(minutes=4)
    assert snapshot.last_metrics is not None
    assert snapshot.last_metrics.values["pids"] == 40.0


def test_rejected_lines_are_counted() -> None:
    state = GatewayState(FakeClock())
    state.note_rejected_line()
    state.note_rejected_line()
    assert state.snapshot().rejected_lines == 2
