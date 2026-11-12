"""Redaction canary: no channel payload ever contains a planted secret, username or account id.

Canary strings are planted in every input the sidecar reads: the secret files, the event
and metrics lines (message text, unknown keys), the phase file, the API notices. Every
alert class is then driven active through the real model, probe and rules, every message
kind is rendered for every channel, and the complete outgoing request (body and headers,
minus the one slot where a channel's API requires its credential) is searched for canaries.
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

import httpx

from brokersre_sidecar.config import Secret, load_secrets, load_settings
from brokersre_sidecar.model import GatewayFeed, GatewayState
from brokersre_sidecar.notify import (
    CONDITION_CLASSES,
    Condition,
    HttpTransport,
    Message,
    MessageFactory,
    RuleConfig,
    RuleEngine,
    build_channels,
)
from brokersre_sidecar.notify.channels import HttpChannel, SmtpChannel
from brokersre_sidecar.probe import ProbeConfig, ProbeEngine
from brokersre_sidecar.redaction import ACCOUNT_RE, SecretRegistry
from brokersre_sidecar.vocab import AlertClass, MessageKind
from fakes.fake_ib import FakeIb
from testkit import T0, FakeClock, iso

ACCOUNT = "DU7654321"
USERNAME = "CANARY_USERNAME"
INSTANCE = "desk-1"

SECRETS = {
    "NOTIFY_WEBHOOK_URL_FILE": "https://hooks.example.com/CANARY_WEBHOOK_PATH",
    "NOTIFY_WEBHOOK_SECRET_FILE": "CANARY_HMAC_SECRET",
    "NOTIFY_TEAMS_URL_FILE": "https://example.logic.azure.com/workflows/CANARY_TEAMS_PATH",
    "NOTIFY_SLACK_URL_FILE": "https://hooks.slack.com/services/CANARY_SLACK_PATH",
    "NOTIFY_TELEGRAM_TOKEN_FILE": "123456:CANARY_TELEGRAM_TOKEN",
    "NOTIFY_NTFY_URL_FILE": "https://ntfy.example.com/CANARY_NTFY_TOPIC",
    "NOTIFY_NTFY_TOKEN_FILE": "CANARY_NTFY_TOKEN",
    "NOTIFY_PAGERDUTY_KEY_FILE": "CANARY_PAGERDUTY_ROUTING_KEY",
    "NOTIFY_SMTP_URL_FILE": "smtps://CANARY_SMTP_USER:CANARY_SMTP_PASSWORD@smtp.example.com:465",
}

# The only place each channel may carry its credential (dictated by the service's API).
CREDENTIAL_HEADERS = {"ntfy": {"authorization"}}
CREDENTIAL_BODY_KEYS = {"pagerduty": {"routing_key"}}


def accept(request: httpx.Request) -> httpx.Response:
    """Answer 200 to anything (the canary tests only render requests)."""
    return httpx.Response(200)


def configured_channels(tmp_path: Path) -> tuple[dict[str, Any], SecretRegistry]:
    env = {
        "IBGW_INSTANCE": INSTANCE,
        "NOTIFY_TELEGRAM_CHAT_ID": "-1001234",
        "NOTIFY_SMTP_FROM": "ibgw@example.com",
        "NOTIFY_SMTP_TO": "ops@example.com",
        "NOTIFY_RUNBOOK_BASE": "https://runbooks.example.com/ibgw",
    }
    tmp_path.mkdir(parents=True, exist_ok=True)
    for variable, content in SECRETS.items():
        path = tmp_path / variable
        path.write_text(content, encoding="utf-8")
        env[variable] = str(path)
    settings = load_settings(env)
    registry = SecretRegistry()
    secrets = load_secrets(settings, registry)
    transport = HttpTransport(httpx.AsyncClient(transport=httpx.MockTransport(accept)))
    return build_channels(settings, secrets, transport), registry


def write_gateway_volume(root: Path, phase: bytes, now: datetime, *, boots: int = 1) -> None:
    """Write a log volume whose every free-text field carries a canary."""
    for name in ("state", "events", "metrics"):
        (root / name).mkdir(parents=True, exist_ok=True)
    (root / "state" / "phase").write_bytes(phase)
    lines = []
    for index in range(boots):
        boot = f"{index:016x}"
        for sequence, name in enumerate(
            (
                "container_start",
                "login_failed",
                "unknown_window",
                "login_stalled",
                "disk_low",
                "memory_high",
                "oom_kill",
            )
        ):
            lines.append(
                {
                    "ts": iso(now - timedelta(seconds=60 - index)),
                    "src": "ibc",
                    "level": "error",
                    "event": name,
                    "msg": f"{USERNAME} failed to log in to {ACCOUNT}",
                    "boot_id": boot,
                    "seq": sequence,
                    "username": USERNAME,
                    "account": ACCOUNT,
                    "CANARY_KEY": {"nested": "CANARY_VALUE"},
                }
            )
    (root / "events" / "events.jsonl").write_text(
        "".join(json.dumps(line) + "\n" for line in lines), encoding="utf-8", newline="\n"
    )
    samples = [
        {
            "ts": iso(now - timedelta(seconds=660 - step * 30)),
            "src": "metrics",
            "boot_id": "0000000000000000",
            "seq": step,
            "phase": "CANARY_PHASE",
            "mem_working_set_bytes": 950,
            "mem_limit_bytes": 1000,
            "disk_free_bytes_logs": 1024,
            "account": ACCOUNT,
            "CANARY_METRIC": 1,
        }
        for step in range(21)
    ]
    (root / "metrics" / "metrics.jsonl").write_text(
        "".join(json.dumps(sample) + "\n" for sample in samples), encoding="utf-8", newline="\n"
    )


async def evaluate_scenario(
    root: Path,
    phase: bytes,
    *,
    api: str,
    boots: int = 1,
    quiet_for: float = 0.0,
    link_lost: bool = True,
) -> tuple[dict[AlertClass, Any], str | None, str]:
    """Run the real feed, model, probe and rules over a canary-laden volume."""
    clock = FakeClock(T0)
    write_gateway_volume(root, phase, clock.now(), boots=boots)
    state = GatewayState(clock)
    GatewayFeed(root, state).poll()
    ib = FakeIb(clock)
    ib.greeting = (
        # Free text before the colon, and after it: a token that is alphanumeric like a
        # farm name (so the character filter alone would let it through), an account
        # id, and one real farm name that must survive.
        (2103, f"{USERNAME} market data farm of {ACCOUNT} is broken:CANARYALNUM"),
        (2105, f"HMDS data farm connection is broken:{ACCOUNT}"),
        (2157, "Sec-def data farm connection is broken:secdefnj"),
    )
    if link_lost:
        ib.greeting += ((1100, f"Connectivity lost for {USERNAME} {ACCOUNT}"),)
    if api == "down":
        ib.connect_behaviour = "hang"
    ib.skew_s = 45.0
    engine = ProbeEngine(
        ProbeConfig(enabled=True, port=4002, client_id=999, interval_s=60.0, timeout_s=10.0),
        ib,
        clock,
        phase=lambda: state.snapshot().phase,
        close_wait=lambda: 3,
    )
    rules = RuleEngine(RuleConfig())
    result: dict[AlertClass, Any] = {}
    # Seven minutes of one-second ticks: long enough for every "sustained" condition.
    for _ in range(420 + int(quiet_for)):
        await engine.tick()
        result = rules.evaluate(
            state.snapshot(), engine.snapshot(), now=clock.now(), mono=clock.monotonic()
        )
        clock.advance(1.0)
    return result, state.snapshot().phase, engine.snapshot().status.value


def outgoing_text(channel: Any, message: Message) -> str:
    """Return everything a channel would put on the wire, minus its credential slot."""
    if isinstance(channel, SmtpChannel):
        return channel.build_email(message).as_string()
    assert isinstance(channel, HttpChannel)
    parts: list[str] = []
    for request in channel.requests(message):
        allowed_headers = CREDENTIAL_HEADERS.get(channel.name, set())
        parts += [
            f"{name}: {value}"
            for name, value in request.headers.items()
            if name.lower() not in allowed_headers
        ]
        body = request.body.decode("utf-8")
        allowed_keys = CREDENTIAL_BODY_KEYS.get(channel.name)
        if allowed_keys:
            parsed = json.loads(body)
            for key in allowed_keys:
                parsed.pop(key, None)
            body = json.dumps(parsed)
        parts.append(body)
    return "\n".join(parts)


async def test_no_canary_reaches_any_channel_for_any_alert_class_and_kind(tmp_path: Path) -> None:
    channels, registry = configured_channels(tmp_path / "secrets-dir-holder")
    assert set(channels) == {"webhook", "teams", "slack", "telegram", "ntfy", "pagerduty", "smtp"}
    factory = MessageFactory(
        INSTANCE, "Asia/Singapore", "https://runbooks.example.com/ibgw", registry
    )

    scenarios: list[tuple[bytes, dict[str, Any]]] = [
        (b"2fa-pending\n", {"api": "ok"}),
        (b"needs-human\n", {"api": "ok"}),
        (b"existing-session\n", {"api": "ok"}),
        (b"exited\n", {"api": "ok"}),
        (b"login\n", {"api": "ok", "boots": 4}),
        (b"logged-in\n", {"api": "down"}),
        (b"logged-in\n", {"api": "ok"}),
        (f"{USERNAME} {ACCOUNT}\n".encode(), {"api": "ok"}),
    ]
    seen_active: set[AlertClass] = set()
    rendered = 0
    for index, (phase, options) in enumerate(scenarios):
        evaluations, phase_token, api_status = await evaluate_scenario(
            tmp_path / f"volume-{index}", phase, **options
        )
        for alert, evaluation in evaluations.items():
            if evaluation.state is not Condition.ACTIVE:
                continue
            seen_active.add(alert)
            for kind, step in (
                (MessageKind.FIRING, 0),
                (MessageKind.ESCALATION, 2),
                (MessageKind.RESOLVED, 0),
            ):
                built = factory.build(
                    kind,
                    alert,
                    detail=evaluation.detail,
                    escalation_step=step,
                    since=T0,
                    phase=phase_token,
                    api_status=api_status,
                    now=T0,
                )
                for channel in channels.values():
                    text = outgoing_text(channel, built)
                    assert "CANARY" not in text, (channel.name, alert, kind, text)
                    assert not ACCOUNT_RE.search(text), (channel.name, alert, kind)
                    assert INSTANCE in text
                    rendered += 1

    # Silence needs its own scenario: every other one keeps the feeds fresh.
    evaluations, phase_token, api_status = await evaluate_scenario(
        tmp_path / "volume-silent", b"logged-in\n", api="ok", quiet_for=400
    )
    assert evaluations[AlertClass.GATEWAY_SILENT].state is Condition.ACTIVE
    seen_active.add(AlertClass.GATEWAY_SILENT)

    assert seen_active == set(CONDITION_CLASSES), set(CONDITION_CLASSES) - seen_active

    extras = [
        factory.build(
            MessageKind.HEARTBEAT,
            AlertClass.HEARTBEAT,
            detail="",
            escalation_step=0,
            since=None,
            phase=phase_token,
            api_status=api_status,
            now=T0,
        ),
        factory.build_test(phase=phase_token, api_status=api_status, now=T0),
        factory.build(
            MessageKind.FIRING,
            AlertClass.GATEWAY_SILENT,
            detail=evaluations[AlertClass.GATEWAY_SILENT].detail,
            escalation_step=0,
            since=T0,
            phase=phase_token,
            api_status=api_status,
            now=T0,
        ),
    ]
    for built in extras:
        for channel in channels.values():
            text = outgoing_text(channel, built)
            assert "CANARY" not in text, (channel.name, built.kind, text)
            assert not ACCOUNT_RE.search(text)
            rendered += 1
    assert rendered > 250


async def test_the_canary_search_itself_would_catch_a_leak(tmp_path: Path) -> None:
    """Guard against a vacuous test: a message built from raw text must trip the search."""
    channels, _ = configured_channels(tmp_path)
    leaky = MessageFactory(INSTANCE, "Etc/UTC", None, SecretRegistry()).build(
        MessageKind.FIRING,
        AlertClass.LOGIN_FAILED,
        detail=f"raw line: {USERNAME} failed",
        escalation_step=0,
        since=T0,
        phase="login",
        api_status="not_measured",
        now=T0,
    )
    for channel in channels.values():
        assert "CANARY" in outgoing_text(channel, leaky), channel.name


def test_credentials_sit_only_in_their_designated_slot(tmp_path: Path) -> None:
    channels, _ = configured_channels(tmp_path)
    built = MessageFactory(INSTANCE, "Etc/UTC", None, SecretRegistry()).build_test(
        phase="logged-in", api_status="ready", now=T0
    )
    ntfy = channels["ntfy"].requests(built)[0]
    assert ntfy.headers["Authorization"] == "Bearer CANARY_NTFY_TOKEN"
    pager = json.loads(channels["pagerduty"].requests(built)[0].body)
    assert pager["routing_key"] == "CANARY_PAGERDUTY_ROUTING_KEY"
    telegram = channels["telegram"].requests(built)[0]
    assert "CANARY_TELEGRAM_TOKEN" in telegram.url
    assert isinstance(Secret("x"), Secret)


async def test_a_farm_notice_reaches_an_alert_only_as_fixed_text_kind_and_a_real_farm_name(
    tmp_path: Path,
) -> None:
    """The sub-check of the canary, made explicit so it cannot pass for an unrelated reason."""
    evaluations, _, api_status = await evaluate_scenario(
        tmp_path, b"logged-in\n", api="ok", link_lost=False
    )
    detail = evaluations[AlertClass.API_UNHEALTHY].detail
    assert api_status == "degraded"
    assert "secdefnj" in detail  # a real farm name is shown
    assert "market_data other" in detail  # an unrecognised name is replaced, the kind is kept
    assert "CANARY" not in detail
    assert not ACCOUNT_RE.search(detail)
