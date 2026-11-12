"""The escalation ladder, de-duplication and delivery tracking (pure state machine, no I/O)."""

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


def at(seconds: float) -> datetime:
    return T0 + timedelta(seconds=seconds)


def run(
    engine: LadderEngine,
    verdicts: dict[AlertClass, Evaluation],
    second: float,
    *,
    delivered: bool = True,
    can_see: bool = True,
) -> list[Outbound]:
    """Step the ladder and answer every notification with the same delivery outcome."""
    due = engine.step(verdicts, at(second), can_see=can_see)
    for item in due:
        if item.kind in (MessageKind.FIRING, MessageKind.ESCALATION):
            engine.record_result(item, delivered=delivered, now=at(second))
    return due


def kinds(outbound: list[Outbound]) -> list[tuple[str, str]]:
    return [(item.alert_class.value, item.kind.value) for item in outbound]


def test_a_new_condition_is_notified_at_once_on_the_primary_channels() -> None:
    engine = ladder()
    (first,) = run(engine, {AlertClass.LOGIN_FAILED: ACTIVE}, 0)
    assert (first.kind, first.alert_class, first.channels) == (
        MessageKind.FIRING,
        AlertClass.LOGIN_FAILED,
        PRIMARY,
    )
    assert first.detail == "detail"
    assert first.since == at(0)
    assert first.attempt == 1
    assert run(engine, {AlertClass.LOGIN_FAILED: ACTIVE}, 1) == []
    assert engine.active()[0].notified is True


def test_two_factor_pending_escalates_at_600_and_1800_seconds_then_stays_quiet() -> None:
    engine = ladder()
    sent: list[tuple[int, Outbound]] = []
    for second in range(0, 7200, 10):
        for item in run(engine, {AlertClass.TWOFA_PENDING: ACTIVE}, second):
            sent.append((second, item))
    assert [(second, item.kind, item.escalation_step, item.channels) for second, item in sent] == [
        (0, MessageKind.FIRING, 0, PRIMARY),
        (600, MessageKind.ESCALATION, 1, ESCALATION),
        (1800, MessageKind.ESCALATION, 2, ESCALATION),
    ]


def test_the_ladder_stops_when_the_condition_resolves_and_everyone_who_heard_is_told() -> None:
    engine = ladder()
    run(engine, {AlertClass.NEEDS_HUMAN: ACTIVE}, 0)
    run(engine, {AlertClass.NEEDS_HUMAN: ACTIVE}, 600)
    (resolved,) = run(engine, {AlertClass.NEEDS_HUMAN: INACTIVE}, 700)
    assert resolved.kind is MessageKind.RESOLVED
    assert resolved.channels == ("teams", "pagerduty", "telegram")
    assert run(engine, {AlertClass.NEEDS_HUMAN: INACTIVE}, 1800) == []
    assert engine.active() == ()


def test_a_resolution_before_any_escalation_goes_to_the_primary_channels_only() -> None:
    engine = ladder()
    run(engine, {AlertClass.TWOFA_PENDING: ACTIVE}, 0)
    (resolved,) = run(engine, {AlertClass.TWOFA_PENDING: INACTIVE}, 60)
    assert resolved.channels == PRIMARY


def test_classes_without_a_ladder_are_never_escalated() -> None:
    engine = ladder()
    sent: list[Outbound] = []
    for second in range(0, 7200, 60):
        sent += run(engine, {AlertClass.API_UNHEALTHY: ACTIVE}, second)
    assert kinds(sent) == [("api_unhealthy", "firing")]


def test_a_missed_first_step_sends_only_the_latest_escalation() -> None:
    engine = ladder()
    run(engine, {AlertClass.TWOFA_PENDING: ACTIVE}, 0)
    (late,) = run(engine, {AlertClass.TWOFA_PENDING: ACTIVE}, 2000)
    assert (late.kind, late.escalation_step) == (MessageKind.ESCALATION, 2)
    assert run(engine, {AlertClass.TWOFA_PENDING: ACTIVE}, 2010) == []


def test_a_condition_that_flaps_is_announced_at_most_once_per_fifteen_minutes() -> None:
    engine = ladder()
    assert kinds(run(engine, {AlertClass.LOGIN_FAILED: ACTIVE}, 0)) == [("login_failed", "firing")]
    assert kinds(run(engine, {AlertClass.LOGIN_FAILED: INACTIVE}, 60)) == [
        ("login_failed", "resolved")
    ]
    # Fires again inside the window: held back, and no "resolved" for a silent episode.
    assert run(engine, {AlertClass.LOGIN_FAILED: ACTIVE}, 120) == []
    assert engine.active()[0].notified is False
    assert run(engine, {AlertClass.LOGIN_FAILED: INACTIVE}, 180) == []
    # Still active when the window ends: announced then.
    assert run(engine, {AlertClass.LOGIN_FAILED: ACTIVE}, 240) == []
    assert run(engine, {AlertClass.LOGIN_FAILED: ACTIVE}, 899) == []
    assert kinds(run(engine, {AlertClass.LOGIN_FAILED: ACTIVE}, 900)) == [
        ("login_failed", "firing")
    ]


def test_an_undecidable_verdict_neither_raises_nor_resolves() -> None:
    engine = ladder()
    assert run(engine, {AlertClass.API_UNHEALTHY: UNKNOWN}, 0) == []
    run(engine, {AlertClass.API_UNHEALTHY: ACTIVE}, 10)
    assert run(engine, {AlertClass.API_UNHEALTHY: UNKNOWN}, 20) == []
    assert run(engine, {}, 30) == []
    assert [alert.alert_class for alert in engine.active()] == ["api_unhealthy"]


def test_disabled_classes_are_ignored() -> None:
    engine = ladder(disabled_classes=frozenset({"clock_skew"}))
    assert run(engine, {AlertClass.CLOCK_SKEW: ACTIVE}, 0) == []
    assert engine.active() == ()


def test_an_alert_is_notified_only_once_a_channel_accepted_it() -> None:
    engine = ladder()
    (first,) = run(engine, {AlertClass.API_UNHEALTHY: ACTIVE}, 0, delivered=False)
    assert first.attempt == 1
    alert = engine.active()[0]
    assert (alert.notified, alert.failed_attempts) == (False, 1)
    # Sent again with a capped back-off: 30 s, 60 s, 120 s, 240 s, then every 300 s.
    attempts: list[int] = []
    for second in range(1, 1500):
        for item in run(engine, {AlertClass.API_UNHEALTHY: ACTIVE}, second, delivered=False):
            assert item.kind is MessageKind.FIRING
            attempts.append(second)
    assert attempts == [30, 90, 210, 450, 750, 1050, 1350]
    assert engine.active()[0].failed_attempts == 8
    # A channel finally accepts it.
    (accepted,) = run(engine, {AlertClass.API_UNHEALTHY: ACTIVE}, 1650)
    assert accepted.attempt == 9
    assert engine.active()[0].notified is True
    assert run(engine, {AlertClass.API_UNHEALTHY: ACTIVE}, 5000) == []


def test_nothing_is_sent_again_while_an_attempt_is_still_in_flight() -> None:
    engine = ladder()
    (pending,) = engine.step({AlertClass.API_UNHEALTHY: ACTIVE}, at(0))
    assert engine.step({AlertClass.API_UNHEALTHY: ACTIVE}, at(600)) == []
    engine.record_result(pending, delivered=True, now=at(601))
    assert engine.active()[0].notified is True


def test_an_alert_nobody_received_resolves_silently() -> None:
    engine = ladder()
    run(engine, {AlertClass.TWOFA_PENDING: ACTIVE}, 0, delivered=False)
    assert run(engine, {AlertClass.TWOFA_PENDING: INACTIVE}, 60) == []
    assert engine.active() == ()


def test_the_escalation_channel_is_told_even_when_the_announcement_never_got_through() -> None:
    engine = ladder()
    seen: list[tuple[int, str, tuple[str, ...]]] = []
    for second in range(0, 700, 10):
        due = engine.step({AlertClass.TWOFA_PENDING: ACTIVE}, at(second))
        for item in due:
            reaches_someone = item.kind is MessageKind.ESCALATION
            engine.record_result(item, delivered=reaches_someone, now=at(second))
            seen.append((second, item.kind.value, item.channels))
    assert (600, "escalation", ESCALATION) in seen
    alert = engine.active()[0]
    assert (alert.notified, alert.escalation_step) == (True, 1)
    # Once someone knows, the announcement is not hammered at the dead channel any more.
    assert run(engine, {AlertClass.TWOFA_PENDING: ACTIVE}, 900) == []
    (resolved,) = run(engine, {AlertClass.TWOFA_PENDING: INACTIVE}, 1000)
    assert resolved.channels == ("teams", "pagerduty", "telegram")


def test_a_result_for_an_episode_that_already_ended_is_ignored() -> None:
    engine = ladder()
    (stale,) = engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(0))
    engine.step({AlertClass.LOGIN_FAILED: INACTIVE}, at(5))
    (fresh,) = engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(10))
    engine.record_result(stale, delivered=True, now=at(11))
    assert engine.active()[0].notified is False
    engine.record_result(fresh, delivered=True, now=at(12))
    assert engine.active()[0].notified is True


def test_without_any_channel_alerts_are_tracked_and_nothing_is_emitted() -> None:
    engine = ladder(primary_channels=(), escalation_channels=())
    assert run(engine, {AlertClass.TWOFA_PENDING: ACTIVE}, 0) == []
    assert run(engine, {AlertClass.TWOFA_PENDING: ACTIVE}, 5000) == []
    assert [alert.alert_class for alert in engine.active()] == ["twofa_pending"]
    assert run(engine, {AlertClass.TWOFA_PENDING: INACTIVE}, 6000) == []


def test_delivered_state_survives_a_restart_without_a_duplicate() -> None:
    before = ladder()
    run(before, {AlertClass.TWOFA_PENDING: ACTIVE}, 0)
    saved = json.loads(json.dumps(before.export_state()))
    assert saved["schema"] == "brokersre.sidecar.notifier-state.v2"
    after = ladder()
    after.import_state(saved)
    assert run(after, {AlertClass.TWOFA_PENDING: ACTIVE}, 30) == []
    (escalation,) = run(after, {AlertClass.TWOFA_PENDING: ACTIVE}, 600)
    assert escalation.escalation_step == 1
    (resolved,) = run(after, {AlertClass.TWOFA_PENDING: INACTIVE}, 660)
    assert resolved.kind is MessageKind.RESOLVED


def test_an_undelivered_alert_is_announced_again_after_a_restart_not_resolved() -> None:
    before = ladder()
    run(before, {AlertClass.TWOFA_PENDING: ACTIVE}, 0, delivered=False)
    saved = json.loads(json.dumps(before.export_state()))
    after = ladder()
    after.import_state(saved)
    # The condition is still there: announce it (again), at once.
    (again,) = run(after, {AlertClass.TWOFA_PENDING: ACTIVE}, 40)
    assert (again.kind, again.since, again.attempt) == (MessageKind.FIRING, at(0), 2)
    assert after.active()[0].notified is True

    gone = ladder()
    gone.import_state(saved)
    # The condition cleared while the sidecar was away: nobody heard of it, say nothing.
    assert run(gone, {AlertClass.TWOFA_PENDING: INACTIVE}, 40) == []


def test_an_attempt_in_flight_when_the_sidecar_stopped_counts_as_not_delivered() -> None:
    before = ladder()
    before.step({AlertClass.NEEDS_HUMAN: ACTIVE}, at(0))  # never answered
    after = ladder()
    after.import_state(json.loads(json.dumps(before.export_state())))
    assert kinds(run(after, {AlertClass.NEEDS_HUMAN: ACTIVE}, 5)) == [("needs_human", "firing")]


def test_the_dirty_flag_tracks_changes_that_need_saving() -> None:
    engine = ladder()
    seen = [engine.dirty]
    (item,) = engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(0))
    seen.append(engine.dirty)
    engine.export_state()
    seen.append(engine.dirty)
    engine.record_result(item, delivered=True, now=at(1))
    seen.append(engine.dirty)
    engine.export_state()
    engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(2))
    seen.append(engine.dirty)
    assert seen == [False, True, False, True, False]


def test_corrupt_or_foreign_saved_state_is_ignored() -> None:
    schema = "brokersre.sidecar.notifier-state.v2"
    cases: tuple[object, ...] = (
        None,
        [],
        "text",
        {"schema": "brokersre.sidecar.notifier-state.v1", "classes": {}},
        {"schema": schema, "classes": {"login_failed": "x"}},
        {
            "schema": schema,
            "classes": {
                "login_failed": {"active": True, "since": "not a time"},
                "made_up": {},
            },
            "heartbeat_date": 5,
        },
        {
            "schema": schema,
            "classes": {
                "login_failed": {
                    "active": False,
                    "notices": {"7": {}, "0": "x", "1": {"failed_attempts": "many"}},
                }
            },
        },
    )
    for garbage in cases:
        engine = ladder()
        engine.import_state(garbage)
        assert kinds(run(engine, {AlertClass.LOGIN_FAILED: ACTIVE}, 0)) == [
            ("login_failed", "firing")
        ]


def test_active_alerts_are_listed_with_severity_and_progress() -> None:
    engine = ladder()
    both = {AlertClass.TWOFA_PENDING: ACTIVE, AlertClass.DISK_LOW: ACTIVE}
    run(engine, both, 0)
    run(engine, both, 600)
    listed = {alert.alert_class: alert for alert in engine.active()}
    assert listed["twofa_pending"].severity == "critical"
    assert listed["twofa_pending"].escalation_step == 1
    assert listed["twofa_pending"].since == at(0)
    assert listed["disk_low"].severity == "warning"
    assert listed["disk_low"].notified is True
    assert listed["disk_low"].failed_attempts == 0


def test_the_heartbeat_is_sent_once_a_day_at_the_local_time_when_nothing_is_active() -> None:
    # T0 is 15:00 UTC = 23:00 in Singapore.
    engine = ladder(heartbeat_time=time(23, 30), time_zone="Asia/Singapore")
    assert run(engine, {}, 0) == []
    (beat,) = run(engine, {}, 30 * 60)
    assert (beat.kind, beat.alert_class, beat.channels) == (
        MessageKind.HEARTBEAT,
        AlertClass.HEARTBEAT,
        PRIMARY,
    )
    assert run(engine, {}, 31 * 60) == []
    # Next local day, 23:30 again.
    assert run(engine, {}, 24 * 3600 + 29 * 60) == []
    assert kinds(run(engine, {}, 24 * 3600 + 30 * 60)) == [("heartbeat", "heartbeat")]


def test_no_heartbeat_while_an_alert_is_active_but_it_follows_once_things_clear() -> None:
    engine = ladder(heartbeat_time=time(23, 30), time_zone="Asia/Singapore")
    run(engine, {AlertClass.API_UNHEALTHY: ACTIVE}, 0)
    assert run(engine, {AlertClass.API_UNHEALTHY: ACTIVE}, 30 * 60) == []
    cleared = run(engine, {AlertClass.API_UNHEALTHY: INACTIVE}, 40 * 60)
    assert kinds(cleared) == [("api_unhealthy", "resolved")]
    assert kinds(run(engine, {AlertClass.API_UNHEALTHY: INACTIVE}, 41 * 60)) == [
        ("heartbeat", "heartbeat")
    ]


def test_no_heartbeat_while_the_sidecar_cannot_see_the_gateway() -> None:
    # The reviewer's reproduction: a heartbeat said "no alert is active" for three days
    # while the log volume was not even mounted.
    engine = ladder(heartbeat_time=time(0, 0))
    assert run(engine, {}, 0, can_see=False) == []
    assert run(engine, {}, 3 * 86400, can_see=False) == []
    assert kinds(run(engine, {}, 3 * 86400 + 60)) == [("heartbeat", "heartbeat")]


def test_the_heartbeat_is_off_by_default_and_when_disabled_and_survives_a_restart() -> None:
    assert run(ladder(), {}, 0) == []
    disabled = ladder(heartbeat_time=time(0, 0), disabled_classes=frozenset({"heartbeat"}))
    assert run(disabled, {}, 0) == []
    first = ladder(heartbeat_time=time(0, 0))
    assert kinds(run(first, {}, 0)) == [("heartbeat", "heartbeat")]
    second = ladder(heartbeat_time=time(0, 0))
    second.import_state(json.loads(json.dumps(first.export_state())))
    assert run(second, {}, 60) == []


STEP = st.tuples(
    st.floats(min_value=0.0, max_value=1200.0),
    st.sampled_from([Condition.ACTIVE, Condition.INACTIVE, Condition.UNKNOWN]),
    st.booleans(),
)


@settings(max_examples=200)
@given(steps=st.lists(STEP, max_size=60), ladder_class=st.booleans(), restart_at=st.integers(0, 60))
def test_message_volume_is_bounded_for_any_sequence_of_verdicts_and_delivery_outcomes(
    steps: list[tuple[float, Condition, bool]], ladder_class: bool, restart_at: int
) -> None:
    alert = AlertClass.TWOFA_PENDING if ladder_class else AlertClass.API_UNHEALTHY
    engine = ladder()
    now = T0
    delivered_firings: list[datetime] = []
    last_firing_attempt: datetime | None = None
    episode_heard = False  # some message of the current episode reached a channel
    delivered_steps: set[int] = set()
    for index, (delta, state, accept) in enumerate(steps):
        if index == restart_at:
            restarted = ladder()
            restarted.import_state(json.loads(json.dumps(engine.export_state())))
            engine = restarted
            last_firing_attempt = None  # after a restart an undelivered alert is sent at once
        now += timedelta(seconds=delta)
        if state is Condition.INACTIVE and not engine.active():
            episode_heard = False
            delivered_steps = set()
        for item in engine.step({alert: Evaluation(state, "d")}, now):
            assert item.alert_class is alert
            if item.kind is MessageKind.FIRING:
                # Never announced again once someone heard, never within 15 minutes of a
                # delivered announcement, and retries are at least 30 s apart.
                assert not episode_heard
                assert all(now - earlier >= timedelta(seconds=900) for earlier in delivered_firings)
                if last_firing_attempt is not None:
                    assert now - last_firing_attempt >= timedelta(seconds=30)
                last_firing_attempt = now
                engine.record_result(item, delivered=accept, now=now)
                if accept:
                    delivered_firings.append(now)
                    episode_heard = True
            elif item.kind is MessageKind.ESCALATION:
                assert ladder_class
                assert item.escalation_step in (1, 2)
                assert item.escalation_step not in delivered_steps
                engine.record_result(item, delivered=accept, now=now)
                if accept:
                    delivered_steps.add(item.escalation_step)
                    episode_heard = True
            elif item.kind is MessageKind.RESOLVED:
                # A resolution only ever follows a message somebody received.
                assert episode_heard
                assert state is Condition.INACTIVE
                episode_heard = False
                delivered_steps = set()
                last_firing_attempt = None
            else:
                raise AssertionError(f"unexpected kind {item.kind}")
        if state is Condition.INACTIVE:
            episode_heard = False
            delivered_steps = set()
            last_firing_attempt = None
