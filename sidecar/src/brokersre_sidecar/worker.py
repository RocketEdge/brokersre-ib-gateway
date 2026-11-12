"""A serial worker thread for blocking calls (leaf module).

The sidecar does two kinds of blocking file I/O: reading the gateway's log volume and saving
the notifier state. Each kind gets its own ``SerialWorker``:

* one thread per worker, so a stuck volume cannot delay the state save (and the other way
  round), and neither can exhaust a shared thread pool;
* one call at a time: while a call has not returned, ``start`` refuses the next one. A caller
  that stopped waiting must not start a second call behind a stuck first one; threads would
  pile up, and for the feed the file offsets a late call advanced would be lost;
* the future returned by ``start`` stays valid after the caller's own timeout, so a late
  result can still be collected;
* the thread is a daemon: a call that never returns cannot keep the process from exiting
  (threads of ``concurrent.futures`` executors are joined at interpreter exit).
"""

from __future__ import annotations

import asyncio
import queue
import threading
from collections.abc import Callable


class WorkerBusyError(Exception):
    """``SerialWorker.start`` was called while the previous call has not returned."""


class SerialWorker:
    """Runs blocking calls for one event loop on one dedicated daemon thread, one at a time.

    Contract: ``start`` and ``busy`` are used from the event-loop thread only. ``busy`` is
    True from ``start`` until the call's outcome has been handed to the loop, whether or not
    anybody still waits for the future.
    """

    def __init__(self, name: str) -> None:
        """Create the worker; the thread is started by the first ``start``.

        Args:
            name: Thread name, visible in stack dumps.
        """
        self._name = name
        self._jobs: queue.SimpleQueue[Callable[[], None] | None] = queue.SimpleQueue()
        self._thread: threading.Thread | None = None
        self._busy = False

    @property
    def busy(self) -> bool:
        """True while a call is running or its outcome is on its way to the loop."""
        return self._busy

    def start[T](self, function: Callable[[], T]) -> asyncio.Future[T]:
        """Start ``function`` on the worker thread.

        Args:
            function: A blocking callable without arguments.

        Returns:
            A future of the running loop that receives the result or the exception. It is
            never cancelled by the worker; awaiting it with a timeout does not stop the call.

        Raises:
            WorkerBusyError: The previous call has not returned; nothing was started.
        """
        if self._busy:
            raise WorkerBusyError(f"{self._name}: the previous call has not returned")
        loop = asyncio.get_running_loop()
        future: asyncio.Future[T] = loop.create_future()
        self._busy = True

        def settle(result: T | None, error: BaseException | None) -> None:
            """Hand the outcome to the future (event-loop thread)."""
            self._busy = False
            if future.done():
                return
            if error is not None:
                future.set_exception(error)
            else:
                future.set_result(result)  # type: ignore[arg-type]

        def job() -> None:
            """Run the call and post its outcome to the loop (worker thread)."""
            result: T | None = None
            error: BaseException | None = None
            try:
                result = function()
            except Exception as caught:  # noqa: BLE001 - delivered to the waiter
                error = caught
            try:
                loop.call_soon_threadsafe(settle, result, error)
            except RuntimeError:
                # The loop is closed: the sidecar is shutting down and nobody waits.
                self._busy = False

        if self._thread is None:
            self._thread = threading.Thread(target=self._run, name=self._name, daemon=True)
            self._thread.start()
        self._jobs.put(job)
        return future

    def close(self) -> None:
        """Let the thread end after the call it is running (idempotent, never blocks)."""
        if self._thread is not None:
            self._jobs.put(None)
            self._thread = None

    def _run(self) -> None:
        """Thread body: run queued jobs until the stop marker arrives."""
        while True:
            job = self._jobs.get()
            if job is None:
                return
            job()
