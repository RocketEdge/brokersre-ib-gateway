"""PagerDuty Events API v2: trigger with a ``dedup_key``, resolve the same incident later."""

from __future__ import annotations

from brokersre_sidecar.config.secrets import Secret
from brokersre_sidecar.notify.channels.base import HttpChannel, HttpRequest, HttpTransport
from brokersre_sidecar.notify.channels.webhook import json_body, json_headers
from brokersre_sidecar.notify.message import Message
from brokersre_sidecar.vocab import MessageKind

EVENTS_URL = "https://events.pagerduty.com/v2/enqueue"


class PagerDutyChannel(HttpChannel):
    """Sends events to one PagerDuty service (integration/routing key).

    Announcements and escalations are ``trigger`` events sharing the message's ``dedup_key``
    (PagerDuty appends them to the open incident instead of paging again); a resolution is a
    ``resolve`` event for that key. Heartbeats are not sent: an "all good" must not open an
    incident. A test message triggers and immediately resolves its own incident.
    """

    name = "pagerduty"

    def __init__(self, transport: HttpTransport, routing_key: Secret) -> None:
        """Create the channel for one Events API v2 routing key."""
        super().__init__(transport)
        self._routing_key = routing_key

    def wants(self, message: Message) -> bool:
        """Accept everything except heartbeats."""
        return message.kind != MessageKind.HEARTBEAT

    def _event(self, action: str, message: Message) -> HttpRequest:
        """Build one Events API request for ``message``."""
        event: dict[str, object] = {
            "routing_key": self._routing_key.reveal(),
            "event_action": action,
            "dedup_key": message.dedup_key,
        }
        if action == "trigger":
            event["payload"] = {
                "summary": message.headline,
                "source": message.instance,
                "severity": message.severity,
                "timestamp": message.time_utc,
                "component": "ib-gateway",
                "group": message.instance,
                "class": message.alert_class,
                "custom_details": {
                    "instruction": message.instruction,
                    "kind": message.kind,
                    "phase": message.phase,
                    "api_status": message.api_status,
                    "time_local": message.time_local,
                    "since_utc": message.since_utc,
                    "detail": message.detail,
                    "escalation_step": message.escalation_step,
                },
            }
            event["client"] = "brokersre-sidecar"
            if message.runbook is not None:
                event["links"] = [{"href": message.runbook, "text": "Runbook"}]
        return HttpRequest(url=EVENTS_URL, body=json_body(event), headers=json_headers())

    def requests(self, message: Message) -> list[HttpRequest]:
        """Return the event(s) for ``message``: resolve, trigger, or trigger+resolve (test)."""
        if message.kind == MessageKind.RESOLVED:
            return [self._event("resolve", message)]
        if message.kind == MessageKind.TEST:
            return [self._event("trigger", message), self._event("resolve", message)]
        return [self._event("trigger", message)]
