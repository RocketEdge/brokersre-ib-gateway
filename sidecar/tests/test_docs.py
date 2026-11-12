"""The documents keep up with the code: every variable, class, channel and metric is described."""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from brokersre_sidecar.metrics import render_metrics
from brokersre_sidecar.model.health import ChannelSnapshot, NotifierSnapshot, TaskSnapshot
from brokersre_sidecar.vocab import AlertClass, ChannelName, ProbeStatus
from testkit import T0, gateway_snapshot, metrics_sample, probe_snapshot

SIDECAR_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = SIDECAR_ROOT.parent
README = (SIDECAR_ROOT / "README.md").read_text(encoding="utf-8")
SETTINGS_SOURCE = (SIDECAR_ROOT / "src" / "brokersre_sidecar" / "config" / "settings.py").read_text(
    encoding="utf-8"
)
TRADEMARK = (
    "Interactive Brokers, IBKR, IB Gateway and Trader Workstation are trademarks of "
    "Interactive Brokers LLC. This project is not affiliated with, endorsed by or sponsored "
    "by Interactive Brokers."
)
# Variables the loader refuses on purpose (a credential in a plain variable).
REFUSED = {
    "NOTIFY_WEBHOOK_URL",
    "NOTIFY_WEBHOOK_SECRET",
    "NOTIFY_TEAMS_URL",
    "NOTIFY_SLACK_URL",
    "NOTIFY_TELEGRAM_TOKEN",
    "NOTIFY_NTFY_URL",
    "NOTIFY_NTFY_TOKEN",
    "NOTIFY_PAGERDUTY_KEY",
    "NOTIFY_SMTP_URL",
}


def variables_read_by_the_loader() -> set[str]:
    """Return every environment variable name that appears as a string in settings.py."""
    names = set(re.findall(r'"([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)"', SETTINGS_SOURCE))
    return names - REFUSED


def test_the_loader_reads_a_plausible_set_of_variables() -> None:
    names = variables_read_by_the_loader()
    assert {"TRADING_MODE", "HEALTH_CLIENT_ID", "NOTIFY_TEAMS_URL_FILE", "SIDECAR_PORT"} <= names
    assert len(names) >= 30


@pytest.mark.parametrize("name", sorted(variables_read_by_the_loader()))
def test_every_environment_variable_has_a_row_in_the_readme(name: str) -> None:
    assert f"| `{name}` |" in README, f"{name} is not documented in sidecar/README.md"


@pytest.mark.parametrize("alert", list(AlertClass))
def test_every_alert_class_is_described_in_the_readme(alert: AlertClass) -> None:
    assert f"| `{alert.value}` |" in README


@pytest.mark.parametrize("channel", list(ChannelName))
def test_every_channel_is_described_in_the_readme(channel: ChannelName) -> None:
    assert f"| `{channel.value}` |" in README


@pytest.mark.parametrize("status", list(ProbeStatus))
def test_every_status_is_described_in_the_readme(status: ProbeStatus) -> None:
    assert f"| `{status.value}` |" in README


def test_every_exported_metric_is_listed_in_the_readme() -> None:
    notifier = NotifierSnapshot(
        enabled=True,
        channels=(ChannelSnapshot("teams", 1, 1, 0, 0, T0, T0, "timeout"),),
        active_alerts=(),
        state_persistence="file",
        state_persistence_reason=None,
    )
    sample = metrics_sample(
        T0,
        mem_working_set_bytes=1,
        mem_limit_bytes=1,
        oom_kills=1,
        cpu_usage_usec=1,
        cpu_throttled_usec=1,
        pids=1,
        java_rss_bytes=1,
        java_threads=1,
        open_fds=1,
    )
    text = render_metrics(
        gateway=gateway_snapshot(last_metrics=sample),
        probe=probe_snapshot(),
        notifier=notifier,
        tasks=(TaskSnapshot("probe", "running", 0, None, None),),
    )
    exported = set(re.findall(r"^# TYPE (\S+) ", text, flags=re.MULTILINE))
    assert len(exported) >= 19
    for name in sorted(exported):
        assert f"`{name}" in README, f"{name} is not documented in sidecar/README.md"


def test_the_readme_ends_with_the_trademark_sentence() -> None:
    assert README.rstrip("\n").endswith(TRADEMARK)


def test_the_readme_tells_to_publish_the_port_on_the_gateway_service() -> None:
    assert '"127.0.0.1:9810:9810"' in README
    assert 'network_mode: "service:ib-gateway"' in README


@pytest.mark.parametrize(
    "relative",
    [
        "docs/sidecar.md",
        "docs/adr/0010-sidecar-for-probe-status-and-alerts.md",
        "compose/docker-compose.sidecar.yml",
        ".github/workflows/sidecar.yml",
        ".github/workflows/sidecar-publish.yml",
        "sidecar/Dockerfile",
        "sidecar/schemas/status.v1.schema.json",
        "sidecar/tests/container/run.sh",
    ],
)
def test_the_sidecars_documents_and_pipeline_files_exist(relative: str) -> None:
    assert (REPOSITORY_ROOT / relative).is_file(), relative


def test_the_adr_follows_the_repository_template() -> None:
    adr = (REPOSITORY_ROOT / "docs/adr/0010-sidecar-for-probe-status-and-alerts.md").read_text(
        encoding="utf-8"
    )
    for heading in (
        "- **Status:**",
        "## Context",
        "## Decision",
        "## Consequences",
        "### Positive",
        "### Negative",
        "## Revisit trigger",
    ):
        assert heading in adr, heading


def test_the_architecture_note_has_a_mermaid_diagram() -> None:
    note = (REPOSITORY_ROOT / "docs/sidecar.md").read_text(encoding="utf-8")
    assert "```mermaid" in note
    assert note.count("```") % 2 == 0, "an unclosed code fence"
