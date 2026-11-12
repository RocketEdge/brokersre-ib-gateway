"""A minimal HTTP/1.1 server on asyncio streams for four read-only endpoints.

Why not a framework: the sidecar serves ``GET`` on a handful of fixed paths. Forty lines of
request-line parsing are easier to audit than a dependency, and every limit is explicit:

* the request head must arrive within ``header_timeout_s`` and fit ``max_header_bytes``;
* only ``GET`` is served; any other method is 405, any other path 404;
* a request body is never parsed or buffered;
* one request per connection (``Connection: close``), at most ``max_connections`` at once;
* the answer must be written within ``write_timeout_s``.

So a slow, silent or malformed client costs one bounded connection slot for a bounded time
and can never block the event loop or another client. Handlers are plain synchronous
callables that return a ``Response`` from in-memory snapshots; they do no I/O.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import re
from collections.abc import Callable, Mapping
from dataclasses import dataclass

from brokersre_sidecar.logsetup import log_event

_LOGGER = logging.getLogger(__name__)

_HEAD_END = b"\r\n\r\n"
_METHOD_RE = re.compile(r"^[A-Z]{1,16}$")
_VERSIONS = frozenset({"HTTP/1.1", "HTTP/1.0"})
_REQUEST_LINE_PARTS = 3
_TEXT = "text/plain; charset=utf-8"

# After an answer to a request that was not fully read (wrong method, oversized head), the
# unread input is discarded for a moment before closing. Closing a socket with unread input
# makes the kernel send a reset, and the client would lose the answer.
_LINGER_BYTES = 256 * 1024

_REASONS = {
    200: "OK",
    400: "Bad Request",
    404: "Not Found",
    405: "Method Not Allowed",
    408: "Request Timeout",
    431: "Request Header Fields Too Large",
    500: "Internal Server Error",
    503: "Service Unavailable",
}


@dataclass(frozen=True, slots=True)
class Response:
    """An HTTP answer.

    Attributes:
        status: Status code.
        content_type: ``Content-Type`` header value.
        body: Body bytes.
        headers: Extra headers as ``(name, value)`` pairs.
    """

    status: int
    content_type: str
    body: bytes
    headers: tuple[tuple[str, str], ...] = ()


Handler = Callable[[], Response]
"""Builds the answer of one route from in-memory state; must not block."""


def _plain(status: int, text: str, *headers: tuple[str, str]) -> Response:
    """Build a short plain-text answer."""
    return Response(status, _TEXT, f"{text}\n".encode(), headers)


class HttpServer:
    """Serves ``GET`` on a fixed set of exact paths."""

    def __init__(
        self,
        routes: Mapping[str, Handler],
        *,
        host: str,
        port: int,
        header_timeout_s: float = 5.0,
        write_timeout_s: float = 5.0,
        max_header_bytes: int = 8192,
        max_connections: int = 32,
        linger_s: float = 1.0,
    ) -> None:
        """Create the server; nothing is bound until ``start``.

        Args:
            routes: Handler per exact path (``/livez`` ...).
            host: Address to bind.
            port: Port to bind (0 picks a free port; see ``port``).
            header_timeout_s: Time allowed for the complete request head.
            write_timeout_s: Time allowed for writing the answer.
            max_header_bytes: Largest accepted request head.
            max_connections: Connections served at once; more are answered 503.
            linger_s: Longest time unread input is discarded after an error answer.
        """
        self._routes = dict(routes)
        self._host = host
        self._port = port
        self._header_timeout_s = header_timeout_s
        self._write_timeout_s = write_timeout_s
        self._max_header_bytes = max_header_bytes
        self._max_connections = max_connections
        self._linger_s = linger_s
        self._server: asyncio.Server | None = None
        self.active_connections = 0
        """Connections currently being served."""

    @property
    def listening(self) -> bool:
        """True between a successful ``start`` and ``close``."""
        return self._server is not None

    @property
    def port(self) -> int:
        """The bound port (the configured port before ``start``)."""
        if self._server is not None and self._server.sockets:
            bound: int = self._server.sockets[0].getsockname()[1]
            return bound
        return self._port

    async def start(self) -> None:
        """Bind and start accepting connections.

        Raises:
            OSError: The address is in use or cannot be bound.
        """
        if self._server is None:
            self._server = await asyncio.start_server(
                self._handle, self._host, self._port, limit=self._max_header_bytes
            )

    async def serve_forever(self) -> None:
        """Start if necessary and serve until cancelled."""
        await self.start()
        assert self._server is not None  # noqa: S101 - set by start()
        await self._server.serve_forever()

    async def close(self) -> None:
        """Stop accepting connections. Idempotent."""
        server, self._server = self._server, None
        if server is not None:
            server.close()
            with contextlib.suppress(OSError, asyncio.CancelledError):
                await server.wait_closed()

    async def _handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        """Serve one connection: one request, one answer, close."""
        over_limit = self.active_connections >= self._max_connections
        self.active_connections += 1
        try:
            if over_limit:
                response: Response | None = _plain(
                    503, "too many connections", ("Retry-After", "1")
                )
                linger = True
            else:
                response, linger = await self._read_request(reader)
            if response is not None:
                await self._respond(writer, response)
                if linger:
                    await self._discard_input(reader)
        except ConnectionError, OSError:
            # The client went away; there is nobody to answer.
            pass
        finally:
            self.active_connections -= 1
            writer.close()
            with contextlib.suppress(ConnectionError, OSError, TimeoutError):
                await asyncio.wait_for(writer.wait_closed(), self._write_timeout_s)

    async def _read_request(self, reader: asyncio.StreamReader) -> tuple[Response | None, bool]:
        """Read the request head and route it.

        Returns:
            ``(response, linger)``: the answer (None when the client closed without sending
            anything) and whether unread input may remain on the socket.
        """
        try:
            head = await asyncio.wait_for(reader.readuntil(_HEAD_END), self._header_timeout_s)
        except TimeoutError:
            return _plain(408, "the request head was not received in time"), True
        except asyncio.LimitOverrunError:
            return _plain(431, "the request head is too large"), True
        except asyncio.IncompleteReadError as error:
            if not error.partial:
                return None, False
            return _plain(400, "incomplete request"), False
        try:
            line = head.split(b"\r\n", 1)[0].decode("ascii")
        except UnicodeDecodeError:
            return _plain(400, "malformed request line"), True
        parts = line.split(" ")
        if (
            len(parts) != _REQUEST_LINE_PARTS
            or not _METHOD_RE.fullmatch(parts[0])
            or not parts[1].startswith("/")
            or parts[2] not in _VERSIONS
        ):
            return _plain(400, "malformed request line"), True
        method, target, _version = parts
        if method != "GET":
            return _plain(405, "only GET is supported", ("Allow", "GET")), True
        handler = self._routes.get(target.split("?", 1)[0])
        if handler is None:
            return _plain(404, "not found"), False
        try:
            return handler(), False
        except Exception as error:  # noqa: BLE001 - a handler bug becomes a 500
            log_event(
                _LOGGER,
                logging.ERROR,
                "http_handler_failed",
                "an endpoint handler raised",
                error_type=type(error).__name__,
                error=str(error),
            )
            return _plain(500, "internal error"), False

    async def _respond(self, writer: asyncio.StreamWriter, response: Response) -> None:
        """Write the answer within the write timeout."""
        reason = _REASONS.get(response.status, "Status")
        headers = [
            f"HTTP/1.1 {response.status} {reason}",
            f"Content-Type: {response.content_type}",
            f"Content-Length: {len(response.body)}",
            "Connection: close",
            "Cache-Control: no-store",
            "X-Content-Type-Options: nosniff",
        ]
        headers += [f"{name}: {value}" for name, value in response.headers]
        writer.write("\r\n".join(headers).encode("ascii") + _HEAD_END + response.body)
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(writer.drain(), self._write_timeout_s)

    async def _discard_input(self, reader: asyncio.StreamReader) -> None:
        """Discard unread input briefly so the client receives the answer, not a reset.

        Bounded by ``linger_s`` seconds and ``_LINGER_BYTES`` bytes; nothing is kept.
        """
        discarded = 0
        with contextlib.suppress(TimeoutError, asyncio.LimitOverrunError, ValueError):
            async with asyncio.timeout(self._linger_s):
                while discarded < _LINGER_BYTES:
                    chunk = await reader.read(65536)
                    if not chunk:
                        return
                    discarded += len(chunk)
