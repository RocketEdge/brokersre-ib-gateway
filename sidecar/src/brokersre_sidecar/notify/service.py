"""The notifier: evaluate the rules, climb the ladder, queue the messages, save the state."""

from __future__ import annotations

import asyncio
import functools
import logging
from collections.abc import Callable
from typing import Literal

from brokersre_sidecar.clock import Clock
from brokersre_sidecar.logsetup import log_event
from brokersre_sidecar.model.health import NotifierSnapshot, ProbeSnapshot
from brokersre_sidecar.model.state import GatewaySnapshot
from brokersre_sidecar.notify.dispatcher import Dispatcher
from brokersre_sidecar.notify.ladder import LadderEngine, Outbound
from brokersre_sidecar.notify.message import MessageFactory
from brokersre_sidecar.notify.rules import RuleEngine
from brokersre_sidecar.notify.store import NotifierStore
from brokersre_sidecar.vocab import UNKNOWN_PHASE, MessageKind, ProbeStatus

_LOGGER = logging.getLogger(__name__)
_TRACKED = (MessageKind.FIRING, MessageKind.ESCALATION)


class Notifier:
    """One evaluation step per call of ``tick`` (about once a second).

    ``tick`` does no network I/O: it only queues messages on the dispatcher, whose workers
    deliver them and report back whether a channel accepted each one. The state file is
    written only when the ladder state changed. A state directory that is missing or
    read-only is not fatal: the notifier keeps its state in memory and says so in
    ``/status``.
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
        for due in self._ladder.step(evaluations, now, can_see=can_see):
            message = self._factory.build(
                due.kind,
                due.alert_class,
                detail=(
                    _not_measured(gateway, probe)
                    if due.kind is MessageKind.HEARTBEAT
                    else due.detail
                ),
                escalation_step=due.escalation_step,
                since=due.since,
                phase=gateway.phase,
                api_status=probe.status.value,
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
        if self._ladder.dirty:
            await self._save()

    def _delivered(self, due: Outbound, accepted: bool) -> None:
        """Tell the ladder whether a notification reached at least one channel."""
        self._ladder.record_result(due, delivered=accepted, now=self._clock.now())
        if not accepted:
            log_event(
                _LOGGER,
                logging.WARNING,
                "notify_undelivered",
                "no channel accepted the notification; it will be sent again",
                alert_class=due.alert_class.value,
                kind=due.kind.value,
                attempt=due.attempt,
            )

    async def _save(self) -> None:
        """Write the ladder state; fall back to memory on failure."""
        state = self._ladder.export_state()
        if self._store is None or self._persistence != "file":
            return
        try:
            await asyncio.to_thread(self._store.save, state)
        except OSError as error:
            self._persistence = "memory"
            self._persistence_reason = f"saving the state failed ({type(error).__name__})"
            log_event(_LOGGER, logging.WARNING, "notifier_state_memory", self._persistence_reason)

    def snapshot(self) -> NotifierSnapshot:
        """Return the notifier's state for ``/status`` and ``/metrics``."""
        return NotifierSnapshot(
            enabled=True,
            channels=self._dispatcher.snapshot(),
            active_alerts=self._ladder.active(),
            state_persistence=self._persistence,
            state_persistence_reason=self._persistence_reason,
        )


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
