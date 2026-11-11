"""A scriptable fake of the ``IbClient`` protocol: the gateway as the probe engine sees it.

No socket, no sleep: behaviours are switched by attributes and time passes on the test's
``FakeClock``. A hanging gateway is modelled by advancing the clock by the timeout and
raising the same error the real adapter raises.
"""

from __future__ import annotations

from datetime import datetime, timedelta
from typing import Literal

from brokersre_sidecar.probe import (
    ErrorListener,
    IbConnectError,
    IbDisconnectedError,
    IbTimeoutError,
)
from testkit import FakeClock

FARMS_OK: tuple[tuple[int, str], ...] = (
    (2104, "Market data farm connection is OK:usfarm"),
    (2106, "HMDS data farm connection is OK:ushmds"),
    (2158, "Sec-def data farm connection is OK:secdefnj"),
)
CLIENT_ID_IN_USE = (
    326,
    "Unable to connect as the client id is already in use. Retry with a unique client id.",
)


class FakeIb:
    """Scriptable gateway.

    Attributes:
        connect_behaviour: ``ok`` (handshake completes), ``refuse`` (TCP refused at once),
            ``hang`` (TCP accepted, API never answers: the connect timeout elapses) or
            ``client_id_in_use`` (error 326, then the gateway closes the socket).
        time_behaviour: ``ok``, ``timeout`` (no answer) or ``disconnect`` (socket drops).
        rtt_s: Simulated duration of a successful round trip.
        skew_s: IBKR time minus local time.
        greeting: Errors/notices the gateway sends right after a successful handshake.
        connect_calls, time_calls, disconnect_calls: How often each method was called.
        connect_args: Arguments of the last ``connect`` call.
    """

    def __init__(self, clock: FakeClock) -> None:
        self._clock = clock
        self._listener: ErrorListener | None = None
        self._connected = False
        self.connect_behaviour: Literal["ok", "refuse", "hang", "client_id_in_use"] = "ok"
        self.time_behaviour: Literal["ok", "timeout", "disconnect"] = "ok"
        self.rtt_s = 0.05
        self.skew_s = 0.0
        self.greeting: tuple[tuple[int, str], ...] = FARMS_OK
        self.connect_calls = 0
        self.time_calls = 0
        self.disconnect_calls = 0
        self.connect_args: tuple[str, int, int, float] | None = None

    def set_error_listener(self, listener: ErrorListener) -> None:
        self._listener = listener

    def emit(self, code: int, message: str = "") -> None:
        """Deliver an API error/notice to the engine, as the gateway would at any time."""
        assert self._listener is not None, "the engine must register its listener first"
        self._listener(code, message)

    def drop(self) -> None:
        """Simulate the gateway closing the API socket between two probes."""
        self._connected = False

    async def connect(self, host: str, port: int, client_id: int, timeout_s: float) -> None:
        self.connect_calls += 1
        self.connect_args = (host, port, client_id, timeout_s)
        if self.connect_behaviour == "refuse":
            raise IbConnectError("ConnectionRefusedError")
        if self.connect_behaviour == "hang":
            self._clock.advance(timeout_s)
            raise IbConnectError("TimeoutError")
        if self.connect_behaviour == "client_id_in_use":
            self.emit(*CLIENT_ID_IN_USE)
            self._clock.advance(timeout_s)
            raise IbConnectError("TimeoutError")
        self._connected = True
        for code, message in self.greeting:
            self.emit(code, message)

    async def current_time(self, timeout_s: float) -> datetime:
        self.time_calls += 1
        if not self._connected:
            raise IbDisconnectedError("not connected")
        if self.time_behaviour == "timeout":
            self._clock.advance(timeout_s)
            raise IbTimeoutError("no answer")
        if self.time_behaviour == "disconnect":
            self._connected = False
            raise IbDisconnectedError("socket closed")
        # The gateway stamps its answer halfway through the round trip.
        self._clock.advance(self.rtt_s / 2)
        answer = self._clock.now() + timedelta(seconds=self.skew_s)
        self._clock.advance(self.rtt_s / 2)
        return answer

    def is_connected(self) -> bool:
        return self._connected

    def disconnect(self) -> None:
        self.disconnect_calls += 1
        self._connected = False
