"""``IbClient`` implemented with ib_async. The ONLY module that imports ``ib_async``.

Why the low-level ``ib_async.Client`` and not the high-level ``ib_async.IB`` (verified in
the 2.1.0 source):

* ``IB.connectAsync`` always sends ``reqPositions``, even with ``readonly=True`` and
  ``fetchFields=StartupFetchNONE``: a position subscription the probe has no use for;
* ``IB`` answers error 1102 with ``reqAccountSummaryAsync()``, a subscription that is never
  cancelled; IBKR allows two, so a connection that lives through a few daily resets would
  start failing with error 322.

``Client`` performs exactly the handshake (version exchange, ``startApi``) and then sends
only what this module asks for, which is the server-time request. The wrapper below
implements the handful of callbacks ``Client`` and its decoder call; every other inbound
message type is ignored by the decoder because the wrapper has no method for it.

Nothing here can place, modify or cancel an order or request market data: the methods that
would do so are simply never referenced (``tests/test_forbidden_calls.py`` scans for them).
"""

from __future__ import annotations

import asyncio
import logging
from datetime import UTC, datetime

from ib_async.client import Client

from brokersre_sidecar.probe.protocol import (
    ErrorListener,
    IbConnectError,
    IbDisconnectedError,
    IbTimeoutError,
)


class _TimeProbeWrapper:
    """The EWrapper subset needed for a handshake and a time round trip.

    Method names and signatures are dictated by ib_async's decoder. The account list the
    gateway sends after the handshake is deliberately not stored.
    """

    def __init__(self) -> None:
        self.listener: ErrorListener | None = None
        self.pending: asyncio.Future[int] | None = None

    def connectAck(self) -> None:
        """Called when the version exchange completed; nothing to do."""

    def setEventsDone(self) -> None:
        """Called on socket close to end subscriptions; the probe has none."""

    def nextValidId(self, reqId: int) -> None:
        """Called with the next order id; irrelevant to a client that never sends orders."""

    def managedAccounts(self, accountsList: str) -> None:
        """Called with the account list; ignored so account ids are not kept here."""

    def connectionClosed(self) -> None:
        """Called when an established connection drops: fail the pending time request."""
        if self.pending is not None and not self.pending.done():
            self.pending.set_exception(IbDisconnectedError("socket closed"))

    def error(
        self, reqId: int, errorCode: int, errorString: str, advancedOrderRejectJson: str = ""
    ) -> None:
        """Called for every API error/notice: forward code and text to the listener."""
        if self.listener is not None:
            self.listener(int(errorCode), str(errorString))

    def currentTime(self, time: int) -> None:
        """Called with the server time in whole seconds: complete the pending request."""
        if self.pending is not None and not self.pending.done():
            self.pending.set_result(int(time))


class IbAsyncClient:
    """One read-only API connection, backed by ``ib_async.Client``.

    Contract: see ``IbClient``. Must be used from the event loop thread. A failed
    ``connect`` leaves the client disconnected and reusable.
    """

    def __init__(self) -> None:
        """Create the client; no socket is opened until ``connect``.

        Side effects:
            Silences the ``ib_async`` loggers: on a decode error the library logs the raw
            message fields, which can contain account ids, and the probe engine reports
            every outcome itself.
        """
        logging.getLogger("ib_async").setLevel(logging.CRITICAL + 1)
        self._wrapper = _TimeProbeWrapper()
        self._client = Client(self._wrapper)

    def set_error_listener(self, listener: ErrorListener) -> None:
        """Register the receiver of API error/notice codes."""
        self._wrapper.listener = listener

    async def connect(self, host: str, port: int, client_id: int, timeout_s: float) -> None:
        """Open the socket and complete the handshake; send nothing else.

        Raises:
            IbConnectError: Refused, timed out or closed by the gateway. The message is the
                exception class name only.
        """
        try:
            await self._client.connectAsync(host, port, client_id, timeout_s)
        except (TimeoutError, OSError) as error:
            # ib_async has already closed the socket and reset itself.
            raise IbConnectError(type(error).__name__) from None

    async def current_time(self, timeout_s: float) -> datetime:
        """Ask for the server time and wait for the answer.

        Raises:
            IbDisconnectedError: Not connected, or the socket dropped while waiting.
            IbTimeoutError: No answer within ``timeout_s``.
        """
        if not self._client.isReady():
            raise IbDisconnectedError("not connected")
        pending: asyncio.Future[int] = asyncio.get_running_loop().create_future()
        self._wrapper.pending = pending
        try:
            self._client.reqCurrentTime()
            epoch = await asyncio.wait_for(pending, timeout_s)
        except TimeoutError:
            raise IbTimeoutError("no answer") from None
        except ConnectionError:
            raise IbDisconnectedError("socket closed") from None
        finally:
            self._wrapper.pending = None
        return datetime.fromtimestamp(epoch, UTC)

    def is_connected(self) -> bool:
        """True when the handshake completed and the socket has not dropped."""
        return bool(self._client.isReady())

    def disconnect(self) -> None:
        """Close the socket if open. Idempotent; never raises."""
        try:
            self._client.disconnect()
        except (OSError, RuntimeError) as error:
            # Closing a transport that the loop already tore down; nothing left to release.
            logging.getLogger(__name__).debug("disconnect ignored: %s", type(error).__name__)
