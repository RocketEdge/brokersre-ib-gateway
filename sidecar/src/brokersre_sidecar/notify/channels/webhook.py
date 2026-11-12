"""Generic JSON webhook, optionally signed with HMAC-SHA256."""

from __future__ import annotations

import hashlib
import hmac
import json

from brokersre_sidecar import __version__
from brokersre_sidecar.config.secrets import Secret
from brokersre_sidecar.notify.channels.base import HttpChannel, HttpRequest, HttpTransport
from brokersre_sidecar.notify.message import Message

SIGNATURE_HEADER = "X-BrokerSRE-Signature"
USER_AGENT = f"brokersre-sidecar/{__version__}"


def json_body(payload: object) -> bytes:
    """Serialise ``payload`` compactly and deterministically (sorted keys, UTF-8)."""
    return json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def json_headers() -> dict[str, str]:
    """Return the headers of a JSON POST from the sidecar."""
    return {"Content-Type": "application/json", "User-Agent": USER_AGENT}


class WebhookChannel(HttpChannel):
    """POSTs ``Message.as_dict()`` (schema ``brokersre.sidecar.alert.v1``) to one URL.

    With a secret, the header ``X-BrokerSRE-Signature: sha256=<hex>`` carries the
    HMAC-SHA256 of the exact body bytes, so the receiver can verify origin and integrity.
    """

    name = "webhook"

    def __init__(self, transport: HttpTransport, url: Secret, hmac_secret: Secret | None) -> None:
        """Create the channel.

        Args:
            transport: Shared HTTP transport.
            url: The receiver's URL (a credential: never logged).
            hmac_secret: Shared secret for the signature header, or None for no signature.
        """
        super().__init__(transport)
        self._url = url
        self._hmac_secret = hmac_secret

    def requests(self, message: Message) -> list[HttpRequest]:
        """Return the single signed POST for ``message``."""
        body = json_body(message.as_dict())
        headers = json_headers()
        if self._hmac_secret is not None:
            digest = hmac.new(self._hmac_secret.reveal().encode(), body, hashlib.sha256)
            headers[SIGNATURE_HEADER] = f"sha256={digest.hexdigest()}"
        return [HttpRequest(url=self._url.reveal(), body=body, headers=headers)]
