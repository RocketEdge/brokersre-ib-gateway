"""Support bundle: a small tar.gz an operator can attach to an issue.

It collects the last lines of the gateway's event and metrics feeds, the phase, the
sidecar's status document, versions and non-secret settings. Because the bundle is meant to
be shared, everything in it is reduced or redacted:

* event lines keep only their contract fields; the message passes ``redact_log_line``;
  unknown keys and lines that are not JSON objects are dropped;
* metrics lines keep only known numeric keys;
* of the raw IBC log only lines carrying the ``IBC:`` marker are included, each redacted
  (dialog dumps, which echo typed text, never carry that marker); the gateway's own
  ``jts`` logs are not included at all;
* account ids keep their last three characters; loaded secrets are scrubbed;
* no secret-file path or content and no host user name is recorded.
"""

from __future__ import annotations

import io
import json
import os
import platform
import tarfile
from datetime import datetime
from importlib import metadata
from pathlib import Path

from brokersre_sidecar import __version__
from brokersre_sidecar.clock import format_utc
from brokersre_sidecar.config.settings import Settings
from brokersre_sidecar.model.events import parse_event, parse_metrics
from brokersre_sidecar.redaction import SecretRegistry, redact_log_line, redact_text
from brokersre_sidecar.tail.phase import read_phase

DEFAULT_MAX_LINES = 500
_TAIL_BYTES = 2 * 1024 * 1024
_IBC_MARKER = "IBC:"

_MANIFEST = """brokersre-ib-gateway-sidecar support bundle
generated: {generated}
instance:  {instance}

Files
  phase.txt         the gateway's phase token (or unknown / not_measured)
  events.jsonl      last {max_lines} event lines: contract fields only, message redacted
  metrics.jsonl     last {max_lines} metrics samples: known numeric keys only
  ibc-redacted.txt  last {max_lines} "IBC:" lines of the raw IBC log, redacted
  status.json       the sidecar's /status document at the time of the bundle
  versions.json     sidecar, Python and ib_async versions
  settings.json     non-secret settings (no secret file path, no credential)

Redaction
  Account ids are shortened to *** plus their last three characters. Values after
  identity keys (user, username, login id, account, password) and e-mail addresses are
  replaced by [REDACTED]. Loaded secrets are replaced by [REDACTED]. Lines of the raw IBC
  log without the "IBC:" marker (dialog dumps) and the gateway's own jts logs are left out.

Review the files before you share the bundle: redaction is pattern based and cannot know
every identifier.
"""


def _tail_lines(path: Path) -> list[str]:
    """Return the complete lines in the last 2 MiB of ``path`` (empty when unreadable).

    Callers filter these lines first and then keep the last ``max_lines`` that qualify, so
    a run of unusable lines at the end does not shrink the bundle.
    """
    try:
        with open(path, "rb") as handle:
            size = os.fstat(handle.fileno()).st_size
            start = max(0, size - _TAIL_BYTES)
            handle.seek(start)
            data = handle.read(_TAIL_BYTES)
    except OSError:
        return []
    lines = data.decode("utf-8", errors="replace").splitlines()
    if start > 0 and lines:
        lines = lines[1:]  # the first line is probably cut
    return lines


def _events(path: Path, max_lines: int, registry: SecretRegistry) -> str:
    """Render the last event lines with contract fields only and a redacted message."""
    rendered: list[str] = []
    for line in _tail_lines(path):
        event = parse_event(line)
        if event is None:
            continue
        try:
            message = json.loads(line).get("msg")
        except ValueError, AttributeError:
            message = None
        rendered.append(
            json.dumps(
                {
                    "ts": format_utc(event.ts),
                    "src": event.src,
                    "level": event.level,
                    "event": event.event,
                    "msg": redact_log_line(message, registry) if isinstance(message, str) else "",
                    "boot_id": event.boot_id,
                    "seq": event.seq,
                }
            )
        )
    return "".join(f"{line}\n" for line in rendered[-max_lines:])


def _metrics(path: Path, max_lines: int) -> str:
    """Render the last metrics samples with known numeric keys only."""
    rendered: list[str] = []
    for line in _tail_lines(path):
        sample = parse_metrics(line)
        if sample is None:
            continue
        rendered.append(
            json.dumps(
                {
                    "ts": format_utc(sample.ts),
                    "boot_id": sample.boot_id,
                    "seq": sample.seq,
                    "phase": sample.phase,
                    **sample.values,
                }
            )
        )
    return "".join(f"{line}\n" for line in rendered[-max_lines:])


def _ibc(path: Path, max_lines: int, registry: SecretRegistry) -> str:
    """Render the last ``IBC:`` lines of the raw IBC log, each redacted."""
    lines = [line for line in _tail_lines(path) if _IBC_MARKER in line]
    return "".join(f"{redact_log_line(line, registry)}\n" for line in lines[-max_lines:])


def _settings(settings: Settings) -> str:
    """Render the non-secret settings."""
    heartbeat = settings.heartbeat_time
    return (
        json.dumps(
            {
                "instance": settings.instance,
                "trading_mode": settings.trading_mode,
                "api_port": settings.api_port,
                "time_zone": settings.time_zone,
                "probe_enabled": settings.probe_enabled,
                "health_client_id": settings.health_client_id,
                "probe_interval_s": settings.probe_interval_s,
                "probe_timeout_s": settings.probe_timeout_s,
                "bind": settings.bind,
                "port": settings.port,
                "escalate_after_s": settings.escalate_after_s,
                "escalate_again_after_s": settings.escalate_again_after_s,
                "heartbeat_time": heartbeat.strftime("%H:%M") if heartbeat else None,
                "runbook_base_set": settings.runbook_base is not None,
                "allow_http": settings.allow_http,
                "configured_channels": list(settings.configured_channels()),
                "primary_channels": list(settings.primary_channels()),
                "escalation_channels": list(settings.escalation_channels()),
                "disabled_classes": sorted(settings.disabled_classes),
            },
            indent=2,
        )
        + "\n"
    )


def _versions() -> str:
    """Render the versions of the sidecar and its runtime."""
    try:
        ib_async = metadata.version("ib_async")
    except metadata.PackageNotFoundError:
        ib_async = "not installed"
    return (
        json.dumps(
            {
                "sidecar": __version__,
                "python": platform.python_version(),
                "ib_async": ib_async,
                "system": platform.system(),
                "machine": platform.machine(),
            },
            indent=2,
        )
        + "\n"
    )


def create_bundle(
    out_dir: Path,
    *,
    settings: Settings,
    registry: SecretRegistry,
    status_json: str | None,
    now: datetime,
    max_lines: int = DEFAULT_MAX_LINES,
) -> Path:
    """Write the support bundle and return its path.

    Args:
        out_dir: Existing, writable directory for the archive.
        settings: Supplies the log directory and the non-secret settings.
        registry: Secrets loaded by this process, scrubbed from every file.
        status_json: Body of ``/status`` from the running sidecar, or None when it could
            not be fetched.
        now: Bundle time (UTC); used in the file name and as the member timestamp.
        max_lines: Upper bound of event, metrics and IBC lines.

    Returns:
        ``<out_dir>/brokersre-sidecar-support-<instance>-<UTC time>.tar.gz``.

    Raises:
        OSError: ``out_dir`` is missing or not writable.
    """
    log_dir = settings.log_dir
    phase = read_phase(log_dir / "state" / "phase")
    if status_json is not None:
        status = redact_text(status_json, registry).rstrip("\n") + "\n"
    else:
        status = (
            json.dumps({"note": "status not available: the sidecar endpoint was not reachable"})
            + "\n"
        )
    files = {
        "MANIFEST.txt": _MANIFEST.format(
            generated=format_utc(now), instance=settings.instance, max_lines=max_lines
        ),
        "phase.txt": f"{phase.token if phase is not None else 'not_measured'}\n",
        "events.jsonl": _events(log_dir / "events" / "events.jsonl", max_lines, registry),
        "metrics.jsonl": _metrics(log_dir / "metrics" / "metrics.jsonl", max_lines),
        "ibc-redacted.txt": _ibc(log_dir / "ibc" / "ibc.log", max_lines, registry),
        "status.json": status,
        "versions.json": _versions(),
        "settings.json": _settings(settings),
    }
    name = f"brokersre-sidecar-support-{settings.instance}-{now.strftime('%Y%m%dT%H%M%SZ')}.tar.gz"
    target = out_dir / name
    temporary = out_dir / f".{name}.tmp-{os.getpid()}"
    mtime = int(now.timestamp())
    try:
        with tarfile.open(temporary, "w:gz") as archive:
            for member_name, content in files.items():
                data = content.encode("utf-8")
                info = tarfile.TarInfo(member_name)
                info.size = len(data)
                info.mtime = mtime
                info.mode = 0o644
                # Numeric zero ids and empty names: the archive records no host identity.
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                archive.addfile(info, io.BytesIO(data))
        os.replace(temporary, target)
    finally:
        if temporary.exists():
            temporary.unlink()
    return target
