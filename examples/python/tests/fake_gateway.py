"""A stand-in for the API side of an IB Gateway: enough wire protocol to try a client offline.

It listens on a TCP port and speaks the text form of the TWS API protocol as server version
178 (what ib_async 2.1.0 negotiates; IBKR's own clients fall back to it as well): the
handshake, the two messages that complete a connection, the answer to a positions request,
the answer to a server-time request, and error messages pushed on demand. It knows nothing
about orders or market data and ignores every other request.

Two uses:

* the end-to-end tests drive the real ib_async through it (``test_end_to_end.py``);
* by hand, to watch a sample client react without an IBKR account::

      uv run python tests/fake_gateway.py --port 4002

  then type ``1100``, ``1102``, ``1101``, ``2103``, ``2104``, ``drop`` or ``quit``.

Data source: none (the account name it reports is made up). It never contacts IBKR.
External dependencies: none (standard library only).
"""

import argparse
import asyncio
import contextlib
import logging
import struct
import sys
import time
from collections.abc import Callable, Sequence
from typing import Final

LOGGER = logging.getLogger("fake_gateway")

#: The server version announced in the handshake: the text protocol, before protobuf.
SERVER_VERSION: Final = 178

#: Message ids of the TWS API that this stand-in understands or sends.
REQUEST_START_API: Final = 71
REQUEST_POSITIONS: Final = 61
REQUEST_CURRENT_TIME: Final = 49
MESSAGE_ERROR: Final = 4
MESSAGE_NEXT_VALID_ID: Final = 9
MESSAGE_MANAGED_ACCOUNTS: Final = 15
MESSAGE_CURRENT_TIME: Final = 49
MESSAGE_POSITION_END: Final = 62

#: A frame longer than this is not a TWS API message; the connection is closed.
MAX_FRAME_BYTES: Final = 1_048_576

#: Text of the messages the interactive mode can push, by code.
PUSHABLE_MESSAGES: Final[dict[int, str]] = {
    1100: "Connectivity between IBKR and the gateway has been lost",
    1101: "Connectivity between IBKR and the gateway has been restored - data lost",
    1102: "Connectivity between IBKR and the gateway has been restored - data maintained",
    2103: "Market data farm connection is broken:usfarm",
    2104: "Market data farm connection is OK:usfarm",
    2105: "HMDS data farm connection is broken:ushmds",
    2106: "HMDS data farm connection is OK:ushmds",
    2157: "Sec-def data farm connection is broken:secdefil",
    2158: "Sec-def data farm connection is OK:secdefil",
}


def encode_frame(*fields: object) -> bytes:
    """Return one TWS API message: a 4-byte big-endian length, then NUL-terminated fields."""
    payload = "".join(f"{field}\0" for field in fields).encode()
    return struct.pack(">I", len(payload)) + payload


async def read_frame(reader: asyncio.StreamReader) -> bytes:
    """Read one length-prefixed frame and return its payload.

    Raises:
        asyncio.IncompleteReadError: The peer closed the connection.
        ValueError: The length field is larger than ``MAX_FRAME_BYTES``.
    """
    (length,) = struct.unpack(">I", await reader.readexactly(4))
    if length > MAX_FRAME_BYTES:
        raise ValueError(f"frame of {length} bytes is not a TWS API message")
    return await reader.readexactly(length)


class FakeGateway:
    """A scriptable API endpoint.

    Contract:
        * ``start`` listens; every client gets the handshake answer, and after its start-API
          message the next valid id and one (made-up) managed account, which is what makes a
          TWS API client consider itself connected.
        * A positions request is answered with "end of positions", a server-time request
          with ``clock()`` as whole epoch seconds. Any other request is recorded and ignored.
        * ``send_error`` pushes an IBKR message code to every connected client;
          ``drop_clients`` closes their sockets (what a restart looks like); ``stop`` also
          stops listening, so that new connections are refused.

    Attributes:
        port: The port being listened on (0 before ``start``).
        hellos: The version range each client offered, for example ``v157..178``.
        requests: Every message received after the handshake, as its list of fields.

    Concurrency: one event loop; create, use and stop it inside the same loop.
    """

    def __init__(self, clock: Callable[[], float] = time.time) -> None:
        """Create a gateway that is not listening yet; ``clock`` supplies the server time."""
        self._clock = clock
        self._server: asyncio.Server | None = None
        self._writers: set[asyncio.StreamWriter] = set()
        self.port = 0
        self.hellos: list[str] = []
        self.requests: list[list[str]] = []

    @property
    def request_ids(self) -> list[int]:
        """The message id of every request received, in order."""
        return [int(fields[0]) for fields in self.requests]

    @property
    def client_count(self) -> int:
        """How many clients are connected right now."""
        return len(self._writers)

    async def start(self, host: str = "127.0.0.1", port: int = 0) -> int:
        """Listen on ``host:port`` (0 picks a free port) and return the port."""
        self._server = await asyncio.start_server(self._serve, host, port)
        self.port = int(self._server.sockets[0].getsockname()[1])
        return self.port

    async def stop(self) -> None:
        """Stop listening and close every client connection."""
        if self._server is not None:
            self._server.close()
            await self.drop_clients()
            await self._server.wait_closed()
            self._server = None

    async def drop_clients(self) -> None:
        """Close every client connection and keep listening."""
        for writer in list(self._writers):
            writer.close()
            with contextlib.suppress(OSError):
                await writer.wait_closed()
        self._writers.clear()

    async def send_error(self, code: int, message: str, req_id: int = -1) -> None:
        """Push IBKR message ``code`` with ``message`` to every connected client.

        The fields are those of server version 178: message id, version 2, request id, code,
        text and an empty advanced-order-reject field.
        """
        for writer in list(self._writers):
            writer.write(encode_frame(MESSAGE_ERROR, 2, req_id, code, message, ""))
            await writer.drain()

    async def _serve(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        """Serve one client until it disconnects; never raises into the server."""
        self._writers.add(writer)
        try:
            await self._handshake(reader, writer)
            while True:
                fields = (await read_frame(reader)).decode(errors="replace").split("\0")[:-1]
                self.requests.append(fields)
                await self._answer(fields, writer)
        except asyncio.IncompleteReadError, ConnectionError, ValueError:
            LOGGER.info("client disconnected")
        finally:
            self._writers.discard(writer)
            writer.close()

    async def _handshake(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        """Read ``API`` plus a NUL byte and the offered version range; answer the handshake."""
        if await reader.readexactly(4) != b"API\0":
            raise ValueError("not a TWS API client")
        self.hellos.append((await read_frame(reader)).decode(errors="replace").strip())
        connection_time = time.strftime("%Y%m%d %H:%M:%S UTC", time.gmtime(self._clock()))
        writer.write(encode_frame(SERVER_VERSION, connection_time))
        await writer.drain()
        LOGGER.info("client connected, offered %s", self.hellos[-1])

    async def _answer(self, fields: list[str], writer: asyncio.StreamWriter) -> None:
        """Answer the three requests this stand-in understands; ignore the rest."""
        request_id = int(fields[0]) if fields and fields[0].isdigit() else -1
        if request_id == REQUEST_START_API:
            writer.write(encode_frame(MESSAGE_NEXT_VALID_ID, 1, 1))
            writer.write(encode_frame(MESSAGE_MANAGED_ACCOUNTS, 1, "FAKE0000"))
        elif request_id == REQUEST_POSITIONS:
            writer.write(encode_frame(MESSAGE_POSITION_END, 1))
        elif request_id == REQUEST_CURRENT_TIME:
            writer.write(encode_frame(MESSAGE_CURRENT_TIME, 1, int(self._clock())))
        else:
            LOGGER.info("request %d ignored", request_id)
        await writer.drain()


async def interactive(port: int) -> None:
    """Run a gateway on ``port`` and obey the commands typed on standard input.

    Commands: a code from ``PUSHABLE_MESSAGES`` pushes that message, ``drop`` closes the
    client connections (a restart as the client sees it), ``quit`` or end of input stops.
    """
    gateway = FakeGateway()
    await gateway.start(port=port)
    codes = ", ".join(str(code) for code in PUSHABLE_MESSAGES)
    LOGGER.info("listening on 127.0.0.1:%d; type a code (%s), drop or quit", port, codes)
    loop = asyncio.get_running_loop()
    try:
        while True:
            line = await loop.run_in_executor(None, sys.stdin.readline)
            command = line.strip()
            # An empty string is the end of input; an empty line is just the Enter key.
            if not line or command == "quit":
                break
            if command == "drop":
                await gateway.drop_clients()
            elif command.isdigit() and int(command) in PUSHABLE_MESSAGES:
                await gateway.send_error(int(command), PUSHABLE_MESSAGES[int(command)])
            else:
                LOGGER.info("unknown command")
    finally:
        await gateway.stop()


def main(argv: Sequence[str] | None = None) -> int:
    """Entry point of the interactive mode; returns the process exit status."""
    parser = argparse.ArgumentParser(description="Stand-in for an IB Gateway API port (offline).")
    parser.add_argument("--port", type=int, default=4002)
    options = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s: %(message)s")
    with contextlib.suppress(KeyboardInterrupt):
        asyncio.run(interactive(options.port))
    return 0


if __name__ == "__main__":
    sys.exit(main())
