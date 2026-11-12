"""Prometheus text exposition (format 0.0.4) of the sidecar's view of the gateway.

Metric names are a frozen contract; a new metric may be added, an existing one is never
renamed. A value that was not measured is OMITTED, never exported as 0: ``absent()`` in an
alert rule then tells "unknown" apart from "zero". The gateway's own sampler values are
re-exported only while the sample is fresh, for the same reason.
"""

from __future__ import annotations

from collections.abc import Sequence
from datetime import timedelta

from brokersre_sidecar import __version__
from brokersre_sidecar.model.health import NotifierSnapshot, ProbeSnapshot, TaskSnapshot
from brokersre_sidecar.model.state import GatewaySnapshot
from brokersre_sidecar.vocab import ProbeStatus

CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8"

# The gateway samples every 30 s; after four missed samples its numbers are history.
SAMPLE_FRESH_FOR = timedelta(seconds=120)

_USEC = 1_000_000.0

# (metric name, type, help, sample key, divisor)
_SAMPLER_METRICS: tuple[tuple[str, str, str, str, float], ...] = (
    (
        "ibgw_memory_working_set_bytes",
        "gauge",
        "Gateway container memory working set.",
        "mem_working_set_bytes",
        1.0,
    ),
    (
        "ibgw_memory_limit_bytes",
        "gauge",
        "Gateway container memory limit.",
        "mem_limit_bytes",
        1.0,
    ),
    (
        "ibgw_oom_kills_total",
        "counter",
        "Out-of-memory kills in the gateway container.",
        "oom_kills",
        1.0,
    ),
    (
        "ibgw_cpu_usage_seconds_total",
        "counter",
        "CPU time used by the gateway container.",
        "cpu_usage_usec",
        _USEC,
    ),
    (
        "ibgw_cpu_throttled_seconds_total",
        "counter",
        "Time the gateway container was CPU-throttled.",
        "cpu_throttled_usec",
        _USEC,
    ),
    ("ibgw_pids", "gauge", "Processes and threads in the gateway container.", "pids", 1.0),
    (
        "ibgw_java_rss_bytes",
        "gauge",
        "Resident memory of the gateway JVM.",
        "java_rss_bytes",
        1.0,
    ),
    ("ibgw_java_threads", "gauge", "Threads of the gateway JVM.", "java_threads", 1.0),
    ("ibgw_open_fds", "gauge", "Open file descriptors of the gateway JVM.", "open_fds", 1.0),
)


def _number(value: float) -> str:
    """Format a sample value: integral values without a fraction, others in full."""
    return str(int(value)) if float(value).is_integer() else repr(float(value))


class _Writer:
    """Accumulates exposition lines, writing HELP and TYPE once per metric."""

    def __init__(self) -> None:
        """Start with no lines and no declared metric."""
        self._lines: list[str] = []
        self._declared: set[str] = set()

    def add(self, name: str, kind: str, help_text: str, value: float, labels: str = "") -> None:
        """Add one sample; the first sample of a metric also writes its HELP and TYPE."""
        if name not in self._declared:
            self._declared.add(name)
            self._lines.append(f"# HELP {name} {help_text}")
            self._lines.append(f"# TYPE {name} {kind}")
        self._lines.append(f"{name}{labels} {_number(value)}")

    def text(self) -> str:
        """Return the exposition, newline-terminated."""
        return "\n".join(self._lines) + "\n"


def render_metrics(
    *,
    gateway: GatewaySnapshot,
    probe: ProbeSnapshot,
    notifier: NotifierSnapshot,
    tasks: Sequence[TaskSnapshot],
) -> str:
    """Render the ``/metrics`` body.

    Args:
        gateway: Gateway snapshot (phase, boots, the last sampler line).
        probe: Probe snapshot (readiness, round-trip time, clock offset, CLOSE_WAIT count).
        notifier: Notifier snapshot (per-channel counters).
        tasks: Supervision records (restart counters).

    Returns:
        Prometheus text format 0.0.4. Label values come from closed vocabularies only, so
        no escaping is needed.
    """
    out = _Writer()
    out.add(
        "ibgw_sidecar_info",
        "gauge",
        "Constant 1, labelled with the sidecar version.",
        1,
        f'{{version="{__version__}"}}',
    )
    if gateway.phase is not None:
        out.add(
            "ibgw_phase",
            "gauge",
            "Gateway lifecycle phase: 1 for the current phase.",
            1,
            f'{{phase="{gateway.phase}"}}',
        )
    if probe.status is not ProbeStatus.NOT_MEASURED:
        out.add(
            "ibgw_api_ready",
            "gauge",
            "1 when the read-only API probe is ready, 0 when degraded, down or refused; "
            "absent when not measured.",
            1 if probe.status is ProbeStatus.READY else 0,
        )
    if probe.last_rtt_s is not None:
        out.add(
            "ibgw_api_rtt_seconds",
            "gauge",
            "Round-trip time of the last successful API time request.",
            probe.last_rtt_s,
        )
    if probe.clock_skew_s is not None:
        out.add(
            "ibgw_clock_offset_seconds",
            "gauge",
            "IBKR time minus host time at the last successful probe (IBKR reports whole seconds).",
            probe.clock_skew_s,
        )
    sample = gateway.last_metrics
    fresh = sample is not None and gateway.taken_at - sample.ts <= SAMPLE_FRESH_FOR
    values = sample.values if sample is not None and fresh else {}
    close_wait = (
        probe.close_wait_sockets
        if probe.close_wait_sockets is not None
        else values.get("api_close_wait_sockets")
    )
    if close_wait is not None:
        out.add(
            "ibgw_api_close_wait_sockets",
            "gauge",
            "Sockets in CLOSE_WAIT on the gateway API port.",
            close_wait,
        )
    if gateway.boots_30m is not None:
        out.add(
            "ibgw_boots_30m",
            "gauge",
            "Gateway container starts in the last 30 minutes.",
            gateway.boots_30m,
        )
    for name, kind, help_text, key, divisor in _SAMPLER_METRICS:
        if key in values:
            out.add(name, kind, help_text, values[key] / divisor)
    for channel in notifier.channels:
        out.add(
            "ibgw_notify_failures_total",
            "counter",
            "Notifications given up on after all retries, per channel.",
            channel.failures_total,
            f'{{channel="{channel.name}"}}',
        )
    for channel in notifier.channels:
        out.add(
            "ibgw_notify_sent_total",
            "counter",
            "Notifications delivered, per channel.",
            channel.sent_total,
            f'{{channel="{channel.name}"}}',
        )
    for channel in notifier.channels:
        out.add(
            "ibgw_notify_dropped_total",
            "counter",
            "Notifications discarded because a channel's outbox was full.",
            channel.dropped_total,
            f'{{channel="{channel.name}"}}',
        )
    if notifier.enabled:
        out.add(
            "ibgw_notify_undelivered_alerts",
            "gauge",
            "Active alerts that no channel has accepted yet (they are sent again).",
            sum(1 for alert in notifier.active_alerts if not alert.notified),
        )
    for task in tasks:
        out.add(
            "ibgw_sidecar_task_restarts_total",
            "counter",
            "Restarts of a sidecar background task after a crash.",
            task.restarts,
            f'{{task="{task.name}"}}',
        )
    return out.text()
