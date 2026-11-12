"""The notifier: evaluate the rules, climb the ladder, queue the messages, save the state."""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Callable
from typing import Literal

from brokersre_sidecar.clock import Clock
from brokersre_sidecar.logsetup import log_event
from brokersre_sidecar.model.health import NotifierSnapshot, ProbeSnapshot
from brokersre_sidecar.model.state import GatewaySnapshot
from brokersre_sidecar.notify.dispatcher import Dispatcher
from brokersre_sidecar.notify.ladder import LadderEngine
from brokersre_sidecar.notify.message import MessageFactory
from brokersre_sidecar.notify.rules import RuleEngine
from brokersre_sidecar.notify.store import NotifierStore

_LOGGER = logging.getLogger(__name__)


class Notifier:
    """One evaluation step per call of ``tick`` (about once a second).

    ``tick`` does no network I/O: it only queues messages on the dispatcher, whose workers
    deliver them. The state file is written only when the ladder state changed. A state
    directory that is missing or read-only is not fatal: the notifier keeps its state in
    memory and says so in ``/status``.
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
        volume_present: Callable[[], bool],
        ready: Callable[[], bool],
    ) -> None:
        """Wire the notifier.

        Args:
            rules: Produces a verdict per alert class.
            ladder: Decides which notification is due.
            factory: Renders due notifications into messages.
            dispatcher: Receives the messages.
            store: State file, or None to keep state in memory only.
            clock: Time source.
            gateway: Returns the current gateway snapshot.
            probe: Returns the current probe snapshot.
            volume_present: Reports whether the gateway log volume is mounted.
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
        self._volume_present = volume_present
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
        evaluations = self._rules.evaluate(
            gateway, probe, now=now, volume_present=self._volume_present()
        )
        for due in self._ladder.step(evaluations, now):
            message = self._factory.build(
                due.kind,
                due.alert_class,
                detail=due.detail,
                escalation_step=due.escalation_step,
                since=due.since,
                phase=gateway.phase,
                api_status=probe.status.value,
                now=now,
            )
            self._dispatcher.enqueue(message, due.channels)
            log_event(
                _LOGGER,
                logging.INFO,
                "notify_queued",
                alert_class=message.alert_class,
                kind=message.kind,
                severity=message.severity,
                channels=list(due.channels),
            )
        if self._ladder.dirty:
            await self._save()

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
