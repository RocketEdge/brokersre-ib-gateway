"""Configuration from environment variables and secret files."""

from __future__ import annotations

from datetime import time
from pathlib import Path

import pytest

from brokersre_sidecar.config import ConfigError, Settings, load_secrets, load_settings
from brokersre_sidecar.config.secrets import SecretFileError, read_secret_file
from brokersre_sidecar.redaction import SecretRegistry


def problems(env: dict[str, str]) -> str:
    """Return the joined problem list of a refused configuration."""
    with pytest.raises(ConfigError) as caught:
        load_settings(env)
    return "\n".join(caught.value.problems)


def test_defaults_describe_a_paper_gateway_with_the_probe_on_and_no_notifier() -> None:
    settings = load_settings({})
    assert settings.instance == "default"
    assert settings.trading_mode == "paper"
    assert settings.api_port == 4002
    assert settings.time_zone == "Etc/UTC"
    assert settings.log_dir == Path("/var/log/ibgateway")
    assert settings.state_dir == Path("/var/lib/sidecar")
    assert settings.probe_enabled is True
    assert settings.health_client_id == 999
    assert settings.probe_interval_s == 60.0
    assert settings.probe_timeout_s == 10.0
    assert (settings.bind, settings.port) == ("0.0.0.0", 9810)
    assert settings.escalate_after_s == 600.0
    assert settings.escalate_again_after_s == 1800.0
    assert settings.heartbeat_time is None
    assert settings.runbook_base is None
    assert settings.exit_when_orphaned is True
    assert settings.configured_channels() == ()


def test_live_mode_selects_port_4001_and_empty_values_count_as_unset() -> None:
    settings = load_settings({"TRADING_MODE": "live", "API_PORT": "", "IBGW_INSTANCE": ""})
    assert settings.api_port == 4001
    assert settings.instance == "default"


def test_explicit_values_are_parsed() -> None:
    settings = load_settings(
        {
            "IBGW_INSTANCE": "desk-1",
            "TIME_ZONE": "Asia/Singapore",
            "API_PORT": "4012",
            "PROBE_ENABLED": "no",
            "HEALTH_CLIENT_ID": "998",
            "PROBE_INTERVAL_S": "30",
            "SIDECAR_BIND": "127.0.0.1",
            "SIDECAR_PORT": "9811",
            "ESCALATE_AFTER_S": "300",
            "ESCALATE_AGAIN_AFTER_S": "900",
            "HEARTBEAT_TIME": "08:30",
            "NOTIFY_RUNBOOK_BASE": "https://runbooks.example.com/ibgw/",
            "NOTIFY_DISABLE_CLASSES": "clock_skew, disk_low",
            "LOG_LEVEL": "DEBUG",
        }
    )
    assert settings.instance == "desk-1"
    assert settings.time_zone == "Asia/Singapore"
    assert settings.api_port == 4012
    assert settings.probe_enabled is False
    assert settings.health_client_id == 998
    assert settings.probe_interval_s == 30.0
    assert (settings.bind, settings.port) == ("127.0.0.1", 9811)
    assert settings.heartbeat_time == time(8, 30)
    assert settings.runbook_base == "https://runbooks.example.com/ibgw"
    assert settings.disabled_classes == frozenset({"clock_skew", "disk_low"})
    assert settings.log_level == "debug"


@pytest.mark.parametrize(
    ("env", "needle"),
    [
        ({"TRADING_MODE": "both"}, "TRADING_MODE"),
        ({"API_PORT": "70000"}, "API_PORT"),
        ({"API_PORT": "abc"}, "API_PORT"),
        ({"TIME_ZONE": "Mars/Olympus"}, "TIME_ZONE"),
        ({"IBGW_INSTANCE": "has space"}, "IBGW_INSTANCE"),
        ({"IBGW_INSTANCE": "DU1234567"}, "IBGW_INSTANCE"),
        ({"PROBE_ENABLED": "maybe"}, "PROBE_ENABLED"),
        ({"EXIT_WHEN_ORPHANED": "maybe"}, "EXIT_WHEN_ORPHANED"),
        ({"HEALTH_CLIENT_ID": "0"}, "HEALTH_CLIENT_ID"),
        ({"PROBE_INTERVAL_S": "1"}, "PROBE_INTERVAL_S"),
        ({"PROBE_INTERVAL_S": "nan"}, "PROBE_INTERVAL_S"),
        ({"SIDECAR_BIND": "localhost"}, "SIDECAR_BIND"),
        ({"SIDECAR_PORT": "0"}, "SIDECAR_PORT"),
        ({"HEARTBEAT_TIME": "25:00"}, "HEARTBEAT_TIME"),
        ({"ESCALATE_AFTER_S": "900", "ESCALATE_AGAIN_AFTER_S": "600"}, "ESCALATE_AGAIN_AFTER_S"),
        ({"NOTIFY_RUNBOOK_BASE": "ftp://example.com"}, "NOTIFY_RUNBOOK_BASE"),
        ({"NOTIFY_RUNBOOK_BASE": "https://user:pw@example.com"}, "NOTIFY_RUNBOOK_BASE"),
        ({"NOTIFY_DISABLE_CLASSES": "everything"}, "NOTIFY_DISABLE_CLASSES"),
        ({"NOTIFY_CHANNELS": "teams"}, "NOTIFY_CHANNELS"),
        ({"NOTIFY_TELEGRAM_TOKEN_FILE": "/run/secrets/t"}, "NOTIFY_TELEGRAM_CHAT_ID"),
        ({"NOTIFY_TELEGRAM_CHAT_ID": "12345"}, "NOTIFY_TELEGRAM_TOKEN_FILE"),
        ({"NOTIFY_SMTP_URL_FILE": "/run/secrets/s"}, "NOTIFY_SMTP_FROM"),
        (
            {
                "NOTIFY_SMTP_URL_FILE": "/run/secrets/s",
                "NOTIFY_SMTP_FROM": "a@example.com",
                "NOTIFY_SMTP_TO": "not-an-address",
            },
            "NOTIFY_SMTP_TO",
        ),
        ({"NOTIFY_WEBHOOK_SECRET_FILE": "/run/secrets/h"}, "NOTIFY_WEBHOOK_URL_FILE"),
        ({"NOTIFY_NTFY_TOKEN_FILE": "/run/secrets/n"}, "NOTIFY_NTFY_URL_FILE"),
        ({"LOG_LEVEL": "chatty"}, "LOG_LEVEL"),
    ],
)
def test_invalid_values_are_refused_naming_the_variable(env: dict[str, str], needle: str) -> None:
    assert needle in problems(env)


def test_every_problem_is_reported_at_once() -> None:
    text = problems({"TRADING_MODE": "both", "SIDECAR_PORT": "x", "TIME_ZONE": "Nope"})
    assert "TRADING_MODE" in text
    assert "SIDECAR_PORT" in text
    assert "TIME_ZONE" in text


@pytest.mark.parametrize(
    "name",
    [
        "NOTIFY_WEBHOOK_URL",
        "NOTIFY_WEBHOOK_SECRET",
        "NOTIFY_TEAMS_URL",
        "NOTIFY_SLACK_URL",
        "NOTIFY_TELEGRAM_TOKEN",
        "NOTIFY_NTFY_URL",
        "NOTIFY_NTFY_TOKEN",
        "NOTIFY_PAGERDUTY_KEY",
        "NOTIFY_SMTP_URL",
    ],
)
def test_a_secret_in_a_plain_variable_is_refused_without_echoing_it(name: str) -> None:
    text = problems({name: "https://CANARY_PLAIN_VALUE.example.com/hook"})
    assert name in text
    assert f"{name}_FILE" in text
    assert "CANARY_PLAIN_VALUE" not in text


def test_a_problem_never_echoes_a_refused_value() -> None:
    assert "CANARY_INSTANCE" not in problems({"IBGW_INSTANCE": "CANARY_INSTANCE with space"})


def test_channel_sets_default_to_every_configured_channel() -> None:
    settings = load_settings(
        {
            "NOTIFY_TEAMS_URL_FILE": "/run/secrets/teams",
            "NOTIFY_PAGERDUTY_KEY_FILE": "/run/secrets/pd",
            "NOTIFY_ESCALATION_CHANNELS": "pagerduty",
        }
    )
    assert settings.configured_channels() == ("teams", "pagerduty")
    assert settings.primary_channels() == ("teams", "pagerduty")
    assert settings.escalation_channels() == ("pagerduty",)


def test_settings_are_immutable() -> None:
    settings = load_settings({})
    with pytest.raises(Exception, match="frozen"):
        settings.port = 1  # type: ignore[misc]
    assert isinstance(settings, Settings)


def write(tmp_path: Path, name: str, data: bytes) -> Path:
    path = tmp_path / name
    path.write_bytes(data)
    return path


@pytest.mark.parametrize(
    "data",
    [
        b"hunter2hunter2",
        b"hunter2hunter2\n",
        b"hunter2hunter2\r\n",
        b"\xef\xbb\xbfhunter2hunter2\r\n\r\n",
    ],
)
def test_secret_files_tolerate_a_bom_and_trailing_line_endings(tmp_path: Path, data: bytes) -> None:
    assert read_secret_file(write(tmp_path, "s", data), "NOTIFY_X_FILE") == "hunter2hunter2"


@pytest.mark.parametrize(
    ("data", "reason"),
    [
        (b"", "empty"),
        (b"\r\n", "empty"),
        (b"\xff\xfeh\x00u\x00", "UTF-16"),
        (b"\xfe\xff\x00h\x00u", "UTF-16"),
        (b"hunter2\x00hunter2", "NUL"),
        (b"\xff\xff\xff", "UTF-8"),
        (b"line one\nline two", "line break"),
        (b"tab\there", "control"),
    ],
)
def test_secret_files_that_cannot_be_a_secret_are_refused_with_a_reason(
    tmp_path: Path, data: bytes, reason: str
) -> None:
    with pytest.raises(SecretFileError, match=reason) as caught:
        read_secret_file(write(tmp_path, "s", data), "NOTIFY_X_FILE")
    assert "NOTIFY_X_FILE" in str(caught.value)
    assert "hunter2" not in str(caught.value)


def test_a_missing_secret_file_is_refused(tmp_path: Path) -> None:
    with pytest.raises(SecretFileError, match="cannot be read"):
        read_secret_file(tmp_path / "absent", "NOTIFY_X_FILE")


def test_an_oversized_secret_file_is_refused(tmp_path: Path) -> None:
    with pytest.raises(SecretFileError, match="larger than"):
        read_secret_file(write(tmp_path, "s", b"x" * 70_000), "NOTIFY_X_FILE")


def channel_env(tmp_path: Path, **files: str) -> dict[str, str]:
    """Write one secret file per keyword and return the matching ``*_FILE`` environment."""
    env: dict[str, str] = {}
    for variable, content in files.items():
        env[variable] = str(write(tmp_path, variable, content.encode("utf-8")))
    return env


def test_secrets_are_loaded_registered_and_never_shown_by_repr(tmp_path: Path) -> None:
    env = channel_env(
        tmp_path,
        NOTIFY_WEBHOOK_URL_FILE="https://hooks.example.com/CANARY_WEBHOOK\n",
        NOTIFY_WEBHOOK_SECRET_FILE="CANARY_HMAC_SECRET",
        NOTIFY_TEAMS_URL_FILE="https://example.logic.azure.com/workflows/CANARY_TEAMS",
        NOTIFY_SLACK_URL_FILE="https://hooks.slack.com/services/CANARY_SLACK",
        NOTIFY_TELEGRAM_TOKEN_FILE="123456:CANARY_TELEGRAM",
        NOTIFY_NTFY_URL_FILE="https://ntfy.example.com/CANARY_TOPIC",
        NOTIFY_NTFY_TOKEN_FILE="CANARY_NTFY_TOKEN",
        NOTIFY_PAGERDUTY_KEY_FILE="CANARY_PAGERDUTY_KEY_0123456789ab",
        NOTIFY_SMTP_URL_FILE="smtps://mailer:CANARY_SMTP_PASSWORD@smtp.example.com:465",
    )
    env |= {
        "NOTIFY_TELEGRAM_CHAT_ID": "-1001234",
        "NOTIFY_SMTP_FROM": "ibgw@example.com",
        "NOTIFY_SMTP_TO": "ops@example.com, oncall@example.com",
    }
    settings = load_settings(env)
    registry = SecretRegistry()
    secrets = load_secrets(settings, registry)
    assert secrets.webhook_url is not None
    assert secrets.webhook_url.reveal() == "https://hooks.example.com/CANARY_WEBHOOK"
    assert secrets.smtp is not None
    assert (secrets.smtp.host, secrets.smtp.port, secrets.smtp.implicit_tls) == (
        "smtp.example.com",
        465,
        True,
    )
    assert secrets.smtp.username == "mailer"
    assert "CANARY" not in repr(secrets)
    assert "CANARY" not in repr(settings)
    assert settings.smtp_to == ("ops@example.com", "oncall@example.com")
    leak = "x CANARY_HMAC_SECRET y https://hooks.slack.com/services/CANARY_SLACK z CANARY_SMTP_PASSWORD"
    assert "CANARY" not in registry.scrub(leak)


def test_plain_http_urls_are_refused_unless_explicitly_allowed(tmp_path: Path) -> None:
    env = channel_env(tmp_path, NOTIFY_NTFY_URL_FILE="http://ntfy.internal:8080/CANARY_TOPIC")
    with pytest.raises(ConfigError) as caught:
        load_secrets(load_settings(env), SecretRegistry())
    text = "\n".join(caught.value.problems)
    assert "NOTIFY_NTFY_URL_FILE" in text
    assert "https" in text
    assert "CANARY" not in text
    allowed = load_secrets(load_settings(env | {"NOTIFY_ALLOW_HTTP": "yes"}), SecretRegistry())
    assert allowed.ntfy_url is not None


@pytest.mark.parametrize(
    ("variable", "content"),
    [
        ("NOTIFY_SLACK_URL_FILE", "hooks.slack.com/services/CANARY"),
        ("NOTIFY_SLACK_URL_FILE", "https:///CANARY-no-host"),
        ("NOTIFY_SLACK_URL_FILE", "https://hooks.slack.com/a b/CANARY"),
        ("NOTIFY_TELEGRAM_TOKEN_FILE", "CANARY-not-a-bot-token"),
        ("NOTIFY_SMTP_URL_FILE", "https://smtp.example.com/CANARY"),
        ("NOTIFY_SMTP_URL_FILE", "smtps://smtp.example.com:notaport"),
    ],
)
def test_malformed_secret_contents_are_refused_without_echoing_them(
    tmp_path: Path, variable: str, content: str
) -> None:
    env = channel_env(tmp_path, **{variable: content})
    env |= {
        "NOTIFY_TELEGRAM_CHAT_ID": "1",
        "NOTIFY_SMTP_FROM": "a@example.com",
        "NOTIFY_SMTP_TO": "b@example.com",
    }
    settings = load_settings(
        {
            key: value
            for key, value in env.items()
            if key.startswith(variable.rsplit("_", 2)[0]) or key == variable
        }
    )
    with pytest.raises(ConfigError) as caught:
        load_secrets(settings, SecretRegistry())
    text = "\n".join(caught.value.problems)
    assert variable in text
    assert "CANARY" not in text


def test_smtp_without_tls_scheme_defaults_and_starttls_port(tmp_path: Path) -> None:
    env = channel_env(tmp_path, NOTIFY_SMTP_URL_FILE="smtp://relay.example.com")
    env |= {"NOTIFY_SMTP_FROM": "a@example.com", "NOTIFY_SMTP_TO": "b@example.com"}
    secrets = load_secrets(load_settings(env), SecretRegistry())
    assert secrets.smtp is not None
    assert (secrets.smtp.port, secrets.smtp.implicit_tls, secrets.smtp.username) == (
        587,
        False,
        None,
    )
