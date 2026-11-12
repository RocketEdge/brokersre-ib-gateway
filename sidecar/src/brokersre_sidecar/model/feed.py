"""Carry the gateway's files into ``GatewayState``: one poll per second, no network.

Layout of the shared volume (log contract v2), mounted read-only::

    <log dir>/state/phase            one token
    <log dir>/events/events.jsonl    JSON lines, rotated to events.jsonl.1
    <log dir>/metrics/metrics.jsonl  JSON lines, one sample every 30 s, same rotation

A gateway that predates contract v2 writes only the phase file; the feeds are then simply
never seen and everything derived from them is reported as not measured.

Reading and applying are separate steps so the blocking file I/O can run in a worker thread
(``read``) while the model is only ever touched from the event-loop thread (``apply``).
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from brokersre_sidecar.model.events import GatewayEvent, MetricsSample, parse_event, parse_metrics
from brokersre_sidecar.model.state import GatewayState
from brokersre_sidecar.tail.follower import FollowerStats, LineFollower
from brokersre_sidecar.tail.phase import PhaseReading, read_phase

# Enough metrics history for the 10-minute memory-pressure window (20 samples) with a wide
# margin, without replaying a day of samples at start.
_METRICS_TAIL_BYTES = 64 * 1024


@dataclass(frozen=True, slots=True)
class FeedBatch:
    """Everything one read of the volume produced.

    Attributes:
        volume_present: Whether the log directory exists.
        phase: The phase file reading, or None when the file is absent.
        events: New event lines, parsed, in file order.
        metrics: New metrics lines, parsed, in file order.
        rejected: New lines of either feed that were not valid contract lines.
    """

    volume_present: bool
    phase: PhaseReading | None
    events: tuple[GatewayEvent, ...]
    metrics: tuple[MetricsSample, ...]
    rejected: int


class GatewayFeed:
    """Reads the phase file and follows both feeds, applying every line to the model.

    Threading model: ``read`` may run in a worker thread, one call at a time (it owns the
    followers' positions); ``apply`` and ``volume_present`` belong to the event-loop thread.
    A line that is not a valid contract line is counted, never raised.
    """

    def __init__(self, log_dir: Path, state: GatewayState) -> None:
        """Create the feed.

        Args:
            log_dir: The gateway's log volume as mounted in this container.
            state: The model to update.
        """
        self._log_dir = log_dir
        self._state = state
        self._phase_path = log_dir / "state" / "phase"
        # The events file is replayed from its rotated predecessor at start: the boot
        # counter and the last login need the recent past, which a rotation would hide.
        self._events = LineFollower(log_dir / "events" / "events.jsonl", replay_rotated=True)
        self._metrics = LineFollower(
            log_dir / "metrics" / "metrics.jsonl", initial_tail_bytes=_METRICS_TAIL_BYTES
        )
        self.volume_present = False
        """Whether the log directory existed at the last applied read."""

    def read(self) -> FeedBatch:
        """Read whatever is new from the volume (blocking file I/O, no model access)."""
        rejected = 0
        events: list[GatewayEvent] = []
        for line in self._events.poll():
            event = parse_event(line)
            if event is None:
                rejected += 1
            else:
                events.append(event)
        samples: list[MetricsSample] = []
        for line in self._metrics.poll():
            sample = parse_metrics(line)
            if sample is None:
                rejected += 1
            else:
                samples.append(sample)
        return FeedBatch(
            volume_present=self._log_dir.is_dir(),
            phase=read_phase(self._phase_path),
            events=tuple(events),
            metrics=tuple(samples),
            rejected=rejected,
        )

    def apply(self, batch: FeedBatch) -> None:
        """Apply one batch to the model (event-loop thread)."""
        self.volume_present = batch.volume_present
        self._state.observe_phase(batch.phase)
        for event in batch.events:
            self._state.observe_event(event)
        for sample in batch.metrics:
            self._state.observe_metrics(sample)
        for _ in range(batch.rejected):
            self._state.note_rejected_line()

    def poll(self) -> None:
        """Read and apply in one step (for synchronous callers and tests)."""
        self.apply(self.read())

    def follower_stats(self) -> dict[str, FollowerStats]:
        """Return the tolerance counters of both followers, keyed ``events`` and ``metrics``."""
        return {"events": self._events.stats, "metrics": self._metrics.stats}
