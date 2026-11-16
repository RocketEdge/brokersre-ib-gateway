"""The escalation ladder, de-duplication and delivery tracking (pure state machine, no I/O)."""

from __future__ import annotations

import json
from datetime import datetime, time, timedelta

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from brokersre_sidecar.clock import format_utc, parse_utc
from brokersre_sidecar.notify import (
    Condition,
    Evaluation,
    LadderConfig,
    LadderEngine,
    Outbound,
)
from brokersre_sidecar.notify.ladder import Moment
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


def test_a_result_that_arrives_after_the_condition_cleared_still_brings_the_resolution() -> None:
    # The incident of 2026-11-16 (sidecar 0.2.1): the announcement reached the webhook at
    # once, the other channel was still failing when the gateway came back, and the late
    # "delivered" was dropped because the episode had ended. Nobody was told it cleared.
    engine = ladder()
    (firing,) = engine.step({AlertClass.GATEWAY_STOPPED: ACTIVE}, at(0))
    assert engine.step({AlertClass.GATEWAY_STOPPED: INACTIVE}, at(5)) == []
    assert engine.active() == ()
    engine.record_result(firing, delivered=True, now=at(9))
    (resolved,) = engine.step({AlertClass.GATEWAY_STOPPED: INACTIVE}, at(10))
    assert (resolved.kind, resolved.alert_class, resolved.channels, resolved.since) == (
        MessageKind.RESOLVED,
        AlertClass.GATEWAY_STOPPED,
        PRIMARY,
        at(0),
    )
    assert engine.step({AlertClass.GATEWAY_STOPPED: INACTIVE}, at(11)) == []


def test_a_late_result_brings_the_resolution_even_while_the_verdict_is_unknown() -> None:
    engine = ladder()
    (firing,) = engine.step({AlertClass.API_UNHEALTHY: ACTIVE}, at(0))
    engine.step({AlertClass.API_UNHEALTHY: INACTIVE}, at(5))
    engine.record_result(firing, delivered=True, now=at(6))
    assert kinds(engine.step({AlertClass.API_UNHEALTHY: UNKNOWN}, at(7))) == [
        ("api_unhealthy", "resolved")
    ]


def test_a_late_failure_after_the_condition_cleared_stays_silent() -> None:
    engine = ladder()
    (firing,) = engine.step({AlertClass.GATEWAY_STOPPED: ACTIVE}, at(0))
    engine.step({AlertClass.GATEWAY_STOPPED: INACTIVE}, at(5))
    engine.record_result(firing, delivered=False, now=at(9))
    assert engine.step({AlertClass.GATEWAY_STOPPED: INACTIVE}, at(10)) == []
    assert engine.step({AlertClass.GATEWAY_STOPPED: INACTIVE}, at(60)) == []


def test_a_second_episode_waits_until_the_first_ones_outcome_is_known() -> None:
    # PagerDuty keys an incident by instance and class, not by episode: a resolution of the
    # first episode queued after the second one's trigger would close the second incident.
    engine = ladder()
    (first,) = engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(0))
    assert engine.step({AlertClass.LOGIN_FAILED: INACTIVE}, at(5)) == []
    assert engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(10)) == []
    assert engine.active()[0].since == at(10)
    engine.record_result(first, delivered=True, now=at(11))
    resolved, second = run(engine, {AlertClass.LOGIN_FAILED: ACTIVE}, 12)
    assert (resolved.kind, resolved.since, resolved.active_again_since) == (
        MessageKind.RESOLVED,
        at(0),
        at(10),
    )
    # Its late resolution must not be the last word while the condition is back: the
    # second episode is announced right after it, not when the window of the first ends.
    assert (second.kind, second.since) == (MessageKind.FIRING, at(10))
    (closing,) = run(engine, {AlertClass.LOGIN_FAILED: INACTIVE}, 20)
    assert (closing.kind, closing.since) == (MessageKind.RESOLVED, at(10))


def test_a_second_episode_is_announced_at_once_when_nobody_heard_of_the_first() -> None:
    engine = ladder()
    (first,) = engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(0))
    engine.step({AlertClass.LOGIN_FAILED: INACTIVE}, at(5))
    assert engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(10)) == []
    engine.record_result(first, delivered=False, now=at(11))
    (second,) = engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(12))
    assert (second.kind, second.since, second.attempt) == (MessageKind.FIRING, at(10), 1)


def test_a_late_result_belongs_to_the_ended_episode_when_the_next_began_that_instant() -> None:
    # While an ended episode waits for a result, the current one sends nothing, so a result
    # that matches the ended one's start and step is always the ended one's.
    engine = ladder()
    (first,) = engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(0))
    engine.step({AlertClass.LOGIN_FAILED: INACTIVE}, at(0))
    assert engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(0)) == []
    engine.record_result(first, delivered=True, now=at(1))
    assert engine.active()[0].notified is False
    assert kinds(engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(2))) == [
        ("login_failed", "resolved"),
        ("login_failed", "firing"),
    ]


def test_a_late_resolution_tells_when_it_cleared_and_what_the_gateway_was_then() -> None:
    # Review of #32 (P5): the resolution was rendered with the facts of the next episode.
    engine = ladder()
    (first,) = engine.step({AlertClass.GATEWAY_STOPPED: ACTIVE}, at(0))
    cleared = Moment(phase="logged-in", api_status="ready")
    assert engine.step({AlertClass.GATEWAY_STOPPED: INACTIVE}, at(3), moment=cleared) == []
    engine.record_result(first, delivered=True, now=at(6))
    (resolved,) = engine.step({AlertClass.GATEWAY_STOPPED: INACTIVE}, at(7))
    assert (resolved.cleared_at, resolved.moment, resolved.active_again_since) == (
        at(3),
        cleared,
        None,
    )


def test_an_immediate_resolution_carries_no_late_facts() -> None:
    engine = ladder()
    run(engine, {AlertClass.GATEWAY_STOPPED: ACTIVE}, 0)
    (resolved,) = engine.step(
        {AlertClass.GATEWAY_STOPPED: INACTIVE}, at(3), moment=Moment("logged-in", "ready")
    )
    assert (resolved.cleared_at, resolved.moment, resolved.active_again_since) == (
        None,
        None,
        None,
    )


def test_a_late_resolution_lets_the_next_episode_through_at_most_once_per_window() -> None:
    # A class that flaps faster than its only channel answers must stay within the
    # de-duplication rule: one announcement after a late resolution, then the window.
    engine = ladder()
    (first,) = engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(0))
    engine.step({AlertClass.LOGIN_FAILED: INACTIVE}, at(1))
    engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(2))
    engine.record_result(first, delivered=True, now=at(3))
    resolved, second = engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(4))
    assert (resolved.kind, second.kind, second.since) == (
        MessageKind.RESOLVED,
        MessageKind.FIRING,
        at(2),
    )
    engine.step({AlertClass.LOGIN_FAILED: INACTIVE}, at(5))  # second still out
    engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(6))
    engine.record_result(second, delivered=True, now=at(7))
    (again,) = engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(8))
    assert (again.kind, again.since, again.active_again_since) == (
        MessageKind.RESOLVED,
        at(2),
        at(6),
    )
    assert run(engine, {AlertClass.LOGIN_FAILED: ACTIVE}, 906) == []  # the window holds it
    (third,) = run(engine, {AlertClass.LOGIN_FAILED: ACTIVE}, 907)
    assert (third.kind, third.since) == (MessageKind.FIRING, at(6))


def test_the_once_per_window_pass_is_not_granted_again_after_a_restart() -> None:
    # Second review of #32 (R3): without exempted_at read back, a restart would allow a
    # second pass inside the same window.
    engine = ladder()
    (first,) = engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(0))
    engine.step({AlertClass.LOGIN_FAILED: INACTIVE}, at(1))
    engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(2))
    engine.record_result(first, delivered=True, now=at(3))
    _, second = engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(4))  # the pass, used
    engine.step({AlertClass.LOGIN_FAILED: INACTIVE}, at(5))  # second still out
    engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(6))
    engine.record_result(second, delivered=True, now=at(7))
    after = ladder()
    after.import_state(json.loads(json.dumps(engine.export_state())))
    assert kinds(after.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(8))) == [
        ("login_failed", "resolved")
    ]


def test_an_episode_let_through_is_still_let_through_after_a_restart() -> None:
    # Second review of #32 (R5): without unheld read back, an episode let through but not
    # yet announced (its announcement was refused) would wait up to 15 minutes.
    engine = ladder()
    (first,) = engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(0))
    engine.step({AlertClass.LOGIN_FAILED: INACTIVE}, at(1))
    engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(2))
    engine.record_result(first, delivered=True, now=at(3))
    _, second = engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(4))
    engine.record_result(second, delivered=False, now=at(5))  # refused: to be sent again
    after = ladder()
    after.import_state(json.loads(json.dumps(engine.export_state())))
    (retry,) = after.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(6))
    assert (retry.kind, retry.since, retry.attempt) == (MessageKind.FIRING, at(2), 2)


def test_a_late_resolution_while_the_verdict_is_unknown_still_lets_the_next_through() -> None:
    engine = ladder()
    (first,) = engine.step({AlertClass.API_UNHEALTHY: ACTIVE}, at(0))
    engine.step({AlertClass.API_UNHEALTHY: INACTIVE}, at(1))
    engine.step({AlertClass.API_UNHEALTHY: ACTIVE}, at(2))
    engine.record_result(first, delivered=True, now=at(3))
    (resolved,) = engine.step({AlertClass.API_UNHEALTHY: UNKNOWN}, at(4))
    assert resolved.active_again_since == at(2)
    (second,) = engine.step({AlertClass.API_UNHEALTHY: ACTIVE}, at(5))
    assert (second.kind, second.since) == (MessageKind.FIRING, at(2))


def test_owed_resolutions_go_out_oldest_first() -> None:
    # Two owed resolutions of one class can only come from a saved state (while one waits,
    # the class sends nothing); whatever the file's order, the older episode goes first.
    newer = {"since": "2026-11-12T15:01:00.000Z", "waiting": [], "heard": True}
    older = {"since": "2026-11-12T15:00:00.000Z", "waiting": [], "heard": True}
    engine = ladder()
    engine.import_state(
        {
            "schema": "brokersre.sidecar.notifier-state.v3",
            "classes": {"login_failed": {"active": False, "closing": [newer, older]}},
        }
    )
    first, second = engine.step({AlertClass.LOGIN_FAILED: INACTIVE}, at(120))
    assert (first.since, second.since) == (at(0), at(60))


def test_a_late_resolution_keeps_its_facts_across_a_restart() -> None:
    before = ladder()
    before.step({AlertClass.GATEWAY_STOPPED: ACTIVE}, at(0))
    cleared = Moment(phase="starting", api_status="not_measured")
    before.step({AlertClass.GATEWAY_STOPPED: INACTIVE}, at(3), moment=cleared)
    after = ladder()
    after.import_state(json.loads(json.dumps(before.export_state())))
    (resolved,) = after.step({AlertClass.GATEWAY_STOPPED: INACTIVE}, at(9))
    assert (resolved.cleared_at, resolved.moment) == (at(3), cleared)


def test_a_result_the_ladder_cannot_place_changes_nothing() -> None:
    engine = ladder()
    stray = Outbound(MessageKind.FIRING, AlertClass.DISK_LOW, PRIMARY, since=at(0))
    engine.record_result(stray, delivered=True, now=at(0))  # a class it never saw
    (first,) = engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(0))
    engine.step({AlertClass.LOGIN_FAILED: INACTIVE}, at(5))
    never_sent = Outbound(
        MessageKind.ESCALATION,
        AlertClass.LOGIN_FAILED,
        ESCALATION,
        escalation_step=1,
        since=at(0),
    )
    engine.record_result(never_sent, delivered=True, now=at(6))
    assert engine.step({AlertClass.LOGIN_FAILED: INACTIVE}, at(7)) == []  # still waiting
    engine.record_result(first, delivered=False, now=at(8))
    engine.record_result(first, delivered=True, now=at(9))  # a duplicate, after it settled
    assert engine.step({AlertClass.LOGIN_FAILED: INACTIVE}, at(10)) == []
    (again,) = engine.step({AlertClass.LOGIN_FAILED: ACTIVE}, at(20))
    other_step = Outbound(
        MessageKind.ESCALATION,
        AlertClass.LOGIN_FAILED,
        ESCALATION,
        escalation_step=2,
        since=again.since,
    )
    engine.record_result(other_step, delivered=True, now=at(21))
    assert engine.active()[0].notified is False


def test_an_escalation_in_flight_when_the_condition_clears_gets_its_resolution_too() -> None:
    # The announcement was delivered long ago; the escalation to PagerDuty is still out when
    # the second factor is approved. The pager must not keep an open incident.
    engine = ladder()
    run(engine, {AlertClass.TWOFA_PENDING: ACTIVE}, 0)
    (escalation,) = engine.step({AlertClass.TWOFA_PENDING: ACTIVE}, at(600))
    assert engine.step({AlertClass.TWOFA_PENDING: INACTIVE}, at(601)) == []
    engine.record_result(escalation, delivered=True, now=at(602))
    (resolved,) = engine.step({AlertClass.TWOFA_PENDING: INACTIVE}, at(603))
    assert resolved.channels == ("teams", "pagerduty", "telegram")
    assert resolved.since == at(0)


def test_an_escalation_that_fails_after_the_condition_cleared_resolves_the_primary_only() -> None:
    engine = ladder()
    run(engine, {AlertClass.TWOFA_PENDING: ACTIVE}, 0)
    (escalation,) = engine.step({AlertClass.TWOFA_PENDING: ACTIVE}, at(600))
    engine.step({AlertClass.TWOFA_PENDING: INACTIVE}, at(601))
    engine.record_result(escalation, delivered=False, now=at(602))
    (resolved,) = engine.step({AlertClass.TWOFA_PENDING: INACTIVE}, at(603))
    assert resolved.channels == PRIMARY


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
    assert saved["schema"] == "brokersre.sidecar.notifier-state.v3"
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


def test_a_hand_over_keeps_its_successor_on_the_immediate_path() -> None:
    engine = ladder()
    run(engine, {AlertClass.LOGIN_STALLED: ACTIVE}, 0)
    handed_over = Evaluation(Condition.INACTIVE, superseded_by=AlertClass.GATEWAY_STOPPED)
    (closing,) = run(engine, {AlertClass.LOGIN_STALLED: handed_over}, 5)
    assert (closing.kind, closing.superseded_by) == (
        MessageKind.RESOLVED,
        AlertClass.GATEWAY_STOPPED,
    )


def test_a_late_resolution_keeps_its_hand_over() -> None:
    engine = ladder()
    (firing,) = engine.step({AlertClass.LOGIN_STALLED: ACTIVE}, at(0))
    handed_over = Evaluation(Condition.INACTIVE, superseded_by=AlertClass.GATEWAY_STOPPED)
    assert engine.step({AlertClass.LOGIN_STALLED: handed_over}, at(5)) == []
    engine.record_result(firing, delivered=True, now=at(6))
    (resolved,) = engine.step({AlertClass.LOGIN_STALLED: INACTIVE}, at(7))
    assert resolved.superseded_by is AlertClass.GATEWAY_STOPPED


def test_an_earlier_escalation_still_resolves_the_pager_when_an_announcement_retry_is_out() -> None:
    engine = ladder()
    (firing,) = engine.step({AlertClass.TWOFA_PENDING: ACTIVE}, at(0))
    engine.record_result(firing, delivered=False, now=at(1))
    retry, escalation = engine.step({AlertClass.TWOFA_PENDING: ACTIVE}, at(600))
    assert [(retry.kind, retry.attempt), (escalation.kind, escalation.attempt)] == [
        (MessageKind.FIRING, 2),
        (MessageKind.ESCALATION, 1),
    ]
    engine.record_result(escalation, delivered=True, now=at(601))  # the pager opened one
    assert engine.step({AlertClass.TWOFA_PENDING: INACTIVE}, at(602)) == []  # retry still out
    engine.record_result(retry, delivered=False, now=at(603))
    (resolved,) = engine.step({AlertClass.TWOFA_PENDING: INACTIVE}, at(604))
    assert resolved.channels == ("teams", "pagerduty", "telegram")


def test_an_escalation_out_when_the_sidecar_stopped_is_resolved_on_the_pager_after_restart() -> (
    None
):
    before = ladder()
    run(before, {AlertClass.TWOFA_PENDING: ACTIVE}, 0)
    (escalation,) = before.step({AlertClass.TWOFA_PENDING: ACTIVE}, at(600))
    assert escalation.kind is MessageKind.ESCALATION  # out when the sidecar stops
    after = ladder()
    after.import_state(json.loads(json.dumps(before.export_state())))
    (resolved,) = run(after, {AlertClass.TWOFA_PENDING: INACTIVE}, 605)
    assert resolved.channels == ("teams", "pagerduty", "telegram")


def test_a_clearing_waiting_on_an_escalation_resolves_the_pager_after_restart() -> None:
    before = ladder()
    run(before, {AlertClass.TWOFA_PENDING: ACTIVE}, 0)
    before.step({AlertClass.TWOFA_PENDING: ACTIVE}, at(600))
    assert before.step({AlertClass.TWOFA_PENDING: INACTIVE}, at(601)) == []
    after = ladder()
    after.import_state(json.loads(json.dumps(before.export_state())))
    (resolved,) = run(after, {AlertClass.TWOFA_PENDING: INACTIVE}, 605)
    assert resolved.channels == ("teams", "pagerduty", "telegram")


def test_an_announcement_in_flight_when_the_sidecar_stopped_is_resolved_if_it_cleared() -> None:
    # Whether it reached anyone is unknown after a restart: the file cannot tell a message
    # no channel had taken from one accepted a moment before a kill (round 2 of the review
    # of #32 showed what the distinction cost). A "resolved" that nobody needed is
    # harmless; an open incident is not.
    before = ladder()
    before.step({AlertClass.GATEWAY_STOPPED: ACTIVE}, at(0))  # never answered
    saved = json.loads(json.dumps(before.export_state()))
    assert saved["schema"] == "brokersre.sidecar.notifier-state.v3"
    after = ladder()
    after.import_state(saved)
    (resolved,) = run(after, {AlertClass.GATEWAY_STOPPED: INACTIVE}, 5)
    assert (resolved.kind, resolved.since) == (MessageKind.RESOLVED, at(0))


def test_an_escalation_accepted_just_before_a_hard_kill_is_resolved_on_the_pager() -> None:
    # Review of #32, round 2 (B2): PagerDuty accepted the escalation after the evaluation
    # that sent it had saved, then the process was killed. The incident must be resolved.
    engine = ladder()
    run(engine, {AlertClass.TWOFA_PENDING: ACTIVE}, 0)
    (escalation,) = engine.step({AlertClass.TWOFA_PENDING: ACTIVE}, at(600))
    saved = json.loads(json.dumps(engine.export_state()))  # what that evaluation wrote
    engine.record_result(escalation, delivered=True, now=at(600.3))  # accepted, then killed
    after = ladder()
    after.import_state(saved)
    (resolved,) = run(after, {AlertClass.TWOFA_PENDING: INACTIVE}, 700)
    assert resolved.channels == ("teams", "pagerduty", "telegram")


def test_a_clearing_still_waiting_for_its_result_is_resolved_after_a_restart() -> None:
    before = ladder()
    before.step({AlertClass.GATEWAY_STOPPED: ACTIVE}, at(0))
    assert before.step({AlertClass.GATEWAY_STOPPED: INACTIVE}, at(5)) == []
    after = ladder()
    after.import_state(json.loads(json.dumps(before.export_state())))
    (resolved,) = run(after, {AlertClass.GATEWAY_STOPPED: INACTIVE}, 10)
    assert (resolved.kind, resolved.since) == (MessageKind.RESOLVED, at(0))
    assert run(after, {AlertClass.GATEWAY_STOPPED: INACTIVE}, 11) == []


def test_state_saved_by_the_previous_version_is_still_read() -> None:
    v2 = {
        "schema": "brokersre.sidecar.notifier-state.v2",
        "classes": {
            "twofa_pending": {
                "active": True,
                "since": "2026-11-16T01:00:00.000Z",
                "delivered": True,
                "escalated": False,
                "last_announced": "2026-11-16T01:00:00.000Z",
                "notices": {"0": {"delivered": True, "failed_attempts": 0}},
            }
        },
        "heartbeat_date": None,
    }
    engine = ladder()
    engine.import_state(v2)
    (alert,) = engine.active()
    assert (alert.alert_class, alert.notified) == ("twofa_pending", True)
    assert run(engine, {AlertClass.TWOFA_PENDING: ACTIVE}, 0) == []
    assert kinds(run(engine, {AlertClass.TWOFA_PENDING: INACTIVE}, 1)) == [
        ("twofa_pending", "resolved")
    ]


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


@pytest.mark.parametrize(
    "schema", ["brokersre.sidecar.notifier-state.v2", "brokersre.sidecar.notifier-state.v3"]
)
def test_corrupt_or_foreign_saved_state_is_ignored(schema: str) -> None:
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
                    "closing": [
                        "x",
                        {"since": "not a time", "waiting": [0]},
                        {"since": "2026-11-16T01:00:00.000Z", "waiting": "0"},
                        {"since": "2026-11-16T01:00:00.000Z", "waiting": [True, 7, "1"]},
                    ],
                }
            },
        },
        {"schema": schema, "classes": {"login_failed": {"closing": {"since": 1}}}},
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


def test_no_heartbeat_while_a_cleared_alert_waits_for_its_result_unless_its_class_is_off() -> None:
    engine = ladder(heartbeat_time=time(0, 0))
    (firing,) = engine.step({AlertClass.CLOCK_SKEW: ACTIVE}, at(0))
    engine.step({AlertClass.CLOCK_SKEW: INACTIVE}, at(1))
    assert engine.step({}, at(2)) == []  # its resolution is still undecided
    saved = json.loads(json.dumps(engine.export_state()))
    engine.record_result(firing, delivered=True, now=at(3))
    assert kinds(engine.step({}, at(4))) == [("clock_skew", "resolved")]
    assert kinds(engine.step({}, at(5))) == [("heartbeat", "heartbeat")]
    # Restarted with the class switched off: its owed resolution is never sent, and it must
    # not hold back the heartbeat for ever.
    off = ladder(heartbeat_time=time(0, 0), disabled_classes=frozenset({"clock_skew"}))
    off.import_state(saved)
    assert kinds(off.step({}, at(6))) == [("heartbeat", "heartbeat")]


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


LATE_STEP = st.tuples(
    st.sampled_from(["step", "step", "step", "answer", "answer", "restart"]),
    # At least a millisecond: two episodes never start at the same instant (one evaluation
    # per tick), and the state file keeps episode starts to the millisecond.
    st.floats(min_value=0.001, max_value=1200.0),
    st.sampled_from([Condition.ACTIVE, Condition.INACTIVE, Condition.UNKNOWN]),
    st.integers(min_value=0, max_value=7),
    st.booleans(),
)


@settings(max_examples=400)
@given(ops=st.lists(LATE_STEP, max_size=80), ladder_class=st.booleans())
def test_results_that_come_back_late_never_lose_a_resolution_nor_invent_one(
    ops: list[tuple[str, float, Condition, int, bool]], ladder_class: bool
) -> None:
    """Delivery results arrive late, in any order, or never (a restart loses them).

    A restart resumes from the state saved after the last evaluation, not from the live
    state: results that came back after that save are lost, as with a hard kill. An
    episode is named by its start as the state file and the messages write it
    (``format_utc``, milliseconds): a restart restores it at that resolution.
    """
    alert = AlertClass.TWOFA_PENDING if ladder_class else AlertClass.API_UNHEALTHY
    engine = ladder()
    now = T0
    pending: list[Outbound] = []  # sent, result not reported yet
    heard: set[str] = set()  # episodes with a message a channel accepted
    lost: set[str] = set()  # episodes with a message whose result a restart lost
    resolved: list[str] = []
    announced_at: list[datetime] = []  # when a channel accepted an announcement
    last_since: str | None = None
    let_through: set[str] = set()  # episodes a late resolution found active
    early: set[str] = set()  # episodes announced within 15 minutes of an acceptance
    grants: list[datetime] = []  # when the ladder let an episode through (saved state)

    def episode(item: Outbound) -> str:
        assert item.since is not None
        return format_utc(item.since)

    def note_grant() -> None:
        saved = engine.export_state()["classes"].get(alert.value, {})
        granted = parse_utc(saved.get("exempted_at"))
        if granted is not None and (not grants or granted != grants[-1]):
            # At most one episode per window goes through without the hold.
            assert not grants or granted - grants[-1] >= timedelta(seconds=900)
            grants.append(granted)

    def take(due: list[Outbound]) -> None:
        nonlocal last_since
        for item in due:
            assert item.alert_class is alert
            since = episode(item)
            # One class, one ordered story: nothing about an episode after the next began
            # (PagerDuty would resolve the newer incident with the older "resolved").
            assert last_since is None or since >= last_since
            last_since = since
            assert since not in resolved
            if item.kind is MessageKind.RESOLVED:
                assert since in heard | lost
                assert since not in {format_utc(listed.since) for listed in engine.active()}
                resolved.append(since)
                if item.active_again_since is not None:
                    let_through.add(format_utc(item.active_again_since))
                continue
            if item.kind is MessageKind.FIRING:
                assert not any(out.kind is MessageKind.FIRING for out in pending)
                if not all(now - accepted >= timedelta(seconds=900) for accepted in announced_at):
                    # Inside the window only an episode a late resolution found active.
                    assert since in let_through
                    early.add(since)
            else:
                assert ladder_class
                assert not any(
                    (out.since, out.escalation_step) == (item.since, item.escalation_step)
                    for out in pending
                )
            pending.append(item)

    # The notifier saves once per evaluation, after the step: that is the file a hard kill
    # leaves. Results that came back after it are lost with the process.
    saved = json.loads(json.dumps(engine.export_state()))
    saved_pending: list[Outbound] = []
    saved_announced: list[datetime] = []

    for kind, delta, state, pick, accept in ops:
        if kind == "step":
            now += timedelta(seconds=delta)
            take(engine.step({alert: Evaluation(state, "d")}, now))
            note_grant()
            assert len(early) <= len(grants)
            saved = json.loads(json.dumps(engine.export_state()))
            saved_pending = list(pending)
            saved_announced = list(announced_at)
        elif kind == "answer" and pending:
            item = pending.pop(pick % len(pending))
            engine.record_result(item, delivered=accept, now=now)
            if accept:
                heard.add(episode(item))
                if item.kind is MessageKind.FIRING:
                    announced_at.append(now)
        elif kind == "restart":
            # Whatever the file shows in flight may have reached someone, answered after
            # the save or not; acceptances after the save are unknown to the new process.
            lost.update(episode(item) for item in saved_pending)
            pending.clear()
            announced_at[:] = saved_announced
            restarted = ladder()
            restarted.import_state(saved)
            engine = restarted
    # Every result still out comes back, then the condition clears for good.
    for item in pending:
        engine.record_result(item, delivered=True, now=now)
        heard.add(episode(item))
    pending.clear()
    now += timedelta(seconds=1)
    take(engine.step({alert: INACTIVE}, now))
    assert heard <= set(resolved)
    assert engine.active() == ()
    assert engine.step({alert: INACTIVE}, now + timedelta(seconds=1)) == []
