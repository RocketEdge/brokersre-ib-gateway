"""What every notification channel shares: the protocol, the error type, the HTTP transport.

A channel turns a ``Message`` into requests for one service and sends them. Failures are
reported as ``DeliveryError`` with a short category (``http_503``, ``timeout``, ``smtp_auth``
...) and a retry hint. The category is the only failure text that ever reaches a log,
``/status`` or ``/metrics``: exception messages of HTTP libraries quote the request URL,
and a webhook URL is a credential.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from typing import Protocol

import httpx

from brokersre_sidecar.notify.message import Message

_RETRYABLE_STATUS = frozenset({408, 425, 429})
_SERVER_ERROR = 500
_OK_LOW, _OK_HIGH = 200, 300


class DeliveryError(Exception):
    """A notification could not be delivered.

    Attributes:
        category: Short, fixed-vocabulary description; safe to log and to expose.
        retryable: False when retrying cannot help (rejected credentials, bad request).
    """

    def __init__(self, category: str, retryable: bool) -> None:
        """Create the error; ``str(error)`` is the category."""
        super().__init__(category)
        self.category = category
        self.retryable = retryable


class Channel(Protocol):
    """One destination of notifications.

    Contract: ``send`` either delivers the message or raises ``DeliveryError``; it is
    bounded in time by its transport; it never logs the message or the credentials.
    """

    name: str

    def wants(self, message: Message) -> bool:
        """Report whether this channel should receive ``message`` at all."""
        ...

    async def send(self, message: Message) -> None:
        """Deliver ``message``.

        Raises:
            DeliveryError: The service refused or could not be reached.
        """
        ...


@dataclass(frozen=True, slots=True)
class HttpRequest:
    """One outgoing HTTP request, built by a channel and sent by ``HttpTransport``.

    Attributes:
        url: Destination. May be or contain a credential; never logged.
        body: Request body bytes.
        headers: Request headers (may contain an ``Authorization`` credential).
        method: HTTP method.
    """

    url: str
    body: bytes
    headers: Mapping[str, str] = field(default_factory=dict)
    method: str = "POST"


class HttpTransport:
    """Sends ``HttpRequest`` values with one shared ``httpx.AsyncClient``.

    Every request has a total time bound, redirects are never followed (a redirect could
    carry the payload to a host the operator did not configure) and TLS certificates are
    verified by the client's defaults.
    """

    def __init__(self, client: httpx.AsyncClient, timeout_s: float = 10.0) -> None:
        """Wrap ``client``.

        Args:
            client: The shared HTTP client (a mock transport in tests).
            timeout_s: Bound applied to connect, write, read and pool wait of each request.
        """
        self._client = client
        self._timeout = httpx.Timeout(timeout_s)

    async def send(self, request: HttpRequest) -> None:
        """Send one request and require a 2xx answer.

        Raises:
            DeliveryError: ``timeout``, ``connect`` or ``transport`` (all retryable),
                ``http_<status>`` (retryable for 5xx, 408, 425 and 429 only), or
                ``invalid_url`` / ``invalid_request`` (final: the request cannot be
                built, for example a header value outside ASCII).
        """
        try:
            response = await self._client.request(
                request.method,
                request.url,
                content=request.body,
                headers=dict(request.headers),
                timeout=self._timeout,
                follow_redirects=False,
            )
        except httpx.TimeoutException:
            raise DeliveryError("timeout", retryable=True) from None
        except httpx.ConnectError:
            raise DeliveryError("connect", retryable=True) from None
        except httpx.InvalidURL:
            raise DeliveryError("invalid_url", retryable=False) from None
        except httpx.HTTPError:
            raise DeliveryError("transport", retryable=True) from None
        except UnicodeError:
            # The request could not be put on the wire at all. The configuration check
            # refuses such values; this keeps a miss from crashing the channel task.
            raise DeliveryError("invalid_request", retryable=False) from None
        status = response.status_code
        if _OK_LOW <= status < _OK_HIGH:
            return
        retryable = status >= _SERVER_ERROR or status in _RETRYABLE_STATUS
        raise DeliveryError(f"http_{status}", retryable=retryable)

    async def aclose(self) -> None:
        """Close the underlying client and its connections."""
        await self._client.aclose()


class HttpChannel:
    """Base of the channels that deliver over HTTP: build requests, send them in order."""

    name = "http"

    def __init__(self, transport: HttpTransport) -> None:
        """Bind the channel to the shared transport."""
        self._transport = transport

    def wants(self, message: Message) -> bool:
        """Accept every message unless a subclass narrows it."""
        return True

    def requests(self, message: Message) -> list[HttpRequest]:
        """Return the requests that deliver ``message`` (subclasses implement this)."""
        raise NotImplementedError

    async def send(self, message: Message) -> None:
        """Send every request of ``message`` in order; stop at the first failure."""
        for request in self.requests(message):
            await self._transport.send(request)
