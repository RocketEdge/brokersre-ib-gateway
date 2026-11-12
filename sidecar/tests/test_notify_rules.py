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


def test_needs_human_after_a_latched_start_names_the_earlier_rejection() -> None:
    # The gateway's rejected-login latch: at a start whose secret files IBKR already rejected
    # it does not log in at all. There is no login_failed_dialog in this start, only
    # login_rejected_latched, and the person must be told to correct the secret files.
    events = {
        "login_rejected_latched": gateway_event("login_rejected_latched", T0 - timedelta(seconds=5))
    }
    gateway = {"phase": "needs-human", "last_events": events}
    states = evaluate(gateway=gateway)
    assert states[AlertClass.NEEDS_HUMAN] is ACTIVE
    assert details(gateway=gateway)[AlertClass.NEEDS_HUMAN] == (
        "gateway phase is needs-human: IBKR rejected these credentials at an earlier start; "
        "the gateway will not log in until the secret files are corrected"
    )


def test_the_newest_cause_of_needs_human_wins() -> None:
    # A rejection in this start after a latched one cannot happen (a latched start never logs
    # in), but the reverse order can sit in the feed of one boot when events are replayed;
    # the newest event names the cause.
    events = {
        "login_rejected_latched": gateway_event(
            "login_rejected_latched", T0 - timedelta(seconds=30)
        ),
        "login_failed_dialog": gateway_event("login_failed_dialog", T0 - timedelta(seconds=5)),
    }
    gateway = {"phase": "needs-human", "last_events": events}
    assert details(gateway=gateway)[AlertClass.NEEDS_HUMAN] == (
        "gateway phase is needs-human: IBKR rejected the login"
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


def test_a_requested_shutdown_is_announced_as_information_not_as_an_exit() -> None:
    events = {"shutdown_requested": gateway_event("shutdown_requested", T0 - timedelta(seconds=9))}
    for phase in ("stopping", "stopped"):
        states = evaluate(gateway={"phase": phase, "last_events": events})
        assert states[AlertClass.GATEWAY_STOPPED] is ACTIVE, phase
        assert states[AlertClass.GATEWAY_EXITED] is INACTIVE, phase
    assert evaluate()[AlertClass.GATEWAY_STOPPED] is INACTIVE
    assert evaluate(gateway={"phase": None})[AlertClass.GATEWAY_STOPPED] is UNKNOWN


def test_ibc_ending_on_its_own_is_an_unexpected_exit() -> None:
    states = evaluate(gateway={"phase": "exited"})
    assert states[AlertClass.GATEWAY_EXITED] is ACTIVE
    assert states[AlertClass.GATEWAY_STOPPED] is INACTIVE
    assert details(gateway={"phase": "exited"})[AlertClass.GATEWAY_EXITED] == (
        "gateway phase is exited: IBC ended on its own"
    )


def test_a_restart_without_a_requested_shutdown_is_announced_for_fifteen_minutes() -> None:
    # The container was killed and started again: it is running now, but it was down.
    crashed = {
        "phase": "login",
        "last_restart_at": T0 - timedelta(minutes=2),
        "last_restart_unexpected": True,
    }
    assert evaluate(gateway=crashed)[AlertClass.GATEWAY_EXITED] is ACTIVE
    assert details(gateway=crashed)[AlertClass.GATEWAY_EXITED] == (
        "the gateway container restarted without a requested shutdown"
    )
    later = crashed | {"last_restart_at": T0 - timedelta(minutes=16)}
    assert evaluate(gateway=later)[AlertClass.GATEWAY_EXITED] is INACTIVE
    deliberate = crashed | {"last_restart_unexpected": False}
    assert evaluate(gateway=deliberate)[AlertClass.GATEWAY_EXITED] is INACTIVE


def test_a_pending_second_factor_is_handed_over_to_the_stop_alert() -> None:
    result = RuleEngine(RuleConfig()).evaluate(
        gateway_snapshot(T0, **twofa("stopped", twofa_initiated=timedelta(minutes=5))),
        probe_snapshot(T0),
        now=T0,
        mono=1000.0,
    )
    assert result[AlertClass.TWOFA_PENDING].superseded_by is AlertClass.GATEWAY_STOPPED


BLIND = "nothing about the gateway is measured"


def test_a_volume_that_cannot_be_read_becomes_an_alert_after_five_minutes() -> None:
    unmounted = {"phase": None, "volume_present": False}
    early = unmounted | {"unreadable_for_s": 299.0}
    assert evaluate(gateway=early)[AlertClass.VOLUME_MISSING] is UNKNOWN
    late = unmounted | {"unreadable_for_s": 300.0}
    assert evaluate(gateway=late)[AlertClass.VOLUME_MISSING] is ACTIVE
    assert details(gateway=late)[AlertClass.VOLUME_MISSING] == (
        f"the gateway's log volume is not mounted for 300 s; {BLIND}"
    )
    assert evaluate()[AlertClass.VOLUME_MISSING] is INACTIVE


def test_a_missing_phase_file_and_an_unknown_token_are_named_as_such() -> None:
    missing = {"phase": None, "volume_present": True, "unreadable_for_s": 600.0}
    assert details(gateway=missing)[AlertClass.VOLUME_MISSING] == (
        f"the phase file state/phase is missing or unreadable for 600 s; {BLIND}"
    )
    unknown = {"phase": "unknown", "volume_present": True, "unreadable_for_s": 600.0}
    assert evaluate(gateway=unknown)[AlertClass.VOLUME_MISSING] is ACTIVE
    assert details(gateway=unknown)[AlertClass.VOLUME_MISSING] == (
        f"the phase file holds a token this sidecar does not know for 600 s; {BLIND}"
    )


def unhealthy(**fields: object) -> dict[str, object]:
    """A probe that has been unhealthy for ten minutes inside a reset window."""
    return {
        "status": ProbeStatus.DOWN,
        "status_since": T0 - timedelta(minutes=10),
        "last_probe_ok": False,
        "in_reset_window": True,
    } | fields


def test_a_reset_window_excuses_a_lost_ibkr_link() -> None:
    degraded = unhealthy(status=ProbeStatus.DEGRADED, last_probe_ok=True, last_error=None)
    assert evaluate(probe=degraded)[AlertClass.API_UNHEALTHY] is UNKNOWN
    assert evaluate(probe=unhealthy(last_error="timeout"))[AlertClass.API_UNHEALTHY] is UNKNOWN
    outside = degraded | {"in_reset_window": False}
    assert evaluate(probe=outside)[AlertClass.API_UNHEALTHY] is ACTIVE


def test_a_reset_window_never_excuses_a_gateway_that_refuses_the_handshake() -> None:
    # IBKR's reset cuts the link between the Gateway and IBKR. It does not stop the
    # Gateway from accepting API clients: a handshake that fails is a local fault.
    refused = unhealthy(last_error="connect_failed")
    assert evaluate(probe=refused)[AlertClass.API_UNHEALTHY] is ACTIVE
    zombie = unhealthy(last_error="timeout", zombie=True)
    assert evaluate(probe=zombie)[AlertClass.API_UNHEALTHY] is ACTIVE


def skewed(minute: int, skew: float, rtt: float = 0.05) -> dict[str, object]:
    """A successful probe taken ``minute`` minutes after T0 that measured ``skew``."""
    return {
        "clock_skew_s": skew,
        "last_rtt_s": rtt,
        "last_probe_at": T0 + timedelta(minutes=minute),
        "last_probe_ok": True,
    }


def test_a_clock_skew_alerts_only_after_two_consecutive_samples() -> None:
    # One reading proves little: the process may have been paused between sending the
    # request and reading the clock.
    engine = RuleEngine(RuleConfig())
    assert evaluate(engine=engine, probe=skewed(0, 45.0))[AlertClass.CLOCK_SKEW] is UNKNOWN
    # The same sample looked at again is not a second sample.
    assert evaluate(engine=engine, probe=skewed(0, 45.0))[AlertClass.CLOCK_SKEW] is UNKNOWN
    second = engine.evaluate(
        gateway_snapshot(T0), probe_snapshot(T0, **skewed(1, 44.0)), now=T0, mono=1000.0
    )[AlertClass.CLOCK_SKEW]
    assert second.state is ACTIVE
    assert second.detail == "IBKR time minus host time is 44.0 s (2 consecutive probes)"
    assert evaluate(engine=engine, probe=skewed(2, -0.3))[AlertClass.CLOCK_SKEW] is INACTIVE


def test_one_outlier_between_good_samples_never_alerts() -> None:
    engine = RuleEngine(RuleConfig())
    verdicts = [
        evaluate(engine=engine, probe=skewed(minute, skew))[AlertClass.CLOCK_SKEW]
        for minute, skew in enumerate([-0.3, 30.0, -0.2, 30.0, -0.4])
    ]
    assert verdicts == [INACTIVE, UNKNOWN, INACTIVE, UNKNOWN, INACTIVE]


def test_a_failed_probe_is_not_a_clock_sample() -> None:
    engine = RuleEngine(RuleConfig())
    evaluate(engine=engine, probe=skewed(0, 45.0))
    # The probe failed a minute later; the engine still shows the last measured skew.
    failed = skewed(1, 45.0) | {"last_probe_ok": False, "status": ProbeStatus.DOWN}
    assert evaluate(engine=engine, probe=failed)[AlertClass.CLOCK_SKEW] is UNKNOWN
    assert evaluate(engine=engine, probe=skewed(2, 45.0))[AlertClass.CLOCK_SKEW] is ACTIVE
    # Leaving the logged-in phase forgets the measurement and the count.
    assert evaluate(engine=engine, probe={"clock_skew_s": None})[AlertClass.CLOCK_SKEW] is UNKNOWN
    assert evaluate(engine=engine, probe=skewed(9, 45.0))[AlertClass.CLOCK_SKEW] is UNKNOWN


def test_half_the_round_trip_time_is_added_to_the_tolerance() -> None:
    # The skew is measured against the middle of the round trip. When the request and the
    # answer take unequal time, that estimate is off by up to half the round trip.
    slow = RuleEngine(RuleConfig())
    for minute in range(3):
        probe = skewed(minute, 3.2, rtt=4.0)  # provable skew 2.7 s, tolerance 1 + 2 s
        assert evaluate(engine=slow, probe=probe)[AlertClass.CLOCK_SKEW] is INACTIVE
    fast = RuleEngine(RuleConfig())
    evaluate(engine=fast, probe=skewed(0, 3.2))
    assert evaluate(engine=fast, probe=skewed(1, 3.2))[AlertClass.CLOCK_SKEW] is ACTIVE


@pytest.mark.parametrize(
    ("phase", "successor"),
    [
        ("needs-human", AlertClass.NEEDS_HUMAN),
        ("exited", AlertClass.GATEWAY_EXITED),
        ("stopping", AlertClass.GATEWAY_STOPPED),
        ("stopped", AlertClass.GATEWAY_STOPPED),
    ],
)
def test_a_stalled_login_that_ends_without_a_login_is_handed_over_not_resolved(
    phase: str, successor: AlertClass
) -> None:
    # Seen end to end: the gateway was stopped while its login was stalled, and the
    # sidecar said "resolved, no action needed" about the stall.
    result = RuleEngine(RuleConfig()).evaluate(
        gateway_snapshot(T0, phase=phase, pairs={"login_stalled": opened()}),
        probe_snapshot(T0),
        now=T0,
        mono=1000.0,
    )
    verdict = result[AlertClass.LOGIN_STALLED]
    assert verdict.state is INACTIVE
    assert verdict.superseded_by is successor
    assert result[successor].state is ACTIVE


def test_a_stalled_login_that_resumes_is_plainly_resolved() -> None:
    result = RuleEngine(RuleConfig()).evaluate(
        gateway_snapshot(T0, phase="2fa-pending", pairs={"login_stalled": closed()}),
        probe_snapshot(T0),
        now=T0,
        mono=1000.0,
    )
    verdict = result[AlertClass.LOGIN_STALLED]
    assert (verdict.state, verdict.superseded_by) == (INACTIVE, None)
    # A closed pair is over, whatever the phase: no hand-over for a stall that ended earlier.
    stopped = RuleEngine(RuleConfig()).evaluate(
        gateway_snapshot(T0, phase="stopped", pairs={"login_stalled": closed()}),
        probe_snapshot(T0),
        now=T0,
        mono=1000.0,
    )
    assert stopped[AlertClass.LOGIN_STALLED].superseded_by is None
