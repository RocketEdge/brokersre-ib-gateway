"""The documents keep up with the code: every variable, class, channel and metric is described."""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from brokersre_sidecar.config import load_settings
from brokersre_sidecar.metrics import render_metrics
from brokersre_sidecar.model.health import (
    ChannelSnapshot,
    DeadmanSnapshot,
    NotifierSnapshot,
    TaskSnapshot,
)
from brokersre_sidecar.notify.catalog import CATALOG
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
    "DEADMAN_PING_URL",
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
        tasks=(TaskSnapshot("probe", "running", 0, None, None, progress_age_s=1.0),),
        deadman=DeadmanSnapshot(True, 60.0, None, T0, None, 1, 0),
    )
    exported = set(re.findall(r"^# TYPE (\S+) ", text, flags=re.MULTILINE))
    assert len(exported) >= 19
    for name in sorted(exported):
        assert f"`{name}" in README, f"{name} is not documented in sidecar/README.md"


def test_the_readme_ends_with_the_trademark_sentence() -> None:
    assert README.rstrip("\n").endswith(TRADEMARK)


def test_the_readme_shows_both_network_modes_and_which_one_is_the_default() -> None:
    assert "### Own network namespace (default, recommended)" in README
    assert "### Shared network namespace (optional)" in README
    assert '"127.0.0.1:9810:9810"' in README
    assert 'network_mode: "service:ib-gateway"' in README


def test_the_default_compose_file_adds_nothing_to_the_gateway_service() -> None:
    default = (REPOSITORY_ROOT / "compose/docker-compose.sidecar.yml").read_text(encoding="utf-8")
    code = "\n".join(line for line in default.splitlines() if not line.lstrip().startswith("#"))
    assert "network_mode" not in code
    assert "\n  ib-gateway:\n" not in code  # no override of the gateway service
    assert ":9810:9810" in code  # the sidecar publishes its own port
    assert "ibgw-logs:/var/log/ibgateway:ro" in code
    shared = (REPOSITORY_ROOT / "compose/docker-compose.sidecar-shared.yml").read_text(
        encoding="utf-8"
    )
    assert 'network_mode: "service:ib-gateway"' in shared
    assert "GATEWAY_HOST: 127.0.0.1" in shared


def test_the_readme_says_plainly_that_a_dead_host_is_silent_without_the_dead_man_ping() -> None:
    assert "**Without a\ndead-man check, a dead host is silent**" in README


def test_the_reset_windows_cite_their_source_and_the_date_they_were_checked() -> None:
    assert "https://brokerage.ibkr.com/en/software/systemStatus.php" in README
    assert "checked on 2026-11-12" in README
    windows = (SIDECAR_ROOT / "src" / "brokersre_sidecar" / "probe" / "windows.py").read_text(
        encoding="utf-8"
    )
    assert "https://brokerage.ibkr.com/en/software/systemStatus.php" in windows
    assert "2026-11-12" in windows


def test_every_link_inside_the_readme_points_at_a_heading_that_exists() -> None:
    headings = re.findall(r"^#{2,3} (.+)$", README, flags=re.MULTILINE)
    anchors = {
        re.sub(r"[^a-z0-9 -]", "", heading.lower()).replace(" ", "-") for heading in headings
    }
    links = set(re.findall(r"\]\(#([a-z0-9-]+)\)", README))
    assert links, "the README has in-page links"
    assert links <= anchors, sorted(links - anchors)


@pytest.mark.parametrize(
    "relative",
    [
        "docs/sidecar.md",
        "docs/adr/0010-sidecar-for-probe-status-and-alerts.md",
        "compose/docker-compose.sidecar.yml",
        "compose/docker-compose.sidecar-shared.yml",
        ".github/workflows/sidecar.yml",
        ".github/workflows/sidecar-publish.yml",
        ".github/workflows/sidecar-rescan.yml",
        "sidecar/Dockerfile",
        "sidecar/schemas/status.v1.schema.json",
        "sidecar/tests/container/run.sh",
        "sidecar/tests/e2e/run.sh",
        "sidecar/tests/e2e/receiver.py",
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


# --- runbooks: one page per alert class, where the link in a notification points ---------

RUNBOOKS = REPOSITORY_ROOT / "docs" / "runbooks"
RUNBOOK_BASE = "https://github.com/RocketEdge/brokersre-ib-gateway/tree/main/docs/runbooks"
RUNBOOK_SECTIONS = (
    "## What it means",
    "## Check first",
    "## What to do",
    "## What not to do",
    "## When it clears",
)


@pytest.mark.parametrize("alert", sorted(AlertClass, key=str))
def test_every_alert_class_has_a_runbook_where_its_link_points(alert: AlertClass) -> None:
    # A notification carries `runbook: <NOTIFY_RUNBOOK_BASE>/<alert class>`. With the base set
    # to this repository's docs/runbooks that address is a directory, so every class has one,
    # and its README.md starts with the alert's own title: the page a person lands on is
    # recognisably about the message that sent them there.
    page = RUNBOOKS / alert.value / "README.md"
    assert page.is_file(), f"docs/runbooks/{alert.value}/README.md is missing"
    text = page.read_text(encoding="utf-8")
    assert text.splitlines()[0] == f"# {CATALOG[alert].title}"
    assert f"`{alert.value}`" in text
    for section in RUNBOOK_SECTIONS:
        assert section in text, f"{alert.value}: section {section!r} is missing"


def test_there_is_no_runbook_for_an_alert_class_that_does_not_exist() -> None:
    directories = {entry.name for entry in RUNBOOKS.iterdir() if entry.is_dir()}
    assert directories == {alert.value for alert in AlertClass}


def test_the_runbook_index_lists_every_class_and_carries_the_trademark_sentence() -> None:
    index = (RUNBOOKS / "README.md").read_text(encoding="utf-8")
    for alert in AlertClass:
        assert f"]({alert.value}/README.md)" in index, f"{alert.value} is not in the index"
    assert index.rstrip().endswith(TRADEMARK)


def test_the_readme_and_the_compose_file_name_the_runbook_base_of_this_repository() -> None:
    compose = (REPOSITORY_ROOT / "compose" / "docker-compose.sidecar.yml").read_text(
        encoding="utf-8"
    )
    assert RUNBOOK_BASE in README
    assert RUNBOOK_BASE in compose


def test_the_sidecar_accepts_the_runbook_base_the_documents_recommend() -> None:
    # The loader refuses a base with a query string, credentials or characters that cannot
    # travel in an HTTP header; the address the README and the compose file give must pass.
    assert load_settings({"NOTIFY_RUNBOOK_BASE": RUNBOOK_BASE}).runbook_base == RUNBOOK_BASE


# The target of an inline Markdown link: `[text](target)`.
_LINK_TARGET = re.compile(r"\]\(([^)\s]+)\)")
# A Markdown heading line; group 1 is its text.
_HEADING = re.compile(r"^#{1,6}\s+(.*)$", re.MULTILINE)


def _anchors(markdown: str) -> set[str]:
    """Return the anchors GitHub derives from the headings of ``markdown``.

    GitHub lower-cases a heading, drops everything but letters, digits, blanks, hyphens and
    underscores, and turns each blank into a hyphen.
    """
    anchors: set[str] = set()
    for heading in _HEADING.findall(markdown):
        kept = "".join(ch for ch in heading.strip().lower() if ch.isalnum() or ch in " -_")
        anchors.add(kept.replace(" ", "-"))
    return anchors


def _runbook_links() -> list[tuple[Path, str]]:
    """Return every relative link of every runbook page as (page, target)."""
    if not RUNBOOKS.is_dir():
        return []
    return [
        (page, target)
        for page in sorted(RUNBOOKS.rglob("*.md"))
        for target in _LINK_TARGET.findall(page.read_text(encoding="utf-8"))
        if not target.startswith(("https://", "http://"))
    ]


def test_every_runbook_links_back_to_the_index() -> None:
    pages = {page for page, target in _runbook_links() if target == "../README.md"}
    assert {page.parent.name for page in pages} == {alert.value for alert in AlertClass}


@pytest.mark.parametrize(
    ("page", "target"),
    _runbook_links(),
    ids=[f"{page.parent.name}:{target}" for page, target in _runbook_links()],
)
def test_every_relative_link_of_a_runbook_leads_somewhere(page: Path, target: str) -> None:
    # A person follows these links during an incident; a dead one costs minutes. The file
    # must exist, and a `#fragment` must be a heading of that file.
    path, _, fragment = target.partition("#")
    linked = (page.parent / path).resolve() if path else page
    assert linked.is_file(), f"{page.parent.name}: {target} leads to no file"
    if fragment:
        assert fragment in _anchors(
            linked.read_text(encoding="utf-8")
        ), f"{page.parent.name}: {linked.name} has no heading for #{fragment}"
