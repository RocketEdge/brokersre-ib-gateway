"""Notification channels and the factory that builds the configured ones."""

from __future__ import annotations

from brokersre_sidecar.config.settings import ChannelSecrets, Settings
from brokersre_sidecar.notify.channels.base import (
    Channel,
    DeliveryError,
    HttpChannel,
    HttpRequest,
    HttpTransport,
)
from brokersre_sidecar.notify.channels.ntfy import NtfyChannel
from brokersre_sidecar.notify.channels.pagerduty import PagerDutyChannel
from brokersre_sidecar.notify.channels.slack import SlackChannel
from brokersre_sidecar.notify.channels.smtp import SmtpChannel, SmtpOpener, open_smtp
from brokersre_sidecar.notify.channels.teams import TeamsChannel
from brokersre_sidecar.notify.channels.telegram import TelegramChannel
from brokersre_sidecar.notify.channels.webhook import WebhookChannel

__all__ = [
    "Channel",
    "DeliveryError",
    "HttpChannel",
    "HttpRequest",
    "HttpTransport",
    "NtfyChannel",
    "PagerDutyChannel",
    "SlackChannel",
    "SmtpChannel",
    "SmtpOpener",
    "TeamsChannel",
    "TelegramChannel",
    "WebhookChannel",
    "build_channels",
    "open_smtp",
]


def build_channels(
    settings: Settings,
    secrets: ChannelSecrets,
    transport: HttpTransport,
    smtp_opener: SmtpOpener = open_smtp,
) -> dict[str, Channel]:
    """Build every channel whose credentials are configured.

    Args:
        settings: Supplies the non-secret channel parameters (chat id, mail addresses).
        secrets: Credentials loaded from the ``*_FILE`` paths.
        transport: Shared HTTP transport for the HTTP channels.
        smtp_opener: Opens SMTP sessions; replaced in tests.

    Returns:
        Channels by name, in the fixed order of ``vocab.ChannelName``. Empty when no channel
        is configured (the notifier then does not run).
    """
    channels: dict[str, Channel] = {}
    if secrets.webhook_url is not None:
        channels[WebhookChannel.name] = WebhookChannel(
            transport, secrets.webhook_url, secrets.webhook_hmac_secret
        )
    if secrets.teams_url is not None:
        channels[TeamsChannel.name] = TeamsChannel(transport, secrets.teams_url)
    if secrets.slack_url is not None:
        channels[SlackChannel.name] = SlackChannel(transport, secrets.slack_url)
    if secrets.telegram_token is not None and settings.telegram_chat_id is not None:
        channels[TelegramChannel.name] = TelegramChannel(
            transport, secrets.telegram_token, settings.telegram_chat_id
        )
    if secrets.ntfy_url is not None:
        channels[NtfyChannel.name] = NtfyChannel(transport, secrets.ntfy_url, secrets.ntfy_token)
    if secrets.pagerduty_key is not None:
        channels[PagerDutyChannel.name] = PagerDutyChannel(transport, secrets.pagerduty_key)
    if secrets.smtp is not None and settings.smtp_from is not None and settings.smtp_to:
        channels[SmtpChannel.name] = SmtpChannel(
            secrets.smtp, settings.smtp_from, settings.smtp_to, smtp_opener
        )
    return channels
