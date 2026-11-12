"""Telegram bot: ``sendMessage`` with plain text (no parse mode, so nothing needs escaping)."""

from __future__ import annotations

from brokersre_sidecar.config.secrets import Secret
from brokersre_sidecar.notify.channels.base import HttpChannel, HttpRequest, HttpTransport
from brokersre_sidecar.notify.channels.webhook import json_body, json_headers
from brokersre_sidecar.notify.message import Message

TELEGRAM_API = "https://api.telegram.org"


class TelegramChannel(HttpChannel):
    """Sends to one chat through the Telegram Bot API.

    The bot token is part of the request URL by the API's design; it appears nowhere else.
    """

    name = "telegram"

    def __init__(self, transport: HttpTransport, token: Secret, chat_id: str) -> None:
        """Create the channel.

        Args:
            transport: Shared HTTP transport.
            token: Bot token ``<bot id>:<secret>``.
            chat_id: Numeric chat id or ``@channelname`` (not a secret).
        """
        super().__init__(transport)
        self._token = token
        self._chat_id = chat_id

    def requests(self, message: Message) -> list[HttpRequest]:
        """Return the single ``sendMessage`` call."""
        payload = {
            "chat_id": self._chat_id,
            "text": message.plain_text(),
            "link_preview_options": {"is_disabled": True},
        }
        url = f"{TELEGRAM_API}/bot{self._token.reveal()}/sendMessage"
        return [HttpRequest(url=url, body=json_body(payload), headers=json_headers())]
