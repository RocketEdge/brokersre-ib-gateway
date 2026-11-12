"""The task supervisor: isolation, restart with capped back-off, crash records."""

from __future__ import annotations

import asyncio
from collections.abc import Callable

from brokersre_sidecar.backoff import Backoff
from brokersre_sidecar.supervisor import Supervisor
from testkit import T0, FakeClock, RecordingSleep


class Crashing:
    """A task factory that raises ``times`` times, then runs until cancelled."""

    def __init__(self, times: int, error: type[Exception] = RuntimeError) -> None:
        self.left = times
        self.error = error
        self.running = asyncio.Event()

    async def __call__(self) -> None:
        if self.left > 0:
            self.left -= 1
            raise self.error("boom with CANARY detail")
        self.running.set()
        await asyncio.Event().wait()


async def run_until(supervisor: Supervisor, condition: Callable[[], bool]) -> None:
    """Run the supervisor until ``condition`` holds, then cancel it."""
    task = asyncio.ensure_future(supervisor.run())
    try:
        async with asyncio.timeout(5):
            while not condition():  # noqa: ASYNC110
                await asyncio.sleep(0)
    finally:
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)


def make(clock: FakeClock | None = None) -> tuple[Supervisor, RecordingSleep, FakeClock]:
    clock = clock or FakeClock()
    sleep = RecordingSleep(clock)
    supervisor = Supervisor(
        clock, sleep, backoff=Backoff(base_s=1.0, cap_s=8.0, jitter=0.0), rand=lambda: 0.5
    )
    return supervisor, sleep, clock


async def test_a_crashed_task_is_restarted_with_capped_exponential_back_off() -> None:
    supervisor, sleep, _ = make()
    factory = Crashing(6)
    supervisor.add("probe", factory)
    await run_until(supervisor, factory.running.is_set)
    assert sleep.calls == [1.0, 2.0, 4.0, 8.0, 8.0, 8.0]
    (record,) = supervisor.snapshot()
    assert (record.name, record.restarts, record.last_error) == ("probe", 6, "RuntimeError")
    assert record.last_crash_at is not None
    assert record.last_crash_at >= T0


async def test_one_crashing_task_never_stalls_another() -> None:
    supervisor, _, _ = make()
    ticks = 0
    done = asyncio.Event()

    async def healthy() -> None:
        nonlocal ticks
        while True:
            ticks += 1
            if ticks >= 50:
                done.set()
            await asyncio.sleep(0)

    supervisor.add("notify", Crashing(10_000, ValueError))
    supervisor.add("http", healthy)
    await run_until(supervisor, done.is_set)
    records = {record.name: record for record in supervisor.snapshot()}
    assert records["http"].restarts == 0
    assert records["http"].last_error is None
    assert records["notify"].restarts > 0
    assert records["notify"].last_error == "ValueError"


async def test_a_task_that_returns_is_treated_as_a_crash_and_restarted() -> None:
    supervisor, _, _ = make()
    runs = 0

    async def returns() -> None:
        nonlocal runs
        runs += 1

    supervisor.add("follow", returns)
    await run_until(supervisor, lambda: runs >= 3)
    (record,) = supervisor.snapshot()
    assert record.last_error == "TaskReturned"
    assert record.restarts >= 2


async def test_the_back_off_resets_after_a_stable_run() -> None:
    supervisor, sleep, clock = make()
    runs = 0
    finished = asyncio.Event()

    async def flaky() -> None:
        nonlocal runs
        runs += 1
        if runs <= 3:
            raise RuntimeError("early crash")
        if runs == 4:
            clock.advance(600)  # a long, healthy run
            raise RuntimeError("late crash")
        finished.set()
        await asyncio.Event().wait()

    supervisor.add("probe", flaky)
    await run_until(supervisor, finished.is_set)
    assert sleep.calls == [1.0, 2.0, 4.0, 1.0]


async def test_the_supervisor_is_alive_only_while_it_runs_and_tasks_stop_with_it() -> None:
    supervisor, _, _ = make()
    cancelled = asyncio.Event()

    async def worker() -> None:
        try:
            await asyncio.Event().wait()
        except asyncio.CancelledError:
            cancelled.set()
            raise

    supervisor.add("http", worker)
    assert supervisor.alive() is False
    seen_alive: list[bool] = []

    def observed_alive() -> bool:
        seen_alive.append(supervisor.alive())
        return seen_alive[-1]

    await run_until(supervisor, observed_alive)
    assert seen_alive[-1] is True
    assert cancelled.is_set()
    assert supervisor.alive() is False
    assert supervisor.snapshot()[0].state == "stopped"


async def test_states_distinguish_running_from_waiting_to_restart() -> None:
    clock = FakeClock()
    release = asyncio.Event()
    waiting = asyncio.Event()

    async def held_sleep(seconds: float) -> None:
        waiting.set()
        await release.wait()

    supervisor = Supervisor(clock, held_sleep, backoff=Backoff(1.0, 8.0, jitter=0.0))
    factory = Crashing(1)
    supervisor.add("probe", factory)
    task = asyncio.ensure_future(supervisor.run())
    await asyncio.wait_for(waiting.wait(), 5)
    assert supervisor.snapshot()[0].state == "backoff"
    release.set()
    await asyncio.wait_for(factory.running.wait(), 5)
    assert supervisor.snapshot()[0].state == "running"
    task.cancel()
    await asyncio.gather(task, return_exceptions=True)
