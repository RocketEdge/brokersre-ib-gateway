"""Alert rules: which condition is active, inactive or not decidable."""

from __future__ import annotations

from datetime import datetime, timedelta

import pytest

from brokersre_sidecar.notify import Condition, RuleConfig, RuleEngine, skew_exceeds
from brokersre_sidecar.vocab import AlertClass, ProbeStatus
from testkit import T0, gateway_event, gateway_snapshot, metrics_sample, probe_snapshot

ACTIVE, INACTIVE, UNKNOWN = Condition.ACTIVE, Condition.INACTIVE, Condition.UNKNOWN


def evaluate(
    *,
    now: datetime = T0,
    engine: RuleEngine | None = None,
    volume_present: bool = True,
    gateway: dict[str, object] | None = None,
    probe: dict[str, object] | None = None,
) -> dict[AlertClass, Condition]:
    rules = engine or RuleEngine(RuleConfig(login_stall_s=300.0))
    result = rules.evaluate(
        gateway_snapshot(now, **(gateway or {})),
        probe_snapshot(now, **(probe or {})),
        now=now,
        volume_present=volume_present,
    )
    return {alert: evaluation.state for alert, evaluation in result.items()}


def test_a_healthy_logged_in_gateway_has_no_active_condition() -> None:
    states = evaluate()
    assert set(states) == set(AlertClass) - {AlertClass.HEARTBEAT}
    assert ACTIVE not in states.values()
    assert states[AlertClass.TWOFA_PENDING] is INACTIVE
    assert states[AlertClass.API_UNHEALTHY] is INACTIVE


@pytest.mark.parametrize(
    ("phase", "alert"),
    [
        ("2fa-pending", AlertClass.TWOFA_PENDING),
        ("needs-human", AlertClass.NEEDS_HUMAN),
        ("existing-session", AlertClass.EXISTING_SESSION),
        ("exited", AlertClass.GATEWAY_EXITED),
    ],
)
def test_phase_conditions_follow_the_phase_token(phase: str, alert: AlertClass) -> None:
    states = evaluate(gateway={"phase": phase})
    assert states[alert] is ACTIVE
    for other in (
        AlertClass.TWOFA_PENDING,
        AlertClass.NEEDS_HUMAN,
        AlertClass.EXISTING_SESSION,
        AlertClass.GATEWAY_EXITED,
    ):
        if other is not alert:
            assert states[other] is INACTIVE


@pytest.mark.parametrize("phase", [None, "unknown"])
def test_an_unmeasured_or_unknown_phase_decides_nothing(phase: str | None) -> None:
    states = evaluate(gateway={"phase": phase, "phase_since": None})
    for alert in (
        AlertClass.TWOFA_PENDING,
        AlertClass.NEEDS_HUMAN,
        AlertClass.EXISTING_SESSION,
        AlertClass.GATEWAY_EXITED,
        AlertClass.LOGIN_STALLED,
    ):
        assert states[alert] is UNKNOWN


def test_a_deliberate_stop_is_not_an_exit_alert() -> None:
    assert evaluate(gateway={"phase": "stopped"})[AlertClass.GATEWAY_EXITED] is INACTIVE


def test_login_stalls_after_the_configured_time_in_phase_login() -> None:
    pending = evaluate(gateway={"phase": "login", "phase_since": T0 - timedelta(seconds=299)})
    assert pending[AlertClass.LOGIN_STALLED] is UNKNOWN
    stalled = evaluate(gateway={"phase": "login", "phase_since": T0 - timedelta(seconds=301)})
    assert stalled[AlertClass.LOGIN_STALLED] is ACTIVE
    assert evaluate()[AlertClass.LOGIN_STALLED] is INACTIVE


def test_the_gateways_own_stall_event_counts_while_still_in_login() -> None:
    events = {"login_stalled": gateway_event("login_stalled", T0 - timedelta(seconds=30))}
    states = evaluate(
        gateway={
            "phase": "login",
            "phase_since": T0 - timedelta(seconds=60),
            "last_events": events,
        }
    )
    assert states[AlertClass.LOGIN_STALLED] is ACTIVE


@pytest.mark.parametrize("name", ["login_failed", "login_failed_dialog"])
def test_a_fresh_login_failure_is_active_until_it_ages_out_or_login_completes(name: str) -> None:
    fresh = {name: gateway_event(name, T0 - timedelta(minutes=2))}
    assert (
        evaluate(gateway={"phase": "login", "last_events": fresh})[AlertClass.LOGIN_FAILED]
        is ACTIVE
    )
    old = {name: gateway_event(name, T0 - timedelta(minutes=16))}
    assert (
        evaluate(gateway={"phase": "login", "last_events": old})[AlertClass.LOGIN_FAILED]
        is INACTIVE
    )
    recovered = fresh | {
        "login_completed": gateway_event("login_completed", T0 - timedelta(minutes=1))
    }
    assert evaluate(gateway={"last_events": recovered})[AlertClass.LOGIN_FAILED] is INACTIVE


def test_an_unknown_window_is_reported_while_not_logged_in() -> None:
    events = {"unknown_window": gateway_event("unknown_window", T0 - timedelta(minutes=1))}
    assert (
        evaluate(gateway={"phase": "login", "last_events": events})[AlertClass.UNKNOWN_WINDOW]
        is ACTIVE
    )
    assert evaluate(gateway={"last_events": events})[AlertClass.UNKNOWN_WINDOW] is INACTIVE


def test_event_conditions_are_undecidable_before_any_feed_line_was_read() -> None:
    states = evaluate(
        gateway={"feeds_seen": False, "last_event_at": None, "last_activity_at": None}
    )
    assert states[AlertClass.LOGIN_FAILED] is UNKNOWN
    assert states[AlertClass.UNKNOWN_WINDOW] is UNKNOWN
    assert states[AlertClass.GATEWAY_SILENT] is UNKNOWN


@pytest.mark.parametrize(
    "status", [ProbeStatus.DOWN, ProbeStatus.DEGRADED, ProbeStatus.CLIENT_ID_IN_USE]
)
def test_the_api_must_be_unhealthy_for_five_minutes_before_it_alerts(status: ProbeStatus) -> None:
    engine = RuleEngine(RuleConfig(login_stall_s=300.0))
    probe = {"status": status, "status_since": T0}
    assert evaluate(engine=engine, probe=probe)[AlertClass.API_UNHEALTHY] is UNKNOWN
    later = T0 + timedelta(seconds=299)
    assert evaluate(now=later, engine=engine, probe=probe)[AlertClass.API_UNHEALTHY] is UNKNOWN
    later = T0 + timedelta(seconds=301)
    assert evaluate(now=later, engine=engine, probe=probe)[AlertClass.API_UNHEALTHY] is ACTIVE


def test_moving_between_unhealthy_statuses_does_not_restart_the_five_minutes() -> None:
    engine = RuleEngine(RuleConfig(login_stall_s=300.0))
    evaluate(engine=engine, probe={"status": ProbeStatus.DOWN, "status_since": T0})
    later = T0 + timedelta(seconds=301)
    flipped = {"status": ProbeStatus.DEGRADED, "status_since": later}
    assert evaluate(now=later, engine=engine, probe=flipped)[AlertClass.API_UNHEALTHY] is ACTIVE
    ready = evaluate(now=later + timedelta(seconds=60), engine=engine)
    assert ready[AlertClass.API_UNHEALTHY] is INACTIVE


def test_an_unhealthy_api_inside_a_reset_window_neither_fires_nor_resolves() -> None:
    engine = RuleEngine(RuleConfig(login_stall_s=300.0))
    evaluate(engine=engine, probe={"status": ProbeStatus.DOWN, "status_since": T0})
    later = T0 + timedelta(minutes=10)
    suppressed = {"status": ProbeStatus.DOWN, "status_since": T0, "in_reset_window": True}
    assert evaluate(now=later, engine=engine, probe=suppressed)[AlertClass.API_UNHEALTHY] is UNKNOWN


def test_an_unmeasured_api_decides_nothing() -> None:
    probe = {"status": ProbeStatus.NOT_MEASURED, "clock_skew_s": None}
    states = evaluate(probe=probe)
    assert states[AlertClass.API_UNHEALTHY] is UNKNOWN
    assert states[AlertClass.CLOCK_SKEW] is UNKNOWN


def test_three_boots_in_thirty_minutes_are_a_restart_storm() -> None:
    assert evaluate(gateway={"boots_30m": 2})[AlertClass.RESTART_STORM] is INACTIVE
    assert evaluate(gateway={"boots_30m": 3})[AlertClass.RESTART_STORM] is ACTIVE
    assert evaluate(gateway={"boots_30m": None})[AlertClass.RESTART_STORM] is UNKNOWN


def test_memory_pressure_alerts_after_ten_minutes_and_an_oom_kill_at_once() -> None:
    pending = evaluate(gateway={"memory_high_since": T0 - timedelta(minutes=9)})
    assert pending[AlertClass.RESOURCE_ALERT] is UNKNOWN
    sustained = evaluate(gateway={"memory_high_since": T0 - timedelta(minutes=10, seconds=1)})
    assert sustained[AlertClass.RESOURCE_ALERT] is ACTIVE
    killed = evaluate(gateway={"last_oom_at": T0 - timedelta(minutes=5)})
    assert killed[AlertClass.RESOURCE_ALERT] is ACTIVE
    long_ago = evaluate(gateway={"last_oom_at": T0 - timedelta(minutes=20)})
    assert long_ago[AlertClass.RESOURCE_ALERT] is INACTIVE
    unmeasured = evaluate(gateway={"memory_ratio": None})
    assert unmeasured[AlertClass.RESOURCE_ALERT] is UNKNOWN


def test_disk_low_comes_from_the_gateway_event_or_a_measured_free_space() -> None:
    events = {"disk_low": gateway_event("disk_low", T0 - timedelta(minutes=3))}
    assert evaluate(gateway={"last_events": events})[AlertClass.DISK_LOW] is ACTIVE
    low = metrics_sample(T0, disk_free_bytes_logs=10 * 1024**2, disk_free_bytes_settings=10**10)
    assert evaluate(gateway={"last_metrics": low})[AlertClass.DISK_LOW] is ACTIVE
    roomy = metrics_sample(T0, disk_free_bytes_logs=10**10)
    assert evaluate(gateway={"last_metrics": roomy})[AlertClass.DISK_LOW] is INACTIVE
    assert evaluate()[AlertClass.DISK_LOW] is UNKNOWN


@pytest.mark.parametrize(
    ("skew", "expected"),
    [
        (0.0, False),
        (-0.99, False),  # a perfect clock reads between -1 and 0: IBKR truncates to seconds
        (0.5, False),
        (1.5, False),
        (1.51, True),
        (-2.0, False),
        (-2.01, True),
        (30.0, True),
        (-30.0, True),
    ],
)
def test_clock_skew_alerts_only_when_provably_beyond_one_second(
    skew: float, expected: bool
) -> None:
    assert skew_exceeds(skew, 1.0) is expected
    state = evaluate(probe={"clock_skew_s": skew})[AlertClass.CLOCK_SKEW]
    assert state is (ACTIVE if expected else INACTIVE)


def test_silence_is_five_minutes_without_any_line_while_the_volume_is_mounted() -> None:
    quiet = {"last_activity_at": T0 - timedelta(seconds=301)}
    assert evaluate(gateway=quiet)[AlertClass.GATEWAY_SILENT] is ACTIVE
    assert evaluate(gateway=quiet, volume_present=False)[AlertClass.GATEWAY_SILENT] is UNKNOWN
    recent = {"last_activity_at": T0 - timedelta(seconds=299)}
    assert evaluate(gateway=recent)[AlertClass.GATEWAY_SILENT] is INACTIVE
    stopped = quiet | {"phase": "stopped"}
    assert evaluate(gateway=stopped)[AlertClass.GATEWAY_SILENT] is UNKNOWN


def test_details_are_built_from_numbers_and_fixed_words_only() -> None:
    rules = RuleEngine(RuleConfig(login_stall_s=300.0))
    result = rules.evaluate(
        gateway_snapshot(phase="login", phase_since=T0 - timedelta(seconds=400), boots_30m=4),
        probe_snapshot(clock_skew_s=12.34),
        now=T0,
        volume_present=True,
    )
    assert result[AlertClass.LOGIN_STALLED].detail == "in phase login for 400 s (limit 300 s)"
    assert result[AlertClass.RESTART_STORM].detail == "4 gateway starts in the last 30 minutes"
    assert result[AlertClass.CLOCK_SKEW].detail == "IBKR time minus host time is 12.3 s"
