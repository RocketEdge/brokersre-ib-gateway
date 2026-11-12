"""Parse the gateway's JSON lines (log contract v2) into small, safe records.

Only fields from closed vocabularies or of numeric type are kept. The ``msg`` text of an
event and every unknown key are dropped at this boundary: the gateway may put the IBKR
username or an account id there, and what the model never holds it can never leak.
"""

from __future__ import annotations

import json
import math
import re
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime
from types import MappingProxyType

from brokersre_sidecar.clock import parse_utc
from brokersre_sidecar.vocab import KNOWN_PHASES

_EVENT_NAME_RE = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
_SOURCE_RE = re.compile(r"^[a-z]{1,16}$")
_BOOT_ID_RE = re.compile(r"^[0-9a-f]{16}$")
_LEVELS = frozenset({"info", "warn", "error"})

METRIC_KEYS: tuple[str, ...] = (
    "mem_working_set_bytes",
    "mem_limit_bytes",
    "oom_kills",
    "cpu_usage_usec",
    "cpu_throttled_usec",
    "pids",
    "java_rss_bytes",
    "java_threads",
    "open_fds",
    "api_close_wait_sockets",
    "disk_free_bytes_logs",
    "disk_free_bytes_settings",
    "disk_total_bytes_logs",
    "disk_total_bytes_settings",
)
"""Numeric keys of a metrics sample; a key that could not be measured is absent."""


@dataclass(frozen=True, slots=True)
class GatewayEvent:
    """One line of ``events/events.jsonl`` reduced to its vocabulary fields.

    Attributes:
        ts: When the gateway emitted the event (UTC).
        event: snake_case event name (validated shape; unknown names are allowed).
        src: Emitting component, or ``"unknown"`` when missing or malformed.
        level: ``info``, ``warn`` or ``error`` (``info`` when missing or malformed).
        boot_id: 16 hex characters identifying one start of the gateway container, or None.
        seq: Monotonic counter within ``boot_id``, or None.
    """

    ts: datetime
    event: str
    src: str
    level: str
    boot_id: str | None
    seq: int | None


@dataclass(frozen=True, slots=True)
class MetricsSample:
    """One line of ``metrics/metrics.jsonl``.

    Attributes:
        ts: Sample time (UTC).
        boot_id: Gateway boot the sample belongs to, or None.
        seq: Sample counter within the boot, or None.
        phase: Phase token recorded by the sampler, or None when missing or not a known token.
        values: Measured values by key (subset of ``METRIC_KEYS``); read-only. A key that is
            absent was not measured and must never be reported as 0.
    """

    ts: datetime
    boot_id: str | None
    seq: int | None
    phase: str | None
    values: Mapping[str, float]


def _load_object(line: str) -> dict[str, object] | None:
    """Return the JSON object in ``line`` or None when it is not one."""
    try:
        parsed = json.loads(line)
    except ValueError, RecursionError:
        return None
    return parsed if isinstance(parsed, dict) else None


def _boot_id(value: object) -> str | None:
    """Return a well-formed boot id or None."""
    return value if isinstance(value, str) and _BOOT_ID_RE.fullmatch(value) else None


def _sequence(value: object) -> int | None:
    """Return a non-negative integer sequence number or None."""
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


def parse_event(line: str) -> GatewayEvent | None:
    """Parse one events line.

    Args:
        line: One complete line as returned by ``LineFollower.poll``.

    Returns:
        The event, or None when the line is not a JSON object with a zone-qualified ``ts``
        and a snake_case ``event`` name. Unknown keys are ignored; ``msg`` is dropped.
    """
    body = _load_object(line)
    if body is None:
        return None
    ts = parse_utc(body.get("ts"))
    name = body.get("event")
    if ts is None or not isinstance(name, str) or not _EVENT_NAME_RE.fullmatch(name):
        return None
    src = body.get("src")
    level = body.get("level")
    return GatewayEvent(
        ts=ts,
        event=name,
        src=src if isinstance(src, str) and _SOURCE_RE.fullmatch(src) else "unknown",
        level=level if isinstance(level, str) and level in _LEVELS else "info",
        boot_id=_boot_id(body.get("boot_id")),
        seq=_sequence(body.get("seq")),
    )


def parse_metrics(line: str) -> MetricsSample | None:
    """Parse one metrics line.

    Args:
        line: One complete line as returned by ``LineFollower.poll``.

    Returns:
        The sample, or None when the line is not a JSON object with a zone-qualified ``ts``.
        A value is kept only when its key is known and it is a finite, non-negative number
        (booleans and numeric strings are not numbers).
    """
    body = _load_object(line)
    if body is None:
        return None
    ts = parse_utc(body.get("ts"))
    if ts is None:
        return None
    values: dict[str, float] = {}
    for key in METRIC_KEYS:
        value = body.get(key)
        if isinstance(value, bool) or not isinstance(value, int | float):
            continue
        number = float(value)
        if math.isfinite(number) and number >= 0:
            values[key] = number
    phase = body.get("phase")
    return MetricsSample(
        ts=ts,
        boot_id=_boot_id(body.get("boot_id")),
        seq=_sequence(body.get("seq")),
        phase=phase if isinstance(phase, str) and phase in KNOWN_PHASES else None,
        values=MappingProxyType(values),
    )
