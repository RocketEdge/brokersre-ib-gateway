"""Closed vocabularies shared by every layer (leaf module).

Everything the sidecar says about the gateway is drawn from these enumerations: phase tokens
of the log contract, probe statuses, alert classes, severities and channel names. Text read
from the gateway (event messages, raw log lines) is never copied into a status document, a
metric label or a notification; a value outside a vocabulary is reported as ``unknown``.
That is what keeps usernames and account ids out of every output by construction.
"""

from __future__ import annotations

from enum import StrEnum


class Phase(StrEnum):
    """Lifecycle phase tokens written by the gateway to ``state/phase`` (log contract v2)."""

    STARTING = "starting"
    LOGIN = "login"
    TWOFA_PENDING = "2fa-pending"
    LOGGED_IN = "logged-in"
    RESTARTING = "restarting"
    EXISTING_SESSION = "existing-session"
    NEEDS_HUMAN = "needs-human"
    STOPPING = "stopping"
    STOPPED = "stopped"
    EXITED = "exited"
    TEST_MODE = "test-mode"


KNOWN_PHASES: frozenset[str] = frozenset(phase.value for phase in Phase)
UNKNOWN_PHASE = "unknown"
"""Reported for a phase file whose token is not in ``KNOWN_PHASES``; never treated as healthy."""


class ProbeStatus(StrEnum):
    """Health of the gateway's API as seen by the read-only probe.

    ``READY``: the last time round trip succeeded, IBKR connectivity is up and no data farm
    is broken. ``DEGRADED``: the round trip works but a farm is broken or IBKR connectivity
    was lost (1100) and not yet restored (1101/1102). ``DOWN``: no handshake, the round trip
    timed out, or the gateway holds dead API sockets and does not answer.
    ``CLIENT_ID_IN_USE``: the gateway refused the reserved client id (error 326); a human
    must free it. ``NOT_MEASURED``: the probe is disabled, the gateway is not logged in, or
    no probe has completed yet. Only ``READY`` makes ``/readyz`` answer 200.
    """

    READY = "ready"
    DEGRADED = "degraded"
    DOWN = "down"
    CLIENT_ID_IN_USE = "client_id_in_use"
    NOT_MEASURED = "not_measured"


class Severity(StrEnum):
    """Urgency of a notification, lowest first."""

    INFO = "info"
    WARNING = "warning"
    ERROR = "error"
    CRITICAL = "critical"


class AlertClass(StrEnum):
    """Conditions the notifier reports. Each has a default severity and a human instruction."""

    TWOFA_PENDING = "twofa_pending"
    NEEDS_HUMAN = "needs_human"
    LOGIN_FAILED = "login_failed"
    EXISTING_SESSION = "existing_session"
    LOGIN_STALLED = "login_stalled"
    UNKNOWN_WINDOW = "unknown_window"
    GATEWAY_EXITED = "gateway_exited"
    API_UNHEALTHY = "api_unhealthy"
    RESTART_STORM = "restart_storm"
    RESOURCE_ALERT = "resource_alert"
    DISK_LOW = "disk_low"
    CLOCK_SKEW = "clock_skew"
    GATEWAY_SILENT = "gateway_silent"
    HEARTBEAT = "heartbeat"


class MessageKind(StrEnum):
    """Why a notification is sent.

    ``FIRING``: a condition became active. ``ESCALATION``: it is still active after the
    escalation delay (human-needed classes only). ``RESOLVED``: it cleared. ``HEARTBEAT``:
    the optional daily all-good message. ``TEST``: ``brokersre-sidecar notify test``.
    """

    FIRING = "firing"
    ESCALATION = "escalation"
    RESOLVED = "resolved"
    HEARTBEAT = "heartbeat"
    TEST = "test"


class ChannelName(StrEnum):
    """Notification channels, in the order they are listed in ``/status``."""

    WEBHOOK = "webhook"
    TEAMS = "teams"
    SLACK = "slack"
    TELEGRAM = "telegram"
    NTFY = "ntfy"
    PAGERDUTY = "pagerduty"
    SMTP = "smtp"
