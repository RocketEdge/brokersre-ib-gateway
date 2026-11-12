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


def test_a_condition_pair_is_open_between_the_gateways_two_events() -> None:
    state = GatewayState(FakeClock())
    assert dict(state.snapshot().pairs) == {}  # never reported: unknown, not "closed"
    feed_event(state, event_line("disk_low", T0))
    feed_event(state, event_line("memory_high", T0 + timedelta(seconds=1)))
    pairs = state.snapshot().pairs
    assert pairs["disk_low"].open is True
    assert pairs["disk_low"].since == T0
    assert pairs["memory_high"].open is True
    assert "login_stalled" not in pairs
    feed_event(state, event_line("disk_ok", T0 + timedelta(hours=3)))
    pairs = state.snapshot().pairs
    assert pairs["disk_low"].open is False
    assert pairs["disk_low"].since == T0 + timedelta(hours=3)
    assert pairs["memory_high"].open is True


def test_a_new_boot_ends_the_pairs_the_previous_boot_left_open() -> None:
    state = GatewayState(FakeClock())
    feed_event(state, event_line("login_stalled", T0, boot=BOOT_A))
    feed_event(state, event_line("disk_low", T0, boot=BOOT_A))
    feed_event(state, event_line("container_start", T0 + timedelta(minutes=5), boot=BOOT_B))
    pairs = state.snapshot().pairs
    assert pairs["login_stalled"].open is False
    assert pairs["disk_low"].open is False
    # The new boot reports the condition again when it still holds.
    feed_event(state, event_line("disk_low", T0 + timedelta(minutes=6), boot=BOOT_B))
    assert state.snapshot().pairs["disk_low"].open is True


def test_the_model_applies_no_threshold_of_its_own_to_memory_or_disk() -> None:
    state = GatewayState(FakeClock())
    feed_metrics(
        state,
        metrics_line(T0, mem_working_set_bytes=999, mem_limit_bytes=1000, disk_free_bytes_logs=1),
    )
    snapshot = state.snapshot()
    assert dict(snapshot.pairs) == {}
    assert snapshot.last_oom_at is None


def test_an_oom_kill_is_the_gateways_event_not_a_counter_the_sidecar_watches() -> None:
    state = GatewayState(FakeClock())
    feed_metrics(state, metrics_line(T0, oom_kills=2))
    feed_metrics(state, metrics_line(T0 + timedelta(seconds=30), oom_kills=3))
    assert state.snapshot().last_oom_at is None
    feed_event(state, event_line("oom_kill", T0 + timedelta(seconds=31)))
    assert state.snapshot().last_oom_at == T0 + timedelta(seconds=31)


def test_a_restart_after_a_requested_shutdown_is_deliberate() -> None:
    state = GatewayState(FakeClock())
    feed_event(state, event_line("container_start", T0, boot=BOOT_A))
    assert state.snapshot().last_restart_at is None  # the first boot seen is not a restart
    feed_event(state, event_line("shutdown_requested", T0 + timedelta(minutes=1), boot=BOOT_A))
    feed_event(state, event_line("shutdown_complete", T0 + timedelta(minutes=2), boot=BOOT_A))
    feed_event(state, event_line("container_start", T0 + timedelta(minutes=3), boot=BOOT_B))
    snapshot = state.snapshot()
    assert snapshot.boot_id == BOOT_B
    assert snapshot.last_restart_at == T0 + timedelta(minutes=3)
    assert snapshot.last_restart_unexpected is False


def test_a_restart_without_a_requested_shutdown_is_unexpected() -> None:
    state = GatewayState(FakeClock())
    feed_event(state, event_line("container_start", T0, boot=BOOT_A))
    feed_event(state, event_line("shutdown_requested", T0, boot=BOOT_A))
    feed_event(state, event_line("container_start", T0 + timedelta(minutes=1), boot=BOOT_B))
    # Boot B is killed: no shutdown event of its own, then boot C appears.
    feed_event(state, event_line("container_start", T0 + timedelta(minutes=9), boot=BOOT_C))
    snapshot = state.snapshot()
    assert snapshot.last_restart_at == T0 + timedelta(minutes=9)
    assert snapshot.last_restart_unexpected is True


def test_replayed_lines_of_an_older_boot_do_not_move_the_current_boot_back() -> None:
    # At start the events file is replayed first, then the metrics file from its tail.
    state = GatewayState(FakeClock())
    feed_event(state, event_line("container_start", T0, boot=BOOT_A))
    feed_event(state, event_line("shutdown_requested", T0, boot=BOOT_A))
    feed_event(state, event_line("container_start", T0 + timedelta(minutes=1), boot=BOOT_B))
    feed_metrics(state, metrics_line(T0 + timedelta(seconds=5), boot=BOOT_A))
    feed_metrics(state, metrics_line(T0 + timedelta(minutes=2), boot=BOOT_B))
    snapshot = state.snapshot()
    assert snapshot.boot_id == BOOT_B
    assert snapshot.last_restart_unexpected is False
    assert snapshot.boots_30m == 2


def test_quiet_time_runs_on_the_monotonic_clock_from_what_the_sidecar_observed() -> None:
    clock = FakeClock()
    state = GatewayState(clock)
    assert state.snapshot().quiet_for_s is None
    # A line with an old timestamp, observed now: the gateway is not "silent for 8 hours".
    feed_event(state, event_line("login_dialog", T0 - timedelta(hours=8)))
    assert state.snapshot().quiet_for_s == 0.0
    clock.advance(40)
    assert state.snapshot().quiet_for_s == 40.0
    # The wall clock jumps (a resumed virtual machine); the monotonic clock does not.
    clock.set(T0 + timedelta(hours=6))
    assert state.snapshot().quiet_for_s == 40.0
    feed_metrics(state, metrics_line(T0))
    assert state.snapshot().quiet_for_s == 0.0


def test_the_time_without_a_readable_phase_file_is_measured() -> None:
    clock = FakeClock()
    state = GatewayState(clock)
    clock.advance(30)
    assert state.snapshot().unreadable_for_s == 30.0  # nothing read since the start
    state.observe_volume(True)
    state.observe_phase(reading("login", T0))
    assert state.snapshot().unreadable_for_s is None
    assert state.snapshot().volume_present is True
    clock.advance(10)
    state.observe_volume(False)
    state.observe_phase(None)
    clock.advance(25)
    snapshot = state.snapshot()
    assert snapshot.unreadable_for_s == 25.0
    assert snapshot.volume_present is False
    assert snapshot.phase is None


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


def test_a_phase_token_the_sidecar_does_not_know_counts_as_not_readable() -> None:
    # A newer gateway may write a token this sidecar has never heard of: every phase rule
    # is then undecidable, exactly as with a missing file.
    clock = FakeClock()
    state = GatewayState(clock)
    state.observe_volume(True)
    state.observe_phase(reading("login", T0))
    clock.advance(5)
    state.observe_phase(reading("unknown", T0))
    clock.advance(40)
    snapshot = state.snapshot()
    assert snapshot.phase == "unknown"
    assert snapshot.unreadable_for_s == 40.0
    state.observe_phase(reading("logged-in", T0))
    assert state.snapshot().unreadable_for_s is None
