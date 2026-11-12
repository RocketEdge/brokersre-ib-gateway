"""Microsoft Teams through a Workflows webhook ("When a Teams webhook request is received").

Office 365 connectors (the old incoming webhooks and their MessageCard format) are retired.
The Workflows trigger expects a message envelope whose attachment is an Adaptive Card:
``{"type": "message", "attachments": [{"contentType":
"application/vnd.microsoft.card.adaptive", "contentUrl": null, "content": {...}}]}`` and
answers 202 Accepted (Microsoft Learn, Teams connector reference; verified 2026-11-12).
Card schema version 1.2 is the version of the documented example; the card uses only
TextBlock, FactSet and Action.OpenUrl, which every Teams client renders.
"""

from __future__ import annotations

from brokersre_sidecar.config.secrets import Secret
from brokersre_sidecar.notify.channels.base import HttpChannel, HttpRequest, HttpTransport
from brokersre_sidecar.notify.channels.webhook import json_body, json_headers
from brokersre_sidecar.notify.message import Message
from brokersre_sidecar.vocab import Severity

_COLOURS = {
    Severity.CRITICAL.value: "Attention",
    Severity.ERROR.value: "Attention",
    Severity.WARNING.value: "Warning",
    Severity.INFO.value: "Good",
}


class TeamsChannel(HttpChannel):
    """Posts an Adaptive Card to a Teams Workflows webhook URL."""

    name = "teams"

    def __init__(self, transport: HttpTransport, url: Secret) -> None:
        """Create the channel for one Workflows webhook URL (a credential: never logged)."""
        super().__init__(transport)
        self._url = url

    def requests(self, message: Message) -> list[HttpRequest]:
        """Return the single POST carrying the card."""
        card: dict[str, object] = {
            "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
            "type": "AdaptiveCard",
            "version": "1.2",
            "body": [
                {
                    "type": "TextBlock",
                    "text": message.headline,
                    "weight": "Bolder",
                    "size": "Medium",
                    "wrap": True,
                    "color": _COLOURS.get(message.severity, "Default"),
                },
                {"type": "TextBlock", "text": message.instruction, "wrap": True},
                {
                    "type": "FactSet",
                    "facts": [{"title": label, "value": value} for label, value in message.facts()],
                },
            ],
        }
        if message.runbook is not None:
            card["actions"] = [
                {"type": "Action.OpenUrl", "title": "Runbook", "url": message.runbook}
            ]
        envelope = {
            "type": "message",
            "attachments": [
                {
                    "contentType": "application/vnd.microsoft.card.adaptive",
                    "contentUrl": None,
                    "content": card,
                }
            ],
        }
        return [
            HttpRequest(url=self._url.reveal(), body=json_body(envelope), headers=json_headers())
        ]
