"""The small surface of the IB API that the probe uses, as a Protocol.

Everything outside ``probe/adapter.py`` talks to the gateway through ``IbClient``. The
surface is deliberately tiny and read-only: connect, ask for the server time, disconnect,
and receive error/notice codes. There is no method that could place, modify or cancel an
order, request market data or read account data, so no caller can do any of that by
mistake.
"""

from __future__ import annotations

from collections.abc import Callable
from datetime import datetime
from typing import Protocol

ErrorListener = Callable[[int, str], None]
"""Receives ``(code, text)`` of every API error/notice. The text comes from the gateway and
is used only to extract a farm name; it is never logged or forwarded."""


class IbError(Exception):
    """Base class of probe transport failures. The message is a short category, never data."""


class IbConnectError(IbError):
    """The TCP connection or the API handshake did not complete in time."""


class IbTimeoutError(IbError):
    """The gateway did not answer the time request in time."""


class IbDisconnectedError(IbError):
    """The API connection is not established or dropped during the request."""


class IbClient(Protocol):
    """One read-only API connection to the gateway.

    Contract: every awaitable method is bounded by its ``timeout_s`` and raises an
    ``IbError`` subclass on failure; ``disconnect`` and ``is_connected`` never raise.
    """

    def set_error_listener(self, listener: ErrorListener) -> None:
        """Register the receiver of API error/notice codes (replaces any previous one)."""
        ...

    async def connect(self, host: str, port: int, client_id: int, timeout_s: float) -> None:
        """Open the socket and complete the API handshake without any startup request.

        Raises:
            IbConnectError: Refused, timed out, or the gateway closed the socket (which is
                what it does for a client id that is in use, after sending error 326).
        """
        ...

    async def current_time(self, timeout_s: float) -> datetime:
        """Ask the gateway for IBKR's current time (whole seconds) and return it in UTC.

        Raises:
            IbTimeoutError: No answer within ``timeout_s``.
            IbDisconnectedError: Not connected, or the socket dropped while waiting.
        """
        ...

    def is_connected(self) -> bool:
        """Report whether the API handshake is complete and the socket is still up."""
        ...

    def disconnect(self) -> None:
        """Close the connection if there is one. Idempotent; never raises."""
        ...
