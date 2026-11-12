"""Task supervisor: every subsystem is an isolated asyncio task that is restarted on a crash.

The sidecar does four independent things (follow the gateway's files, probe the API, serve
HTTP, notify). Each runs as its own task under ``Supervisor``; a task that raises or returns
is recorded (name of the exception, time, restart count) and started again after a capped
exponential back-off. A crash in one task never cancels another. The records are published
in ``/status`` and ``/metrics``, so a subsystem that keeps crashing is visible, not silent.
"""

from __future__ import annotations

import asyncio
import logging
import random
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import datetime
from typing import Literal

from brokersre_sidecar.backoff import Backoff
from brokersre_sidecar.clock import Clock, Sleep
from brokersre_sidecar.logsetup import log_event
from brokersre_sidecar.model.health import TaskSnapshot

_LOGGER = logging.getLogger(__name__)

TaskFactory = Callable[[], Awaitable[None]]
"""Starts one run of a task; the coroutine is expected to run until cancelled."""


@dataclass(slots=True)
class _Record:
    """Mutable supervision record of one task."""

    state: Literal["running", "backoff", "stopped"] = "stopped"
    restarts: int = 0
    last_error: str | None = None
    last_crash_at: datetime | None = None


class Supervisor:
    """Runs named tasks and restarts the ones that stop.

    Contract: ``run`` returns only by cancellation; cancelling it cancels every task.
    ``alive`` is True exactly while ``run`` is executing (this is what ``/livez`` reports).
    """

    def __init__(
        self,
        clock: Clock,
        sleep: Sleep,
        *,
        backoff: Backoff | None = None,
        stable_after_s: float = 300.0,
        rand: Callable[[], float] = random.random,
    ) -> None:
        """Create the supervisor.

        Args:
            clock: Time source for crash records and for measuring how long a run lasted.
            sleep: Awaitable delay between a crash and the restart.
            backoff: Restart delays (default 1 s doubling to 60 s, 20 % jitter).
            stable_after_s: A run that lasted at least this long resets the back-off, so an
                occasional crash is retried quickly and a crash loop is slowed down.
            rand: Random source of the jitter.
        """
        self._clock = clock
        self._sleep = sleep
        self._backoff = backoff if backoff is not None else Backoff(base_s=1.0, cap_s=60.0)
        self._stable_after_s = stable_after_s
        self._rand = rand
        self._factories: dict[str, TaskFactory] = {}
        self._records: dict[str, _Record] = {}
        self._alive = False

    def add(self, name: str, factory: TaskFactory) -> None:
        """Register a task before ``run`` is called.

        Args:
            name: Stable task name shown in ``/status`` and as a metric label.
            factory: Called for every (re)start of the task.
        """
        self._factories[name] = factory
        self._records[name] = _Record()

    def alive(self) -> bool:
        """Report whether the supervisor is running its tasks."""
        return self._alive

    def snapshot(self) -> tuple[TaskSnapshot, ...]:
        """Return the supervision record of every task, in registration order."""
        return tuple(
            TaskSnapshot(
                name=name,
                state=record.state,
                restarts=record.restarts,
                last_error=record.last_error,
                last_crash_at=record.last_crash_at,
            )
            for name, record in self._records.items()
        )

    async def run(self) -> None:
        """Run every registered task until this coroutine is cancelled."""
        self._alive = True
        try:
            async with asyncio.TaskGroup() as group:
                for name, factory in self._factories.items():
                    group.create_task(self._guard(name, factory), name=f"sidecar-{name}")
        finally:
            self._alive = False

    async def _guard(self, name: str, factory: TaskFactory) -> None:
        """Run one task forever: record every stop and restart it after a back-off."""
        record = self._records[name]
        attempt = 0
        while True:
            started = self._clock.monotonic()
            record.state = "running"
            try:
                await factory()
                error_name = "TaskReturned"
                detail = "the task returned; it is expected to run until cancelled"
            except asyncio.CancelledError:
                record.state = "stopped"
                raise
            except Exception as error:  # noqa: BLE001 - the one place that must outlive any bug
                error_name = type(error).__name__
                detail = str(error)
            if self._clock.monotonic() - started >= self._stable_after_s:
                attempt = 0
            attempt += 1
            record.restarts += 1
            record.last_error = error_name
            record.last_crash_at = self._clock.now()
            record.state = "backoff"
            delay = self._backoff.delay(attempt, self._rand)
            log_event(
                _LOGGER,
                logging.ERROR,
                "task_crashed",
                "a background task stopped and will be restarted",
                task=name,
                error_type=error_name,
                error=detail,
                restarts=record.restarts,
                restart_in_s=round(delay, 1),
            )
            await self._sleep(delay)
