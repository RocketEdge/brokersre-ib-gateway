"""The escalation ladder and de-duplication (pure state machine, no I/O)."""

from __future__ import annotations

import json
from datetime import datetime, time, timedelta

from hypothesis import given, settings
from hypothesis import strategies as st

from brokersre_sidecar.notify import (
    Condition,
    Evaluation,
    LadderConfig,
    LadderEngine,
    Outbound,
)
from brokersre_sidecar.vocab import AlertClass, MessageKind
from testkit import T0

PRIMARY = ("teams",)
ESCALATION = ("pagerduty", "telegram")
ACTIVE = Evaluation(Condition.ACTIVE, "detail")
INACTIVE = Evaluation(Condition.INACTIVE)
UNKNOWN = Evaluation(Condition.UNKNOWN)


def ladder(**overrides: object) -> LadderEngine:
    fields: dict[str, object] = {
        "primary_channels": PRIMARY,
        "escalation_channels": ESCALATION,
        "escalate_after_s": 600.0,
        "escalate_again_after_s": 1800.0,
    }
    fields.update(overrides)
    return LadderEngine(LadderConfig(**fields))  # type: ignore[arg-type]


def kinds(outbound: list[Outbound]) -> list[tuple[str, str]]:
    return [(item.alert_class.value, item.kind.value) for item in outbound]


def at(seconds: float) -> datetime:
    return T0 + timedelta(seconds=seconds)


def test_a_new_condition_is_notified_at_once_on_the_primary_channels() -> None:
    engine = ladder()
    (first,) = engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(0))
    assert (first.kind, first.alert_class, first.channels) == (
        MessageKind.FIRING,
        AlertClass.LOGIN_FAILED,
        PRIMARY,
    )
    assert first.detail == "detail"
    assert first.since == at(0)
    assert engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(1)) == []


def test_two_factor_pending_escalates_at_600_and_1800_seconds_then_stays_quiet() -> None:
    engine = ladder()
    sent: list[tuple[float, Outbound]] = []
    for second in range(0, 7200, 10):
        for item in engine.step({AlertClass.TWOFA_PENDING: ACTIVE}, at(second)):
            sent.append((second, item))
    assert [(second, item.kind, item.escalation_step, item.channels) for second, item in sent] == [
        (0, MessageKind.FIRING, 0, PRIMARY),
        (600, MessageKind.ESCALATION, 1, ESCALATION),
        (1800, MessageKind.ESCALATION, 2, ESCALATION),
    ]


def test_the_ladder_stops_when_the_condition_resolves_and_everyone_who_heard_is_told() -> None:
    engine = ladder()
    engine.step({AlertClass.NEEDS_HUMAN: ACTIVE}, at(0))
    engine.step({AlertClass.NEEDS_HUMAN: ACTIVE}, at(600))
    (resolved,) = engine.step({AlertClass.NEEDS_HUMAN: INACTIVE}, at(700))
    assert resolved.kind is MessageKind.RESOLVED
    assert resolved.channels == ("teams", "pagerduty", "telegram")
    assert engine.step({AlertClass.NEEDS_HUMAN: INACTIVE}, at(1800)) == []
    assert engine.active() == ()


def test_a_resolution_before_any_escalation_goes_to_the_primary_channels_only() -> None:
    engine = ladder()
    engine.step({AlertClass.TWOFA_PENDING: ACTIVE}, at(0))
    (resolved,) = engine.step({AlertClass.TWOFA_PENDING: INACTIVE}, at(60))
    assert resolved.channels == PRIMARY


def test_classes_without_a_ladder_are_never_escalated() -> None:
    engine = ladder()
    sent: list[Outbound] = []
    for second in range(0, 7200, 60):
        sent += engine.step({AlertClass.API_UNHEALTHY: ACTIVE}, at(second))
    assert kinds(sent) == [("api_unhealthy", "firing")]


def test_a_missed_first_step_sends_only_the_latest_escalation() -> None:
    engine = ladder()
    engine.step({AlertClass.TWOFA_PENDING: ACTIVE}, at(0))
    (late,) = engine.step({AlertClass.TWOFA_PENDING: ACTIVE}, at(2000))
    assert (late.kind, late.escalation_step) == (MessageKind.ESCALATION, 2)
    assert engine.step({AlertClass.TWOFA_PENDING: ACTIVE}, at(2010)) == []


def test_a_condition_that_flaps_is_announced_at_most_once_per_fifteen_minutes() -> None:
    engine = ladder()
    assert kinds(engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(0))) == [
        ("login_failed", "firing")
    ]
    assert kinds(engine.step({AlertClass.LOGIN_FAILED: INACTIVE}, at(60))) == [
        ("login_failed", "resolved")
    ]
    # Fires again inside the window: held back, and no "resolved" for a silent episode.
    assert engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(120)) == []
    assert engine.active()[0].notified is False
    assert engine.step({AlertClass.LOGIN_FAILED: INACTIVE}, at(180)) == []
    # Still active when the window ends: announced then.
    assert engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(240)) == []
    assert engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(899)) == []
    assert kinds(engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(900))) == [
        ("login_failed", "firing")
    ]


def test_an_undecidable_verdict_neither_raises_nor_resolves() -> None:
    engine = ladder()
    assert engine.step({AlertClass.API_UNHEALTHY: UNKNOWN}, at(0)) == []
    engine.step({AlertClass.API_UNHEALTHY: ACTIVE}, at(10))
    assert engine.step({AlertClass.API_UNHEALTHY: UNKNOWN}, at(20)) == []
    assert engine.step({}, at(30)) == []
    assert [alert.alert_class for alert in engine.active()] == ["api_unhealthy"]


def test_disabled_classes_are_ignored() -> None:
    engine = ladder(disabled_classes=frozenset({"clock_skew"}))
    assert engine.step({AlertClass.CLOCK_SKEW: ACTIVE}, at(0)) == []
    assert engine.active() == ()


def test_state_survives_a_restart_without_a_duplicate_and_resolves_afterwards() -> None:
    before = ladder()
    before.step({AlertClass.TWOFA_PENDING: ACTIVE}, at(0))
    saved = json.loads(json.dumps(before.export_state()))
    after = ladder()
    after.import_state(saved)
    assert after.step({AlertClass.TWOFA_PENDING: ACTIVE}, at(30)) == []
    (escalation,) = after.step({AlertClass.TWOFA_PENDING: ACTIVE}, at(600))
    assert escalation.escalation_step == 1
    (resolved,) = after.step({AlertClass.TWOFA_PENDING: INACTIVE}, at(660))
    assert resolved.kind is MessageKind.RESOLVED


def test_the_dirty_flag_tracks_changes_that_need_saving() -> None:
    engine = ladder()
    assert engine.dirty is False
    engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(0))
    assert engine.dirty is True
    engine.export_state()
    assert engine.dirty is False
    engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(1))
    assert engine.dirty is False


def test_corrupt_or_foreign_saved_state_is_ignored() -> None:
    for garbage in (
        None,
        [],
        "text",
        {"schema": "something-else"},
        {"schema": "brokersre.sidecar.notifier-state.v1", "classes": {"login_failed": "x"}},
        {
            "schema": "brokersre.sidecar.notifier-state.v1",
            "classes": {"login_failed": {"active": True, "since": "not a time"}, "made_up": {}},
            "heartbeat_date": 5,
        },
    ):
        engine = ladder()
        engine.import_state(garbage)
        assert kinds(engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(0))) == [
            ("login_failed", "firing")
        ]


def test_active_alerts_are_listed_with_severity_and_progress() -> None:
    engine = ladder()
    engine.step({AlertClass.TWOFA_PENDING: ACTIVE, AlertClass.DISK_LOW: ACTIVE}, at(0))
    engine.step({AlertClass.TWOFA_PENDING: ACTIVE, AlertClass.DISK_LOW: ACTIVE}, at(600))
    listed = {alert.alert_class: alert for alert in engine.active()}
    assert listed["twofa_pending"].severity == "critical"
    assert listed["twofa_pending"].escalation_step == 1
    assert listed["twofa_pending"].since == at(0)
    assert listed["disk_low"].severity == "warning"
    assert listed["disk_low"].notified is True


# --- heartbeat ----------------------------------------------------------------------------


def test_the_heartbeat_is_sent_once_a_day_at_the_local_time_when_nothing_is_active() -> None:
    # T0 is 15:00 UTC = 23:00 in Singapore.
    engine = ladder(heartbeat_time=time(23, 30), time_zone="Asia/Singapore")
    assert engine.step({}, at(0)) == []
    (beat,) = engine.step({}, at(30 * 60))
    assert (beat.kind, beat.alert_class, beat.channels) == (
        MessageKind.HEARTBEAT,
        AlertClass.HEARTBEAT,
        PRIMARY,
    )
    assert engine.step({}, at(31 * 60)) == []
    # Next local day, 23:30 again.
    assert engine.step({}, at(24 * 3600 + 29 * 60)) == []
    assert kinds(engine.step({}, at(24 * 3600 + 30 * 60))) == [("heartbeat", "heartbeat")]


def test_no_heartbeat_while_an_alert_is_active_but_it_follows_once_things_clear() -> None:
    engine = ladder(heartbeat_time=time(23, 30), time_zone="Asia/Singapore")
    engine.step({AlertClass.API_UNHEALTHY: ACTIVE}, at(0))
    assert engine.step({AlertClass.API_UNHEALTHY: ACTIVE}, at(30 * 60)) == []
    cleared = engine.step({AlertClass.API_UNHEALTHY: INACTIVE}, at(40 * 60))
    assert kinds(cleared) == [("api_unhealthy", "resolved")]
    assert kinds(engine.step({AlertClass.API_UNHEALTHY: INACTIVE}, at(41 * 60))) == [
        ("heartbeat", "heartbeat")
    ]


def test_the_heartbeat_is_off_by_default_and_when_disabled_and_survives_a_restart() -> None:
    assert ladder().step({}, at(0)) == []
    disabled = ladder(heartbeat_time=time(0, 0), disabled_classes=frozenset({"heartbeat"}))
    assert disabled.step({}, at(0)) == []
    first = ladder(heartbeat_time=time(0, 0))
    assert kinds(first.step({}, at(0))) == [("heartbeat", "heartbeat")]
    second = ladder(heartbeat_time=time(0, 0))
    second.import_state(json.loads(json.dumps(first.export_state())))
    assert second.step({}, at(60)) == []


# --- invariants ---------------------------------------------------------------------------

STEP = st.tuples(
    st.floats(min_value=0.0, max_value=1200.0),
    st.sampled_from([Condition.ACTIVE, Condition.INACTIVE, Condition.UNKNOWN]),
)


@settings(max_examples=300, deadline=None)
@given(steps=st.lists(STEP, max_size=60), ladder_class=st.booleans(), restart_at=st.integers(0, 60))
def test_message_volume_is_bounded_for_any_sequence_of_verdicts(
    steps: list[tuple[float, Condition]], ladder_class: bool, restart_at: int
) -> None:
    alert = AlertClass.TWOFA_PENDING if ladder_class else AlertClass.API_UNHEALTHY
    engine = ladder()
    now = T0
    firing_times: list[datetime] = []
    open_notified_episode = False
    escalations_in_episode = 0
    for index, (delta, state) in enumerate(steps):
        if index == restart_at:
            restarted = ladder()
            restarted.import_state(json.loads(json.dumps(engine.export_state())))
            engine = restarted
        now += timedelta(seconds=delta)
        for item in engine.step({alert: Evaluation(state, "d")}, now):
            assert item.alert_class is alert
            if item.kind is MessageKind.FIRING:
                # At most one announcement per class per 15 minutes.
                assert all(now - earlier >= timedelta(seconds=900) for earlier in firing_times)
                assert not open_notified_episode
                firing_times.append(now)
                open_notified_episode = True
                escalations_in_episode = 0
            elif item.kind is MessageKind.ESCALATION:
                assert ladder_class
                assert open_notified_episode
                escalations_in_episode += 1
                assert escalations_in_episode <= 2
            elif item.kind is MessageKind.RESOLVED:
                # A resolution only ever follows an announcement of the same episode.
                assert open_notified_episode
                assert state is Condition.INACTIVE
                open_notified_episode = False
            else:
                raise AssertionError(f"unexpected kind {item.kind}")
