"""The notifier: evaluate the rules, climb the ladder, queue the messages, save the state."""

from __future__ import annotations

import asyncio
import functools
import logging
from collections.abc import Callable
from datetime import datetime
from typing import Literal

from brokersre_sidecar.clock import Clock, format_utc
from brokersre_sidecar.logsetup import log_event
from brokersre_sidecar.model.health import NotifierSnapshot, ProbeSnapshot
from brokersre_sidecar.model.state import GatewaySnapshot
from brokersre_sidecar.notify.dispatcher import Dispatcher
from brokersre_sidecar.notify.ladder import LadderEngine, Moment, Outbound
from brokersre_sidecar.notify.message import MessageFactory
from brokersre_sidecar.notify.rules import RuleEngine
from brokersre_sidecar.notify.store import NotifierStore
from brokersre_sidecar.vocab import UNKNOWN_PHASE, AlertClass, MessageKind, ProbeStatus
from brokersre_sidecar.worker import SerialWorker

_LOGGER = logging.getLogger(__name__)
_TRACKED = (MessageKind.FIRING, MessageKind.ESCALATION)
# A state file of a few hundred bytes on a local volume; anything longer is a stuck disk.
_SAVE_TIMEOUT_S = 5.0
# Delay between attempts while the state cannot be saved.
_SAVE_RETRY_S = 30.0


class Notifier:
    """One evaluation step per call of ``tick`` (about once a second).

    ``tick`` does no network I/O: it only queues messages on the dispatcher, whose workers
    deliver them and report back whether a channel accepted each one. The state file is
    written only when the ladder state changed, on a thread of its own, with a time
    bound: a save that hangs or fails neither stalls the alerts nor is repeated behind
    itself; the state is then kept in memory (``/status`` says so) and the save is tried
    again later. A state directory that is missing or read-only when the sidecar starts
    means memory only.
    """

    def __init__(
        self,
        *,
        rules: RuleEngine,
        ladder: LadderEngine,
        factory: MessageFactory,
        dispatcher: Dispatcher,
        store: NotifierStore | None,
        clock: Clock,
        gateway: Callable[[], GatewaySnapshot],
        probe: Callable[[], ProbeSnapshot],
        ready: Callable[[], bool],
        save_timeout_s: float = _SAVE_TIMEOUT_S,
    ) -> None:
        """Wire the notifier.

        Args:
            rules: Produces a verdict per alert class.
            ladder: Decides which notification is due.
            factory: Renders due notifications into messages.
            dispatcher: Receives the messages and reports their delivery.
            store: State file, or None to keep state in memory only.
            clock: Time source.
            gateway: Returns the current gateway snapshot.
            probe: Returns the current probe snapshot.
            ready: False until the gateway feed was read once; nothing is evaluated before
                that, so a restart cannot "resolve" alerts from an empty model.
            save_timeout_s: Longest wait for one write of the state file.
        """
        self._rules = rules
        self._ladder = ladder
        self._factory = factory
        self._dispatcher = dispatcher
        self._store = store
        self._clock = clock
        self._gateway = gateway
        self._probe = probe
        self._ready = ready
        self._save_timeout_s = save_timeout_s
        self._saver = SerialWorker("sidecar-state")
        self._write: asyncio.Future[None] | None = None  # the latest write started
        self._waiting: frozenset[tuple[AlertClass, datetime]] = frozenset()
        self._can_save = False
        self._unsaved = False
        self._save_retry_at: float | None = None
        self._persistence: Literal["file", "memory"] = "memory"
        self._persistence_reason: str | None = "no state file is configured"

    def load_state(self) -> None:
        """Load the saved ladder state and decide whether state can be persisted.

        Side effects:
            Reads the state file; probes the state directory for writability.
        """
        if self._store is None:
            return
        self._ladder.import_state(self._store.load())
        if self._store.writable():
            self._can_save = True
            self._persistence = "file"
            self._persistence_reason = None
        else:
            self._persistence = "memory"
            self._persistence_reason = (
                "the state directory is not writable; de-duplication state is kept in "
                "memory and is lost when the sidecar restarts"
            )
            log_event(_LOGGER, logging.WARNING, "notifier_state_memory", self._persistence_reason)

    async def tick(self) -> None:
        """Evaluate once: queue due notifications and persist a changed state."""
        if not self._ready():
            return
        now = self._clock.now()
        gateway = self._gateway()
        probe = self._probe()
        evaluations = self._rules.evaluate(gateway, probe, now=now, mono=self._clock.monotonic())
        can_see = gateway.phase is not None and gateway.phase != UNKNOWN_PHASE
        current = Moment(phase=gateway.phase, api_status=probe.status.value)
        # Results that came back since the last tick decided waits: say so before the
        # "resolved" they owe is queued; waits that begin in this step are logged after it.
        self._log_waiting()
        for due in self._ladder.step(evaluations, now, can_see=can_see, moment=current):
            if due.kind is MessageKind.HEARTBEAT:
                detail = _not_measured(gateway, probe)
            elif due.cleared_at is not None:
                detail = _late_resolution(due, due.cleared_at)
            else:
                detail = due.detail
            # A late resolution shows the gateway as it was when the condition cleared:
            # by now the facts may belong to the next episode of the class.
            shown = due.moment if due.moment is not None else current
            message = self._factory.build(
                due.kind,
                due.alert_class,
                detail=detail,
                escalation_step=due.escalation_step,
                since=due.since,
                phase=shown.phase,
                api_status=shown.api_status,
                now=now,
                superseded_by=due.superseded_by,
            )
            # Announcements and escalations report back: the alert counts as notified only
            # when a channel accepted the message.
            on_done = functools.partial(self._delivered, due) if due.kind in _TRACKED else None
            self._dispatcher.enqueue(message, due.channels, on_done)
            log_event(
                _LOGGER,
                logging.INFO,
                "notify_queued",
                alert_class=message.alert_class,
                kind=message.kind,
                severity=message.severity,
                channels=list(due.channels),
                attempt=due.attempt,
            )
        self._log_waiting()
        if self._ladder.dirty or self._unsaved:
            await self._save()

    def _log_waiting(self) -> None:
        """Log when a cleared alert starts and stops waiting for a message's result.

        While it waits, nothing new is sent for its class; without these two events that
        hold would be invisible. Called before and after each step: ``decided`` is logged
        before the ``notify_queued`` of the ``resolved`` it owes, which follows only if a
        channel had accepted a message about the alert (``decided`` does not say which
        way); ``waiting`` is logged after the step in which the wait began.
        """
        now_waiting = self._ladder.waiting()
        for alert, since in sorted(now_waiting - self._waiting, key=_by_class):
            log_event(
                _LOGGER,
                logging.INFO,
                "notify_resolution_waiting",
                "the condition cleared while a message about it was being sent; its "
                "resolution waits for that result, and the class sends nothing new until then",
                alert_class=alert.value,
                since=format_utc(since),
            )
        for alert, since in sorted(self._waiting - now_waiting, key=_by_class):
            log_event(
                _LOGGER,
                logging.INFO,
                "notify_resolution_decided",
                "the result is in: the resolution is sent if a channel had accepted",
                alert_class=alert.value,
                since=format_utc(since),
            )
        self._waiting = now_waiting

    def _delivered(self, due: Outbound, accepted: bool) -> None:
        """Tell the ladder whether a notification reached at least one channel.

        Called by the dispatcher at the first acceptance, or when every channel failed;
        possibly after the condition has cleared, which the ladder handles.
        """
        self._ladder.record_result(due, delivered=accepted, now=self._clock.now())
        if not accepted:
            log_event(
                _LOGGER,
                logging.WARNING,
                "notify_undelivered",
                "no channel accepted the notification; it is sent again while the condition lasts",
                alert_class=due.alert_class.value,
                kind=due.kind.value,
                attempt=due.attempt,
            )

    async def save_on_stop(self) -> None:
        """Write the state once more, after the outboxes were flushed at shutdown.

        The flush reports delivery outcomes to the ladder after the last evaluation; without
        this write they are lost, and the next start resends a delivered announcement or
        resolves one that no channel accepted. A save that failed a moment ago is tried
        anyway: this is the last chance. A write still running (the stop cancelled the
        evaluation that awaited it) is waited for first, else this one would be skipped.
        Each wait is bounded by ``save_timeout_s``; if that write has still not returned,
        the final save is skipped and the log says so (the next start then sends again or
        resolves what the file shows in flight).
        """
        if not (self._ladder.dirty or self._unsaved):
            return
        if self._saver.busy and self._write is not None:
            await asyncio.wait({self._write}, timeout=self._save_timeout_s)
        if self._saver.busy:
            log_event(
                _LOGGER,
                logging.WARNING,
                "notifier_state_unsaved",
                "the state could not be written at stop: an earlier write has not returned "
                f"within {self._save_timeout_s:g} s",
            )
            return
        self._save_retry_at = None
        await self._save()

    def close(self) -> None:
        """Let the state thread end (called when the sidecar stops)."""
        self._saver.close()

    async def _save(self) -> None:
        """Write the ladder state on the state thread; keep it in memory when that fails.

        At most one write runs at a time and the wait for it is bounded. While a write has
        not returned, or within ``_SAVE_RETRY_S`` of a failure, nothing is started and the
        state stays marked as unsaved; the next attempt writes whatever is current then.
        """
        if self._store is None or not self._can_save:
            self._ladder.export_state()  # nothing to write to: only clears the dirty flag
            return
        self._unsaved = True
        if self._saver.busy:
            return
        mono = self._clock.monotonic()
        if self._save_retry_at is not None and mono < self._save_retry_at:
            return
        write = self._saver.start(functools.partial(self._store.save, self._ladder.export_state()))
        # Collect every outcome, also one nobody awaits any more (a stop cancelled this
        # evaluation, or the wait below timed out), so a late error is not reported as
        # "Future exception was never retrieved".
        write.add_done_callback(lambda finished: finished.exception())
        self._write = write
        done, _ = await asyncio.wait({write}, timeout=self._save_timeout_s)
        if not done:
            self._save_failed(
                f"saving the state did not finish within {self._save_timeout_s:g} s", mono
            )
            return
        error = write.exception()
        if isinstance(error, OSError):
            self._save_failed(f"saving the state failed ({type(error).__name__})", mono)
            return
        if error is not None:
            raise error
        self._unsaved = False
        self._save_retry_at = None
        if self._persistence != "file":
            log_event(_LOGGER, logging.INFO, "notifier_state_file", "the state is saved again")
        self._persistence = "file"
        self._persistence_reason = None

    def _save_failed(self, reason: str, mono: float) -> None:
        """Record a failed or overdue save and schedule the next attempt."""
        self._save_retry_at = mono + _SAVE_RETRY_S
        if self._persistence_reason != reason:
            log_event(_LOGGER, logging.WARNING, "notifier_state_memory", reason)
        self._persistence = "memory"
        self._persistence_reason = reason

    def snapshot(self) -> NotifierSnapshot:
        """Return the notifier's state for ``/status`` and ``/metrics``."""
        return NotifierSnapshot(
            enabled=True,
            channels=self._dispatcher.snapshot(),
            active_alerts=self._ladder.active(),
            state_persistence=self._persistence,
            state_persistence_reason=self._persistence_reason,
        )


def _by_class(item: tuple[AlertClass, datetime]) -> tuple[str, datetime]:
    """Sort key: class name, then episode start (stable log order)."""
    return item[0].value, item[1]


def _late_resolution(due: Outbound, cleared_at: datetime) -> str:
    """Say when a late resolution's condition cleared, why it is late, and whether it is back.

    Fixed words and timestamps only (the message text rules). Every clause must be true of
    this resolution: the phase and API status shown are the clearing's only when they were
    kept (``due.moment``), else the current ones, and it is late either because the
    delivery result of an earlier message (announcement or escalation) came back after the
    clearing, or because a restart of the sidecar lost that result.

    Args:
        due: The late ``RESOLVED``.
        cleared_at: When its condition cleared (``due.cleared_at``, not None).
    """
    facts = "as at that time" if due.moment is not None else "as at sending"
    detail = f"cleared at {format_utc(cleared_at)} (phase and API status {facts}); "
    if due.result_lost:
        detail += (
            "sent after a restart of the sidecar, which lost the delivery result of an "
            "earlier message about it"
        )
    else:
        detail += "sent once the delivery result of an earlier message about it was known"
    if due.active_again_since is not None:
        detail += f"; active again since {format_utc(due.active_again_since)}"
    return detail


def _not_measured(gateway: GatewaySnapshot, probe: ProbeSnapshot) -> str:
    """Say what a heartbeat cannot vouch for; empty when everything is measured.

    A heartbeat means "the sidecar runs and no alert is active". That is reassuring only as
    far as the sidecar can see, so the message names every blind spot: an API that is not
    probed right now (with the probe's own reason) and a gateway that writes no feeds. A
    sidecar that cannot read the phase at all sends no heartbeat (see ``LadderEngine.step``).
    """
    gaps: list[str] = []
    if probe.status is ProbeStatus.NOT_MEASURED:
        gaps.append(f"the API ({probe.reason})")
    if not gateway.feeds_seen:
        gaps.append("the gateway's event and metrics feeds (none seen)")
    return "Not measured: " + "; ".join(gaps) if gaps else ""
