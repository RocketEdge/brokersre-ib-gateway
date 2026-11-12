"""ntfy: publish to a topic URL with title, priority, tags and click headers."""

from __future__ import annotations

from brokersre_sidecar.config.secrets import Secret
from brokersre_sidecar.notify.channels.base import HttpChannel, HttpRequest, HttpTransport
from brokersre_sidecar.notify.channels.webhook import USER_AGENT
from brokersre_sidecar.notify.message import Message
from brokersre_sidecar.vocab import MessageKind, Severity

# ntfy priorities: 5 urgent (bypasses do-not-disturb on phones), 4 high, 3 default, 2 low.
_PRIORITY = {
    Severity.CRITICAL.value: "5",
    Severity.ERROR.value: "4",
    Severity.WARNING.value: "3",
    Severity.INFO.value: "2",
}
_KIND_TAGS = {
    MessageKind.RESOLVED.value: "white_check_mark",
    MessageKind.HEARTBEAT.value: "heartbeat",
    MessageKind.TEST.value: "test_tube",
}
_SEVERITY_TAGS = {
    Severity.CRITICAL.value: "rotating_light",
    Severity.ERROR.value: "rotating_light",
    Severity.WARNING.value: "warning",
}


class NtfyChannel(HttpChannel):
    """Publishes to one ntfy topic (ntfy.sh or self-hosted)."""

    name = "ntfy"

    def __init__(self, transport: HttpTransport, url: Secret, token: Secret | None) -> None:
        """Create the channel.

        Args:
            transport: Shared HTTP transport.
            url: Topic URL; the topic name is the credential of an open ntfy server.
            token: Access token sent as ``Authorization: Bearer``, or None.
        """
        super().__init__(transport)
        self._url = url
        self._token = token

    def requests(self, message: Message) -> list[HttpRequest]:
        """Return the single publish request (text body, metadata in headers)."""
        tag = _KIND_TAGS.get(message.kind) or _SEVERITY_TAGS.get(message.severity, "information")
        headers = {
            "Content-Type": "text/plain; charset=utf-8",
            "User-Agent": USER_AGENT,
            "Title": message.headline,
            "Priority": _PRIORITY.get(message.severity, "3"),
            "Tags": tag,
        }
        if message.runbook is not None:
            headers["Click"] = message.runbook
        if self._token is not None:
            headers["Authorization"] = f"Bearer {self._token.reveal()}"
        return [
            HttpRequest(url=self._url.reveal(), body=message.body_text().encode(), headers=headers)
        ]
