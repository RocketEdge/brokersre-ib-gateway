"""Carry the gateway's files into ``GatewayState``: one ``poll()`` per second, no network.

Layout of the shared volume (log contract v2), mounted read-only::

    <log dir>/state/phase            one token
    <log dir>/events/events.jsonl    JSON lines, rotated to events.jsonl.1
    <log dir>/metrics/metrics.jsonl  JSON lines, one sample every 30 s, same rotation

A gateway that predates contract v2 writes only the phase file; the feeds are then simply
never seen and everything derived from them is reported as not measured.
"""

from __future__ import annotations

from pathlib import Path

from brokersre_sidecar.model.events import parse_event, parse_metrics
from brokersre_sidecar.model.state import GatewayState
from brokersre_sidecar.tail.follower import FollowerStats, LineFollower
from brokersre_sidecar.tail.phase import read_phase

# Enough metrics history for the 10-minute memory-pressure window (20 samples) with a wide
# margin, without replaying a day of samples at start.
_METRICS_TAIL_BYTES = 64 * 1024


class GatewayFeed:
    """Reads the phase file and follows both feeds, applying every line to the model.

    ``poll()`` does blocking reads of small local files; the caller runs it off the event
    loop. A line that is not a valid contract line is counted, never raised.
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

    def poll(self) -> None:
        """Read whatever is new and apply it to the model.

        Side effects:
            Updates the model and ``volume_present`` (whether the log directory exists).
        """
        self.volume_present = self._log_dir.is_dir()
        self._state.observe_phase(read_phase(self._phase_path))
        for line in self._events.poll():
            event = parse_event(line)
            if event is None:
                self._state.note_rejected_line()
            else:
                self._state.observe_event(event)
        for line in self._metrics.poll():
            sample = parse_metrics(line)
            if sample is None:
                self._state.note_rejected_line()
            else:
                self._state.observe_metrics(sample)

    def follower_stats(self) -> dict[str, FollowerStats]:
        """Return the tolerance counters of both followers, keyed ``events`` and ``metrics``."""
        return {"events": self._events.stats, "metrics": self._metrics.stats}
