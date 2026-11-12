"""Alert rules: which condition is active, inactive or not decidable."""

from __future__ import annotations

from collections.abc import Mapping
from datetime import datetime, timedelta

import pytest

from brokersre_sidecar.model import PairState
from brokersre_sidecar.notify import Condition, RuleConfig, RuleEngine, skew_exceeds
from brokersre_sidecar.vocab import AlertClass, ProbeStatus
from testkit import BOOT, T0, gateway_event, gateway_snapshot, probe_snapshot

ACTIVE, INACTIVE, UNKNOWN = Condition.ACTIVE, Condition.INACTIVE, Condition.UNKNOWN


def evaluate(
    *,
    now: datetime = T0,
    mono: float = 1000.0,
    engine: RuleEngine | None = None,
    gateway: Mapping[str, object] | None = None,
    probe: Mapping[str, object] | None = None,
) -> dict[AlertClass, Condition]:
    rules = engine or RuleEngine(RuleConfig())
    result = rules.evaluate(
        gateway_snapshot(now, **(gateway or {})),
        probe_snapshot(now, **(probe or {})),
        now=now,
        mono=mono,
    )
    return {alert: evaluation.state for alert, evaluation in result.items()}


def details(
    *, gateway: Mapping[str, object], probe: Mapping[str, object] | None = None
) -> dict[AlertClass, str]:
    result = RuleEngine(RuleConfig()).evaluate(
        gateway_snapshot(T0, **gateway), probe_snapshot(T0, **(probe or {})), now=T0, mono=1000.0
    )
    return {alert: evaluation.detail for alert, evaluation in result.items()}


def opened(since: datetime = T0 - timedelta(minutes=30)) -> PairState:
    return PairState(True, since, BOOT)


def closed(since: datetime = T0 - timedelta(minutes=1)) -> PairState:
    return PairState(False, since, BOOT)


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


def test_a_stalled_login_is_what_the_gateway_says_not_a_timer_of_the_sidecar() -> None:
    # Hours in phase login without the gateway's event: no opinion, no alert.
    long_login = {"phase": "login", "phase_since": T0 - timedelta(hours=5)}
    assert evaluate(gateway=long_login)[AlertClass.LOGIN_STALLED] is UNKNOWN
    stalled = long_login | {"pairs": {"login_stalled": opened()}}
    assert evaluate(gateway=stalled)[AlertClass.LOGIN_STALLED] is ACTIVE
    resumed = long_login | {"pairs": {"login_stalled": closed()}}
    assert evaluate(gateway=resumed)[AlertClass.LOGIN_STALLED] is INACTIVE


def test_an_open_stall_ends_when_the_gateway_is_no_longer_logging_in() -> None:
    for phase in ("logged-in", "stopped", "exited", "needs-human", "2fa-pending"):
        states = evaluate(gateway={"phase": phase, "pairs": {"login_stalled": opened()}})
        assert states[AlertClass.LOGIN_STALLED] is INACTIVE, phase


def test_disk_low_holds_from_the_gateways_event_until_its_all_clear_however_long() -> None:
    # The reviewer's reproduction: the event without its closing partner used to "resolve"
    # after 15 minutes by a timer of the sidecar.
    low = {"pairs": {"disk_low": opened(T0 - timedelta(hours=9))}}
    assert evaluate(gateway=low)[AlertClass.DISK_LOW] is ACTIVE
    assert evaluate(gateway={"pairs": {"disk_low": closed()}})[AlertClass.DISK_LOW] is INACTIVE
    assert evaluate()[AlertClass.DISK_LOW] is UNKNOWN  # never reported: no alert, no "resolved"


def test_the_sidecar_has_no_disk_or_memory_threshold_of_its_own() -> None:
    from testkit import metrics_sample

    tight = metrics_sample(
        T0,
        disk_free_bytes_logs=1024,
        disk_total_bytes_logs=10**12,
        mem_working_set_bytes=999,
        mem_limit_bytes=1000,
    )
    states = evaluate(gateway={"last_metrics": tight})
    assert states[AlertClass.DISK_LOW] is UNKNOWN
    assert states[AlertClass.RESOURCE_ALERT] is UNKNOWN


def test_memory_pressure_is_the_gateways_pair_and_an_oom_kill_is_a_point_event() -> None:
    high = {"pairs": {"memory_high": opened()}}
    assert evaluate(gateway=high)[AlertClass.RESOURCE_ALERT] is ACTIVE
    cleared = {"pairs": {"memory_high": closed()}}
    assert evaluate(gateway=cleared)[AlertClass.RESOURCE_ALERT] is INACTIVE
    killed = {"last_oom_at": T0 - timedelta(minutes=5)}
    assert evaluate(gateway=killed)[AlertClass.RESOURCE_ALERT] is ACTIVE
    long_ago = cleared | {"last_oom_at": T0 - timedelta(minutes=20)}
    assert evaluate(gateway=long_ago)[AlertClass.RESOURCE_ALERT] is INACTIVE
    assert evaluate()[AlertClass.RESOURCE_ALERT] is UNKNOWN
    stopped = high | {"phase": "stopped"}
    assert evaluate(gateway=stopped)[AlertClass.RESOURCE_ALERT] is INACTIVE


def test_a_fresh_login_failure_is_active_until_it_ages_out_or_login_completes() -> None:
    fresh = {"login_failed": gateway_event("login_failed", T0 - timedelta(minutes=2))}
    assert (
        evaluate(gateway={"phase": "login", "last_events": fresh})[AlertClass.LOGIN_FAILED]
        is ACTIVE
    )
    old = {"login_failed": gateway_event("login_failed", T0 - timedelta(minutes=16))}
    assert (
        evaluate(gateway={"phase": "login", "last_events": old})[AlertClass.LOGIN_FAILED]
        is INACTIVE
    )
    recovered = fresh | {
        "login_completed": gateway_event("login_completed", T0 - timedelta(minutes=1))
    }
    assert evaluate(gateway={"last_events": recovered})[AlertClass.LOGIN_FAILED] is INACTIVE


def test_a_rejected_login_is_one_alert_needs_human_with_the_cause_not_two() -> None:
    # The reviewer's reproduction: login_failed_dialog sets phase needs-human; both
    # login_failed and needs_human used to fire.
    events = {
        "login_failed_dialog": gateway_event("login_failed_dialog", T0 - timedelta(seconds=5)),
        "login_failed": gateway_event("login_failed", T0 - timedelta(seconds=6)),
    }
    gateway = {"phase": "needs-human", "last_events": events}
    states = evaluate(gateway=gateway)
    assert states[AlertClass.NEEDS_HUMAN] is ACTIVE
    assert states[AlertClass.LOGIN_FAILED] is INACTIVE
    assert details(gateway=gateway)[AlertClass.NEEDS_HUMAN] == (
        "gateway phase is needs-human: IBKR rejected the login"
    )


def test_needs_human_after_unapproved_prompts_says_so() -> None:
    events = {"needs_human": gateway_event("needs_human", T0 - timedelta(seconds=5))}
    gateway = {"phase": "needs-human", "last_events": events}
    assert details(gateway=gateway)[AlertClass.NEEDS_HUMAN] == (
        "gateway phase is needs-human: the second factor was not approved"
    )
    assert details(gateway={"phase": "needs-human"})[AlertClass.NEEDS_HUMAN] == (
        "gateway phase is needs-human"
    )


def test_an_unknown_window_is_reported_while_not_logged_in() -> None:
    events = {"unknown_window": gateway_event("unknown_window", T0 - timedelta(minutes=1))}
    assert (
        evaluate(gateway={"phase": "login", "last_events": events})[AlertClass.UNKNOWN_WINDOW]
        is ACTIVE
    )
    assert evaluate(gateway={"last_events": events})[AlertClass.UNKNOWN_WINDOW] is INACTIVE


def test_event_conditions_are_undecidable_before_any_feed_line_was_read() -> None:
    states = evaluate(
        gateway={
            "feeds_seen": False,
            "last_event_at": None,
            "last_activity_at": None,
            "quiet_for_s": None,
        }
    )
    assert states[AlertClass.LOGIN_FAILED] is UNKNOWN
    assert states[AlertClass.UNKNOWN_WINDOW] is UNKNOWN
    assert states[AlertClass.GATEWAY_SILENT] is UNKNOWN


@pytest.mark.parametrize(
    "status", [ProbeStatus.DOWN, ProbeStatus.DEGRADED, ProbeStatus.CLIENT_ID_IN_USE]
)
def test_the_api_must_be_unhealthy_for_five_minutes_before_it_alerts(status: ProbeStatus) -> None:
    engine = RuleEngine(RuleConfig())
    probe = {"status": status, "status_since": T0}
    assert evaluate(engine=engine, probe=probe)[AlertClass.API_UNHEALTHY] is UNKNOWN
    assert evaluate(engine=engine, probe=probe, mono=1299.0)[AlertClass.API_UNHEALTHY] is UNKNOWN
    assert evaluate(engine=engine, probe=probe, mono=1301.0)[AlertClass.API_UNHEALTHY] is ACTIVE


def test_the_five_minutes_are_measured_on_the_monotonic_clock() -> None:
    # The wall clock jumps an hour (a resumed VM, an NTP step): no alert out of thin air.
    engine = RuleEngine(RuleConfig())
    probe = {"status": ProbeStatus.DOWN, "status_since": T0}
    evaluate(engine=engine, probe=probe, mono=1000.0)
    jumped = T0 + timedelta(hours=1)
    assert (
        evaluate(now=jumped, engine=engine, probe=probe, mono=1010.0)[AlertClass.API_UNHEALTHY]
        is UNKNOWN
    )


def test_moving_between_unhealthy_statuses_does_not_restart_the_five_minutes() -> None:
    engine = RuleEngine(RuleConfig())
    evaluate(engine=engine, probe={"status": ProbeStatus.DOWN, "status_since": T0})
    flipped = {"status": ProbeStatus.DEGRADED, "status_since": T0 + timedelta(seconds=301)}
    assert evaluate(engine=engine, probe=flipped, mono=1301.0)[AlertClass.API_UNHEALTHY] is ACTIVE
    ready = evaluate(engine=engine, mono=1361.0)
    assert ready[AlertClass.API_UNHEALTHY] is INACTIVE


def test_an_unmeasured_api_decides_nothing() -> None:
    probe = {"status": ProbeStatus.NOT_MEASURED, "clock_skew_s": None}
    states = evaluate(probe=probe)
    assert states[AlertClass.API_UNHEALTHY] is UNKNOWN
    assert states[AlertClass.CLOCK_SKEW] is UNKNOWN


def test_three_boots_in_thirty_minutes_are_a_restart_storm() -> None:
    assert evaluate(gateway={"boots_30m": 2})[AlertClass.RESTART_STORM] is INACTIVE
    assert evaluate(gateway={"boots_30m": 3})[AlertClass.RESTART_STORM] is ACTIVE
    assert evaluate(gateway={"boots_30m": None})[AlertClass.RESTART_STORM] is UNKNOWN


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
def test_a_skew_is_beyond_the_limit_only_when_that_is_provable(skew: float, expected: bool) -> None:
    assert skew_exceeds(skew, 1.0) is expected


def test_silence_is_five_minutes_without_an_observed_line_on_the_monotonic_clock() -> None:
    assert evaluate(gateway={"quiet_for_s": 301.0})[AlertClass.GATEWAY_SILENT] is ACTIVE
    assert evaluate(gateway={"quiet_for_s": 299.0})[AlertClass.GATEWAY_SILENT] is INACTIVE
    # Old timestamps in the files do not matter: only what the sidecar observed does.
    stale_text = {"quiet_for_s": 5.0, "last_activity_at": T0 - timedelta(hours=8)}
    assert evaluate(gateway=stale_text)[AlertClass.GATEWAY_SILENT] is INACTIVE


def test_a_stopped_gateway_is_expected_to_be_silent() -> None:
    for phase in ("stopping", "stopped", "exited"):
        states = evaluate(gateway={"quiet_for_s": 9999.0, "phase": phase})
        assert states[AlertClass.GATEWAY_SILENT] is UNKNOWN, phase


def test_details_are_built_from_numbers_and_fixed_words_only() -> None:
    result = details(
        gateway={
            "phase": "login",
            "boots_30m": 4,
            "quiet_for_s": 400.0,
            "pairs": {"login_stalled": opened(), "disk_low": opened(), "memory_high": opened()},
        }
    )
    assert result[AlertClass.LOGIN_STALLED] == "the gateway reports a stalled login"
    assert result[AlertClass.RESTART_STORM] == "4 gateway starts in the last 30 minutes"
    assert result[AlertClass.DISK_LOW] == "the gateway reports low disk space"
    assert result[AlertClass.RESOURCE_ALERT] == "the gateway reports memory pressure"
    assert result[AlertClass.GATEWAY_SILENT] == "no event and no metrics sample for 400 s"


def twofa(phase: str, **events_at: timedelta) -> dict[str, object]:
    """A gateway in ``phase`` whose named events happened that long ago."""
    events = {name: gateway_event(name, T0 - ago) for name, ago in events_at.items()}
    return {"phase": phase, "last_events": events, "last_login": None}


@pytest.mark.parametrize("phase", ["login", "restarting", "starting"])
def test_an_unanswered_prompt_stays_pending_while_the_gateway_logs_in_again(phase: str) -> None:
    # twofa_timeout sets the phase to login; the next prompt is seconds away.
    gateway = twofa(
        phase, twofa_initiated=timedelta(seconds=200), twofa_timeout=timedelta(seconds=20)
    )
    assert evaluate(gateway=gateway)[AlertClass.TWOFA_PENDING] is ACTIVE


def test_a_login_without_any_prompt_is_not_a_pending_second_factor() -> None:
    assert evaluate(gateway=twofa("login"))[AlertClass.TWOFA_PENDING] is INACTIVE


def test_only_a_completed_login_resolves_the_second_factor() -> None:
    pending = twofa("login", twofa_dialog=timedelta(minutes=30))
    assert evaluate(gateway=pending)[AlertClass.TWOFA_PENDING] is ACTIVE
    approved = pending | {"phase": "logged-in", "last_login": T0 - timedelta(seconds=5)}
    assert evaluate(gateway=approved)[AlertClass.TWOFA_PENDING] is INACTIVE
    # A later login in progress (the daily restart) is not a pending prompt either.
    next_day = approved | {"phase": "login"}
    assert evaluate(gateway=next_day)[AlertClass.TWOFA_PENDING] is INACTIVE


def test_a_prompt_of_an_earlier_boot_does_not_keep_a_new_boot_pending() -> None:
    events = {
        "twofa_initiated": gateway_event(
            "twofa_initiated", T0 - timedelta(minutes=10), boot="00000000000000ff"
        )
    }
    gateway = {"phase": "login", "last_events": events, "last_login": None}
    assert evaluate(gateway=gateway)[AlertClass.TWOFA_PENDING] is INACTIVE


@pytest.mark.parametrize(
    ("phase", "successor"),
    [
        ("needs-human", AlertClass.NEEDS_HUMAN),
        ("exited", AlertClass.GATEWAY_EXITED),
    ],
)
def test_the_second_factor_alert_is_handed_over_not_resolved(
    phase: str, successor: AlertClass
) -> None:
    result = RuleEngine(RuleConfig()).evaluate(
        gateway_snapshot(T0, **twofa(phase, twofa_initiated=timedelta(minutes=5))),
        probe_snapshot(T0),
        now=T0,
        mono=1000.0,
    )
    verdict = result[AlertClass.TWOFA_PENDING]
    assert verdict.state is INACTIVE
    assert verdict.superseded_by is successor
    assert result[successor].state is ACTIVE
