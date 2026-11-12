"""The serial worker: blocking calls on one dedicated thread, never two at a time."""

from __future__ import annotations

import asyncio
import threading

import pytest

from brokersre_sidecar.worker import SerialWorker, WorkerBusyError


def is_busy(worker: SerialWorker) -> bool:
    """Read the flag through a function so that type narrowing does not stick."""
    return worker.busy


async def test_a_call_runs_on_the_workers_own_thread_and_returns_its_result() -> None:
    worker = SerialWorker("sidecar-test")
    try:
        name = await asyncio.wait_for(worker.start(lambda: threading.current_thread().name), 5)
        again = await asyncio.wait_for(worker.start(lambda: threading.current_thread().name), 5)
    finally:
        worker.close()
    assert name == again == "sidecar-test"
    assert name != threading.current_thread().name


async def test_an_exception_of_the_call_reaches_the_waiter() -> None:
    worker = SerialWorker("sidecar-test")

    def fail() -> None:
        raise OSError("disk full")

    try:
        with pytest.raises(OSError, match="disk full"):
            await asyncio.wait_for(worker.start(fail), 5)
        assert worker.busy is False
        assert await asyncio.wait_for(worker.start(lambda: 7), 5) == 7
    finally:
        worker.close()


async def test_a_second_call_is_refused_while_the_first_has_not_returned() -> None:
    worker = SerialWorker("sidecar-test")
    release = threading.Event()
    started = threading.Event()
    calls: list[str] = []

    def blocked() -> str:
        calls.append("first")
        started.set()
        release.wait(10)
        return "late"

    try:
        first = worker.start(blocked)
        await asyncio.to_thread(started.wait, 5)
        assert is_busy(worker)
        # The waiter gives up; the call itself keeps running and the worker stays busy.
        done, _ = await asyncio.wait({first}, timeout=0.05)
        assert not done
        with pytest.raises(WorkerBusyError):
            worker.start(lambda: calls.append("second"))
        release.set()
        # The late result is not lost: the same future completes.
        assert await asyncio.wait_for(first, 5) == "late"
        assert not is_busy(worker)
        assert calls == ["first"]
    finally:
        release.set()
        worker.close()


async def test_a_blocked_call_does_not_block_the_event_loop() -> None:
    worker = SerialWorker("sidecar-test")
    release = threading.Event()
    try:
        future = worker.start(lambda: release.wait(10))
        ticks = 0
        for _ in range(20):
            await asyncio.sleep(0.001)
            ticks += 1
        assert ticks == 20
        assert not future.done()
    finally:
        release.set()
        worker.close()


def test_the_worker_thread_is_a_daemon_so_a_stuck_call_cannot_keep_the_process_alive() -> None:
    async def scenario() -> bool:
        worker = SerialWorker("sidecar-daemon-check")
        release = threading.Event()
        try:
            worker.start(lambda: release.wait(10))
            await asyncio.sleep(0.01)
            (thread,) = [t for t in threading.enumerate() if t.name == "sidecar-daemon-check"]
            return thread.daemon
        finally:
            release.set()
            worker.close()

    assert asyncio.run(scenario()) is True


async def test_no_thread_exists_before_the_first_call() -> None:
    SerialWorker("sidecar-never-used")
    assert all(thread.name != "sidecar-never-used" for thread in threading.enumerate())


async def test_a_result_that_arrives_after_the_loop_closed_is_dropped_quietly() -> None:
    release = threading.Event()
    finished = threading.Event()

    def late() -> None:
        release.wait(10)
        finished.set()

    def scenario() -> SerialWorker:
        async def start() -> SerialWorker:
            worker = SerialWorker("sidecar-test")
            worker.start(late)
            await asyncio.sleep(0.01)
            return worker

        return asyncio.run(start())

    worker = await asyncio.to_thread(scenario)  # that loop is closed now
    release.set()
    assert await asyncio.to_thread(finished.wait, 5)
    worker.close()
