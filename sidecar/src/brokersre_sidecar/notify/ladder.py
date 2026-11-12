"""De-duplication and the escalation ladder: which notification is due right now.

A pure state machine. ``step()`` takes the rule verdicts and the time and returns the
notifications to send; it performs no I/O and reads no clock, so every schedule is testable
to the second. Its state is small, JSON-serialisable and survives a restart of the sidecar
through ``export_state`` / ``import_state``.

Rules of the ladder:

* A condition that becomes active is announced at once (``FIRING``) on the primary
  channels, but a class is announced at most once per ``dedup_window_s`` (15 minutes): a
  flapping condition is held back and announced when the window ends, if it is still active.
* Classes that need a human now (two-factor pending, needs-human) are repeated on the
  escalation channels ``escalate_after_s`` after the announcement and once more at
  ``escalate_again_after_s``; then the ladder is silent until the condition clears.
* When an announced condition clears, ``RESOLVED`` goes to every channel that heard about
  it. A condition that was never announced resolves silently.
* An ``UNKNOWN`` verdict changes nothing.
* The optional heartbeat is sent once per local day at or after ``heartbeat_time`` when no
  alert is active and nothing else is being sent.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from datetime import datetime, time, timedelta
from typing import Any
from zoneinfo import ZoneInfo

from brokersre_sidecar.clock import format_utc, parse_utc
from brokersre_sidecar.model.health import ActiveAlertSnapshot
from brokersre_sidecar.notify.catalog import CATALOG, CONDITION_CLASSES
from brokersre_sidecar.notify.rules import Condition, Evaluation
from brokersre_sidecar.vocab import AlertClass, MessageKind

STATE_SCHEMA = "brokersre.sidecar.notifier-state.v1"
_MAX_ESCALATIONS = 2


@dataclass(frozen=True, slots=True)
class LadderConfig:
    """Parameters of the ladder.

    Attributes:
        primary_channels: Channels that receive announcements, resolutions and heartbeats.
        escalation_channels: Channels that receive escalations.
        escalate_after_s: Delay from the announcement to the first escalation.
        escalate_again_after_s: Delay from the announcement to the second escalation.
        dedup_window_s: Minimum time between two announcements of the same class.
        heartbeat_time: Local time of the daily heartbeat, or None for no heartbeat.
        time_zone: IANA zone ``heartbeat_time`` is expressed in.
        disabled_classes: Alert class names that are never notified.
    """

    primary_channels: tuple[str, ...]
    escalation_channels: tuple[str, ...]
    escalate_after_s: float
    escalate_again_after_s: float
    dedup_window_s: float = 900.0
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
        since: When the episode began, or None for a heartbeat.
    """

    kind: MessageKind
    alert_class: AlertClass
    channels: tuple[str, ...]
    detail: str = ""
    escalation_step: int = 0
    since: datetime | None = None


@dataclass(slots=True)
class _AlertState:
    """Mutable per-class state (one episode at a time)."""

    active: bool = False
    since: datetime | None = None
    notified: bool = False
    notified_at: datetime | None = None
    last_fired: datetime | None = None
    escalations: int = 0

    def clear_episode(self) -> None:
        """End the current episode, keeping ``last_fired`` for de-duplication."""
        self.active = False
        self.since = None
        self.notified = False
        self.notified_at = None
        self.escalations = 0


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
        self._state = _State()
        self.dirty = False
        """True when the state changed since the last ``export_state`` (needs saving)."""

    def step(self, evaluations: Mapping[AlertClass, Evaluation], now: datetime) -> list[Outbound]:
        """Advance the ladder and return the notifications that are due.

        Args:
            evaluations: Verdict per class; a missing class counts as ``UNKNOWN``.
            now: Current time (UTC).

        Returns:
            Notifications in catalogue order; the heartbeat, if due, is the only item.
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
                due += self._on_inactive(alert)
        if not due and self._heartbeat_due(now):
            self._state.heartbeat_date = now.astimezone(self._zone).date().isoformat()
            self.dirty = True
            due.append(
                Outbound(MessageKind.HEARTBEAT, AlertClass.HEARTBEAT, self._config.primary_channels)
            )
        return due

    def _on_active(
        self, alert: AlertClass, evaluation: Evaluation, now: datetime
    ) -> list[Outbound]:
        """Handle an active verdict: open an episode, announce it, climb the ladder."""
        state = self._state.classes.setdefault(alert, _AlertState())
        config = self._config
        due: list[Outbound] = []
        if not state.active:
            state.active = True
            state.since = now
            state.notified = False
            state.escalations = 0
            self.dirty = True
        if not state.notified:
            window = timedelta(seconds=config.dedup_window_s)
            if state.last_fired is None or now - state.last_fired >= window:
                state.notified = True
                state.notified_at = now
                state.last_fired = now
                self.dirty = True
                due.append(
                    Outbound(
                        MessageKind.FIRING,
                        alert,
                        config.primary_channels,
                        detail=evaluation.detail,
                        since=state.since,
                    )
                )
            return due
        if not CATALOG[alert].ladder or state.notified_at is None:
            return due
        elapsed = (now - state.notified_at).total_seconds()
        reached = 0
        if elapsed >= config.escalate_again_after_s:
            reached = 2
        elif elapsed >= config.escalate_after_s:
            reached = 1
        if reached > state.escalations:
            # One message even when both steps were missed (the sidecar was down).
            state.escalations = reached
            self.dirty = True
            due.append(
                Outbound(
                    MessageKind.ESCALATION,
                    alert,
                    config.escalation_channels,
                    detail=evaluation.detail,
                    escalation_step=reached,
                    since=state.since,
                )
            )
        return due

    def _on_inactive(self, alert: AlertClass) -> list[Outbound]:
        """Handle an inactive verdict: close the episode and tell whoever heard about it."""
        state = self._state.classes.get(alert)
        if state is None or not state.active:
            return []
        due: list[Outbound] = []
        if state.notified:
            channels = list(self._config.primary_channels)
            if state.escalations > 0:
                channels += [
                    name for name in self._config.escalation_channels if name not in channels
                ]
            due.append(Outbound(MessageKind.RESOLVED, alert, tuple(channels), since=state.since))
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
            if state is not None and state.active and state.since is not None:
                listed.append(
                    ActiveAlertSnapshot(
                        alert_class=alert.value,
                        severity=CATALOG[alert].severity.value,
                        since=state.since,
                        notified=state.notified,
                        escalation_step=state.escalations,
                    )
                )
        return tuple(listed)

    def export_state(self) -> dict[str, Any]:
        """Return the state as a JSON-serialisable mapping and clear ``dirty``."""
        classes: dict[str, dict[str, Any]] = {}
        for alert, state in self._state.classes.items():
            if not state.active and state.last_fired is None:
                continue
            classes[alert.value] = {
                "active": state.active,
                "since": format_utc(state.since) if state.since else None,
                "notified": state.notified,
                "notified_at": format_utc(state.notified_at) if state.notified_at else None,
                "last_fired": format_utc(state.last_fired) if state.last_fired else None,
                "escalations": state.escalations,
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
        worst outcome of ignoring state is one repeated notification.
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
                notified=raw.get("notified") is True,
                notified_at=parse_utc(raw.get("notified_at")),
                last_fired=parse_utc(raw.get("last_fired")),
                escalations=_clamp_escalations(raw.get("escalations")),
            )
            if state.active and state.since is None:
                continue
            if state.notified and state.notified_at is None:
                continue
            self._state.classes[known[name]] = state


def _clamp_escalations(value: object) -> int:
    """Return a saved escalation counter as an int in ``[0, 2]`` (0 for anything else)."""
    if isinstance(value, int) and not isinstance(value, bool):
        return max(0, min(_MAX_ESCALATIONS, value))
    return 0
