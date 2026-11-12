"""Read-only example client for IB Gateway that copes with a gateway that is not ready.

What it shows (the rules are spelled out in ``examples/README.md``):

* connect with retry: a refused or unanswered connection means "the gateway is not ready
  yet", so the client tries again with capped exponential back-off and jitter;
* IBKR code 1100 (connectivity between the gateway and IBKR lost): stop sending, keep the
  connection; 1102 (restored, data maintained): continue; 1101 (restored, data lost):
  continue and re-subscribe;
* the data-farm codes 2103/2105/2157 (broken) and 2104/2106/2158 (OK) are recorded and do
  not stop the client;
* the gateway's daily restart closes the socket: the client notices and reconnects.

It is read-only by construction: it connects with ``readonly=True``, asks ib_async for no
startup data, and its only request is the IBKR server time. It contains no order, cancel or
what-if call and no market-data subscription.

Data source: the TWS API of an IB Gateway (in this repository's container: the relay on port
4003 for live or 4004 for paper, usually published on the host as 4001 or 4002).
Frequency: one server-time request every ``--interval`` seconds (default 30).
External dependency: ib_async 2.1.0 (pinned in ``pyproject.toml``).

Run it::

    uv run python resilient_client.py --host 127.0.0.1 --port 4002 --client-id 101

Layers, each testable without a network:

* ``BackoffPolicy`` and ``GatewayState`` are pure;
* ``Session`` is the boundary; ``IbAsyncSession`` is its ib_async implementation and the
  only code that touches ib_async;
* ``ResilientClient`` holds the behaviour and is tested against a scriptable session.
"""

import argparse
import asyncio
import contextlib
import datetime as dt
import enum
import logging
import os
import random
import signal
import sys
import time
from collections.abc import Awaitable, Callable, Mapping, Sequence
from dataclasses import dataclass, field
from typing import Final, Protocol

import ib_async

LOGGER = logging.getLogger("resilient_client")

#: IBKR system message codes this client acts on (TWS API "System Message Codes").
CONNECTIVITY_LOST: Final = 1100
CONNECTIVITY_RESTORED_DATA_LOST: Final = 1101
CONNECTIVITY_RESTORED_DATA_KEPT: Final = 1102
CLIENT_ID_IN_USE: Final = 326

#: Data-farm codes mapped to the kind of farm they describe. The kind is the fallback name
#: of a farm whose message does not end in ``:<farm name>``.
FARM_BROKEN_CODES: Final[Mapping[int, str]] = {2103: "market-data", 2105: "hmds", 2157: "sec-def"}
FARM_OK_CODES: Final[Mapping[int, str]] = {2104: "market-data", 2106: "hmds", 2158: "sec-def"}

#: Largest exponent used for the back-off: 2**32 seconds is far beyond any sensible cap, and
#: a bounded exponent keeps the float arithmetic from overflowing after days of retries.
MAX_BACKOFF_EXPONENT: Final = 32

MAX_PORT: Final = 65535

ErrorHandler = Callable[[int, int, str], None]
DisconnectHandler = Callable[[], None]


class Readiness(enum.Enum):
    """Whether the client may send a request right now.

    * ``DISCONNECTED``: no API connection. Connect (with back-off) before anything else.
    * ``READY``: connected, and the gateway can reach IBKR. Requests are allowed.
    * ``CONNECTIVITY_LOST``: connected to the gateway, but the gateway reported 1100. Send
      nothing and keep the connection: IBKR restores it and reports 1101 or 1102.
    """

    DISCONNECTED = "disconnected"
    READY = "ready"
    CONNECTIVITY_LOST = "connectivity-lost"


class Action(enum.Enum):
    """What the caller of ``GatewayState`` must do after an event.

    * ``NONE``: nothing changed for the caller.
    * ``PAUSE``: stop sending requests until told otherwise.
    * ``RESUME``: requests may continue; subscriptions are intact.
    * ``RESUBSCRIBE``: requests may continue and every subscription must be made again.
    """

    NONE = "none"
    PAUSE = "pause"
    RESUME = "resume"
    RESUBSCRIBE = "resubscribe"


@dataclass(frozen=True, slots=True)
class BackoffPolicy:
    """Capped exponential back-off with jitter for connection attempts.

    The delay before retry number ``attempt`` (0 for the first retry) is drawn uniformly from
    ``[raw * (1 - jitter), raw]`` with ``raw = min(cap_s, base_s * 2**attempt)``. Jitter only
    shortens the delay, so ``cap_s`` is a hard upper bound.

    Why: a gateway that restarts must not be hammered, and several clients of one gateway must
    not reconnect in the same instant.

    Attributes:
        base_s: Delay before the first retry, in seconds; positive.
        cap_s: Largest delay, in seconds; at least ``base_s``.
        jitter: Fraction of the delay that may be shaved off, from 0 (none) to 1.

    Raises:
        ValueError: If a value is outside its range (checked when the policy is created).
    """

    base_s: float = 1.0
    cap_s: float = 30.0
    jitter: float = 0.25

    def __post_init__(self) -> None:
        """Refuse a policy that could yield a zero, negative or unbounded delay."""
        if self.base_s <= 0:
            raise ValueError("base_s must be positive")
        if self.cap_s < self.base_s:
            raise ValueError("cap_s must not be smaller than base_s")
        if not 0 <= self.jitter <= 1:
            raise ValueError("jitter must be between 0 and 1")

    def delay(self, attempt: int, rng: random.Random) -> float:
        """Return the pause before retry number ``attempt``, in seconds.

        Args:
            attempt: Number of the retry, counted from 0; must not be negative.
            rng: Source of the jitter (injected so that tests are deterministic).

        Returns:
            A delay in ``[raw * (1 - jitter), raw]``, never above ``cap_s``.

        Raises:
            ValueError: If ``attempt`` is negative.
        """
        if attempt < 0:
            raise ValueError("attempt must not be negative")
        raw = min(self.cap_s, self.base_s * 2.0 ** min(attempt, MAX_BACKOFF_EXPONENT))
        return raw * (1 - self.jitter * rng.random())


class GatewayState:
    """Pure state machine: readiness and data-farm status derived from gateway events.

    It has no I/O and no clock. Feed it the three kinds of event a client sees (connected,
    disconnected, an IBKR message code) and it answers with the ``Action`` the client must
    take. Invariants: a message code never makes a disconnected client ready; only 1101 and
    1102 end the pause that 1100 started; a disconnect forgets the farm status, because the
    next connection is a new session.
    """

    def __init__(self) -> None:
        """Start disconnected with no farm reported broken."""
        self._readiness = Readiness.DISCONNECTED
        self._broken_farms: set[str] = set()

    @property
    def readiness(self) -> Readiness:
        """Whether requests may be sent right now."""
        return self._readiness

    @property
    def broken_farms(self) -> tuple[str, ...]:
        """Names of the data farms currently reported broken, sorted."""
        return tuple(sorted(self._broken_farms))

    def on_connected(self) -> Action:
        """Record a new API connection.

        Returns:
            ``Action.RESUBSCRIBE``: a new session has no subscriptions, so whatever the client
            subscribes to must be set up now (again).
        """
        self._readiness = Readiness.READY
        self._broken_farms.clear()
        return Action.RESUBSCRIBE

    def on_disconnected(self) -> Action:
        """Record that the API connection is gone (closed by the peer or by the client).

        Returns:
            ``Action.PAUSE``: nothing may be sent until ``on_connected``.
        """
        self._readiness = Readiness.DISCONNECTED
        self._broken_farms.clear()
        return Action.PAUSE

    def on_error(self, code: int, message: str) -> Action:
        """Apply one IBKR message code.

        Args:
            code: The ``errorCode`` of the TWS API error callback.
            message: Its text; used only to read the farm name of a data-farm code
                (the part after the last colon, for example ``usfarm``).

        Returns:
            ``PAUSE`` for 1100, ``RESUME`` for 1102, ``RESUBSCRIBE`` for 1101, ``NONE`` for
            everything else (farm codes update ``broken_farms`` and return ``NONE``). Any code
            received while disconnected returns ``NONE`` and changes nothing.
        """
        if self._readiness is Readiness.DISCONNECTED:
            return Action.NONE
        if code == CONNECTIVITY_LOST:
            self._readiness = Readiness.CONNECTIVITY_LOST
            return Action.PAUSE
        if code == CONNECTIVITY_RESTORED_DATA_KEPT:
            self._readiness = Readiness.READY
            return Action.RESUME
        if code == CONNECTIVITY_RESTORED_DATA_LOST:
            self._readiness = Readiness.READY
            return Action.RESUBSCRIBE
        if code in FARM_BROKEN_CODES:
            self._broken_farms.add(_farm_name(message, FARM_BROKEN_CODES[code]))
        elif code in FARM_OK_CODES:
            self._broken_farms.discard(_farm_name(message, FARM_OK_CODES[code]))
        return Action.NONE


def _farm_name(message: str, kind: str) -> str:
    """Return the farm a data-farm message is about.

    IBKR writes ``Market data farm connection is OK:usfarm``: the name follows the last colon.
    The text is not a contract, so a message without a name falls back to ``kind``.
    """
    _, colon, name = message.rpartition(":")
    return name.strip() if colon and name.strip() else kind


class Session(Protocol):
    """The broker boundary: everything ``ResilientClient`` needs from an API connection.

    Implemented by ``IbAsyncSession`` for real use and by a scriptable fake in the tests.
    Contract: ``connect`` raises ``OSError`` (``ConnectionRefusedError``, ``TimeoutError``,
    ``ConnectionError`` are subclasses) when the gateway is not reachable or not ready;
    ``server_time`` raises ``TimeoutError`` when no answer arrives in time and
    ``ConnectionError`` when the connection closes meanwhile; handlers are called on the
    event loop, never from another thread.
    """

    def is_connected(self) -> bool:
        """Return whether an API connection currently stands."""
        ...

    async def connect(self, host: str, port: int, client_id: int, timeout_s: float) -> None:
        """Open a read-only API connection or raise ``OSError`` within ``timeout_s``."""
        ...

    async def server_time(self, timeout_s: float) -> dt.datetime:
        """Return IBKR's server time (timezone-aware) or raise within ``timeout_s``."""
        ...

    def disconnect(self) -> None:
        """Close the connection; safe to call when it is already closed."""
        ...

    def on_error(self, handler: ErrorHandler) -> None:
        """Register ``handler(req_id, code, message)`` for IBKR message codes."""
        ...

    def on_disconnected(self, handler: DisconnectHandler) -> None:
        """Register ``handler()`` for a connection that was closed."""
        ...


class IbAsyncSession:
    """``Session`` on top of ``ib_async.IB``; the only code here that touches ib_async.

    Choices, all verified against ib_async 2.1.0:

    * ``connectAsync(..., readonly=True, fetchFields=StartupFetchNONE)``: no order
      synchronisation and no account or execution fetch on connect. ib_async still asks for
      the positions once while connecting (a read-only request it makes unconditionally).
    * ``errorEvent`` emits ``(reqId, errorCode, errorString, contract)``; the contract is not
      passed on.
    * ib_async reacts to every 1102 by opening a new account-summary subscription that it
      never cancels (IBKR allows two; then error 322). A client that survives many outages
      would run into that, and this one needs no account data, so that handler is detached.

    Threading: ib_async runs on the asyncio event loop; so do all handlers.
    """

    def __init__(self, ib: ib_async.IB | None = None) -> None:
        """Wrap ``ib`` (a new ``ib_async.IB`` when omitted) and attach to its events.

        Args:
            ib: The ib_async object to use; create it inside a running event loop.
        """
        self._ib = ib if ib is not None else ib_async.IB()
        self._error_handlers: list[ErrorHandler] = []
        self._disconnect_handlers: list[DisconnectHandler] = []
        library_handler = getattr(self._ib, "_onError", None)
        if library_handler is not None:
            self._ib.errorEvent.disconnect(library_handler)
        self._ib.errorEvent += self._forward_error
        self._ib.disconnectedEvent += self._forward_disconnect

    def is_connected(self) -> bool:
        """Return whether ib_async reports a ready API connection."""
        return bool(self._ib.isConnected())

    async def connect(self, host: str, port: int, client_id: int, timeout_s: float) -> None:
        """Connect read-only, without startup data (see the class docstring).

        ib_async applies its ``timeout`` to every step of connecting separately (socket,
        handshake, each synchronisation request), so one attempt could take several times
        as long. One deadline around the whole call makes ``timeout_s`` the real limit.

        Raises:
            OSError: The gateway refused, did not answer within ``timeout_s`` seconds
                (``TimeoutError``), or closed the connection while connecting. Nothing is
                left connected when this is raised.
        """
        try:
            async with asyncio.timeout(timeout_s):
                await self._ib.connectAsync(
                    host,
                    port,
                    clientId=client_id,
                    timeout=timeout_s,
                    readonly=True,
                    fetchFields=ib_async.StartupFetchNONE,
                )
        except TimeoutError:
            self._ib.disconnect()
            raise

    async def server_time(self, timeout_s: float) -> dt.datetime:
        """Ask the gateway for IBKR's server time and return it in UTC.

        Raises:
            TimeoutError: No answer within ``timeout_s`` seconds.
            ConnectionError: The connection closed while the request was pending.
        """
        answer = await asyncio.wait_for(self._ib.reqCurrentTimeAsync(), timeout_s)
        return answer.astimezone(dt.UTC)

    def disconnect(self) -> None:
        """Close the API connection (no effect when it is already closed)."""
        self._ib.disconnect()

    def on_error(self, handler: ErrorHandler) -> None:
        """Register ``handler(req_id, code, message)`` for IBKR message codes."""
        self._error_handlers.append(handler)

    def on_disconnected(self, handler: DisconnectHandler) -> None:
        """Register ``handler()`` for a closed connection."""
        self._disconnect_handlers.append(handler)

    def _forward_error(self, req_id: int, code: int, message: str, _contract: object) -> None:
        """Pass ib_async's error event on to the registered handlers, without the contract."""
        for handler in self._error_handlers:
            handler(req_id, code, message)

    def _forward_disconnect(self) -> None:
        """Pass ib_async's disconnected event on to the registered handlers."""
        for handler in self._disconnect_handlers:
            handler()


@dataclass(frozen=True, slots=True)
class ClientConfig:
    """Settings of one ``ResilientClient``.

    Attributes:
        host: Gateway host name or address.
        port: API port (1 to 65535): the relay port of the gateway container or the host
            port it is published on.
        client_id: TWS API client id (0 or more). Every client connected to one gateway
            needs its own; a duplicate is refused with IBKR code 326.
        poll_interval_s: Seconds between two server-time requests; positive.
        connect_timeout_s: Seconds one connection attempt may take; positive.
        request_timeout_s: Seconds to wait for the server time; positive.
        max_missed_polls: Unanswered requests in a row after which the connection is
            treated as dead and replaced; at least 1.
        backoff: Pause policy between connection attempts.

    Raises:
        ValueError: If a value is outside its range (checked when the object is created).
    """

    host: str = "127.0.0.1"
    port: int = 4002
    client_id: int = 101
    poll_interval_s: float = 30.0
    connect_timeout_s: float = 10.0
    request_timeout_s: float = 10.0
    max_missed_polls: int = 3
    backoff: BackoffPolicy = field(default_factory=BackoffPolicy)

    def __post_init__(self) -> None:
        """Refuse a configuration that could never work."""
        if not 1 <= self.port <= MAX_PORT:
            raise ValueError("port must be between 1 and 65535")
        if self.client_id < 0:
            raise ValueError("client_id must not be negative")
        for name in ("poll_interval_s", "connect_timeout_s", "request_timeout_s"):
            if getattr(self, name) <= 0:
                raise ValueError(f"{name} must be positive")
        if self.max_missed_polls < 1:
            raise ValueError("max_missed_polls must be at least 1")


class ResilientClient:
    """Keep one read-only API connection usable across outages and gateway restarts.

    The client owns a ``Session`` and a ``GatewayState``. ``run`` loops forever: connect when
    disconnected (retrying with back-off), ask for the server time when ready, pause. Events
    from the session (IBKR message codes, a closed socket) update the state between two
    steps; they never start a request themselves.

    Robustness rules it implements:

    * a failed connection attempt is normal ("gateway not ready"), never an error;
    * during 1100 nothing is sent and the connection is kept;
    * ``max_missed_polls`` unanswered requests in a row replace a connection that looks
      dead (a half-open socket never reports a disconnect);
    * stopping (cancelling ``run``) closes the connection, which frees the client id.

    Attributes:
        state: The readiness state machine (read it, do not write it).
        resubscriptions: How often subscriptions had to be (re-)established: once per
            connection plus once per 1101.
        last_server_time: The last server time received, in UTC, or ``None``.

    Concurrency: single event loop, no threads; not safe to share between loops.
    """

    def __init__(
        self,
        session: Session,
        config: ClientConfig,
        *,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
        rng: random.Random | None = None,
        on_resubscribe: Callable[[], None] | None = None,
    ) -> None:
        """Create the client and attach it to the session's events.

        Args:
            session: The broker boundary; not connected yet.
            config: Endpoint, timeouts and back-off.
            sleep: Awaitable pause, ``asyncio.sleep`` by default (injected by the tests).
            rng: Source of the back-off jitter; a new generator when omitted.
            on_resubscribe: Called whenever subscriptions must be (re-)established. This
                sample has none; a strategy sets up its subscriptions here.
        """
        self._session = session
        self._config = config
        self._sleep = sleep
        # Jitter needs no cryptographic randomness.
        self._rng = rng if rng is not None else random.Random()  # noqa: S311
        self._on_resubscribe = on_resubscribe
        self._missed_polls = 0
        self._stopping = False
        self.state = GatewayState()
        self.resubscriptions = 0
        self.last_server_time: dt.datetime | None = None
        session.on_error(self._handle_error)
        session.on_disconnected(self._handle_disconnected)

    async def connect_once(self) -> bool:
        """Make one connection attempt.

        Returns:
            ``True`` when the connection stands (the state is then ``READY`` and the
            re-subscribe hook has run), ``False`` when the gateway is not ready: connection
            refused, handshake not answered in time, connection cut while connecting, host
            unreachable. All of these are ``OSError`` and none is treated as a failure of
            the client. Any other exception is a defect and propagates.
        """
        config = self._config
        try:
            await self._session.connect(
                config.host, config.port, config.client_id, config.connect_timeout_s
            )
        except OSError as error:
            LOGGER.info(
                "gateway not ready at %s:%d (%s)", config.host, config.port, type(error).__name__
            )
            return False
        self._missed_polls = 0
        LOGGER.info("connected to %s:%d, client id %d", config.host, config.port, config.client_id)
        self._apply(self.state.on_connected())
        return True

    async def connect_until_ready(self) -> None:
        """Retry ``connect_once`` until it succeeds, pausing per the back-off policy.

        The attempt counter starts at zero on every call, so a later outage is retried
        quickly at first. There is no attempt limit: a gateway may wait for a second factor
        for a long time, and giving up would only move the retry loop into a supervisor.
        """
        attempt = 0
        while not await self.connect_once():
            delay = self._config.backoff.delay(attempt, self._rng)
            LOGGER.info("next connection attempt in %.1f s", delay)
            await self._sleep(delay)
            attempt += 1

    async def poll_once(self) -> dt.datetime | None:
        """Ask for the IBKR server time if, and only if, the client is ready.

        Returns:
            The server time in UTC, or ``None`` when nothing was sent (disconnected, or
            paused by 1100) or no usable answer came. An unanswered request counts towards
            ``max_missed_polls``; reaching it, or a connection that closed during the
            request, drops the connection so that ``run`` reconnects.
        """
        if self.state.readiness is not Readiness.READY:
            return None
        try:
            answer = await self._session.server_time(self._config.request_timeout_s)
        except TimeoutError:
            self._missed_polls += 1
            LOGGER.warning(
                "no answer to the server-time request (%d of %d in a row)",
                self._missed_polls,
                self._config.max_missed_polls,
            )
            if self._missed_polls >= self._config.max_missed_polls:
                LOGGER.error("the connection looks dead: closing it to reconnect")
                self._drop_connection()
            return None
        except ConnectionError:
            LOGGER.warning("the connection closed during the server-time request")
            self._drop_connection()
            return None
        self._missed_polls = 0
        self.last_server_time = answer.astimezone(dt.UTC)
        LOGGER.info("IBKR server time %s", self.last_server_time.isoformat())
        return self.last_server_time

    async def run(self) -> None:
        """Run until cancelled: connect when needed, poll when ready, pause, repeat.

        Cancelling the task is the way to stop; the connection is closed on the way out.
        """
        self._stopping = False
        try:
            while True:
                if self.state.readiness is Readiness.DISCONNECTED:
                    await self.connect_until_ready()
                await self.poll_once()
                await self._sleep(self._config.poll_interval_s)
        finally:
            # Tell the disconnect handler that this disconnect is ours, not the gateway's.
            self._stopping = True
            self._session.disconnect()

    def _apply(self, action: Action) -> None:
        """Carry out what the state machine asked for (only re-subscribing needs work)."""
        if action is Action.RESUBSCRIBE:
            self.resubscriptions += 1
            if self._on_resubscribe is not None:
                self._on_resubscribe()

    def _drop_connection(self) -> None:
        """Close the connection and make sure the state says so, whatever the session reports."""
        self._session.disconnect()
        self._handle_disconnected()

    def _handle_error(self, _req_id: int, code: int, message: str) -> None:
        """React to one IBKR message code.

        Only the code and, for farm codes, the farm name are logged: the raw text of an IBKR
        message can name an account.
        """
        if code == CLIENT_ID_IN_USE:
            LOGGER.error(
                "client id %d is already in use on this gateway (IBKR code 326): "
                "stop the other client or choose another --client-id",
                self._config.client_id,
            )
            return
        farms_before = self.state.broken_farms
        action = self.state.on_error(code, message)
        if action is Action.PAUSE:
            LOGGER.warning(
                "IBKR code 1100: connectivity lost; sending nothing, keeping the connection"
            )
        elif action is Action.RESUME:
            LOGGER.info("IBKR code 1102: connectivity restored, data maintained; continuing")
        elif action is Action.RESUBSCRIBE:
            LOGGER.warning("IBKR code 1101: connectivity restored, data lost; re-subscribing")
        elif self.state.broken_farms != farms_before:
            LOGGER.info(
                "IBKR code %d: data farms now broken: %s",
                code,
                ", ".join(self.state.broken_farms) or "none",
            )
        self._apply(action)

    def _handle_disconnected(self) -> None:
        """Record a closed connection once; ``run`` reconnects on its next step.

        A disconnect made by ``run`` on its way out is logged as what it is, a stop, so that
        the last line of a stopped client does not promise a reconnect.
        """
        if self.state.readiness is Readiness.DISCONNECTED:
            return
        self.state.on_disconnected()
        if self._stopping:
            LOGGER.info("disconnected: client stopped")
        else:
            LOGGER.warning("disconnected from the gateway (restart or shutdown); will reconnect")


def _port(text: str) -> int:
    """Parse a TCP port for argparse (1 to 65535)."""
    try:
        value = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a port number: {text!r}") from None
    if not 1 <= value <= MAX_PORT:
        raise argparse.ArgumentTypeError("a port is a number from 1 to 65535")
    return value


def _client_id(text: str) -> int:
    """Parse a TWS API client id for argparse (0 or more)."""
    try:
        value = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a client id: {text!r}") from None
    if value < 0:
        raise argparse.ArgumentTypeError("a client id is 0 or more")
    return value


def _seconds(text: str) -> float:
    """Parse a positive number of seconds for argparse."""
    try:
        value = float(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a number of seconds: {text!r}") from None
    if value <= 0:
        raise argparse.ArgumentTypeError("the interval must be positive")
    return value


def parse_args(argv: Sequence[str], environ: Mapping[str, str]) -> ClientConfig:
    """Build the configuration from the command line and the environment.

    Args:
        argv: Arguments without the program name.
        environ: Environment to read defaults from: ``IBGW_HOST``, ``IBGW_PORT`` (the two
            that ``wait-for-gateway.sh`` reads as well) and ``IB_CLIENT_ID``.

    Returns:
        The configuration; an option wins over the environment.

    Raises:
        SystemExit: With status 2 and a message on stderr for a value that cannot work
            (argparse's convention), whether it came from an option or the environment.
    """
    parser = argparse.ArgumentParser(
        prog="resilient_client.py",
        description="Read-only example: print the IBKR server time and survive gateway outages.",
    )
    parser.add_argument("--host", default=environ.get("IBGW_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=_port, default=environ.get("IBGW_PORT", "4002"))
    parser.add_argument("--client-id", type=_client_id, default=environ.get("IB_CLIENT_ID", "101"))
    parser.add_argument(
        "--interval", type=_seconds, default="30", help="seconds between two requests"
    )
    options = parser.parse_args(argv)
    return ClientConfig(
        host=options.host,
        port=options.port,
        client_id=options.client_id,
        poll_interval_s=options.interval,
    )


async def run_client(config: ClientConfig) -> None:
    """Run a client on a real ib_async session until SIGINT or SIGTERM.

    The signal handlers cancel this task, which makes ``ResilientClient.run`` disconnect. On
    Windows event loops cannot take signal handlers; Ctrl+C still ends ``asyncio.run``.
    """
    client = ResilientClient(IbAsyncSession(), config)
    task = asyncio.current_task()
    if task is not None:
        loop = asyncio.get_running_loop()
        for signum in (signal.SIGINT, signal.SIGTERM):
            with contextlib.suppress(NotImplementedError):
                loop.add_signal_handler(signum, task.cancel)
    await client.run()


def configure_logging() -> None:
    """Log to stderr at INFO with UTC timestamps, and silence ib_async's own loggers.

    Why ib_async is silenced: it logs the text of every IBKR message verbatim (that text can
    name an account) and every refused connection as an error (expected while a gateway
    restarts). This client reports both itself, by code and in one line each. Lower the
    level of the ``ib_async`` logger again when you debug the library.
    """
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)sZ %(levelname)s %(name)s: %(message)s"
    )
    logging.Formatter.converter = time.gmtime
    logging.getLogger("ib_async").setLevel(logging.CRITICAL)


def main(argv: Sequence[str] | None = None) -> int:
    """Entry point: parse the options, set up logging, run until stopped.

    Returns:
        0 after a requested stop. A usage error ends the process with status 2.
    """
    config = parse_args(sys.argv[1:] if argv is None else argv, os.environ)
    configure_logging()
    with contextlib.suppress(KeyboardInterrupt, asyncio.CancelledError):
        asyncio.run(run_client(config))
    return 0


if __name__ == "__main__":
    sys.exit(main())
