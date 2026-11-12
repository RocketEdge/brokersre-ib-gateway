"""The versioned ``/status`` document (``brokersre.sidecar.status.v1``) and its JSON Schema.

The pydantic models below ARE the contract: ``schemas/status.v1.schema.json`` is generated
from them (``brokersre-sidecar print-schema status``) and a test fails when the committed
file differs. Rules of the document:

* a value that was not measured is ``null``, never 0 or "ok";
* every string is drawn from a closed vocabulary, is a timestamp, or is the operator's own
  instance label; there is no field for a username, an account id, a URL or a token;
* adding a field is a compatible change; removing or renaming one needs ``status.v2``.
"""

from __future__ import annotations

import platform
from collections.abc import Sequence
from datetime import datetime
from importlib import metadata
from typing import Annotated, Any, Literal

from pydantic import BaseModel, ConfigDict, Field

from brokersre_sidecar import __version__
from brokersre_sidecar.clock import format_utc
from brokersre_sidecar.model.health import NotifierSnapshot, ProbeSnapshot, TaskSnapshot
from brokersre_sidecar.model.state import GatewaySnapshot

STATUS_SCHEMA = "brokersre.sidecar.status.v1"
STATUS_SCHEMA_ID = (
    "https://github.com/RocketEdge/brokersre-ib-gateway/sidecar/schemas/status.v1.schema.json"
)

Timestamp = Annotated[
    str,
    Field(
        pattern=r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$",
        description="UTC, ISO-8601 with milliseconds and a Z suffix",
    ),
]
PhaseToken = Literal[
    "starting",
    "login",
    "2fa-pending",
    "logged-in",
    "restarting",
    "existing-session",
    "needs-human",
    "stopping",
    "stopped",
    "exited",
    "test-mode",
    "unknown",
]
StatusValue = Literal["ready", "degraded", "down", "client_id_in_use", "not_measured"]


class _Model(BaseModel):
    """Base of every status model: immutable, no unknown fields."""

    model_config = ConfigDict(frozen=True, extra="forbid", populate_by_name=True)


class Farm(_Model):
    """One IBKR data farm reported on the probe's API connection."""

    kind: Literal["market_data", "historical_data", "sec_def"]
    name: str = Field(pattern=r"^[a-z0-9.-]{1,24}$")
    condition: Literal["ok", "broken", "inactive"]


class LastProbe(_Model):
    """Outcome of the most recent probe attempt; all null before the first attempt."""

    at: Timestamp | None
    ok: bool | None
    rtt_s: float | None = Field(description="Round-trip time of the time request, seconds")
    error: Literal["connect_failed", "timeout", "disconnected", "client_id_in_use"] | None
    consecutive_failures: int = Field(ge=0)


class GatewayFeed(_Model):
    """How much of the gateway's log volume the sidecar can see."""

    volume_present: bool = Field(description="The gateway log directory is mounted")
    feeds_seen: bool = Field(description="At least one events or metrics line was read")
    last_event_at: Timestamp | None
    last_metrics_at: Timestamp | None
    rejected_lines: int = Field(ge=0, description="Feed lines that were not contract lines")


class Versions(_Model):
    """Versions of the sidecar and its runtime."""

    sidecar: str
    python: str
    ib_async: str


class Channel(_Model):
    """Delivery statistics of one notification channel."""

    name: Literal["webhook", "teams", "slack", "telegram", "ntfy", "pagerduty", "smtp"]
    sent_total: int = Field(ge=0)
    failures_total: int = Field(ge=0)
    dropped_total: int = Field(ge=0)
    queue_depth: int = Field(ge=0)
    last_success_at: Timestamp | None
    last_failure_at: Timestamp | None
    last_error: str | None = Field(
        pattern=r"^[a-z0-9_]{1,40}$", description="Failure category, never a URL or a reply"
    )


class ActiveAlert(_Model):
    """One alert condition that is active now."""

    alert_class: str = Field(alias="class", pattern=r"^[a-z_]{1,40}$")
    severity: Literal["info", "warning", "error", "critical"]
    since: Timestamp
    notified: bool = Field(description="A channel accepted a notification of this episode")
    escalation_step: int = Field(ge=0, le=2)
    failed_attempts: int = Field(
        ge=0, description="Attempts of the pending notification that no channel accepted"
    )


class Notifier(_Model):
    """State of the notifier."""

    enabled: bool
    channels: list[Channel]
    active_alerts: list[ActiveAlert]
    state_persistence: Literal["file", "memory", "disabled"]
    state_persistence_reason: str | None


class Task(_Model):
    """Supervision record of one background task."""

    name: str = Field(pattern=r"^[a-z0-9-]{1,40}$")
    state: Literal["running", "backoff", "stopped"]
    restarts: int = Field(ge=0)
    last_error: str | None = Field(description="Exception class name of the last crash")
    last_crash_at: Timestamp | None


class StatusDocument(_Model):
    """The document served at ``GET /status``."""

    schema_id: Literal["brokersre.sidecar.status.v1"] = Field(alias="schema")
    generated_at: Timestamp
    instance: str = Field(pattern=r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")
    trading_mode: Literal["paper", "live"]
    network_mode: Literal["own_network", "shared_namespace"] = Field(
        description="own_network: the sidecar reaches the gateway over the container "
        "network; shared_namespace: it runs inside the gateway's network namespace"
    )
    phase: PhaseToken | None = Field(description="null: the phase file is absent")
    phase_since: Timestamp | None
    status: StatusValue
    reason: str = Field(description="One line explaining status")
    status_since: Timestamp | None
    connectivity: Literal["ok", "lost", "not_measured"]
    farms: list[Farm]
    last_probe: LastProbe
    clock_skew_s: float | None = Field(description="IBKR time minus host time, seconds")
    close_wait_sockets: int | None = Field(description="Half-closed sockets on the API port")
    zombie: bool
    in_reset_window: bool = Field(
        description="Inside a reset window of the configured IBKR region; always false "
        "with IBKR_REGION=none"
    )
    boot_id: str | None = Field(pattern=r"^[0-9a-f]{16}$")
    boots_30m: int | None
    last_login: Timestamp | None
    gateway_feed: GatewayFeed
    versions: Versions
    notifier: Notifier
    tasks: list[Task]


def _ts(instant: datetime | None) -> str | None:
    """Format an optional instant."""
    return format_utc(instant) if instant is not None else None


def _rounded(value: float | None, digits: int) -> float | None:
    """Round an optional float (keeps the document readable and stable)."""
    return round(value, digits) if value is not None else None


def _ib_async_version() -> str:
    """Return the installed ib_async version without importing the library."""
    try:
        return metadata.version("ib_async")
    except metadata.PackageNotFoundError:
        return "not installed"


def build_status(
    *,
    instance: str,
    trading_mode: Literal["paper", "live"],
    network_mode: Literal["own_network", "shared_namespace"],
    gateway: GatewaySnapshot,
    probe: ProbeSnapshot,
    notifier: NotifierSnapshot,
    tasks: Sequence[TaskSnapshot],
    now: datetime,
) -> StatusDocument:
    """Assemble the status document from the subsystem snapshots.

    Args:
        instance: The operator's instance label.
        trading_mode: ``paper`` or ``live``.
        network_mode: ``own_network`` or ``shared_namespace`` (see ``Settings``).
        gateway: What the feeds and the phase file say.
        probe: What the API probe says.
        notifier: Notifier state (``enabled=False`` when no channel is configured).
        tasks: Supervision records.
        now: Generation time (UTC).

    Returns:
        The validated document; serialise with ``model_dump_json(by_alias=True)``.
    """
    last_metrics = gateway.last_metrics
    return StatusDocument.model_validate(
        {
            "schema": STATUS_SCHEMA,
            "generated_at": format_utc(now),
            "instance": instance,
            "trading_mode": trading_mode,
            "network_mode": network_mode,
            "phase": gateway.phase,
            "phase_since": _ts(gateway.phase_since),
            "status": probe.status.value,
            "reason": probe.reason,
            "status_since": _ts(probe.status_since),
            "connectivity": probe.connectivity,
            "farms": [
                {"kind": farm.kind, "name": farm.name, "condition": farm.condition}
                for farm in probe.farms
            ],
            "last_probe": {
                "at": _ts(probe.last_probe_at),
                "ok": probe.last_probe_ok,
                "rtt_s": _rounded(probe.last_rtt_s, 4),
                "error": probe.last_error,
                "consecutive_failures": probe.consecutive_failures,
            },
            "clock_skew_s": _rounded(probe.clock_skew_s, 3),
            "close_wait_sockets": probe.close_wait_sockets,
            "zombie": probe.zombie,
            "in_reset_window": probe.in_reset_window,
            "boot_id": gateway.boot_id,
            "boots_30m": gateway.boots_30m,
            "last_login": _ts(gateway.last_login),
            "gateway_feed": {
                "volume_present": gateway.volume_present,
                "feeds_seen": gateway.feeds_seen,
                "last_event_at": _ts(gateway.last_event_at),
                "last_metrics_at": _ts(last_metrics.ts) if last_metrics is not None else None,
                "rejected_lines": gateway.rejected_lines,
            },
            "versions": {
                "sidecar": __version__,
                "python": platform.python_version(),
                "ib_async": _ib_async_version(),
            },
            "notifier": {
                "enabled": notifier.enabled,
                "channels": [
                    {
                        "name": channel.name,
                        "sent_total": channel.sent_total,
                        "failures_total": channel.failures_total,
                        "dropped_total": channel.dropped_total,
                        "queue_depth": channel.queue_depth,
                        "last_success_at": _ts(channel.last_success_at),
                        "last_failure_at": _ts(channel.last_failure_at),
                        "last_error": channel.last_error,
                    }
                    for channel in notifier.channels
                ],
                "active_alerts": [
                    {
                        "class": alert.alert_class,
                        "severity": alert.severity,
                        "since": format_utc(alert.since),
                        "notified": alert.notified,
                        "escalation_step": alert.escalation_step,
                        "failed_attempts": alert.failed_attempts,
                    }
                    for alert in notifier.active_alerts
                ],
                "state_persistence": notifier.state_persistence,
                "state_persistence_reason": notifier.state_persistence_reason,
            },
            "tasks": [
                {
                    "name": task.name,
                    "state": task.state,
                    "restarts": task.restarts,
                    "last_error": task.last_error,
                    "last_crash_at": _ts(task.last_crash_at),
                }
                for task in tasks
            ],
        }
    )


def status_json_schema() -> dict[str, Any]:
    """Return the JSON Schema (draft 2020-12) of the status document.

    Generated in serialisation mode, so every field is listed as required: a consumer can
    rely on each key being present (possibly ``null``).
    """
    schema = StatusDocument.model_json_schema(by_alias=True, mode="serialization")
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": STATUS_SCHEMA_ID,
        **schema,
        "title": "brokersre-ib-gateway-sidecar status document (brokersre.sidecar.status.v1)",
    }
