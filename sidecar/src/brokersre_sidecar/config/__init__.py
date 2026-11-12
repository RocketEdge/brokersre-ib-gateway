"""Configuration layer: environment variables and secret files (lowest layer of the package)."""

from brokersre_sidecar.config.secrets import Secret, SecretFileError, SmtpTarget, read_secret_file
from brokersre_sidecar.config.settings import (
    ChannelSecrets,
    ConfigError,
    Settings,
    endpoint_text,
    load_secrets,
    load_settings,
)

__all__ = [
    "ChannelSecrets",
    "ConfigError",
    "Secret",
    "SecretFileError",
    "Settings",
    "SmtpTarget",
    "endpoint_text",
    "load_secrets",
    "load_settings",
    "read_secret_file",
]
