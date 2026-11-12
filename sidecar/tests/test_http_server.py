"""The HTTP endpoints: routing, limits, and resistance to slow or malformed clients."""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator

import pytest

from brokersre_sidecar.http import HttpServer, Response

GENEROUS = 5.0


def text(body: str, status: int = 200) -> Response:
    return Response(status, "text/plain; charset=utf-8", body.encode())


def explode() -> Response:
    raise RuntimeError("handler bug with CANARY detail")


ROUTES = {
    "/livez": lambda: text("ok\n"),
    "/readyz": lambda: text("not_measured: first probe pending\n", 503),
    "/status": lambda: Response(200, "application/json", b'{"schema":"x"}'),
    "/boom": explode,
}


@pytest.fixture
async def server() -> AsyncIterator[HttpServer]:
    instance = HttpServer(
        ROUTES, host="127.0.0.1", port=0, header_timeout_s=0.2, max_connections=4, linger_s=0.05
    )
    await instance.start()
    task = asyncio.ensure_future(instance.serve_forever())
    yield instance
    task.cancel()
    await asyncio.gather(task, return_exceptions=True)
    await instance.close()


async def exchange(server: HttpServer, raw: bytes, *, close_write: bool = False) -> bytes:
    """Send raw bytes and return everything the server answers until it closes."""
    reader, writer = await asyncio.open_connection("127.0.0.1", server.port)
    writer.write(raw)
    await writer.drain()
    if close_write:
        writer.write_eof()
    try:
        return await asyncio.wait_for(reader.read(), GENEROUS)
    finally:
        writer.close()


def parse(raw: bytes) -> tuple[int, dict[str, str], bytes]:
    head, _, body = raw.partition(b"\r\n\r\n")
    lines = head.decode("ascii").split("\r\n")
    status = int(lines[0].split(" ")[1])
    headers = {
        name.lower(): value.strip() for name, value in (line.split(":", 1) for line in lines[1:])
    }
    return status, headers, body


async def get(server: HttpServer, path: str) -> tuple[int, dict[str, str], bytes]:
    return parse(await exchange(server, f"GET {path} HTTP/1.1\r\nHost: x\r\n\r\n".encode()))


async def test_a_route_answers_with_status_type_length_and_closes(server: HttpServer) -> None:
    status, headers, body = await get(server, "/livez")
    assert (status, body) == (200, b"ok\n")
    assert headers["content-type"] == "text/plain; charset=utf-8"
    assert headers["content-length"] == "3"
    assert headers["connection"] == "close"
    assert headers["cache-control"] == "no-store"
    assert headers["x-content-type-options"] == "nosniff"


async def test_a_handler_decides_the_status_code(server: HttpServer) -> None:
    status, _, body = await get(server, "/readyz")
    assert (status, body) == (503, b"not_measured: first probe pending\n")


async def test_a_query_string_is_ignored_and_http_1_0_is_accepted(server: HttpServer) -> None:
    status, _, body = await get(server, "/status?pretty=1")
    assert (status, body) == (200, b'{"schema":"x"}')
    status, _, _ = parse(await exchange(server, b"GET /livez HTTP/1.0\r\n\r\n"))
    assert status == 200


async def test_an_unknown_path_is_404(server: HttpServer) -> None:
    for path in ("/", "/metrics/", "/LIVEZ", "/../etc/passwd", "/livez/extra"):
        status, _, _ = await get(server, path)
        assert status == 404, path


@pytest.mark.parametrize("method", ["POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH"])
async def test_any_other_method_is_405_with_an_allow_header(
    server: HttpServer, method: str
) -> None:
    raw = await exchange(server, f"{method} /livez HTTP/1.1\r\nHost: x\r\n\r\n".encode())
    status, headers, _ = parse(raw)
    assert status == 405
    assert headers["allow"] == "GET"


async def test_a_request_body_is_never_read(server: HttpServer) -> None:
    body = b"x" * 100_000
    head = f"POST /status HTTP/1.1\r\nHost: x\r\nContent-Length: {len(body)}\r\n\r\n".encode()
    reader, writer = await asyncio.open_connection("127.0.0.1", server.port)
    writer.write(head)
    await writer.drain()
    # The answer arrives before a single body byte was sent.
    answer = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), GENEROUS)
    writer.close()
    assert answer.startswith(b"HTTP/1.1 405 ")


@pytest.mark.parametrize(
    "raw",
    [
        b"NONSENSE\r\n\r\n",
        b"GET\r\n\r\n",
        b"GET /livez\r\n\r\n",
        b"GET /livez HTTP/9.9\r\n\r\n",
        b"GET livez HTTP/1.1\r\n\r\n",
        b"\xff\xfe\x00 /livez HTTP/1.1\r\n\r\n",
        b"GET /livez HTTP/1.1 extra\r\n\r\n",
    ],
)
async def test_a_malformed_request_line_is_400(server: HttpServer, raw: bytes) -> None:
    status, _, _ = parse(await exchange(server, raw))
    assert status == 400


async def test_an_oversized_header_block_is_431(server: HttpServer) -> None:
    raw = b"GET /livez HTTP/1.1\r\nX-Padding: " + b"a" * 20_000 + b"\r\n\r\n"
    status, _, _ = parse(await exchange(server, raw))
    assert status == 431


async def test_a_client_that_never_finishes_its_headers_gets_408_and_is_disconnected(
    server: HttpServer,
) -> None:
    status, _, _ = parse(await exchange(server, b"GET /livez HTTP/1.1\r\nHost: x\r\n"))
    assert status == 408


async def test_a_client_that_connects_and_closes_at_once_is_tolerated(server: HttpServer) -> None:
    assert await exchange(server, b"", close_write=True) == b""
    status, _, _ = await get(server, "/livez")
    assert status == 200


async def test_a_stalled_client_does_not_delay_other_clients(server: HttpServer) -> None:
    _stalled_reader, stalled_writer = await asyncio.open_connection("127.0.0.1", server.port)
    stalled_writer.write(b"GET /livez HTTP/1.1\r\n")
    await stalled_writer.drain()
    try:
        status, _, _ = await asyncio.wait_for(get(server, "/livez"), GENEROUS)
        assert status == 200
    finally:
        stalled_writer.close()


async def test_connections_beyond_the_limit_are_refused_with_503() -> None:
    # A long header timeout: the four stalled connections must still hold their slots when
    # the fifth arrives, however slow the machine.
    server = HttpServer(
        ROUTES, host="127.0.0.1", port=0, header_timeout_s=60, max_connections=4, linger_s=0.05
    )
    await server.start()
    held = []
    try:
        for _ in range(4):
            reader, writer = await asyncio.open_connection("127.0.0.1", server.port)
            writer.write(b"GET /livez HTTP/1.1\r\n")
            await writer.drain()
            held.append((reader, writer))
        async with asyncio.timeout(GENEROUS):
            while server.active_connections < 4:  # noqa: ASYNC110
                await asyncio.sleep(0)
        status, headers, _ = await get(server, "/livez")
        assert status == 503
        assert headers["retry-after"] == "1"
    finally:
        for _, writer in held:
            writer.close()
        await server.close()


async def test_a_handler_that_raises_is_a_500_without_details_and_the_server_survives(
    server: HttpServer,
) -> None:
    status, _, body = await get(server, "/boom")
    assert status == 500
    assert b"CANARY" not in body
    status, _, _ = await get(server, "/livez")
    assert status == 200


async def test_the_bound_port_is_reported_and_close_is_idempotent() -> None:
    instance = HttpServer({"/livez": lambda: text("ok\n")}, host="127.0.0.1", port=0)
    await instance.start()
    assert instance.port > 0
    await instance.close()
    await instance.close()
