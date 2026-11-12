"""In-memory model of the gateway, fed from its phase file and its two JSON-lines feeds.

``GatewayState`` is mutated by one task (the follower) and read through ``snapshot()``,
which returns an immutable value for the probe, the notifier, the HTTP endpoints and the
metrics renderer. Everything is bounded: a fixed number of event names and boot ids is
remembered, so a gateway that writes garbage cannot grow the sidecar's memory.

Absence is never healthy: a quantity that was not observed is ``None`` in the snapshot.

The gateway is the single source of truth for the conditions it reports as event pairs
(``login_stalled``/``login_resumed``, ``disk_low``/``disk_ok``, ``memory_high``/``memory_ok``):
the model only remembers whether each pair is open. It applies no threshold of its own.

Durations that decide alerts (how long nothing was written, how long the volume has been
unreadable) are measured on the monotonic clock from the moment the sidecar OBSERVED
something, never from timestamps in the files: a paused virtual machine or a stepped wall
clock must not look like a silent gateway.
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

CONDITION_PAIRS: Mapping[str, str] = MappingProxyType(
    {
        "login_stalled": "login_resumed",
        "disk_low": "disk_ok",
        "memory_high": "memory_ok",
    }
)
"""Opening event -> closing event of every condition the gateway reports as a pair."""

_CLOSERS = {closing: opening for opening, closing in CONDITION_PAIRS.items()}
_MAX_EVENT_NAMES = 256
_MAX_BOOTS = 64


@dataclass(frozen=True, slots=True)
class PairState:
    """Last known state of one gateway-reported condition pair.

    Attributes:
        open: True after the opening event, False after the closing event or after the
            boot that opened it ended.
        since: Timestamp of the event (or of the first line of the new boot) that set it.
        boot_id: Boot the state belongs to, or None when the line carried none.
    """

    open: bool
    since: datetime
    boot_id: str | None


@dataclass(frozen=True, slots=True)
class GatewaySnapshot:
    """Immutable view of what the sidecar knows about the gateway at one instant.

    Attributes:
        taken_at: When the snapshot was taken (UTC).
        volume_present: Whether the gateway's log directory exists.
        phase: Phase token, ``"unknown"`` for an unrecognised file, None when the phase file
            is absent (not measured).
        phase_since: Since when the phase has held (a lower bound right after the sidecar
            started), or None.
        unreadable_for_s: Seconds (monotonic) for which the volume or its phase file has
            been unreadable without interruption; None while both are readable.
        boot_id: Boot id of the newest boot seen, or None (a gateway without log contract v2).
        boots_30m: Number of distinct boots that first appeared in the last 30 minutes, or
            None when no boot id was ever seen.
        last_restart_at: Timestamp of the first line of the newest boot when the sidecar saw
            the boot id change, or None.
        last_restart_unexpected: For that restart: True when the previous boot ended without
            a ``shutdown_requested`` event (a crash, a kill, IBC exiting on its own).
        last_login: Time of the newest ``login_completed`` event, or None.
        last_events: Newest event per name; read-only.
        last_metrics: Newest metrics sample, or None.
        last_event_at: Time of the newest event of any name, or None.
        last_activity_at: Time of the newest line of either feed, or None.
        feeds_seen: True once any valid line of either feed was read; False means the
            gateway does not (yet) write the v2 feeds and silence cannot be judged.
        quiet_for_s: Seconds (monotonic) since the sidecar last observed a new line of
            either feed; None when it never observed one.
        pairs: State of each gateway-reported condition pair that was ever seen, keyed by
            its opening event name. A missing key means "never reported": unknown.
        last_oom_at: Time of the newest ``oom_kill`` event, or None.
        rejected_lines: Lines of either feed that were not valid contract lines.
    """

    taken_at: datetime
    volume_present: bool
    phase: str | None
    phase_since: datetime | None
    unreadable_for_s: float | None
    boot_id: str | None
    boots_30m: int | None
    last_restart_at: datetime | None
    last_restart_unexpected: bool | None
    last_login: datetime | None
    last_events: Mapping[str, GatewayEvent]
    last_metrics: MetricsSample | None
    last_event_at: datetime | None
    last_activity_at: datetime | None
    feeds_seen: bool
    quiet_for_s: float | None
    pairs: Mapping[str, PairState]
    last_oom_at: datetime | None
    rejected_lines: int


class GatewayState:
    """Mutable model of one gateway container.

    Threading model: single-threaded; every method is called from the event loop thread.
    """

    def __init__(self, clock: Clock) -> None:
        """Create an empty model.

        Args:
            clock: Supplies "now" for the boot window and for clamping file times, and the
                monotonic readings behind ``quiet_for_s`` and ``unreadable_for_s``.
        """
        self._clock = clock
        self._volume_present = False
        self._phase: str | None = None
        self._phase_since: datetime | None = None
        # Unreadable from the start: nothing has been read yet.
        self._unreadable_since: float | None = clock.monotonic()
        self._boot_id: str | None = None
        self._boots: OrderedDict[str, datetime] = OrderedDict()
        self._last_restart_at: datetime | None = None
        self._last_restart_unexpected: bool | None = None
        self._last_login: datetime | None = None
        self._last_events: OrderedDict[str, GatewayEvent] = OrderedDict()
        self._last_metrics: MetricsSample | None = None
        self._last_event_at: datetime | None = None
        self._last_activity_at: datetime | None = None
        self._last_line_observed: float | None = None
        self._pairs: dict[str, PairState] = {}
        self._last_oom_at: datetime | None = None
        self._rejected_lines = 0

    @property
    def phase(self) -> str | None:
        """The current phase token (``"unknown"`` for an unrecognised file, None when absent)."""
        return self._phase

    @property
    def boot_id(self) -> str | None:
        """Boot id of the newest boot seen, or None."""
        return self._boot_id

    def observe_volume(self, present: bool) -> None:
        """Record whether the gateway's log directory exists (it only explains a missing phase)."""
        self._volume_present = present

    def observe_phase(self, reading: PhaseReading | None) -> None:
        """Record one reading of the phase file.

        ``phase_since`` moves only when the token changes. The gateway rewrites the file
        with the same token on every classified event, so the file time alone would keep
        resetting it. At a change the file's modification time is used (clamped to now),
        which also gives a sensible value right after the sidecar starts.

        Args:
            reading: Result of ``read_phase``; None when the file is absent.
        """
        if reading is None:
            self._phase = None
            self._phase_since = None
            if self._unreadable_since is None:
                self._unreadable_since = self._clock.monotonic()
            return
        self._unreadable_since = None
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
        if event.event == "oom_kill" and (
            self._last_oom_at is None or event.ts > self._last_oom_at
        ):
            self._last_oom_at = event.ts
        if event.event in CONDITION_PAIRS:
            self._pairs[event.event] = PairState(True, event.ts, event.boot_id)
        elif event.event in _CLOSERS:
            self._pairs[_CLOSERS[event.event]] = PairState(False, event.ts, event.boot_id)

    def observe_metrics(self, sample: MetricsSample) -> None:
        """Record one metrics sample (in file order)."""
        self._note_line(sample.ts, sample.boot_id)
        self._last_metrics = sample

    def note_rejected_line(self) -> None:
        """Count a line of either feed that was not a valid contract line."""
        self._rejected_lines += 1

    def _note_line(self, ts: datetime, boot_id: str | None) -> None:
        """Update activity and the boot table for one accepted line."""
        self._last_line_observed = self._clock.monotonic()
        if self._last_activity_at is None or ts > self._last_activity_at:
            self._last_activity_at = ts
        if boot_id is None:
            return
        if boot_id in self._boots:
            # A line of a boot already known (the two feeds are replayed one after the
            # other at start): keep the earliest time, never go back to an older boot.
            if ts < self._boots[boot_id]:
                self._boots[boot_id] = ts
            return
        previous = self._boot_id
        self._boots[boot_id] = ts
        while len(self._boots) > _MAX_BOOTS:
            self._boots.popitem(last=False)
        self._boot_id = boot_id
        if previous is None:
            return
        requested = self._last_events.get("shutdown_requested")
        self._last_restart_at = ts
        self._last_restart_unexpected = requested is None or requested.boot_id != previous
        # A condition the previous boot reported as open ended with that boot: the new
        # boot reports it again if it still holds.
        for name, pair in self._pairs.items():
            if pair.open:
                self._pairs[name] = PairState(False, ts, boot_id)

    def snapshot(self) -> GatewaySnapshot:
        """Return an immutable view of the current state."""
        now = self._clock.now()
        mono = self._clock.monotonic()
        boots = (
            sum(1 for first_seen in self._boots.values() if now - first_seen <= BOOT_WINDOW)
            if self._boots
            else None
        )
        return GatewaySnapshot(
            taken_at=now,
            volume_present=self._volume_present,
            phase=self._phase,
            phase_since=self._phase_since,
            unreadable_for_s=(
                mono - self._unreadable_since if self._unreadable_since is not None else None
            ),
            boot_id=self._boot_id,
            boots_30m=boots,
            last_restart_at=self._last_restart_at,
            last_restart_unexpected=self._last_restart_unexpected,
            last_login=self._last_login,
            last_events=MappingProxyType(dict(self._last_events)),
            last_metrics=self._last_metrics,
            last_event_at=self._last_event_at,
            last_activity_at=self._last_activity_at,
            feeds_seen=self._last_activity_at is not None,
            quiet_for_s=(
                mono - self._last_line_observed if self._last_line_observed is not None else None
            ),
            pairs=MappingProxyType(dict(self._pairs)),
            last_oom_at=self._last_oom_at,
            rejected_lines=self._rejected_lines,
        )
