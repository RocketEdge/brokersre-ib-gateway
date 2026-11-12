"""Scriptable stand-ins for the broker boundary; nothing here opens a socket.

Two fakes, one per layer of ``resilient_client``:

* ``FakeSession`` implements the ``Session`` protocol. The tests of ``ResilientClient`` script
  its connection attempts and its server-time answers and push IBKR message codes through it.
* ``FakeIB`` looks like the part of ``ib_async.IB`` that ``IbAsyncSession`` touches. Its events
  are real ``eventkit.Event`` objects (the event class ib_async itself uses), so the adapter's
  wiring is exercised with the real emit path.

External dependencies: ``eventkit`` (installed with ib_async). Data source: none.
"""

import asyncio
import datetime as dt
from collections.abc import Callable
from typing import Any

from eventkit import Event

ErrorHandler = Callable[[int, int, str], None]
DisconnectHandler = Callable[[], None]

#: The answer of a healthy gateway to a server-time request.
SERVER_TIME = dt.datetime(2026, 11, 12, 14, 30, 0, tzinfo=dt.UTC)


class FakeSession:
    """A ``Session`` whose behaviour is scripted by the test.

    Contract:
        * ``connect_script`` holds one entry per future connection attempt: an exception
          instance to raise, or ``None`` to succeed. When it is empty every attempt succeeds.
        * ``time_script`` holds one entry per future server-time request: an exception
          instance to raise or a ``datetime`` to return. When it is empty ``SERVER_TIME`` is
          returned.
        * ``emit_error`` and ``drop`` play the gateway's side: an IBKR message code, and the
          socket being closed by the peer (what the daily restart looks like).

    Every call is recorded so that a test can assert on what was (not) sent.
    """

    def __init__(
        self,
        connect_script: list[BaseException | None] | None = None,
        time_script: list[BaseException | dt.datetime] | None = None,
    ) -> None:
        """Create a disconnected session with the given scripts (see the class contract)."""
        self.connect_script: list[BaseException | None] = list(connect_script or [])
        self.time_script: list[BaseException | dt.datetime] = list(time_script or [])
        self.connected = False
        self.connect_calls: list[tuple[str, int, int, float]] = []
        self.time_requests: list[float] = []
        self.disconnect_calls = 0
        self._error_handlers: list[ErrorHandler] = []
        self._disconnect_handlers: list[DisconnectHandler] = []

    def is_connected(self) -> bool:
        """Return whether the scripted connection currently stands."""
        return self.connected

    async def connect(self, host: str, port: int, client_id: int, timeout_s: float) -> None:
        """Record the attempt, then succeed or raise as ``connect_script`` says."""
        self.connect_calls.append((host, port, client_id, timeout_s))
        outcome = self.connect_script.pop(0) if self.connect_script else None
        if outcome is not None:
            raise outcome
        self.connected = True

    async def server_time(self, timeout_s: float) -> dt.datetime:
        """Record the request, then answer or raise as ``time_script`` says."""
        self.time_requests.append(timeout_s)
        outcome = self.time_script.pop(0) if self.time_script else SERVER_TIME
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome

    def disconnect(self) -> None:
        """Record the call and close the connection, notifying the handlers as ib_async does."""
        self.disconnect_calls += 1
        if self.connected:
            self.connected = False
            for handler in self._disconnect_handlers:
                handler()

    def on_error(self, handler: ErrorHandler) -> None:
        """Register a handler for IBKR message codes."""
        self._error_handlers.append(handler)

    def on_disconnected(self, handler: DisconnectHandler) -> None:
        """Register a handler for a closed connection."""
        self._disconnect_handlers.append(handler)

    def emit_error(self, code: int, message: str = "", req_id: int = -1) -> None:
        """Play the gateway sending IBKR message ``code`` to every error handler."""
        for handler in self._error_handlers:
            handler(req_id, code, message)

    def drop(self) -> None:
        """Play the peer closing the socket (daily restart, gateway stopped)."""
        self.connected = False
        for handler in self._disconnect_handlers:
            handler()


class FakeIB:
    """The slice of ``ib_async.IB`` that ``IbAsyncSession`` uses, with recorded calls.

    The method and attribute names are ib_async's (camelCase) on purpose. ``errorEvent``
    emits ``(reqId, errorCode, errorString, contract)`` and ``disconnectedEvent`` emits
    nothing, exactly as in ib_async 2.1.0.
    """

    def __init__(self) -> None:
        """Create a disconnected fake with fresh events and empty call records."""
        self.errorEvent = Event("errorEvent")
        self.disconnectedEvent = Event("disconnectedEvent")
        self.connected = False
        self.connect_calls: list[dict[str, Any]] = []
        self.disconnect_calls = 0
        self.time_requests = 0
        self.time_answer: dt.datetime | None = dt.datetime(
            2026, 11, 12, 9, 30, 0, tzinfo=dt.timezone(dt.timedelta(hours=-5))
        )
        self.connect_hangs = False

    def isConnected(self) -> bool:
        """Return whether ``connectAsync`` has succeeded and ``disconnect`` was not called."""
        return self.connected

    async def connectAsync(self, host: str, port: int, **kwargs: Any) -> FakeIB:
        """Record the arguments and mark the fake as connected.

        With ``connect_hangs`` set the call never returns, like a synchronisation step of
        ib_async that the gateway does not answer.
        """
        self.connect_calls.append({"host": host, "port": port, **kwargs})
        if self.connect_hangs:
            await asyncio.Event().wait()
        self.connected = True
        return self

    def reqCurrentTimeAsync(self) -> asyncio.Future[dt.datetime]:
        """Return a future holding ``time_answer``; it never completes when that is ``None``."""
        self.time_requests += 1
        future: asyncio.Future[dt.datetime] = asyncio.get_running_loop().create_future()
        if self.time_answer is not None:
            future.set_result(self.time_answer)
        return future

    def disconnect(self) -> str | None:
        """Record the call, mark the fake as disconnected and emit ``disconnectedEvent``."""
        self.disconnect_calls += 1
        if self.connected:
            self.connected = False
            self.disconnectedEvent.emit()
        return None
