"""Slack incoming webhook: a fallback ``text`` plus Block Kit sections."""

from __future__ import annotations

from brokersre_sidecar.config.secrets import Secret
from brokersre_sidecar.notify.channels.base import HttpChannel, HttpRequest, HttpTransport
from brokersre_sidecar.notify.channels.webhook import json_body, json_headers
from brokersre_sidecar.notify.message import Message

# Slack allows at most 10 fields in one section block.
_MAX_FIELDS = 10


def escape_mrkdwn(text: str) -> str:
    """Escape the three characters Slack treats as markup control: ``&``, ``<`` and ``>``."""
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


class SlackChannel(HttpChannel):
    """Posts to a Slack incoming-webhook URL."""

    name = "slack"

    def __init__(self, transport: HttpTransport, url: Secret) -> None:
        """Create the channel for one incoming-webhook URL (a credential: never logged)."""
        super().__init__(transport)
        self._url = url

    def requests(self, message: Message) -> list[HttpRequest]:
        """Return the single POST: notification text plus formatted blocks."""
        headline = escape_mrkdwn(message.headline)
        blocks: list[dict[str, object]] = [
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": f"*{headline}*\n{escape_mrkdwn(message.instruction)}",
                },
            },
            {
                "type": "section",
                "fields": [
                    {"type": "mrkdwn", "text": f"*{label}*\n{escape_mrkdwn(value)}"}
                    for label, value in message.facts()[:_MAX_FIELDS]
                ],
            },
        ]
        if message.runbook is not None:
            blocks.append(
                {
                    "type": "context",
                    "elements": [{"type": "mrkdwn", "text": f"<{message.runbook}|Runbook>"}],
                }
            )
        payload = {
            "text": f"{message.headline}\n{message.instruction}",
            "blocks": blocks,
        }
        return [
            HttpRequest(url=self._url.reveal(), body=json_body(payload), headers=json_headers())
        ]
