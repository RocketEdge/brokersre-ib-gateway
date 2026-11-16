"""The documents keep up with the code: every variable, class, channel and metric is described."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
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
from brokersre_sidecar.notify.message import MessageFactory
from brokersre_sidecar.redaction import SecretRegistry
from brokersre_sidecar.vocab import AlertClass, ChannelName, MessageKind, ProbeStatus
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
    shared = (REPOSITORY_ROOT / "compose/docker-compose.sidecar-shared.yml").read_text(
        encoding="utf-8"
    )
    assert 'network_mode: "service:ib-gateway"' in shared
    assert "GATEWAY_HOST: 127.0.0.1" in shared


LOG_VOLUME_MOUNT = (
    "- type: volume\n"
    "source: ibgw-logs\n"
    "target: /var/log/ibgateway\n"
    "read_only: true\n"
    "volume:\n"
    "nocopy: true\n"
)
"""How every container other than the gateway mounts the gateway's log volume (lines without
their indentation): read-only, and without the copy-up that would hand an EMPTY volume the
owner of that container image's mount point. compose creates such a container after the
gateway; sidecar/tests/e2e/fresh-volumes.sh starts the sidecar files for real."""

COMPOSE_CONFIGURATIONS: tuple[tuple[tuple[str, ...], tuple[str, ...], int], ...] = (
    (("compose/docker-compose.example.yml", "compose/docker-compose.sidecar.yml"), (), 1),
    (("compose/docker-compose.example.yml", "compose/docker-compose.sidecar-shared.yml"), (), 1),
    (("compose/docker-compose.example.yml", "compose/docker-compose.azure.yml"), ("azure",), 2),
    (
        ("compose/docker-compose.example.yml", "compose/docker-compose.azure.yml"),
        ("azure-cert",),
        2,
    ),
    (("compose/docker-compose.example.yml", "compose/docker-compose.console.yml"), (), 0),
    (("compose/docker-compose.multi.yml",), (), 0),
    (("docs/recipes/docker-compose.vector.yml",), (), 1),
    (("examples/compose-with-client.yml",), (), 0),
    (("windows/templates/compose.yaml.tmpl",), (), 0),
)
"""Every shipped compose file, in the combinations users start: the files, the profiles, and
how many mounts of a gateway log volume by another container the resolved configuration has.
The count keeps the check from passing on a configuration where nothing was found."""


GATEWAY_IMAGE_PLACEHOLDERS = frozenset({"__IMAGE_REF__"})
"""Image placeholders that stand for the gateway image (the Windows kit fills in its digest)."""


def _is_gateway(service: dict[str, object]) -> bool:
    """Return whether a resolved compose service runs the gateway image (not the sidecar)."""
    image = str(service.get("image", ""))
    if image in GATEWAY_IMAGE_PLACEHOLDERS:
        return True
    return "brokersre-ib-gateway" in image and "brokersre-ib-gateway-sidecar" not in image


def _without_comments(text: str) -> str:
    """Return ``text`` without comments, blank lines and indentation, one line per line.

    Args:
        text: A YAML file (or a Markdown file with YAML examples).

    Returns:
        The remaining lines, each stripped of its indentation and of a trailing ``# ...``
        comment, joined with newlines and ending in one. Indentation is dropped so that the
        same mount is recognised at any nesting depth.
    """
    lines = (re.sub(r"\s+#.*$", "", line).strip() for line in text.splitlines())
    return "\n".join(line for line in lines if line and not line.startswith("#")) + "\n"


def _resolved_compose(files: tuple[str, ...], profiles: tuple[str, ...]) -> dict[str, object]:
    """Return ``docker compose config`` of the files as JSON, without interpolation.

    Compose itself turns the short and the long volume syntax, key order and a trailing slash
    into one form, so the check below sees what Docker will mount, not how a file spells it.
    Without interpolation no variable needs a value.
    """
    docker = shutil.which("docker")
    assert docker is not None
    command = [docker, "compose", "-p", "log-volume-policy"]
    for name in files:
        command += ["-f", str(REPOSITORY_ROOT / name)]
    for profile in profiles:
        command += ["--profile", profile]
    command += ["config", "--no-interpolate", "--format", "json"]
    # The command is built from constants and the repository's own file names.
    done = subprocess.run(  # noqa: S603
        command, capture_output=True, text=True, check=False, timeout=120
    )
    assert done.returncode == 0, f"{files}: {done.stderr[-500:]}"
    resolved: dict[str, object] = json.loads(done.stdout)
    return resolved


def _log_volume_readers(resolved: dict[str, object]) -> list[tuple[str, dict[str, object]]]:
    """Return every (service, mount) by which a container other than a gateway mounts a log volume.

    A log volume is a named volume that a gateway service mounts at ``/var/log/ibgateway``; a
    mount of any volume at that path by another service counts too (the Vector recipe names an
    external volume and has no gateway service).
    """
    services = resolved["services"]
    assert isinstance(services, dict)
    log_sources = {
        mount.get("source")
        for service in services.values()
        if _is_gateway(service)
        for mount in service.get("volumes", [])
        if mount.get("type") == "volume"
        and str(mount.get("target", "")).rstrip("/") == "/var/log/ibgateway"
    }
    readers = []
    for name, service in services.items():
        if _is_gateway(service):
            continue
        for mount in service.get("volumes", []):
            if mount.get("type") != "volume":
                continue
            target = str(mount.get("target", "")).rstrip("/")
            if target == "/var/log/ibgateway" or mount.get("source") in log_sources:
                readers.append((name, mount))
    return readers


def _docker_compose_available() -> bool:
    """Return whether ``docker compose`` can be run here."""
    docker = shutil.which("docker")
    if docker is None:
        return False
    done = subprocess.run(  # noqa: S603
        [docker, "compose", "version"], capture_output=True, check=False, timeout=60
    )
    return done.returncode == 0


@pytest.mark.parametrize(
    ("files", "profiles", "expected"),
    COMPOSE_CONFIGURATIONS,
    ids=[
        " + ".join(files) + "".join(f" --profile {p}" for p in profiles)
        for files, profiles, _ in COMPOSE_CONFIGURATIONS
    ],
)
def test_every_container_but_the_gateway_mounts_the_log_volume_read_only_and_without_copy_up(
    files: tuple[str, ...], profiles: tuple[str, ...], expected: int
) -> None:
    if not _docker_compose_available():
        # CI has Docker: there the check must run, never skip.
        assert not os.environ.get("CI"), "docker compose is needed for this check in CI"
        pytest.skip("docker compose is not available")
    readers = _log_volume_readers(_resolved_compose(files, profiles))
    assert len(readers) == expected, readers
    for service, mount in readers:
        assert mount.get("read_only") is True, f"{service}: {mount}"
        volume_options = mount.get("volume")
        assert isinstance(volume_options, dict), f"{service}: {mount}"
        assert volume_options.get("nocopy") is True, f"{service}: {mount}"


SIDECAR_STOP_GRACE_S = 20.0
"""Least time a shipped compose file gives the sidecar to stop. Stopping takes up to 13 s:
the flush of the outboxes (3 s), a state write the stop interrupted (up to 5 s) and the
final save after the flush (up to 5 s). Docker's default of 10 s would kill the final save,
and after a hard kill the next start treats what was in flight as possibly received."""


def _sidecar_services(resolved: dict[str, object]) -> list[tuple[str, dict[str, object]]]:
    """Return every (name, service) of a resolved configuration that runs the sidecar image."""
    services = resolved["services"]
    assert isinstance(services, dict)
    return [
        (name, service)
        for name, service in services.items()
        if "brokersre-ib-gateway-sidecar" in str(service.get("image", ""))
    ]


def _duration_s(text: str) -> float:
    """Return a Go duration as compose prints it (``20s``, ``1m30s``, ``500ms``) in seconds."""
    units = {"h": 3600.0, "m": 60.0, "s": 1.0, "ms": 0.001, "us": 1e-6, "ns": 1e-9}
    parts = re.findall(r"([0-9]+(?:\.[0-9]+)?)(ms|us|ns|h|m|s)", text)
    assert parts, text
    assert "".join(f"{n}{u}" for n, u in parts) == text, text
    return sum(float(number) * units[unit] for number, unit in parts)


@pytest.mark.parametrize(
    ("files", "profiles"),
    [(files, profiles) for files, profiles, _ in COMPOSE_CONFIGURATIONS],
    ids=[
        " + ".join(files) + "".join(f" --profile {p}" for p in profiles)
        for files, profiles, _ in COMPOSE_CONFIGURATIONS
    ],
)
def test_every_sidecar_service_has_time_to_save_its_state_when_it_stops(
    files: tuple[str, ...], profiles: tuple[str, ...]
) -> None:
    if not _docker_compose_available():
        assert not os.environ.get("CI"), "docker compose is needed for this check in CI"
        pytest.skip("docker compose is not available")
    sidecars = _sidecar_services(_resolved_compose(files, profiles))
    if any("sidecar" in name for name in files):
        assert sidecars, f"{files}: no sidecar service found"
    for name, service in sidecars:
        grace = service.get("stop_grace_period")
        assert isinstance(grace, str), f"{name}: no stop_grace_period"
        assert _duration_s(grace) >= SIDECAR_STOP_GRACE_S, f"{name}: {grace}"


def test_the_readme_example_gives_the_sidecar_time_to_stop() -> None:
    assert "stop_grace_period: 20s" in _without_comments(README)


def test_every_shipped_compose_file_is_in_a_checked_configuration() -> None:
    checked = {name for files, _, _ in COMPOSE_CONFIGURATIONS for name in files}
    shipped = {
        path.relative_to(REPOSITORY_ROOT).as_posix()
        for pattern in (
            "compose/*.yml",
            "compose/*.yaml",
            "docs/recipes/*.yml",
            "examples/*.yml",
            "examples/*.yaml",
            "windows/templates/*.tmpl",
        )
        for path in REPOSITORY_ROOT.glob(pattern)
        if "services:" in path.read_text(encoding="utf-8")
    }
    assert shipped == checked, sorted(shipped ^ checked)


def test_the_readme_example_mounts_the_log_volume_the_same_way_and_says_why() -> None:
    assert LOG_VOLUME_MOUNT in _without_comments(README)
    assert "Keep `nocopy` when you write your own compose file." in README


def test_the_package_version_is_the_version_the_publish_workflow_tags() -> None:
    # sidecar-publish.yml tags the image with the version in pyproject.toml; the CLI, the
    # metrics and the compose tags use __version__.
    import tomllib

    from brokersre_sidecar import __version__

    project = tomllib.loads((SIDECAR_ROOT / "pyproject.toml").read_text(encoding="utf-8"))
    assert project["project"]["version"] == __version__


def test_the_compose_files_and_the_readme_name_the_version_of_the_package() -> None:
    from brokersre_sidecar import __version__

    tag = f"ghcr.io/rocketedge/brokersre-ib-gateway-sidecar:{__version__}"
    for name in (
        "compose/docker-compose.sidecar.yml",
        "compose/docker-compose.sidecar-shared.yml",
        "sidecar/README.md",
    ):
        text = (REPOSITORY_ROOT / name).read_text(encoding="utf-8")
        tags = set(
            re.findall(r"ghcr\.io/rocketedge/brokersre-ib-gateway-sidecar:[0-9][^\s\"']*", text)
        )
        assert tags == {tag}, f"{name}: {sorted(tags)}"


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


# `docker compose` not followed by `-f <file>` or by the placeholder `...`. The repository has
# no compose file of a default name (`compose.yaml`, `docker-compose.yml`), so such a command
# copied from these documents stops with "no configuration file provided" (seen 2026-11-16
# with the sidecar README's `docker compose run --rm --no-deps sidecar check-config`).
_COMPOSE_WITHOUT_FILES = re.compile(r"docker compose(?!\s+(?:-f\s|\.\.\.))")
_COMPOSE_PLACEHOLDER = "`docker compose ...` stands for your compose command with its files"


def _compose_documents() -> list[Path]:
    """Return the sidecar README and every runbook page: the documents a person copies from."""
    runbooks = sorted(RUNBOOKS.rglob("*.md")) if RUNBOOKS.is_dir() else []
    return [SIDECAR_ROOT / "README.md", *runbooks]


@pytest.mark.parametrize(
    "document",
    _compose_documents(),
    ids=[path.relative_to(REPOSITORY_ROOT).as_posix() for path in _compose_documents()],
)
def test_every_compose_command_names_its_files_or_the_placeholder(document: Path) -> None:
    text = document.read_text(encoding="utf-8")
    bare = [
        f"line {number}: {line.strip()}"
        for number, line in enumerate(text.splitlines(), start=1)
        if _COMPOSE_WITHOUT_FILES.search(line)
    ]
    assert bare == [], f"{document.name}: compose commands without their files: {bare}"


def test_every_document_that_uses_the_compose_placeholder_says_what_it_stands_for() -> None:
    # The runbook pages share the index's definition; the README is read on its own. Blanks
    # and line breaks are folded, so a rewrapped paragraph still counts.
    index = " ".join((RUNBOOKS / "README.md").read_text(encoding="utf-8").split())
    readme = " ".join(README.split())
    assert _COMPOSE_PLACEHOLDER in index
    assert "docker compose ..." in readme
    assert _COMPOSE_PLACEHOLDER in readme


def test_the_readme_and_the_compose_file_name_the_runbook_base_of_this_repository() -> None:
    compose = (REPOSITORY_ROOT / "compose" / "docker-compose.sidecar.yml").read_text(
        encoding="utf-8"
    )
    assert RUNBOOK_BASE in README
    assert RUNBOOK_BASE in compose


def _runbook_links_of_messages() -> list[tuple[str, str | None]]:
    """Return (source, runbook link) of every kind of message the notifier can send.

    Built with the base the documents recommend: one firing message per alert class (every
    kind of a class carries the same link) and the message of `notify test`.
    """
    factory = MessageFactory("desk-1", "Etc/UTC", RUNBOOK_BASE, SecretRegistry())
    links: list[tuple[str, str | None]] = [
        (
            alert.value,
            factory.build(
                MessageKind.FIRING,
                alert,
                detail="",
                escalation_step=0,
                since=None,
                phase=None,
                api_status="not_measured",
                now=T0,
            ).runbook,
        )
        for alert in sorted(AlertClass, key=str)
    ]
    test_message = factory.build_test(phase=None, api_status="not_measured", now=T0)
    links.append(("notify test", test_message.runbook))
    return links


@pytest.mark.parametrize(
    ("source", "link"),
    _runbook_links_of_messages(),
    ids=[source for source, _ in _runbook_links_of_messages()],
)
def test_every_runbook_link_a_message_carries_leads_to_a_page(
    source: str, link: str | None
) -> None:
    # A person taps the link in the notification. `notify test` is the first message most
    # people see, and its link led to docs/runbooks/test, which does not exist (GitHub 404,
    # seen 2026-11-17 with sidecar 0.2.1 and a local ntfy server).
    assert link is not None
    assert link == RUNBOOK_BASE or link.startswith(f"{RUNBOOK_BASE}/"), link
    page = RUNBOOKS / link.removeprefix(RUNBOOK_BASE).strip("/") / "README.md"
    assert page.is_file(), f"{source}: {link} leads to no page"


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
