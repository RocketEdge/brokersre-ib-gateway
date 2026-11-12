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
* An ``UNKNOWN`` verdict changes nothing.
* The optional heartbeat is sent once per local day at or after ``heartbeat_time`` when the
  sidecar can see the gateway, no alert is active and nothing else is being sent.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from datetime import datetime, time, timedelta
from typing import Any
from zoneinfo import ZoneInfo

from brokersre_sidecar.backoff import Backoff
from brokersre_sidecar.clock import format_utc, parse_utc
from brokersre_sidecar.model.health import ActiveAlertSnapshot
from brokersre_sidecar.notify.catalog import CATALOG, CONDITION_CLASSES
from brokersre_sidecar.notify.rules import Condition, Evaluation
from brokersre_sidecar.vocab import AlertClass, MessageKind

STATE_SCHEMA = "brokersre.sidecar.notifier-state.v2"
_FIRING_STEP = 0
_LAST_STEP = 2


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
    """

    kind: MessageKind
    alert_class: AlertClass
    channels: tuple[str, ...]
    detail: str = ""
    escalation_step: int = 0
    since: datetime | None = None
    attempt: int = 1
    superseded_by: AlertClass | None = None


@dataclass(slots=True)
class _Notice:
    """Delivery state of one notification of an episode (announcement or escalation step)."""

    delivered: bool = False
    in_flight: bool = False
    failed_attempts: int = 0
    retry_at: datetime | None = None


@dataclass(slots=True)
class _AlertState:
    """Mutable per-class state (one episode at a time)."""

    active: bool = False
    since: datetime | None = None
    delivered: bool = False
    escalated: bool = False
    last_announced: datetime | None = None
    notices: dict[int, _Notice] = field(default_factory=dict)

    def clear_episode(self) -> None:
        """End the current episode, keeping ``last_announced`` for de-duplication."""
        self.active = False
        self.since = None
        self.delivered = False
        self.escalated = False
        self.notices = {}


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
    ) -> list[Outbound]:
        """Advance the ladder and return the notifications that are due.

        Args:
            evaluations: Verdict per class; a missing class counts as ``UNKNOWN``.
            now: Current time (UTC).
            can_see: Whether the sidecar can see the gateway at all (volume mounted, phase
                known). Without that there is nothing a heartbeat could vouch for.

        Returns:
            Notifications in catalogue order; the heartbeat, if due, is the only item.
            Every ``FIRING`` and ``ESCALATION`` must be answered with ``record_result``.
        """
        due: list[Outbound] = []
        for alert in CONDITION_CLASSES:
            if alert.value in self._config.disabled_classes:
                continue
            evaluation = evaluations.get(alert)
            if evaluation is None or evaluation.state is Condition.UNKNOWN:
                continue
            if evaluation.state is Condition.ACTIVE:
                due += self._on_active(alert, evaluation, now)
            else:
                due += self._on_inactive(alert, evaluation)
        if not due and can_see and self._heartbeat_due(now):
            self._state.heartbeat_date = now.astimezone(self._zone).date().isoformat()
            self.dirty = True
            due.append(
                Outbound(MessageKind.HEARTBEAT, AlertClass.HEARTBEAT, self._config.primary_channels)
            )
        return due

    def record_result(self, outbound: Outbound, *, delivered: bool, now: datetime) -> None:
        """Record whether a ``FIRING`` or ``ESCALATION`` reached at least one channel.

        A result for an episode that has ended meanwhile is ignored.

        Args:
            outbound: The notification returned by ``step``.
            delivered: True when at least one channel accepted it.
            now: Current time (UTC).
        """
        state = self._state.classes.get(outbound.alert_class)
        if state is None or not state.active or state.since != outbound.since:
            return
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
        self, alert: AlertClass, evaluation: Evaluation, now: datetime
    ) -> list[Outbound]:
        """Handle an active verdict: open an episode, announce it, climb the ladder."""
        state = self._state.classes.setdefault(alert, _AlertState())
        config = self._config
        if not state.active:
            state.clear_episode()
            state.active = True
            state.since = now
            self.dirty = True
        due: list[Outbound] = []
        if not state.delivered:
            window = timedelta(seconds=config.dedup_window_s)
            held = state.last_announced is not None and now - state.last_announced < window
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

    def _on_inactive(self, alert: AlertClass, evaluation: Evaluation) -> list[Outbound]:
        """Handle an inactive verdict: close the episode and tell whoever heard about it."""
        state = self._state.classes.get(alert)
        if state is None or not state.active:
            return []
        due: list[Outbound] = []
        if state.delivered:
            channels = list(self._config.primary_channels)
            if state.escalated:
                channels += [
                    name for name in self._config.escalation_channels if name not in channels
                ]
            due.append(
                Outbound(
                    MessageKind.RESOLVED,
                    alert,
                    tuple(channels),
                    since=state.since,
                    superseded_by=evaluation.superseded_by,
                )
            )
        state.clear_episode()
        self.dirty = True
        return due

    def _heartbeat_due(self, now: datetime) -> bool:
        """True at or after the heartbeat time on a local day without a heartbeat yet."""
        config = self._config
        if config.heartbeat_time is None or AlertClass.HEARTBEAT.value in config.disabled_classes:
            return False
        if any(state.active for state in self._state.classes.values()):
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

    def export_state(self) -> dict[str, Any]:
        """Return the state as a JSON-serialisable mapping and clear ``dirty``."""
        classes: dict[str, dict[str, Any]] = {}
        for alert, state in self._state.classes.items():
            if not state.active and state.last_announced is None:
                continue
            classes[alert.value] = {
                "active": state.active,
                "since": format_utc(state.since) if state.since else None,
                "delivered": state.delivered,
                "escalated": state.escalated,
                "last_announced": (
                    format_utc(state.last_announced) if state.last_announced else None
                ),
                "notices": {
                    str(step): {
                        "delivered": notice.delivered,
                        "failed_attempts": notice.failed_attempts,
                    }
                    for step, notice in state.notices.items()
                },
            }
        self.dirty = False
        return {
            "schema": STATE_SCHEMA,
            "classes": classes,
            "heartbeat_date": self._state.heartbeat_date,
        }

    def import_state(self, data: object) -> None:
        """Load state saved by ``export_state``.

        Tolerant by design: a file from another schema, a truncated or hand-edited file or
        an entry of an unknown class is ignored (entry by entry) rather than raised. The
        worst outcome of ignoring state is one repeated notification. What was in flight
        when the sidecar stopped is treated as not delivered: it is sent again.
        """
        if not isinstance(data, dict) or data.get("schema") != STATE_SCHEMA:
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
            )
            if state.active and state.since is None:
                continue
            self._state.classes[known[name]] = state


def _load_notices(raw: object) -> dict[int, _Notice]:
    """Read the saved per-step delivery state; anything malformed is dropped."""
    notices: dict[int, _Notice] = {}
    if not isinstance(raw, dict):
        return notices
    for key, value in raw.items():
        if key not in ("0", "1", "2") or not isinstance(value, dict):
            continue
        attempts = value.get("failed_attempts")
        notices[int(key)] = _Notice(
            delivered=value.get("delivered") is True,
            failed_attempts=(
                attempts if isinstance(attempts, int) and not isinstance(attempts, bool) else 0
            ),
        )
    return notices
