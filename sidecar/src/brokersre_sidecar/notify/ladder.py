"""De-duplication, delivery tracking and the escalation ladder: which notification is due.

A pure state machine. ``step()`` takes the rule verdicts and the time and returns the
notifications to send; ``record_result()`` is told whether a notification reached at least
one channel. It performs no I/O and reads no clock, so every schedule is testable to the
second. Its state is small, JSON-serialisable and survives a restart of the sidecar through
``export_state`` / ``import_state``.

Rules of the ladder:

* A condition that becomes active is announced at once (``FIRING``) on the primary
  channels, but a class is announced at most once per ``dedup_window_s`` (15 minutes): a
  flapping condition is held back and announced when the window ends, if it is still active.
* **An alert counts as notified only when a channel accepted a message about it.** While
  the condition is active and nothing was delivered, the announcement is sent again with a
  capped back-off (30 s doubling to 5 minutes). The "not yet delivered" state is persisted,
  so a restart announces again instead of forgetting.
* Classes that need a human now (two-factor pending, needs-human) are repeated on the
  escalation channels ``escalate_after_s`` and ``escalate_again_after_s`` after the
  condition BEGAN (the first prompt), whether or not the announcement got through: when the
  primary channel is down, the escalation channel is the one that still can tell someone.
* When a condition clears, ``RESOLVED`` goes to the channels that heard about it. A
  condition nobody was told about clears silently: no "resolved" for an alert that no
  channel ever received.
* **A person who received a message about an episode receives its resolution**, also when
  the condition clears while that message is still out. The episode then ends at once, and
  its resolution is decided when the outstanding results are in: sent if any message of the
  episode was accepted, dropped if none was. Until then nothing new is sent for that class
  (a new episode is held, as by the de-duplication window), so the messages of one class
  never overtake each other: a receiver that keys by class (PagerDuty's ``dedup_key`` is
  instance and class) never gets an older "resolved" after a newer trigger.
* What was in flight when the sidecar stopped is sent again while the condition lasts, and
  counts as possibly received: should the condition clear first, its resolution is sent.
  The state file is written once per evaluation, so after a hard kill it cannot tell a
  message no channel had taken from one a channel accepted a moment before the kill; a
  "resolved" that nobody needed is harmless, an incident that is never closed is not.
* An ``UNKNOWN`` verdict changes nothing (a resolution that is already owed is still sent).
* The optional heartbeat is sent once per local day at or after ``heartbeat_time`` when the
  sidecar can see the gateway, no alert is active and nothing else is being sent.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field, replace
from datetime import datetime, time, timedelta
from typing import Any
from zoneinfo import ZoneInfo

from brokersre_sidecar.backoff import Backoff
from brokersre_sidecar.clock import format_utc, parse_utc
from brokersre_sidecar.model.health import ActiveAlertSnapshot
from brokersre_sidecar.notify.catalog import CATALOG, CONDITION_CLASSES
from brokersre_sidecar.notify.rules import Condition, Evaluation
from brokersre_sidecar.vocab import AlertClass, MessageKind

STATE_SCHEMA = "brokersre.sidecar.notifier-state.v3"
# Written by the sidecar up to 0.2.1: no in-flight marks and no closing episodes. Still read.
_PREVIOUS_SCHEMA = "brokersre.sidecar.notifier-state.v2"
_FIRING_STEP = 0
_LAST_STEP = 2
_STEPS = frozenset({0, 1, 2})


@dataclass(frozen=True, slots=True)
class LadderConfig:
    """Parameters of the ladder.

    Attributes:
        primary_channels: Channels that receive announcements, resolutions and heartbeats.
        escalation_channels: Channels that receive escalations.
        escalate_after_s: Delay from the start of the condition to the first escalation.
        escalate_again_after_s: Delay from the start of the condition to the second one.
        dedup_window_s: Minimum time between two delivered announcements of the same class.
        retry_base_s: Delay before an undelivered notification is sent again.
        retry_cap_s: Longest delay between two attempts of an undelivered notification.
        heartbeat_time: Local time of the daily heartbeat, or None for no heartbeat.
        time_zone: IANA zone ``heartbeat_time`` is expressed in.
        disabled_classes: Alert class names that are never notified.
    """

    primary_channels: tuple[str, ...]
    escalation_channels: tuple[str, ...]
    escalate_after_s: float
    escalate_again_after_s: float
    dedup_window_s: float = 900.0
    retry_base_s: float = 30.0
    retry_cap_s: float = 300.0
    heartbeat_time: time | None = None
    time_zone: str = "Etc/UTC"
    disabled_classes: frozenset[str] = frozenset()


@dataclass(frozen=True, slots=True)
class Moment:
    """What the gateway looked like at one evaluation, kept for a resolution sent later.

    Attributes:
        phase: Gateway phase token, or None when not measured.
        api_status: ``vocab.ProbeStatus`` value.
    """

    phase: str | None
    api_status: str


@dataclass(frozen=True, slots=True)
class Outbound:
    """One notification that is due.

    Attributes:
        kind: Why it is sent.
        alert_class: The class it is about (``HEARTBEAT`` for the heartbeat).
        channels: Names of the channels to send it to.
        detail: The rule's factual detail (empty for resolutions and heartbeats).
        escalation_step: 0 for an announcement, 1 or 2 for an escalation.
        since: When the episode began, or None for a heartbeat. Together with the class and
            the step it identifies the notification for ``record_result``.
        attempt: 1 for the first try, counting up while it stays undelivered.
        superseded_by: For a ``RESOLVED`` that is a hand-over: the class that took over.
        cleared_at: For a late ``RESOLVED`` (its episode cleared while a message about it
            was out): when the condition cleared. None for an immediate one.
        moment: For a late ``RESOLVED``: the gateway's phase and API status at the
            clearing, to render it with instead of the current ones (which may belong to
            the next episode). None when not known (immediate, or not given to ``step``).
        active_again_since: For a late ``RESOLVED``: the start of the episode of the same
            class that is active when it is sent, if any.
    """

    kind: MessageKind
    alert_class: AlertClass
    channels: tuple[str, ...]
    detail: str = ""
    escalation_step: int = 0
    since: datetime | None = None
    attempt: int = 1
    superseded_by: AlertClass | None = None
    cleared_at: datetime | None = None
    moment: Moment | None = None
    active_again_since: datetime | None = None


@dataclass(slots=True)
class _Notice:
    """Delivery state of one notification of an episode (announcement or escalation step).

    Attributes:
        delivered: A channel accepted it.
        in_flight: Sent; no result yet. Never sent again while set.
        uncertain: An attempt's result was lost because the sidecar stopped while it was
            out; it may have reached someone. Does not stop a resend, but makes the
            episode's clearing worth a resolution.
        failed_attempts: Attempts that no channel accepted.
        retry_at: Earliest time of the next attempt after a failure.
    """

    delivered: bool = False
    in_flight: bool = False
    uncertain: bool = False
    failed_attempts: int = 0
    retry_at: datetime | None = None


@dataclass(slots=True)
class _Closing:
    """An episode that ended while some of its messages were still out.

    Lifecycle: kept while ``waiting`` is not empty (the resolution is undecided). Once it is
    empty the next ``step`` removes it, with its resolution if ``heard`` and silently if
    not (``_owed_resolutions`` is the one place that decides).

    Attributes:
        since: When the episode began; with the step it matches a late ``record_result``.
        waiting: Steps (0 = announcement, 1-2 = escalations) whose result is outstanding.
        heard: A channel accepted (or, across a restart, possibly accepted) a message of it.
        escalated: An escalation of it was accepted (or possibly was): the resolution goes
            to the escalation channels too.
        superseded_by: The hand-over class of the verdict that ended it, if any.
        cleared_at: When the condition cleared (the resolution says so).
        moment: Phase and API status at the clearing, or None when not given.
        announced_late: Its announcement was accepted after the clearing, which restarted
            the de-duplication window then; only that lets the episode active when the
            resolution goes out through the hold (``_exempt``).
    """

    since: datetime
    waiting: set[int]
    heard: bool
    escalated: bool
    superseded_by: AlertClass | None
    cleared_at: datetime | None = None
    moment: Moment | None = None
    announced_late: bool = False


@dataclass(slots=True)
class _AlertState:
    """Mutable per-class state: the current episode and the ended ones still to settle.

    Attributes:
        unheld: The current episode is announced without the de-duplication hold, because
            the late resolution of the previous one went out while it was active (that
            resolution must not be the last word while the condition is back).
        exempted_at: When the last episode of this class was made ``unheld``; at most one
            per de-duplication window, so a class that flaps faster than its channels
            answer still stays within the de-duplication rule.
    """

    active: bool = False
    since: datetime | None = None
    delivered: bool = False
    escalated: bool = False
    last_announced: datetime | None = None
    notices: dict[int, _Notice] = field(default_factory=dict)
    closing: list[_Closing] = field(default_factory=list)
    unheld: bool = False
    exempted_at: datetime | None = None

    def clear_episode(self) -> None:
        """End the current episode, keeping the class's timestamps and the closing episodes."""
        self.active = False
        self.since = None
        self.delivered = False
        self.escalated = False
        self.unheld = False
        self.notices = {}

    def waiting_on_earlier(self) -> bool:
        """True while an ended episode of this class still waits for a delivery result."""
        return any(closing.waiting for closing in self.closing)


@dataclass(slots=True)
class _State:
    """Everything the ladder remembers."""

    classes: dict[AlertClass, _AlertState] = field(default_factory=dict)
    heartbeat_date: str | None = None


class LadderEngine:
    """The ladder state machine.

    Single-threaded; ``step`` must be called with a non-decreasing ``now``.
    """

    def __init__(self, config: LadderConfig) -> None:
        """Create an engine with empty state."""
        self._config = config
        self._zone = ZoneInfo(config.time_zone)
        self._retry = Backoff(base_s=config.retry_base_s, cap_s=config.retry_cap_s, jitter=0.0)
        self._state = _State()
        self.dirty = False
        """True when the state changed since the last ``export_state`` (needs saving)."""

    def step(
        self,
        evaluations: Mapping[AlertClass, Evaluation],
        now: datetime,
        *,
        can_see: bool = True,
        moment: Moment | None = None,
    ) -> list[Outbound]:
        """Advance the ladder and return the notifications that are due.

        Args:
            evaluations: Verdict per class; a missing class counts as ``UNKNOWN``.
            now: Current time (UTC).
            can_see: Whether the sidecar can see the gateway at all (volume mounted, phase
                known). Without that there is nothing a heartbeat could vouch for.
            moment: The gateway's phase and API status now. Kept with an episode that
                clears while a message about it is out, so that its resolution, sent
                later, tells what the gateway looked like when it cleared.

        Returns:
            Notifications in catalogue order; within a class, owed resolutions of ended
            episodes (oldest first) come before anything about the current one. The
            heartbeat, if due, is the only item. Every ``FIRING`` and ``ESCALATION`` must
            be answered with ``record_result``.
        """
        due: list[Outbound] = []
        for alert in CONDITION_CLASSES:
            if alert.value in self._config.disabled_classes:
                continue
            state = self._state.classes.get(alert)
            owed, moved = (
                self._owed_resolutions(alert, state) if state and state.closing else ([], False)
            )
            evaluation = evaluations.get(alert)
            current: list[Outbound] = []
            if evaluation is not None and evaluation.state is Condition.ACTIVE:
                current = self._on_active(alert, evaluation, now, after_late=moved)
            elif evaluation is not None and evaluation.state is Condition.INACTIVE:
                current = self._on_inactive(alert, evaluation, now, moment)
            elif moved and state is not None and state.active:
                self._exempt(state, now)  # undecidable now, but the episode is still open
            due += self._active_again(alert, owed) + current
        if not due and can_see and self._heartbeat_due(now):
            self._state.heartbeat_date = now.astimezone(self._zone).date().isoformat()
            self.dirty = True
            due.append(
                Outbound(MessageKind.HEARTBEAT, AlertClass.HEARTBEAT, self._config.primary_channels)
            )
        return due

    def record_result(self, outbound: Outbound, *, delivered: bool, now: datetime) -> None:
        """Record whether a ``FIRING`` or ``ESCALATION`` reached at least one channel.

        A result for the current episode updates its delivery state (and schedules a retry
        when nothing was accepted). A result for an episode that ended while the message was
        out decides that episode's resolution (see the module rules). Any other result (a
        duplicate, or one for an episode the state no longer knows) is ignored.

        Args:
            outbound: The notification returned by ``step``.
            delivered: True when at least one channel accepted it.
            now: Current time (UTC).
        """
        state = self._state.classes.get(outbound.alert_class)
        if state is None:
            return
        step = outbound.escalation_step
        # Ended episodes first: while one waits, the current episode sends nothing (see
        # ``_on_active``), so a match here can never be a message of the current episode.
        for closing in state.closing:
            if closing.since != outbound.since or step not in closing.waiting:
                continue
            closing.waiting.discard(step)
            if delivered:
                closing.heard = True
                if step == _FIRING_STEP:
                    # A delivered announcement starts the de-duplication window, late or not.
                    state.last_announced = now
                    closing.announced_late = True
                else:
                    closing.escalated = True
            self.dirty = True
            return
        if state.active and state.since == outbound.since:
            self._record_current(state, outbound, delivered=delivered, now=now)

    def _record_current(
        self, state: _AlertState, outbound: Outbound, *, delivered: bool, now: datetime
    ) -> None:
        """Apply a delivery result to the current episode of ``state``."""
        notice = state.notices.get(outbound.escalation_step)
        if notice is None:
            return
        notice.in_flight = False
        self.dirty = True
        if delivered:
            notice.delivered = True
            notice.retry_at = None
            state.delivered = True
            if outbound.escalation_step == _FIRING_STEP:
                state.last_announced = now
            else:
                state.escalated = True
            return
        notice.failed_attempts += 1
        notice.retry_at = now + timedelta(
            seconds=self._retry.delay(notice.failed_attempts, lambda: 0.5)
        )

    def _attempt(
        self,
        state: _AlertState,
        step: int,
        now: datetime,
        kind: MessageKind,
        alert: AlertClass,
        channels: tuple[str, ...],
        detail: str,
    ) -> list[Outbound]:
        """Emit notice ``step`` when it is not delivered, not in flight and its retry is due."""
        if not channels:
            return []
        notice = state.notices.setdefault(step, _Notice())
        if notice.delivered or notice.in_flight:
            return []
        if notice.retry_at is not None and now < notice.retry_at:
            return []
        notice.in_flight = True
        self.dirty = True
        return [
            Outbound(
                kind,
                alert,
                channels,
                detail=detail,
                escalation_step=step,
                since=state.since,
                attempt=notice.failed_attempts + 1,
            )
        ]

    def _on_active(
        self, alert: AlertClass, evaluation: Evaluation, now: datetime, *, after_late: bool
    ) -> list[Outbound]:
        """Handle an active verdict: open an episode, announce it, climb the ladder.

        Args:
            alert: The class.
            evaluation: Its active verdict (the detail goes into the messages).
            now: Current time (UTC).
            after_late: A late resolution of an earlier episode whose announcement was
                accepted late goes out in this step; this episode is then announced without
                the de-duplication hold (``_exempt``).
        """
        state = self._state.classes.setdefault(alert, _AlertState())
        config = self._config
        if not state.active:
            state.clear_episode()
            state.active = True
            state.since = now
            self.dirty = True
        if after_late:
            self._exempt(state, now)
        if state.waiting_on_earlier():
            # Whether the previous episode gets a resolution is not known yet; a message
            # about this one now could reach a receiver before that resolution does.
            return []
        due: list[Outbound] = []
        if not state.delivered:
            window = timedelta(seconds=config.dedup_window_s)
            held = (
                not state.unheld
                and state.last_announced is not None
                and now - state.last_announced < window
            )
            if not held:
                due += self._attempt(
                    state,
                    _FIRING_STEP,
                    now,
                    MessageKind.FIRING,
                    alert,
                    config.primary_channels,
                    evaluation.detail,
                )
        if CATALOG[alert].ladder and state.since is not None:
            elapsed = (now - state.since).total_seconds()
            reached = 0
            if elapsed >= config.escalate_again_after_s:
                reached = _LAST_STEP
            elif elapsed >= config.escalate_after_s:
                reached = 1
            if reached:
                # Only the latest step is sent: a first step that was missed (the sidecar
                # was down, or it never got through) is superseded by the second.
                due += self._attempt(
                    state,
                    reached,
                    now,
                    MessageKind.ESCALATION,
                    alert,
                    config.escalation_channels,
                    evaluation.detail,
                )
        return due

    def _exempt(self, state: _AlertState, now: datetime) -> None:
        """Let the open episode through the de-duplication hold, once per window.

        Called when a late resolution of an earlier episode goes out while this one is
        active and that episode's announcement was accepted late, after the clearing: that
        acceptance restarted the window, so without this the new episode would wait up to
        15 minutes behind a "resolved" that is already untrue (and PagerDuty would hold no
        open incident). A late escalation result alone moves no window and lets nothing
        through. At most one episode per window is let through: a class that flaps faster
        than its channels answer still sends no more than one extra announcement per
        window.
        """
        if state.unheld or not state.active:
            return
        window = timedelta(seconds=self._config.dedup_window_s)
        if state.exempted_at is not None and now - state.exempted_at < window:
            return
        state.unheld = True
        state.exempted_at = now
        self.dirty = True

    def _active_again(self, alert: AlertClass, owed: list[Outbound]) -> list[Outbound]:
        """Mark late resolutions with the start of the episode of their class now active."""
        state = self._state.classes.get(alert)
        if not owed or state is None or not state.active or state.since is None:
            return owed
        return [replace(item, active_again_since=state.since) for item in owed]

    def _on_inactive(
        self, alert: AlertClass, evaluation: Evaluation, now: datetime, moment: Moment | None
    ) -> list[Outbound]:
        """Handle an inactive verdict: close the episode and tell whoever heard about it.

        With a message of the episode still out, the decision waits for its result (the
        episode is kept as a ``_Closing``, with the time and ``moment`` of the clearing);
        otherwise it is made now.
        """
        state = self._state.classes.get(alert)
        if state is None or not state.active or state.since is None:
            return []
        uncertain = {step for step, notice in state.notices.items() if notice.uncertain}
        heard = state.delivered or bool(uncertain)
        escalated = state.escalated or any(step != _FIRING_STEP for step in uncertain)
        waiting = {step for step, notice in state.notices.items() if notice.in_flight}
        due: list[Outbound] = []
        if waiting:
            state.closing.append(
                _Closing(
                    state.since,
                    waiting,
                    heard,
                    escalated,
                    evaluation.superseded_by,
                    cleared_at=now,
                    moment=moment,
                )
            )
        elif heard:
            due.append(self._resolution(alert, state.since, escalated, evaluation.superseded_by))
        state.clear_episode()
        self.dirty = True
        return due

    def _owed_resolutions(
        self, alert: AlertClass, state: _AlertState
    ) -> tuple[list[Outbound], bool]:
        """Settle the ended episodes whose results are all in.

        Returns:
            Their resolutions, oldest first (none for an episode nobody heard), and whether
            one of them had its announcement accepted late, which restarted the
            de-duplication window after the clearing.
        """
        settled = sorted(
            (closing for closing in state.closing if not closing.waiting),
            key=lambda closing: closing.since,
        )
        if not settled:
            return [], False
        state.closing = [closing for closing in state.closing if closing.waiting]
        self.dirty = True
        heard = [closing for closing in settled if closing.heard]
        resolutions = [
            self._resolution(
                alert,
                closing.since,
                closing.escalated,
                closing.superseded_by,
                cleared_at=closing.cleared_at,
                moment=closing.moment,
            )
            for closing in heard
        ]
        return resolutions, any(closing.announced_late for closing in heard)

    def _resolution(
        self,
        alert: AlertClass,
        since: datetime,
        escalated: bool,
        superseded_by: AlertClass | None,
        *,
        cleared_at: datetime | None = None,
        moment: Moment | None = None,
    ) -> Outbound:
        """Build the ``RESOLVED`` for one episode: primary channels, escalation ones if told.

        ``cleared_at`` and ``moment`` are given for a late resolution only.
        """
        channels = list(self._config.primary_channels)
        if escalated:
            channels += [name for name in self._config.escalation_channels if name not in channels]
        return Outbound(
            MessageKind.RESOLVED,
            alert,
            tuple(channels),
            since=since,
            superseded_by=superseded_by,
            cleared_at=cleared_at,
            moment=moment,
        )

    def _heartbeat_due(self, now: datetime) -> bool:
        """True at or after the heartbeat time on a local day without a heartbeat yet."""
        config = self._config
        if config.heartbeat_time is None or AlertClass.HEARTBEAT.value in config.disabled_classes:
            return False
        if any(state.active for state in self._state.classes.values()):
            return False
        # An ended episode still being settled is "something being sent", unless its class
        # is switched off: then nothing of it is ever sent and it must not block for ever.
        if any(
            state.closing and alert.value not in config.disabled_classes
            for alert, state in self._state.classes.items()
        ):
            return False
        local = now.astimezone(self._zone)
        if local.time() < config.heartbeat_time:
            return False
        return self._state.heartbeat_date != local.date().isoformat()

    def active(self) -> tuple[ActiveAlertSnapshot, ...]:
        """Return the active conditions in catalogue order."""
        listed = []
        for alert in CONDITION_CLASSES:
            state = self._state.classes.get(alert)
            if state is None or not state.active or state.since is None:
                continue
            steps = [step for step, notice in state.notices.items() if notice.delivered and step]
            pending = [notice for notice in state.notices.values() if not notice.delivered]
            listed.append(
                ActiveAlertSnapshot(
                    alert_class=alert.value,
                    severity=CATALOG[alert].severity.value,
                    since=state.since,
                    notified=state.delivered,
                    escalation_step=max(steps, default=0),
                    failed_attempts=max((notice.failed_attempts for notice in pending), default=0),
                )
            )
        return tuple(listed)

    def waiting(self) -> frozenset[tuple[AlertClass, datetime]]:
        """Return the ended episodes whose resolution still waits for a delivery result.

        While one of a class is listed, nothing new is sent for that class (see the
        module rules); each message it waits for holds a channel for at most the
        dispatcher's bound (four tries of 10 s plus back-off, 48.4 s with the defaults)
        times its place in that channel's queue.
        """
        return frozenset(
            (alert, closing.since)
            for alert, state in self._state.classes.items()
            for closing in state.closing
            if closing.waiting
        )

    def export_state(self) -> dict[str, Any]:
        """Return the state as a JSON-serialisable mapping and clear ``dirty``."""
        classes: dict[str, dict[str, Any]] = {}
        for alert, state in self._state.classes.items():
            if (
                not state.active
                and state.last_announced is None
                and state.exempted_at is None
                and not state.closing
            ):
                continue
            classes[alert.value] = {
                "active": state.active,
                "since": format_utc(state.since) if state.since else None,
                "delivered": state.delivered,
                "escalated": state.escalated,
                "unheld": state.unheld,
                "last_announced": (
                    format_utc(state.last_announced) if state.last_announced else None
                ),
                "exempted_at": format_utc(state.exempted_at) if state.exempted_at else None,
                "notices": {
                    str(step): {
                        "delivered": notice.delivered,
                        "failed_attempts": notice.failed_attempts,
                        "in_flight": notice.in_flight,
                        "uncertain": notice.uncertain,
                    }
                    for step, notice in state.notices.items()
                },
                "closing": [
                    {
                        "since": format_utc(closing.since),
                        "waiting": sorted(closing.waiting),
                        "heard": closing.heard,
                        "announced_late": closing.announced_late,
                        "escalated": closing.escalated,
                        "superseded_by": (
                            closing.superseded_by.value if closing.superseded_by else None
                        ),
                        "cleared_at": (
                            format_utc(closing.cleared_at) if closing.cleared_at else None
                        ),
                        "moment": (
                            {
                                "phase": closing.moment.phase,
                                "api_status": closing.moment.api_status,
                            }
                            if closing.moment
                            else None
                        ),
                    }
                    for closing in state.closing
                ],
            }
        self.dirty = False
        return {
            "schema": STATE_SCHEMA,
            "classes": classes,
            "heartbeat_date": self._state.heartbeat_date,
        }

    def import_state(self, data: object) -> None:
        """Load state saved by ``export_state`` (this schema or the previous one, v2).

        Tolerant by design: a file from another schema, a truncated or hand-edited file or
        an entry of an unknown class is ignored (entry by entry) rather than raised. The
        worst outcome of ignoring state is one repeated notification. What was in flight
        when the sidecar stopped never reports back: it is treated as not delivered (it is
        sent again while the condition lasts) and as possibly received (its clearing is
        told). A v2 file carries no in-flight marks, so nothing in it is possibly received.
        """
        if not isinstance(data, dict) or data.get("schema") not in (STATE_SCHEMA, _PREVIOUS_SCHEMA):
            return
        heartbeat_date = data.get("heartbeat_date")
        if isinstance(heartbeat_date, str):
            self._state.heartbeat_date = heartbeat_date
        classes = data.get("classes")
        if not isinstance(classes, dict):
            return
        known = {alert.value: alert for alert in CONDITION_CLASSES}
        for name, raw in classes.items():
            if name not in known or not isinstance(raw, dict):
                continue
            state = _AlertState(
                active=raw.get("active") is True,
                since=parse_utc(raw.get("since")),
                delivered=raw.get("delivered") is True,
                escalated=raw.get("escalated") is True,
                last_announced=parse_utc(raw.get("last_announced")),
                notices=_load_notices(raw.get("notices")),
                closing=_load_closing(raw.get("closing")),
                unheld=raw.get("unheld") is True,
                exempted_at=parse_utc(raw.get("exempted_at")),
            )
            if state.active and state.since is None:
                continue
            self._state.classes[known[name]] = state


def _load_notices(raw: object) -> dict[int, _Notice]:
    """Read the saved per-step delivery state; anything malformed is dropped.

    A notice saved while in flight is loaded as not in flight and uncertain: its result
    went with the stopped process, and it may have reached someone.
    """
    notices: dict[int, _Notice] = {}
    if not isinstance(raw, dict):
        return notices
    for key, value in raw.items():
        if key not in ("0", "1", "2") or not isinstance(value, dict):
            continue
        attempts = value.get("failed_attempts")
        notices[int(key)] = _Notice(
            delivered=value.get("delivered") is True,
            uncertain=value.get("uncertain") is True or value.get("in_flight") is True,
            failed_attempts=(
                attempts if isinstance(attempts, int) and not isinstance(attempts, bool) else 0
            ),
        )
    return notices


def _load_closing(raw: object) -> list[_Closing]:
    """Read the saved ended-but-unsettled episodes; anything malformed is dropped.

    A step that was still waiting when the sidecar stopped never reports back: it counts as
    possibly received, so the episode's resolution is owed and goes out at the next step.
    """
    loaded: list[_Closing] = []
    if not isinstance(raw, list):
        return loaded
    classes = {alert.value: alert for alert in AlertClass}
    for entry in raw:
        if not isinstance(entry, dict):
            continue
        since = parse_utc(entry.get("since"))
        waiting = entry.get("waiting")
        if since is None or not isinstance(waiting, list):
            continue
        lost = _steps(waiting)
        successor = entry.get("superseded_by")
        closing = _Closing(
            since=since,
            waiting=set(),
            heard=entry.get("heard") is True or bool(lost),
            escalated=entry.get("escalated") is True or any(step != _FIRING_STEP for step in lost),
            superseded_by=classes.get(successor) if isinstance(successor, str) else None,
            cleared_at=parse_utc(entry.get("cleared_at")),
            moment=_load_moment(entry.get("moment")),
            announced_late=entry.get("announced_late") is True,
        )
        if closing.heard:
            loaded.append(closing)
    return loaded


def _load_moment(raw: object) -> Moment | None:
    """Read a saved phase and API status; anything malformed is None (shown as current)."""
    if not isinstance(raw, dict):
        return None
    phase = raw.get("phase")
    api_status = raw.get("api_status")
    if not isinstance(api_status, str) or (phase is not None and not isinstance(phase, str)):
        return None
    return Moment(phase=phase, api_status=api_status)


def _steps(raw: object) -> set[int]:
    """Read a saved list of ladder steps (0, 1, 2); anything else is dropped."""
    if not isinstance(raw, list):
        return set()
    return {
        step
        for step in raw
        if isinstance(step, int) and not isinstance(step, bool) and step in _STEPS
    }
