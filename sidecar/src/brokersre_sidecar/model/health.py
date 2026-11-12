"""Immutable snapshots exchanged between subsystems (pure data, no behaviour).

The probe, the notifier and the supervisor each publish a snapshot; the HTTP endpoints, the
metrics renderer and the alert rules read them. Keeping the types here lets those
subsystems stay independent of one another: none imports another, all import the model.

Every text field is drawn from a closed vocabulary or built from numbers; none carries text
read from the gateway.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Literal

from brokersre_sidecar.vocab import ProbeStatus

FarmKind = Literal["market_data", "historical_data", "sec_def"]
FarmCondition = Literal["ok", "broken", "inactive"]
Connectivity = Literal["ok", "lost", "not_measured"]
ProbeError = Literal["connect_failed", "timeout", "disconnected", "client_id_in_use"]


@dataclass(frozen=True, slots=True)
class FarmState:
    """State of one IBKR data farm as last reported through the API.

    Attributes:
        kind: Which service the farm provides.
        name: Farm name (for example ``usfarm``) when the notice carried one that looks
            like an IBKR farm name; otherwise ``other``. Never any other gateway text.
        condition: ``ok`` (2104/2106/2158), ``broken`` (2103/2105/2157) or ``inactive``
            (2107/2108: idle, connects on demand; not a fault).
    """

    kind: FarmKind
    name: str
    condition: FarmCondition


@dataclass(frozen=True, slots=True)
class ProbeSnapshot:
    """Result of the read-only API probe at one instant.

    Attributes:
        status: See ``vocab.ProbeStatus``.
        reason: One line explaining ``status``, built from fixed phrases and numbers.
        status_since: When ``status`` last changed, or None before the first evaluation.
        connectivity: IBKR connectivity as reported by codes 1100/1101/1102 on the current
            API connection; ``not_measured`` without a connection.
        farms: Data farms reported on the current API connection.
        last_probe_at: When the last probe attempt finished, or None.
        last_probe_ok: Outcome of the last attempt, or None before the first.
        last_rtt_s: Duration of the last successful time round trip in seconds, or None.
        last_error: Why the last attempt failed, or None.
        consecutive_failures: Failed attempts since the last success.
        clock_skew_s: IBKR time minus local time in seconds at the last success (IBKR
            reports whole seconds), or None.
        close_wait_sockets: Sockets in CLOSE_WAIT on the API port, or None when not
            measurable.
        zombie: True when half-closed API sockets have persisted and the API does not answer.
        in_reset_window: True inside a reset window of the configured IBKR region (never
            with ``IBKR_REGION=none``), when a disconnect is
            normal.
    """

    status: ProbeStatus
    reason: str
    status_since: datetime | None
    connectivity: Connectivity
    farms: tuple[FarmState, ...]
    last_probe_at: datetime | None
    last_probe_ok: bool | None
    last_rtt_s: float | None
    last_error: ProbeError | None
    consecutive_failures: int
    clock_skew_s: float | None
    close_wait_sockets: int | None
    zombie: bool
    in_reset_window: bool


@dataclass(frozen=True, slots=True)
class ChannelSnapshot:
    """Delivery statistics of one notification channel.

    Attributes:
        name: Channel name (``vocab.ChannelName``).
        sent_total: Messages delivered.
        failures_total: Messages given up on after all retries.
        dropped_total: Messages discarded because the channel's outbox was full.
        queue_depth: Messages waiting in the outbox.
        last_success_at: Time of the last delivery, or None.
        last_failure_at: Time of the last failed message, or None.
        last_error: Short failure category (for example ``http_503`` or ``timeout``); never
            a URL or a response body.
    """

    name: str
    sent_total: int
    failures_total: int
    dropped_total: int
    queue_depth: int
    last_success_at: datetime | None
    last_failure_at: datetime | None
    last_error: str | None


@dataclass(frozen=True, slots=True)
class ActiveAlertSnapshot:
    """One alert condition that is currently active.

    Attributes:
        alert_class: ``vocab.AlertClass`` value.
        severity: ``vocab.Severity`` value.
        since: When the condition was first seen active.
        notified: True when at least one channel accepted a notification of this
            episode (False while it is held back by de-duplication, while no channel
            has accepted it yet, and when no channel is configured).
        escalation_step: Highest escalation delivered for this episode (0-2).
        failed_attempts: Attempts of the pending notification that no channel accepted;
            it is sent again with a capped back-off while this is above zero.
    """

    alert_class: str
    severity: str
    since: datetime
    notified: bool
    escalation_step: int
    failed_attempts: int = 0


@dataclass(frozen=True, slots=True)
class NotifierSnapshot:
    """State of the notifier for ``/status`` and ``/metrics``.

    Attributes:
        enabled: False when no channel is configured (the notifier does not run).
        channels: Per-channel statistics.
        active_alerts: Conditions currently active.
        state_persistence: ``file`` when de-duplication state survives a restart, ``memory``
            when the state directory is not writable, ``disabled`` when the notifier is off.
        state_persistence_reason: Why persistence is ``memory``, or None.
    """

    enabled: bool
    channels: tuple[ChannelSnapshot, ...]
    active_alerts: tuple[ActiveAlertSnapshot, ...]
    state_persistence: Literal["file", "memory", "disabled"]
    state_persistence_reason: str | None


@dataclass(frozen=True, slots=True)
class TaskSnapshot:
    """Supervision record of one background task.

    Attributes:
        name: Task name (``follow``, ``probe``, ``notify``, ``http``).
        state: ``running`` or ``backoff`` (crashed, waiting to be restarted).
        restarts: Times the task was restarted after a crash.
        last_error: Exception class name of the last crash, or None.
        last_crash_at: When it last crashed, or None.
        progress_age_s: Seconds since the task last completed a step of its loop (since
            the supervisor started, before the first step). None for a task that
            reports no progress (it serves requests or waits for a queue) and before
            the supervisor runs.
        stalled: True when ``progress_age_s`` is beyond the task's limit.
    """

    name: str
    state: Literal["running", "backoff", "stopped"]
    restarts: int
    last_error: str | None
    last_crash_at: datetime | None
    progress_age_s: float | None = None
    stalled: bool = False
