"""Sidecar configuration: environment variables in, one immutable ``Settings`` object out.

Design rules:

* Every problem is collected and reported at once (``ConfigError.problems``), each naming
  its variable. A refused value is never echoed: it may be a pasted credential.
* A credential is accepted only as a ``*_FILE`` path. The same name without ``_FILE``
  (``NOTIFY_SLACK_URL`` ...) is refused at start, so a URL or token can never sit in a
  compose file, ``docker inspect`` output or ``/proc/<pid>/environ``.
* An empty value means "unset" (compose renders ``${VAR:-}`` as an empty string).
* The notifier is opt-in: it exists only when at least one channel is configured.
"""

from __future__ import annotations

import ipaddress
import math
import re
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from datetime import time
from pathlib import Path
from typing import Literal
from urllib.parse import urlsplit
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import BaseModel, ConfigDict

from brokersre_sidecar.config.secrets import (
    Secret,
    SecretFileError,
    SmtpTarget,
    parse_smtp_url,
    read_secret_file,
    validate_http_url,
    validate_telegram_token,
)
from brokersre_sidecar.redaction import ACCOUNT_RE, SecretRegistry
from brokersre_sidecar.vocab import AlertClass, ChannelName

DEFAULT_LOG_DIR = "/var/log/ibgateway"
DEFAULT_STATE_DIR = "/var/lib/sidecar"
# All interfaces of the SHARED network namespace: the sidecar has no port mapping of its own,
# so the endpoints are reachable from outside only where the gateway service publishes 9810.
DEFAULT_BIND = "0.0.0.0"  # noqa: S104
PAPER_API_PORT = 4002
LIVE_API_PORT = 4001

# Variables that would hold a credential in the environment; each is refused in favour of
# its *_FILE form.
_REFUSED_PLAIN = (
    "NOTIFY_WEBHOOK_URL",
    "NOTIFY_WEBHOOK_SECRET",
    "NOTIFY_TEAMS_URL",
    "NOTIFY_SLACK_URL",
    "NOTIFY_TELEGRAM_TOKEN",
    "NOTIFY_NTFY_URL",
    "NOTIFY_NTFY_TOKEN",
    "NOTIFY_PAGERDUTY_KEY",
    "NOTIFY_SMTP_URL",
)

_INSTANCE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")
_HHMM_RE = re.compile(r"^([01]\d|2[0-3]):([0-5]\d)$")
_EMAIL_RE = re.compile(r"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$")
_TELEGRAM_CHAT_RE = re.compile(r"^(-?\d{1,20}|@[A-Za-z0-9_]{5,32})$")
_TRUE = frozenset({"yes", "true", "1", "on"})
_FALSE = frozenset({"no", "false", "0", "off"})
_LOG_LEVELS = frozenset({"debug", "info", "warn", "warning", "error"})


class ConfigError(Exception):
    """The configuration is unusable.

    Attributes:
        problems: One line per problem, each starting with the variable name. Safe to print:
            no line contains a configured value.
    """

    def __init__(self, problems: list[str]) -> None:
        """Store the problem list; the exception text joins the lines."""
        super().__init__("; ".join(problems))
        self.problems = problems


class Settings(BaseModel):
    """Validated, immutable sidecar configuration. Field names mirror the variables.

    Paths to secret files are kept here; their contents are loaded separately by
    ``load_secrets`` so that ``repr(settings)`` can never show a credential.
    """

    model_config = ConfigDict(frozen=True)

    instance: str
    trading_mode: Literal["paper", "live"]
    api_port: int
    time_zone: str
    log_dir: Path
    state_dir: Path
    log_level: str

    probe_enabled: bool
    health_client_id: int
    probe_interval_s: float
    probe_timeout_s: float

    bind: str
    port: int
    exit_when_orphaned: bool

    login_stall_s: float
    escalate_after_s: float
    escalate_again_after_s: float
    heartbeat_time: time | None
    runbook_base: str | None
    allow_http: bool
    notify_channels: tuple[str, ...] | None
    notify_escalation_channels: tuple[str, ...] | None
    disabled_classes: frozenset[str]

    webhook_url_file: Path | None
    webhook_secret_file: Path | None
    teams_url_file: Path | None
    slack_url_file: Path | None
    telegram_token_file: Path | None
    telegram_chat_id: str | None
    ntfy_url_file: Path | None
    ntfy_token_file: Path | None
    pagerduty_key_file: Path | None
    smtp_url_file: Path | None
    smtp_from: str | None
    smtp_to: tuple[str, ...]

    def configured_channels(self) -> tuple[str, ...]:
        """Return the names of the channels that have their secret file set, in fixed order."""
        present = {
            ChannelName.WEBHOOK: self.webhook_url_file,
            ChannelName.TEAMS: self.teams_url_file,
            ChannelName.SLACK: self.slack_url_file,
            ChannelName.TELEGRAM: self.telegram_token_file,
            ChannelName.NTFY: self.ntfy_url_file,
            ChannelName.PAGERDUTY: self.pagerduty_key_file,
            ChannelName.SMTP: self.smtp_url_file,
        }
        return tuple(name.value for name, path in present.items() if path is not None)

    def primary_channels(self) -> tuple[str, ...]:
        """Return the channels that receive first notifications (default: all configured)."""
        return (
            self.notify_channels if self.notify_channels is not None else self.configured_channels()
        )

    def escalation_channels(self) -> tuple[str, ...]:
        """Return the channels that receive escalations (default: all configured)."""
        if self.notify_escalation_channels is not None:
            return self.notify_escalation_channels
        return self.configured_channels()


@dataclass(frozen=True, slots=True)
class ChannelSecrets:
    """Credentials of the configured channels; a channel that is not configured is None.

    Every value is a ``Secret`` (or an ``SmtpTarget`` holding one), so the dataclass repr
    shows placeholders only.
    """

    webhook_url: Secret | None = None
    webhook_hmac_secret: Secret | None = None
    teams_url: Secret | None = None
    slack_url: Secret | None = None
    telegram_token: Secret | None = None
    ntfy_url: Secret | None = None
    ntfy_token: Secret | None = None
    pagerduty_key: Secret | None = None
    smtp: SmtpTarget | None = None


class _Reader:
    """Typed access to an environment mapping that collects problems instead of raising."""

    def __init__(self, env: Mapping[str, str]) -> None:
        """Wrap ``env``; ``problems`` collects one line per invalid variable."""
        self._env = env
        self.problems: list[str] = []

    def raw(self, name: str) -> str | None:
        """Return the stripped value of ``name`` or None when unset or empty."""
        value = self._env.get(name, "").strip()
        return value or None

    def text(
        self, name: str, default: str | None, check: Callable[[str], str | None]
    ) -> str | None:
        """Return ``name`` after ``check`` accepted it (``check`` returns a problem or None)."""
        value = self.raw(name)
        if value is None:
            return default
        problem = check(value)
        if problem is not None:
            self.problems.append(f"{name}: {problem}")
            return default
        return value

    def flag(self, name: str, default: bool) -> bool:
        """Parse a yes/no variable."""
        value = self.raw(name)
        if value is None:
            return default
        lowered = value.lower()
        if lowered in _TRUE:
            return True
        if lowered in _FALSE:
            return False
        self.problems.append(f"{name}: must be yes or no")
        return default

    def integer(self, name: str, default: int, low: int, high: int) -> int:
        """Parse an integer within ``[low, high]``."""
        value = self.raw(name)
        if value is None:
            return default
        try:
            number = int(value, 10)
        except ValueError:
            self.problems.append(f"{name}: must be an integer between {low} and {high}")
            return default
        if not low <= number <= high:
            self.problems.append(f"{name}: must be an integer between {low} and {high}")
            return default
        return number

    def seconds(self, name: str, default: float, low: float, high: float) -> float:
        """Parse a finite number of seconds within ``[low, high]``."""
        value = self.raw(name)
        if value is None:
            return default
        try:
            number = float(value)
        except ValueError:
            number = math.nan
        if not math.isfinite(number) or not low <= number <= high:
            self.problems.append(
                f"{name}: must be a number of seconds between {low:g} and {high:g}"
            )
            return default
        return number

    def path(self, name: str) -> Path | None:
        """Return ``name`` as a path, or None when unset."""
        value = self.raw(name)
        return Path(value) if value is not None else None

    def names(self, name: str, allowed: frozenset[str], what: str) -> tuple[str, ...] | None:
        """Parse a comma-separated list whose items must all be in ``allowed``."""
        value = self.raw(name)
        if value is None:
            return None
        items = tuple(item.strip().lower() for item in value.split(",") if item.strip())
        if not items or any(item not in allowed for item in items):
            self.problems.append(
                f"{name}: must be a comma-separated list of {what}: {', '.join(sorted(allowed))}"
            )
            return None
        return tuple(dict.fromkeys(items))


def _check_instance(value: str) -> str | None:
    """Accept a label of letters, digits, dot, dash, underscore that is not an account id."""
    if not _INSTANCE_RE.fullmatch(value):
        return "must be 1-63 characters of letters, digits, '.', '_' or '-', starting with a letter or digit"
    if ACCOUNT_RE.fullmatch(value):
        return "must not be an IBKR account id (the label appears in every notification)"
    return None


def _check_time_zone(value: str) -> str | None:
    """Accept an IANA zone name known to ``zoneinfo``."""
    try:
        ZoneInfo(value)
    except ZoneInfoNotFoundError, ValueError, OSError:
        return "must be an IANA time zone name such as America/New_York"
    return None


def _check_bind(value: str) -> str | None:
    """Accept an IPv4 or IPv6 address literal (no host names: nothing is resolved at start)."""
    try:
        ipaddress.ip_address(value)
    except ValueError:
        return "must be an IP address such as 0.0.0.0 or 127.0.0.1"
    return None


def _check_runbook(value: str) -> str | None:
    """Accept an http(s) URL without credentials, query or fragment."""
    try:
        parts = urlsplit(value)
        host = parts.hostname
    except ValueError:
        return "must be an https:// URL"
    if parts.scheme not in ("https", "http") or not host:
        return "must be an https:// URL"
    if parts.username or parts.password or parts.query or parts.fragment:
        return "must not contain credentials, a query string or a fragment (it is printed in every notification)"
    return None


def load_settings(env: Mapping[str, str]) -> Settings:
    """Build ``Settings`` from an environment mapping.

    Args:
        env: Normally ``os.environ``. Unknown variables are ignored.

    Returns:
        The validated configuration. No file is read here.

    Raises:
        ConfigError: One or more variables are invalid; ``problems`` lists all of them.
    """
    reader = _Reader(env)
    for name in _REFUSED_PLAIN:
        if reader.raw(name) is not None:
            reader.problems.append(
                f"{name}: a credential in a plain variable is refused; write it to a file and set {name}_FILE to the path"
            )

    instance = reader.text("IBGW_INSTANCE", "default", _check_instance) or "default"
    mode_text = reader.text(
        "TRADING_MODE",
        "paper",
        lambda v: None if v.lower() in ("paper", "live") else "must be live or paper",
    )
    trading_mode: Literal["paper", "live"] = (
        "live" if (mode_text or "paper").lower() == "live" else "paper"
    )
    api_port = reader.integer(
        "API_PORT", LIVE_API_PORT if trading_mode == "live" else PAPER_API_PORT, 1, 65535
    )
    time_zone = reader.text("TIME_ZONE", "Etc/UTC", _check_time_zone) or "Etc/UTC"
    log_level = (
        reader.text(
            "LOG_LEVEL",
            "info",
            lambda v: None if v.lower() in _LOG_LEVELS else "must be debug, info, warn or error",
        )
        or "info"
    ).lower()

    escalate_after_s = reader.seconds("ESCALATE_AFTER_S", 600.0, 60.0, 86400.0)
    escalate_again_after_s = reader.seconds(
        "ESCALATE_AGAIN_AFTER_S", max(1800.0, escalate_after_s * 3), 60.0, 7 * 86400.0
    )
    if escalate_again_after_s <= escalate_after_s:
        reader.problems.append("ESCALATE_AGAIN_AFTER_S: must be greater than ESCALATE_AFTER_S")

    heartbeat_text = reader.text(
        "HEARTBEAT_TIME",
        None,
        lambda v: None if _HHMM_RE.fullmatch(v) else "must be HH:MM (24-hour, in TIME_ZONE)",
    )
    heartbeat_time = (
        time(int(heartbeat_text[:2]), int(heartbeat_text[3:])) if heartbeat_text else None
    )
    runbook = reader.text("NOTIFY_RUNBOOK_BASE", None, _check_runbook)

    files = {
        ChannelName.WEBHOOK: reader.path("NOTIFY_WEBHOOK_URL_FILE"),
        ChannelName.TEAMS: reader.path("NOTIFY_TEAMS_URL_FILE"),
        ChannelName.SLACK: reader.path("NOTIFY_SLACK_URL_FILE"),
        ChannelName.TELEGRAM: reader.path("NOTIFY_TELEGRAM_TOKEN_FILE"),
        ChannelName.NTFY: reader.path("NOTIFY_NTFY_URL_FILE"),
        ChannelName.PAGERDUTY: reader.path("NOTIFY_PAGERDUTY_KEY_FILE"),
        ChannelName.SMTP: reader.path("NOTIFY_SMTP_URL_FILE"),
    }
    configured = frozenset(name.value for name, path in files.items() if path is not None)
    webhook_secret_file = reader.path("NOTIFY_WEBHOOK_SECRET_FILE")
    if webhook_secret_file is not None and files[ChannelName.WEBHOOK] is None:
        reader.problems.append(
            "NOTIFY_WEBHOOK_URL_FILE: required when NOTIFY_WEBHOOK_SECRET_FILE is set"
        )
    ntfy_token_file = reader.path("NOTIFY_NTFY_TOKEN_FILE")
    if ntfy_token_file is not None and files[ChannelName.NTFY] is None:
        reader.problems.append("NOTIFY_NTFY_URL_FILE: required when NOTIFY_NTFY_TOKEN_FILE is set")

    chat_id = reader.text(
        "NOTIFY_TELEGRAM_CHAT_ID",
        None,
        lambda v: (
            None if _TELEGRAM_CHAT_RE.fullmatch(v) else "must be a numeric chat id or @channelname"
        ),
    )
    if files[ChannelName.TELEGRAM] is not None and reader.raw("NOTIFY_TELEGRAM_CHAT_ID") is None:
        reader.problems.append(
            "NOTIFY_TELEGRAM_CHAT_ID: required when NOTIFY_TELEGRAM_TOKEN_FILE is set"
        )
    if files[ChannelName.TELEGRAM] is None and reader.raw("NOTIFY_TELEGRAM_CHAT_ID") is not None:
        reader.problems.append(
            "NOTIFY_TELEGRAM_TOKEN_FILE: required when NOTIFY_TELEGRAM_CHAT_ID is set"
        )

    smtp_from = reader.text(
        "NOTIFY_SMTP_FROM",
        None,
        lambda v: None if _EMAIL_RE.fullmatch(v) else "must be an e-mail address",
    )
    smtp_to_text = reader.raw("NOTIFY_SMTP_TO")
    smtp_to = tuple(item.strip() for item in (smtp_to_text or "").split(",") if item.strip())
    if any(not _EMAIL_RE.fullmatch(address) for address in smtp_to):
        reader.problems.append("NOTIFY_SMTP_TO: must be a comma-separated list of e-mail addresses")
        smtp_to = ()
    if files[ChannelName.SMTP] is not None:
        if reader.raw("NOTIFY_SMTP_FROM") is None:
            reader.problems.append("NOTIFY_SMTP_FROM: required when NOTIFY_SMTP_URL_FILE is set")
        if smtp_to_text is None:
            reader.problems.append("NOTIFY_SMTP_TO: required when NOTIFY_SMTP_URL_FILE is set")

    notify_channels = reader.names("NOTIFY_CHANNELS", configured, "configured channels")
    escalation_channels = reader.names(
        "NOTIFY_ESCALATION_CHANNELS", configured, "configured channels"
    )
    disabled = reader.names(
        "NOTIFY_DISABLE_CLASSES", frozenset(item.value for item in AlertClass), "alert classes"
    )

    settings = Settings(
        instance=instance,
        trading_mode=trading_mode,
        api_port=api_port,
        time_zone=time_zone,
        log_dir=Path(reader.raw("GATEWAY_LOG_DIR") or DEFAULT_LOG_DIR),
        state_dir=Path(reader.raw("SIDECAR_STATE_DIR") or DEFAULT_STATE_DIR),
        log_level=log_level,
        probe_enabled=reader.flag("PROBE_ENABLED", True),
        # Client id 0 is special in the IB API (it adopts orders placed by hand); the probe
        # must never be that client.
        health_client_id=reader.integer("HEALTH_CLIENT_ID", 999, 1, 2_147_483_647),
        probe_interval_s=reader.seconds("PROBE_INTERVAL_S", 60.0, 5.0, 3600.0),
        probe_timeout_s=reader.seconds("PROBE_TIMEOUT_S", 10.0, 1.0, 60.0),
        bind=reader.text("SIDECAR_BIND", DEFAULT_BIND, _check_bind) or DEFAULT_BIND,
        port=reader.integer("SIDECAR_PORT", 9810, 1, 65535),
        exit_when_orphaned=reader.flag("EXIT_WHEN_ORPHANED", True),
        login_stall_s=reader.seconds("LOGIN_STALL_S", 300.0, 30.0, 86400.0),
        escalate_after_s=escalate_after_s,
        escalate_again_after_s=escalate_again_after_s,
        heartbeat_time=heartbeat_time,
        runbook_base=runbook.rstrip("/") if runbook else None,
        allow_http=reader.flag("NOTIFY_ALLOW_HTTP", False),
        notify_channels=notify_channels,
        notify_escalation_channels=escalation_channels,
        disabled_classes=frozenset(disabled or ()),
        webhook_url_file=files[ChannelName.WEBHOOK],
        webhook_secret_file=webhook_secret_file,
        teams_url_file=files[ChannelName.TEAMS],
        slack_url_file=files[ChannelName.SLACK],
        telegram_token_file=files[ChannelName.TELEGRAM],
        telegram_chat_id=chat_id,
        ntfy_url_file=files[ChannelName.NTFY],
        ntfy_token_file=ntfy_token_file,
        pagerduty_key_file=files[ChannelName.PAGERDUTY],
        smtp_url_file=files[ChannelName.SMTP],
        smtp_from=smtp_from,
        smtp_to=smtp_to,
    )
    if reader.problems:
        raise ConfigError(reader.problems)
    return settings


def load_secrets(settings: Settings, registry: SecretRegistry) -> ChannelSecrets:
    """Read and validate the secret file of every configured channel.

    Args:
        settings: Configuration holding the ``*_FILE`` paths.
        registry: Receives every secret value so logs and messages are scrubbed of them.

    Returns:
        The channel credentials.

    Raises:
        ConfigError: A file is unreadable or its content is malformed; every problem is
            listed, each naming its variable and never the content.

    Side effects:
        Reads the secret files.
    """
    problems: list[str] = []

    def read(
        path: Path | None, variable: str, check: Callable[[str, str], None] | None = None
    ) -> Secret | None:
        """Read one optional secret, validate it and register it; collect any problem."""
        if path is None:
            return None
        try:
            value = read_secret_file(path, variable)
            if check is not None:
                check(value, variable)
        except SecretFileError as error:
            problems.append(str(error))
            return None
        registry.add(value)
        return Secret(value)

    def http_url(value: str, variable: str) -> None:
        """Validate an HTTP(S) endpoint under the NOTIFY_ALLOW_HTTP policy."""
        validate_http_url(value, variable, settings.allow_http)

    smtp: SmtpTarget | None = None
    if settings.smtp_url_file is not None:
        try:
            smtp_url = read_secret_file(settings.smtp_url_file, "NOTIFY_SMTP_URL_FILE")
            registry.add(smtp_url)
            smtp = parse_smtp_url(smtp_url, "NOTIFY_SMTP_URL_FILE", registry)
        except SecretFileError as error:
            problems.append(str(error))

    secrets = ChannelSecrets(
        webhook_url=read(settings.webhook_url_file, "NOTIFY_WEBHOOK_URL_FILE", http_url),
        webhook_hmac_secret=read(settings.webhook_secret_file, "NOTIFY_WEBHOOK_SECRET_FILE"),
        teams_url=read(settings.teams_url_file, "NOTIFY_TEAMS_URL_FILE", http_url),
        slack_url=read(settings.slack_url_file, "NOTIFY_SLACK_URL_FILE", http_url),
        telegram_token=read(
            settings.telegram_token_file, "NOTIFY_TELEGRAM_TOKEN_FILE", validate_telegram_token
        ),
        ntfy_url=read(settings.ntfy_url_file, "NOTIFY_NTFY_URL_FILE", http_url),
        ntfy_token=read(settings.ntfy_token_file, "NOTIFY_NTFY_TOKEN_FILE"),
        pagerduty_key=read(settings.pagerduty_key_file, "NOTIFY_PAGERDUTY_KEY_FILE"),
        smtp=smtp,
    )
    if problems:
        raise ConfigError(problems)
    return secrets
