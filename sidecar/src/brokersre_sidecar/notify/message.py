"""The notification message: one immutable value rendered by every channel.

A message is assembled only from closed vocabularies (class, kind, severity, phase, API
status), the alert catalogue, timestamps, the operator's own instance label and runbook
base, and the rule's numeric detail. As a last line of defence every text field also passes
``redact_text`` (loaded secrets, account ids) before it is stored.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from zoneinfo import ZoneInfo

from brokersre_sidecar.clock import format_utc
from brokersre_sidecar.notify.catalog import CATALOG
from brokersre_sidecar.redaction import SecretRegistry, redact_text
from brokersre_sidecar.vocab import (
    KNOWN_PHASES,
    UNKNOWN_PHASE,
    AlertClass,
    MessageKind,
    ProbeStatus,
    Severity,
)

ALERT_SCHEMA = "brokersre.sidecar.alert.v1"
"""Schema tag of the generic webhook payload."""

_TEST_CLASS = "test"
_API_STATUSES = frozenset(status.value for status in ProbeStatus)


@dataclass(frozen=True, slots=True)
class Message:
    """One notification, ready to render.

    Attributes:
        instance: The operator's label of this gateway (``IBGW_INSTANCE``).
        alert_class: ``vocab.AlertClass`` value, or ``test``.
        kind: ``vocab.MessageKind`` value.
        severity: ``vocab.Severity`` value (``info`` for resolutions, heartbeats and tests).
        phase: Gateway phase token, ``unknown`` or ``not_measured``.
        api_status: ``vocab.ProbeStatus`` value.
        time_utc: When the message was created, ``YYYY-MM-DDTHH:MM:SS.mmmZ``.
        time_local: The same instant in the configured zone, with the zone name.
        since_utc: When the condition began, or None.
        title: Headline without severity and instance.
        instruction: What the human should do.
        detail: Factual detail from the rule (numbers and fixed words), possibly empty.
        runbook: Runbook URL for this class, or None when no base is configured.
        dedup_key: Stable key of the condition (instance and class) for receivers that
            group or resolve by key.
        escalation_step: 0, or 1-2 for an escalation.
    """

    instance: str
    alert_class: str
    kind: str
    severity: str
    phase: str
    api_status: str
    time_utc: str
    time_local: str
    since_utc: str | None
    title: str
    instruction: str
    detail: str
    runbook: str | None
    dedup_key: str
    escalation_step: int

    @property
    def headline(self) -> str:
        """``[SEVERITY] instance: title`` (subject line, card title, push title)."""
        return f"[{self.severity.upper()}] {self.instance}: {self.title}"

    def facts(self) -> list[tuple[str, str]]:
        """Return the labelled facts in display order; optional ones only when present."""
        facts = [
            ("Instance", self.instance),
            ("Class", self.alert_class),
            ("Severity", self.severity),
            ("Phase", self.phase),
            ("API status", self.api_status),
            ("Time (UTC)", self.time_utc),
            ("Time (local)", self.time_local),
        ]
        if self.since_utc is not None:
            facts.append(("Since (UTC)", self.since_utc))
        if self.detail:
            facts.append(("Detail", self.detail))
        return facts

    def body_text(self) -> str:
        """Return the instruction followed by the facts (and the runbook), one per line."""
        lines = [self.instruction, ""]
        lines += [f"{label}: {value}" for label, value in self.facts()]
        if self.runbook is not None:
            lines.append(f"Runbook: {self.runbook}")
        return "\n".join(lines)

    def plain_text(self) -> str:
        """Return the whole message as plain text: headline, blank line, body."""
        return f"{self.headline}\n\n{self.body_text()}"

    def as_dict(self) -> dict[str, object]:
        """Return the generic webhook payload (schema ``brokersre.sidecar.alert.v1``)."""
        return {
            "schema": ALERT_SCHEMA,
            "instance": self.instance,
            "class": self.alert_class,
            "kind": self.kind,
            "severity": self.severity,
            "phase": self.phase,
            "api_status": self.api_status,
            "time_utc": self.time_utc,
            "time_local": self.time_local,
            "since_utc": self.since_utc,
            "title": self.title,
            "instruction": self.instruction,
            "detail": self.detail,
            "runbook": self.runbook,
            "dedup_key": self.dedup_key,
            "escalation_step": self.escalation_step,
        }


class MessageFactory:
    """Builds ``Message`` values for one sidecar instance."""

    def __init__(
        self,
        instance: str,
        time_zone: str,
        runbook_base: str | None,
        registry: SecretRegistry,
    ) -> None:
        """Create the factory.

        Args:
            instance: Validated instance label.
            time_zone: IANA zone for the local time shown in messages.
            runbook_base: Base URL of the operator's runbooks, or None.
            registry: Secrets to scrub from every text field.
        """
        self._instance = instance
        self._zone_name = time_zone
        self._zone = ZoneInfo(time_zone)
        self._runbook_base = runbook_base
        self._registry = registry

    def build(
        self,
        kind: MessageKind,
        alert: AlertClass,
        *,
        detail: str,
        escalation_step: int,
        since: datetime | None,
        phase: str | None,
        api_status: str,
        now: datetime,
    ) -> Message:
        """Build the message for one due notification.

        Args:
            kind: Why the message is sent.
            alert: The alert class it is about.
            detail: The rule's factual detail.
            escalation_step: 0, or the escalation number.
            since: When the condition began.
            phase: Current gateway phase token (None when not measured).
            api_status: Current probe status value.
            now: Creation time (UTC).
        """
        spec = CATALOG[alert]
        title = spec.title
        instruction = spec.instruction
        severity = spec.severity
        if kind is MessageKind.ESCALATION:
            title = f"{spec.title} (still pending, escalation {escalation_step} of 2)"
        elif kind is MessageKind.RESOLVED:
            title = f"Resolved: {spec.title}"
            instruction = "No action needed. The condition has cleared."
            severity = Severity.INFO
        return self._assemble(
            kind=kind,
            alert_class=alert.value,
            severity=severity,
            title=title,
            instruction=instruction,
            detail=detail,
            escalation_step=escalation_step,
            since=since,
            phase=phase,
            api_status=api_status,
            now=now,
        )

    def build_test(self, *, phase: str | None, api_status: str, now: datetime) -> Message:
        """Build the message sent by ``brokersre-sidecar notify test``."""
        return self._assemble(
            kind=MessageKind.TEST,
            alert_class=_TEST_CLASS,
            severity=Severity.INFO,
            title="Test notification",
            instruction="No action needed. This message confirms that this channel works.",
            detail="",
            escalation_step=0,
            since=None,
            phase=phase,
            api_status=api_status,
            now=now,
        )

    def _assemble(
        self,
        *,
        kind: MessageKind,
        alert_class: str,
        severity: Severity,
        title: str,
        instruction: str,
        detail: str,
        escalation_step: int,
        since: datetime | None,
        phase: str | None,
        api_status: str,
        now: datetime,
    ) -> Message:
        """Normalise the vocabulary fields, render the times and scrub the text."""
        if phase is None:
            shown_phase = "not_measured"
        elif phase in KNOWN_PHASES:
            shown_phase = phase
        else:
            shown_phase = UNKNOWN_PHASE
        local = now.astimezone(self._zone)
        runbook = f"{self._runbook_base}/{alert_class}" if self._runbook_base is not None else None
        return Message(
            instance=self._clean(self._instance),
            alert_class=alert_class,
            kind=kind.value,
            severity=severity.value,
            phase=shown_phase,
            api_status=api_status if api_status in _API_STATUSES else "unknown",
            time_utc=format_utc(now),
            time_local=f"{local.strftime('%Y-%m-%d %H:%M:%S %Z')} ({self._zone_name})",
            since_utc=format_utc(since) if since is not None else None,
            title=self._clean(title),
            instruction=self._clean(instruction),
            detail=self._clean(detail),
            runbook=runbook,
            dedup_key=f"brokersre-sidecar:{self._clean(self._instance)}:{alert_class}",
            escalation_step=escalation_step,
        )

    def _clean(self, text: str) -> str:
        """Scrub loaded secrets and account ids from one text field."""
        return redact_text(text, self._registry)
