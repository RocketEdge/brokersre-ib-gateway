"""An in-process TCP server that speaks the minimum of the IB API wire protocol.

It exists to exercise the real ``ib_async`` client inside ``probe/adapter.py`` without a
gateway: the handshake, the two messages every API server sends after ``startApi``
(managed accounts, next valid id), the time request, and error/notice messages. Every
message the client sends is recorded, which is how the tests prove that the adapter sends
nothing but ``startApi`` and the time request.

Wire format (IB API v100+): each message is a 4-byte big-endian length followed by
NUL-terminated text fields; the client opens with the literal ``API`` and a NUL byte.
"""

from __future__ import annotations

import asyncio
import contextlib
import struct
from typing import Literal

SERVER_VERSION = 178
ACCOUNT = "DU1234567"

MSG_ERROR = "4"
MSG_NEXT_VALID_ID = "9"
MSG_MANAGED_ACCOUNTS = "15"
MSG_CURRENT_TIME = "49"
REQ_CURRENT_TIME = "49"

Mode = Literal["ok", "silent", "no_time_answer", "client_id_in_use", "malformed_after_accounts"]


def frame(*fields: object) -> bytes:
    """Encode one API message."""
    payload = "".join(f"{field}\0" for field in fields).encode()
    return struct.pack(">I", len(payload)) + payload


class WireGateway:
    """Scriptable API server on 127.0.0.1 (ephemeral port).

    Attributes:
        mode: ``ok``; ``silent`` (accepts TCP, never answers the handshake);
            ``no_time_answer`` (handshake ok, time requests ignored); ``client_id_in_use``
            (error 326 after startApi, then the socket is closed).
        epoch: The time (whole seconds since the epoch) returned to a time request.
        greeting: ``(code, text)`` notices sent right after the handshake.
        received: Decoded messages sent by clients after the version handshake.
        port: The listening port (set by ``start``).
    """

    def __init__(self) -> None:
        self.mode: Mode = "ok"
        self.epoch = 1_800_000_000
        self.greeting: list[tuple[int, str]] = [
            (2104, "Market data farm connection is OK:usfarm"),
            (2106, "HMDS data farm connection is OK:ushmds"),
            (2158, "Sec-def data farm connection is OK:secdefnj"),
        ]
        self.received: list[list[str]] = []
        self.port = 0
        self.time_requested = asyncio.Event()
        self._server: asyncio.Server | None = None
        self._writers: list[asyncio.StreamWriter] = []

    async def start(self) -> int:
        """Start listening and return the port."""
        self._server = await asyncio.start_server(self._serve, "127.0.0.1", 0)
        self.port = self._server.sockets[0].getsockname()[1]
        return self.port

    async def stop(self) -> None:
        """Close every client socket and the listener."""
        self.drop_clients()
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()

    def drop_clients(self) -> None:
        """Close every client connection, as a restarting gateway does."""
        for writer in self._writers:
            writer.close()
        self._writers.clear()

    def push_error(self, code: int, text: str) -> None:
        """Send an error/notice (request id -1) to every connected client."""
        for writer in self._writers:
            writer.write(frame(MSG_ERROR, 2, -1, code, text, ""))

    async def _read_frame(self, reader: asyncio.StreamReader) -> list[str]:
        """Read one length-prefixed message and return its fields."""
        (length,) = struct.unpack(">I", await reader.readexactly(4))
        payload = await reader.readexactly(length)
        return payload.decode().split("\0")[:-1]

    async def _serve(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        """Serve one client according to ``mode``."""
        self._writers.append(writer)
        with contextlib.suppress(asyncio.IncompleteReadError, ConnectionError):
            assert await reader.readexactly(4) == b"API\0"
            (length,) = struct.unpack(">I", await reader.readexactly(4))
            await reader.readexactly(length)  # "v157..178"
            if self.mode == "silent":
                await reader.read()  # hold the socket open until the client gives up
                return
            writer.write(frame(SERVER_VERSION, "20261112 15:00:00 UTC"))
            self.received.append(await self._read_frame(reader))  # startApi
            if self.mode == "client_id_in_use":
                text = "Unable to connect as the client id is already in use. Retry with a unique client id."
                writer.write(frame(MSG_ERROR, 2, -1, 326, text, ""))
                await writer.drain()
                writer.close()
                return
            if self.mode == "malformed_after_accounts":
                # The account list and a message with a non-numeric id in one segment.
                writer.write(frame(MSG_MANAGED_ACCOUNTS, 1, ACCOUNT) + frame("x", 1, 1))
                await writer.drain()
                await reader.read()
                return
            writer.write(frame(MSG_MANAGED_ACCOUNTS, 1, ACCOUNT))
            writer.write(frame(MSG_NEXT_VALID_ID, 1, 1))
            for code, text in self.greeting:
                writer.write(frame(MSG_ERROR, 2, -1, code, text, ""))
            while True:
                fields = await self._read_frame(reader)
                self.received.append(fields)
                if fields[0] == REQ_CURRENT_TIME:
                    self.time_requested.set()
                    if self.mode != "no_time_answer":
                        writer.write(frame(MSG_CURRENT_TIME, 1, self.epoch))
