"""Message rendering and the payload of every notification channel."""

from __future__ import annotations

import hashlib
import hmac
import json
import smtplib
from datetime import timedelta
from email.message import EmailMessage
from typing import Any

import httpx
import pytest

from brokersre_sidecar.config import Secret, SmtpTarget
from brokersre_sidecar.notify import DeliveryError, HttpTransport, Message, MessageFactory
from brokersre_sidecar.notify.channels import (
    HttpRequest,
    NtfyChannel,
    PagerDutyChannel,
    SlackChannel,
    SmtpChannel,
    TeamsChannel,
    TelegramChannel,
    WebhookChannel,
)
from brokersre_sidecar.notify.channels.smtp import open_smtp
from brokersre_sidecar.redaction import SecretRegistry
from brokersre_sidecar.vocab import AlertClass, MessageKind
from testkit import T0


def factory(**overrides: Any) -> MessageFactory:
    fields: dict[str, Any] = {
        "instance": "desk-1",
        "time_zone": "Asia/Singapore",
        "runbook_base": "https://runbooks.example.com/ibgw",
        "registry": SecretRegistry(),
    }
    fields.update(overrides)
    return MessageFactory(**fields)


def message(
    kind: MessageKind = MessageKind.FIRING,
    alert: AlertClass = AlertClass.TWOFA_PENDING,
    **overrides: Any,
) -> Message:
    fields: dict[str, Any] = {
        "detail": "gateway phase is 2fa-pending",
        "escalation_step": 0,
        "since": T0 - timedelta(seconds=30),
        "phase": "2fa-pending",
        "api_status": "not_measured",
        "now": T0,
    }
    fields.update(overrides)
    return factory().build(kind, alert, **fields)


class Recorder:
    """An ``httpx`` mock transport that records requests and answers from a script."""

    def __init__(self, *statuses: int) -> None:
        self.requests: list[httpx.Request] = []
        self._statuses = list(statuses) or [200]

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        status = self._statuses.pop(0) if len(self._statuses) > 1 else self._statuses[0]
        return httpx.Response(status, text="ok")

    def transport(self) -> HttpTransport:
        return HttpTransport(httpx.AsyncClient(transport=httpx.MockTransport(self)))

    def json(self, index: int = 0) -> Any:
        return json.loads(self.requests[index].content)


def test_a_message_carries_instance_class_severity_phase_both_times_and_the_instruction() -> None:
    built = message()
    assert built.instance == "desk-1"
    assert built.alert_class == "twofa_pending"
    assert built.kind == "firing"
    assert built.severity == "critical"
    assert built.phase == "2fa-pending"
    assert built.time_utc == "2026-11-12T15:00:00.000Z"
    assert built.time_local == "2026-11-12 23:00:00 +08 (Asia/Singapore)"
    assert built.title == "IBKR two-factor approval needed"
    assert built.instruction.startswith("Approve the IBKR Mobile prompt now")
    assert built.runbook == "https://runbooks.example.com/ibgw/twofa_pending"
    assert built.dedup_key == "brokersre-sidecar:desk-1:twofa_pending"
    assert built.headline == "[CRITICAL] desk-1: IBKR two-factor approval needed"
    text = built.plain_text()
    assert "Approve the IBKR Mobile prompt now" in text
    assert "Phase: 2fa-pending" in text
    assert "Time (UTC): 2026-11-12T15:00:00.000Z" in text
    assert "Runbook: https://runbooks.example.com/ibgw/twofa_pending" in text


def test_escalations_resolutions_heartbeats_and_tests_have_their_own_wording() -> None:
    escalation = message(MessageKind.ESCALATION, escalation_step=2)
    assert escalation.title == "IBKR two-factor approval needed (still pending, escalation 2 of 2)"
    assert escalation.severity == "critical"
    resolved = message(MessageKind.RESOLVED, detail="")
    assert resolved.title == "Resolved: IBKR two-factor approval needed"
    assert resolved.severity == "info"
    assert resolved.instruction == "No action needed. The condition has cleared."
    beat = message(MessageKind.HEARTBEAT, AlertClass.HEARTBEAT, detail="", since=None)
    assert beat.title == "Daily heartbeat"
    assert beat.severity == "info"
    test = factory().build_test(phase="logged-in", api_status="ready", now=T0)
    assert test.kind == "test"
    assert test.alert_class == "test"
    assert "confirms that this channel works" in test.instruction


def test_without_a_runbook_base_there_is_no_runbook_and_unknown_phases_are_named_safely() -> None:
    built = factory(runbook_base=None).build(
        MessageKind.FIRING,
        AlertClass.API_UNHEALTHY,
        detail="x",
        escalation_step=0,
        since=T0,
        phase=None,
        api_status="down",
        now=T0,
    )
    assert built.runbook is None
    assert built.phase == "not_measured"
    assert "Runbook" not in built.plain_text()
    odd = message(phase="CANARY not a phase")
    assert odd.phase == "unknown"


def test_every_text_field_is_scrubbed_of_registered_secrets_and_account_ids() -> None:
    registry = SecretRegistry()
    registry.add("CANARY_SECRET_VALUE")
    built = factory(registry=registry).build(
        MessageKind.FIRING,
        AlertClass.API_UNHEALTHY,
        detail="status down for DU1234567 via CANARY_SECRET_VALUE",
        escalation_step=0,
        since=T0,
        phase="logged-in",
        api_status="down",
        now=T0,
    )
    assert built.detail == "status down for ***567 via [REDACTED]"


async def test_the_generic_webhook_posts_versioned_json_signed_with_hmac_sha256() -> None:
    recorder = Recorder()
    channel = WebhookChannel(
        recorder.transport(),
        Secret("https://hooks.example.com/CANARY_PATH"),
        Secret("hunter2hunter2"),
    )
    await channel.send(message())
    (request,) = recorder.requests
    assert request.method == "POST"
    assert str(request.url) == "https://hooks.example.com/CANARY_PATH"
    assert request.headers["content-type"] == "application/json"
    body = recorder.json()
    assert body["schema"] == "brokersre.sidecar.alert.v1"
    assert body["class"] == "twofa_pending"
    assert body["kind"] == "firing"
    assert body["severity"] == "critical"
    assert body["instance"] == "desk-1"
    assert body["dedup_key"] == "brokersre-sidecar:desk-1:twofa_pending"
    expected = hmac.new(b"hunter2hunter2", request.content, hashlib.sha256).hexdigest()
    assert request.headers["x-brokersre-signature"] == f"sha256={expected}"


async def test_the_webhook_is_unsigned_without_a_secret() -> None:
    recorder = Recorder()
    await WebhookChannel(recorder.transport(), Secret("https://h.example.com/x"), None).send(
        message()
    )
    assert "x-brokersre-signature" not in recorder.requests[0].headers


async def test_teams_receives_an_adaptive_card_in_the_workflows_envelope() -> None:
    recorder = Recorder(202)
    await TeamsChannel(
        recorder.transport(), Secret("https://x.logic.azure.com/workflows/abc")
    ).send(message())
    body = recorder.json()
    assert body["type"] == "message"
    (attachment,) = body["attachments"]
    assert attachment["contentType"] == "application/vnd.microsoft.card.adaptive"
    assert attachment["contentUrl"] is None
    card = attachment["content"]
    assert card["type"] == "AdaptiveCard"
    assert card["version"] == "1.2"
    assert card["$schema"] == "http://adaptivecards.io/schemas/adaptive-card.json"
    texts = [block["text"] for block in card["body"] if block["type"] == "TextBlock"]
    assert texts[0] == "[CRITICAL] desk-1: IBKR two-factor approval needed"
    assert any(text.startswith("Approve the IBKR Mobile prompt now") for text in texts)
    facts = {
        fact["title"]: fact["value"]
        for block in card["body"]
        if block["type"] == "FactSet"
        for fact in block["facts"]
    }
    assert facts["Phase"] == "2fa-pending"
    assert facts["Time (local)"] == "2026-11-12 23:00:00 +08 (Asia/Singapore)"
    assert card["actions"] == [
        {
            "type": "Action.OpenUrl",
            "title": "Runbook",
            "url": "https://runbooks.example.com/ibgw/twofa_pending",
        }
    ]


async def test_slack_receives_text_and_blocks_with_markup_escaped() -> None:
    recorder = Recorder()
    await SlackChannel(recorder.transport(), Secret("https://hooks.slack.com/services/T/B/x")).send(
        message(detail="ratio > 85% & rising <fast>")
    )
    body = recorder.json()
    assert body["text"].startswith("[CRITICAL] desk-1: IBKR two-factor approval needed")
    rendered = json.dumps(body["blocks"])
    assert "ratio &gt; 85% &amp; rising &lt;fast&gt;" in rendered
    assert "<https://runbooks.example.com/ibgw/twofa_pending|Runbook>" in rendered


async def test_telegram_posts_plain_text_to_the_bot_api_with_the_token_only_in_the_url() -> None:
    recorder = Recorder()
    await TelegramChannel(recorder.transport(), Secret("123456:hunter2hunter2"), "-100123").send(
        message()
    )
    (request,) = recorder.requests
    assert str(request.url) == "https://api.telegram.org/bot123456:hunter2hunter2/sendMessage"
    body = recorder.json()
    assert body["chat_id"] == "-100123"
    assert "parse_mode" not in body
    assert body["link_preview_options"] == {"is_disabled": True}
    assert "hunter2" not in request.content.decode()
    assert body["text"].startswith("[CRITICAL] desk-1: IBKR two-factor approval needed")


async def test_ntfy_publishes_with_title_priority_tags_click_and_optional_bearer_token() -> None:
    recorder = Recorder()
    channel = NtfyChannel(
        recorder.transport(), Secret("https://ntfy.example.com/ibgw"), Secret("hunter2hunter2")
    )
    await channel.send(message())
    await channel.send(message(MessageKind.RESOLVED, detail=""))
    firing, resolved = recorder.requests
    assert str(firing.url) == "https://ntfy.example.com/ibgw"
    assert firing.headers["title"] == "[CRITICAL] desk-1: IBKR two-factor approval needed"
    assert firing.headers["priority"] == "5"
    assert firing.headers["tags"] == "rotating_light"
    assert firing.headers["click"] == "https://runbooks.example.com/ibgw/twofa_pending"
    assert firing.headers["authorization"] == "Bearer hunter2hunter2"
    assert firing.content.decode().startswith("Approve the IBKR Mobile prompt now")
    assert resolved.headers["priority"] == "2"
    assert resolved.headers["tags"] == "white_check_mark"
    plain = NtfyChannel(recorder.transport(), Secret("https://ntfy.example.com/ibgw"), None)
    await plain.send(message())
    assert "authorization" not in recorder.requests[-1].headers


async def test_pagerduty_triggers_with_a_dedup_key_and_resolves_the_same_incident() -> None:
    recorder = Recorder(202)
    channel = PagerDutyChannel(recorder.transport(), Secret("hunter2hunter2hunter2hunter2abcd"))
    await channel.send(message())
    await channel.send(message(MessageKind.ESCALATION, escalation_step=1))
    await channel.send(message(MessageKind.RESOLVED, detail=""))
    trigger, again, resolve = (json.loads(request.content) for request in recorder.requests)
    assert str(recorder.requests[0].url) == "https://events.pagerduty.com/v2/enqueue"
    assert trigger["routing_key"] == "hunter2hunter2hunter2hunter2abcd"
    assert trigger["event_action"] == "trigger"
    assert trigger["dedup_key"] == "brokersre-sidecar:desk-1:twofa_pending"
    assert trigger["payload"]["severity"] == "critical"
    assert trigger["payload"]["source"] == "desk-1"
    assert trigger["payload"]["summary"] == "[CRITICAL] desk-1: IBKR two-factor approval needed"
    assert trigger["payload"]["timestamp"] == "2026-11-12T15:00:00.000Z"
    assert trigger["payload"]["custom_details"]["phase"] == "2fa-pending"
    assert trigger["links"] == [
        {"href": "https://runbooks.example.com/ibgw/twofa_pending", "text": "Runbook"}
    ]
    assert again["event_action"] == "trigger"
    assert again["dedup_key"] == trigger["dedup_key"]
    assert resolve == {
        "routing_key": "hunter2hunter2hunter2hunter2abcd",
        "event_action": "resolve",
        "dedup_key": "brokersre-sidecar:desk-1:twofa_pending",
    }


async def test_pagerduty_ignores_heartbeats_and_a_test_opens_and_closes_its_own_incident() -> None:
    recorder = Recorder(202)
    channel = PagerDutyChannel(recorder.transport(), Secret("hunter2hunter2hunter2hunter2abcd"))
    assert channel.wants(message(MessageKind.HEARTBEAT, AlertClass.HEARTBEAT, since=None)) is False
    assert channel.wants(message()) is True
    await channel.send(factory().build_test(phase="logged-in", api_status="ready", now=T0))
    actions = [json.loads(request.content)["event_action"] for request in recorder.requests]
    assert actions == ["trigger", "resolve"]
    assert json.loads(recorder.requests[0].content)["payload"]["severity"] == "info"


@pytest.mark.parametrize(
    ("status", "category", "retryable"),
    [
        (500, "http_500", True),
        (503, "http_503", True),
        (429, "http_429", True),
        (408, "http_408", True),
        (400, "http_400", False),
        (401, "http_401", False),
        (404, "http_404", False),
        (302, "http_302", False),
    ],
)
async def test_a_non_2xx_answer_is_a_delivery_error_with_a_category_and_no_url(
    status: int, category: str, retryable: bool
) -> None:
    recorder = Recorder(status)
    channel = SlackChannel(recorder.transport(), Secret("https://hooks.slack.com/CANARY_PATH"))
    with pytest.raises(DeliveryError) as caught:
        await channel.send(message())
    assert caught.value.category == category
    assert caught.value.retryable is retryable
    assert "CANARY" not in str(caught.value)
    assert len(recorder.requests) == 1  # a redirect is never followed


@pytest.mark.parametrize(
    ("error", "category"),
    [
        (httpx.ReadTimeout("slow CANARY_URL"), "timeout"),
        (httpx.ConnectTimeout("slow CANARY_URL"), "timeout"),
        (httpx.ConnectError("refused CANARY_URL"), "connect"),
        (httpx.RemoteProtocolError("garbage CANARY_URL"), "transport"),
    ],
)
async def test_transport_failures_are_retryable_categories_that_never_quote_the_url(
    error: Exception, category: str
) -> None:
    def explode(request: httpx.Request) -> httpx.Response:
        raise error

    transport = HttpTransport(httpx.AsyncClient(transport=httpx.MockTransport(explode)))
    with pytest.raises(DeliveryError) as caught:
        await SlackChannel(transport, Secret("https://hooks.slack.com/x")).send(message())
    assert caught.value.category == category
    assert caught.value.retryable is True
    assert "CANARY" not in str(caught.value)


class FakeSmtp:
    """Records what an ``smtplib.SMTP`` session is asked to do."""

    def __init__(self, fail_with: Exception | None = None) -> None:
        self.calls: list[str] = []
        self.sent: list[EmailMessage] = []
        self.fail_with = fail_with

    def __enter__(self) -> FakeSmtp:
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.calls.append("quit")

    def login(self, user: str, password: str) -> None:
        self.calls.append(f"login:{user}")

    def send_message(self, email: EmailMessage) -> None:
        if self.fail_with is not None:
            raise self.fail_with
        self.calls.append("send")
        self.sent.append(email)


TARGET = SmtpTarget("smtp.example.com", 465, True, "mailer", Secret("hunter2hunter2"))


async def test_smtp_sends_a_plain_text_mail_with_headline_subject_after_logging_in() -> None:
    session = FakeSmtp()
    channel = SmtpChannel(
        TARGET, "ibgw@example.com", ("ops@example.com", "oncall@example.com"), lambda *_: session
    )
    await channel.send(message())
    assert session.calls == ["login:mailer", "send", "quit"]
    (email,) = session.sent
    assert email["Subject"] == "[CRITICAL] desk-1: IBKR two-factor approval needed"
    assert email["From"] == "ibgw@example.com"
    assert email["To"] == "ops@example.com, oncall@example.com"
    assert email["Auto-Submitted"] == "auto-generated"
    assert "Approve the IBKR Mobile prompt now" in email.get_content()
    assert "hunter2" not in email.as_string()


async def test_smtp_without_credentials_does_not_log_in() -> None:
    session = FakeSmtp()
    target = SmtpTarget("relay.example.com", 587, False, None, None)
    await SmtpChannel(target, "a@example.com", ("b@example.com",), lambda *_: session).send(
        message()
    )
    assert session.calls == ["send", "quit"]


@pytest.mark.parametrize(
    ("error", "category", "retryable"),
    [
        (smtplib.SMTPAuthenticationError(535, b"CANARY denied"), "smtp_auth", False),
        (smtplib.SMTPRecipientsRefused({"b@example.com": (550, b"CANARY")}), "smtp_refused", False),
        (smtplib.SMTPServerDisconnected("CANARY gone"), "smtp_disconnected", True),
        (smtplib.SMTPNotSupportedError("CANARY no starttls"), "smtp_no_starttls", False),
        (TimeoutError("CANARY slow"), "timeout", True),
        (ConnectionRefusedError("CANARY refused"), "connect", True),
    ],
)
async def test_smtp_failures_become_delivery_errors_without_server_text(
    error: Exception, category: str, retryable: bool
) -> None:
    channel = SmtpChannel(
        TARGET, "a@example.com", ("b@example.com",), lambda *_: FakeSmtp(fail_with=error)
    )
    with pytest.raises(DeliveryError) as caught:
        await channel.send(message())
    assert (caught.value.category, caught.value.retryable) == (category, retryable)
    assert "CANARY" not in str(caught.value)


def test_implicit_tls_uses_smtp_ssl_and_plain_smtp_requires_starttls(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    opened: list[tuple[str, str, int, float]] = []

    class Session:
        def __init__(self, kind: str, host: str, port: int, timeout: float) -> None:
            opened.append((kind, host, port, timeout))
            self.tls_started = False

        def starttls(self, context: object) -> None:
            assert context is not None
            self.tls_started = True

    monkeypatch.setattr(
        smtplib,
        "SMTP_SSL",
        lambda host, port, timeout, context: Session("ssl", host, port, timeout),
    )
    monkeypatch.setattr(
        smtplib, "SMTP", lambda host, port, timeout: Session("plain", host, port, timeout)
    )
    implicit: Any = open_smtp(TARGET, 10.0)
    assert opened == [("ssl", "smtp.example.com", 465, 10.0)]
    assert implicit.tls_started is False
    explicit: Any = open_smtp(SmtpTarget("relay.example.com", 587, False, None, None), 10.0)
    assert opened[-1] == ("plain", "relay.example.com", 587, 10.0)
    assert explicit.tls_started is True


def test_a_hand_over_is_worded_as_superseded_not_as_resolved() -> None:
    handed_over = factory().build(
        MessageKind.RESOLVED,
        AlertClass.TWOFA_PENDING,
        detail="",
        escalation_step=0,
        since=T0,
        phase="needs-human",
        api_status="not_measured",
        now=T0,
        superseded_by=AlertClass.NEEDS_HUMAN,
    )
    assert handed_over.kind == "resolved"  # receivers that close incidents by kind still do
    assert handed_over.title == "Superseded: IBKR two-factor approval needed"
    assert handed_over.instruction == (
        "This alert is closed because the gateway moved on, not because the problem went "
        "away. Follow the needs_human alert."
    )
    assert "Resolved" not in handed_over.plain_text()


def test_a_requested_stop_is_an_information_message() -> None:
    stopped = message(MessageKind.FIRING, AlertClass.GATEWAY_STOPPED, phase="stopped")
    assert stopped.severity == "info"
    assert stopped.title == "The gateway was stopped on request"
    exited = message(MessageKind.FIRING, AlertClass.GATEWAY_EXITED, phase="exited")
    assert exited.severity == "critical"
    assert exited.title == "The gateway stopped unexpectedly"


async def test_a_request_that_cannot_be_put_on_the_wire_is_a_final_delivery_failure() -> None:
    # Belt and braces behind the configuration check: whatever reaches a header, the
    # channel task must get a DeliveryError, not an encoding error that crashes it.
    def unreachable(request: httpx.Request) -> httpx.Response:
        raise AssertionError("the request must not be sent")

    transport = HttpTransport(httpx.AsyncClient(transport=httpx.MockTransport(unreachable)))
    request = HttpRequest(
        url="https://ntfy.example.com/topic",
        body=b"text",
        headers={"Authorization": "Bearer CANARY_caf\u00e9\u2713"},
    )
    with pytest.raises(DeliveryError) as caught:
        await transport.send(request)
    assert (caught.value.category, caught.value.retryable) == ("invalid_request", False)
    assert "CANARY" not in str(caught.value)
