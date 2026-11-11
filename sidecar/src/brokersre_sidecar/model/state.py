"""In-memory model of the gateway, fed from its phase file and its two JSON-lines feeds.

``GatewayState`` is mutated by one task (the follower) and read through ``snapshot()``,
which returns an immutable value for the probe, the notifier, the HTTP endpoints and the
metrics renderer. Everything is bounded: a fixed number of event names and boot ids is
remembered, so a gateway that writes garbage cannot grow the sidecar's memory.

Absence is never healthy: a quantity that was not observed is ``None`` in the snapshot.
"""

from __future__ import annotations

from collections import OrderedDict
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime, timedelta
from types import MappingProxyType

from brokersre_sidecar.clock import Clock
from brokersre_sidecar.model.events import GatewayEvent, MetricsSample
from brokersre_sidecar.tail.phase import PhaseReading

BOOT_WINDOW = timedelta(minutes=30)
"""Look-back of the boot counter (``boots_30m``)."""

MEMORY_HIGH_RATIO = 0.85
"""Working set above this fraction of the cgroup limit counts as memory pressure."""

_MAX_EVENT_NAMES = 256
_MAX_BOOTS = 64


@dataclass(frozen=True, slots=True)
class GatewaySnapshot:
    """Immutable view of what the sidecar knows about the gateway at one instant.

    Attributes:
        taken_at: When the snapshot was taken (UTC).
        phase: Phase token, ``"unknown"`` for an unrecognised file, None when the phase file
            is absent (not measured).
        phase_since: Since when the phase has held (a lower bound right after the sidecar
            started), or None.
        boot_id: Boot id of the newest line seen, or None (a gateway without log contract v2).
        boots_30m: Number of distinct boots that first appeared in the last 30 minutes, or
            None when no boot id was ever seen.
        last_login: Time of the newest ``login_completed`` event, or None.
        last_events: Newest event per name; read-only.
        last_metrics: Newest metrics sample, or None.
        last_event_at: Time of the newest event of any name, or None.
        last_activity_at: Time of the newest line of either feed, or None.
        feeds_seen: True once any valid line of either feed was read; False means the
            gateway does not (yet) write the v2 feeds and silence cannot be judged.
        memory_ratio: Working set divided by the cgroup limit in the newest sample, or None
            when either was not measured.
        memory_high_since: Start of the current uninterrupted run of samples above
            ``MEMORY_HIGH_RATIO``, or None.
        last_oom_at: When an OOM kill was last observed (counter increase or ``oom_kill``
            event), or None.
        rejected_lines: Lines of either feed that were not valid contract lines.
    """

    taken_at: datetime
    phase: str | None
    phase_since: datetime | None
    boot_id: str | None
    boots_30m: int | None
    last_login: datetime | None
    last_events: Mapping[str, GatewayEvent]
    last_metrics: MetricsSample | None
    last_event_at: datetime | None
    last_activity_at: datetime | None
    feeds_seen: bool
    memory_ratio: float | None
    memory_high_since: datetime | None
    last_oom_at: datetime | None
    rejected_lines: int


class GatewayState:
    """Mutable model of one gateway container.

    Threading model: single-threaded; every method is called from the event loop thread.
    """

    def __init__(self, clock: Clock) -> None:
        """Create an empty model.

        Args:
            clock: Supplies "now" for the boot window and for clamping file times.
        """
        self._clock = clock
        self._phase: str | None = None
        self._phase_since: datetime | None = None
        self._boot_id: str | None = None
        self._boots: OrderedDict[str, datetime] = OrderedDict()
        self._last_login: datetime | None = None
        self._last_events: OrderedDict[str, GatewayEvent] = OrderedDict()
        self._last_metrics: MetricsSample | None = None
        self._last_event_at: datetime | None = None
        self._last_activity_at: datetime | None = None
        self._memory_ratio: float | None = None
        self._memory_high_since: datetime | None = None
        self._oom_kills: float | None = None
        self._last_oom_at: datetime | None = None
        self._rejected_lines = 0

    def observe_phase(self, reading: PhaseReading | None) -> None:
        """Record one reading of the phase file.

        ``phase_since`` moves only when the token changes. The gateway rewrites the file
        with the same token on every classified event, so the file time alone would keep
        resetting the clock that ``login_stalled`` depends on. At a change the file's
        modification time is used (clamped to now), which also gives a sensible value right
        after the sidecar starts.

        Args:
            reading: Result of ``read_phase``; None when the file is absent.
        """
        if reading is None:
            self._phase = None
            self._phase_since = None
            return
        if reading.token != self._phase:
            self._phase = reading.token
            self._phase_since = min(reading.modified, self._clock.now())

    def observe_event(self, event: GatewayEvent) -> None:
        """Record one event line (in file order)."""
        self._note_line(event.ts, event.boot_id)
        self._last_events[event.event] = event
        self._last_events.move_to_end(event.event)
        while len(self._last_events) > _MAX_EVENT_NAMES:
            self._last_events.popitem(last=False)
        if self._last_event_at is None or event.ts > self._last_event_at:
            self._last_event_at = event.ts
        if event.event == "login_completed" and (
            self._last_login is None or event.ts > self._last_login
        ):
            self._last_login = event.ts
        if event.event == "oom_kill":
            self._note_oom(event.ts)

    def observe_metrics(self, sample: MetricsSample) -> None:
        """Record one metrics sample (in file order)."""
        self._note_line(sample.ts, sample.boot_id)
        self._last_metrics = sample
        working_set = sample.values.get("mem_working_set_bytes")
        limit = sample.values.get("mem_limit_bytes")
        if working_set is None or limit is None or limit <= 0:
            # Not measured: pressure cannot be claimed and a running episode cannot continue.
            self._memory_ratio = None
            self._memory_high_since = None
        else:
            self._memory_ratio = working_set / limit
            if self._memory_ratio > MEMORY_HIGH_RATIO:
                if self._memory_high_since is None:
                    self._memory_high_since = sample.ts
            else:
                self._memory_high_since = None
        oom_kills = sample.values.get("oom_kills")
        if oom_kills is not None:
            # The first reading is a baseline: the counter may have been non-zero for days.
            if self._oom_kills is not None and oom_kills > self._oom_kills:
                self._note_oom(sample.ts)
            self._oom_kills = oom_kills

    def note_rejected_line(self) -> None:
        """Count a line of either feed that was not a valid contract line."""
        self._rejected_lines += 1

    def _note_line(self, ts: datetime, boot_id: str | None) -> None:
        """Update activity time and the boot table for one accepted line."""
        if self._last_activity_at is None or ts > self._last_activity_at:
            self._last_activity_at = ts
        if boot_id is None:
            return
        self._boot_id = boot_id
        if boot_id not in self._boots:
            self._boots[boot_id] = ts
            while len(self._boots) > _MAX_BOOTS:
                self._boots.popitem(last=False)
        elif ts < self._boots[boot_id]:
            self._boots[boot_id] = ts

    def _note_oom(self, ts: datetime) -> None:
        """Record an observed OOM kill."""
        if self._last_oom_at is None or ts > self._last_oom_at:
            self._last_oom_at = ts

    def snapshot(self) -> GatewaySnapshot:
        """Return an immutable view of the current state."""
        now = self._clock.now()
        boots = (
            sum(1 for first_seen in self._boots.values() if now - first_seen <= BOOT_WINDOW)
            if self._boots
            else None
        )
        return GatewaySnapshot(
            taken_at=now,
            phase=self._phase,
            phase_since=self._phase_since,
            boot_id=self._boot_id,
            boots_30m=boots,
            last_login=self._last_login,
            last_events=MappingProxyType(dict(self._last_events)),
            last_metrics=self._last_metrics,
            last_event_at=self._last_event_at,
            last_activity_at=self._last_activity_at,
            feeds_seen=self._last_activity_at is not None,
            memory_ratio=self._memory_ratio,
            memory_high_since=self._memory_high_since,
            last_oom_at=self._last_oom_at,
            rejected_lines=self._rejected_lines,
        )
