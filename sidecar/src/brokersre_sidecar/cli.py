"""Command line of the sidecar (``brokersre-sidecar``).

==================  ==========================================================
command             what it does / exit code
==================  ==========================================================
run (default)       run the sidecar until SIGTERM or SIGINT (0; 2: bad config)
status              print ``/status`` of the local sidecar (0 only when ready;
                    1 not ready; 3 not reachable)
healthcheck         0 when ``/livez`` answers 200 (the image's HEALTHCHECK)
check-config        validate the configuration without starting (0; 2 invalid)
notify test         send a test message to every configured channel
                    (0; 1 a channel failed; 2 none configured or bad config)
print-schema NAME   print a JSON Schema (``status``)
support-bundle      write a redacted tar.gz of recent state to ``--out DIR``
==================  ==========================================================

Heavy modules (pydantic, httpx, ib_async) are imported inside the commands that need them,
so ``healthcheck``, which Docker runs every few seconds, starts on the standard library
alone. Nothing here prints a configured value: problems name the variable only.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import http.client
import json
import logging
import os
import signal
import sys
import threading
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import TYPE_CHECKING, NoReturn, TextIO

from brokersre_sidecar import __version__

if TYPE_CHECKING:
    from brokersre_sidecar.config import ChannelSecrets, Settings
    from brokersre_sidecar.redaction import SecretRegistry

EXIT_OK = 0
EXIT_NOT_READY = 1
EXIT_USAGE = 2
EXIT_UNREACHABLE = 3

_DEFAULT_PORT = 9810
_CLIENT_TIMEOUT_S = 5.0
_WILDCARD_BINDS = frozenset({"", "0.0.0.0", "::"})  # noqa: S104 - compared, not bound
_HTTP_OK = 200


class _Unreachable(Exception):
    """The local sidecar endpoint could not be reached or answered unusably."""


class _UsageError(Exception):
    """The command line is invalid; the message has already been written."""


class _Parser(argparse.ArgumentParser):
    """An argument parser that writes to the streams given to ``main`` and never exits."""

    stream: TextIO = sys.stderr

    def _print_message(self, message: str, file: object = None) -> None:
        """Write usage and error text to the injected stream."""
        if message:
            self.stream.write(message)

    def exit(self, status: int = 0, message: str | None = None) -> NoReturn:
        """Raise instead of exiting, so ``main`` returns the exit code."""
        if message:
            self.stream.write(message)
        raise _UsageError


def _build_parser(err: TextIO) -> _Parser:
    """Create the parser with every sub-command."""
    _Parser.stream = err
    parser = _Parser(
        prog="brokersre-sidecar",
        description="Read-only probe, status API, metrics and notifier for the IB Gateway image.",
    )
    parser.add_argument("--version", action="store_true", help="print the version and exit")
    commands = parser.add_subparsers(dest="command", parser_class=_Parser)
    commands.add_parser("run", help="run the sidecar (default)")
    commands.add_parser("status", help="print /status; exit 0 only when ready")
    commands.add_parser("healthcheck", help="exit 0 when /livez answers 200")
    commands.add_parser("check-config", help="validate the configuration without starting")
    notify = commands.add_parser("notify", help="notifier commands")
    notify_commands = notify.add_subparsers(dest="notify_command", required=True)
    notify_commands.add_parser("test", help="send a test message to every configured channel")
    schema = commands.add_parser("print-schema", help="print a JSON Schema")
    schema.add_argument("name", choices=["status"])
    bundle = commands.add_parser("support-bundle", help="write a redacted support bundle")
    bundle.add_argument("--out", required=True, help="existing directory for the archive")
    bundle.add_argument("--lines", type=int, default=500, help="lines per feed (default 500)")
    bundle.add_argument(
        "--redact-file",
        action="append",
        default=[],
        metavar="PATH",
        help="file whose content is scrubbed from the bundle (for example the username secret)",
    )
    return parser


def _endpoint(env: Mapping[str, str]) -> tuple[str, int]:
    """Return the address a local client uses to reach the sidecar's endpoints.

    Raises:
        ValueError: ``SIDECAR_PORT`` is not a number.
    """
    bind = env.get("SIDECAR_BIND", "").strip()
    host = "127.0.0.1" if bind in _WILDCARD_BINDS else bind
    port_text = env.get("SIDECAR_PORT", "").strip()
    return host, int(port_text) if port_text else _DEFAULT_PORT


def _get(env: Mapping[str, str], path: str) -> tuple[int, bytes]:
    """GET ``path`` from the local sidecar.

    Raises:
        _Unreachable: No answer (not running, wrong port, timeout) or an invalid port.
    """
    try:
        host, port = _endpoint(env)
        connection = http.client.HTTPConnection(host, port, timeout=_CLIENT_TIMEOUT_S)
        try:
            connection.request("GET", path)
            response = connection.getresponse()
            return response.status, response.read()
        finally:
            connection.close()
    except (OSError, http.client.HTTPException, ValueError) as error:
        raise _Unreachable(type(error).__name__) from None


def _load(
    env: Mapping[str, str],
) -> tuple[Settings, ChannelSecrets, SecretRegistry]:
    """Load settings and secrets.

    Raises:
        ConfigError: Invalid variables or unusable secret files.
    """
    from brokersre_sidecar.config import load_secrets, load_settings
    from brokersre_sidecar.redaction import SecretRegistry

    settings = load_settings(env)
    registry = SecretRegistry()
    return settings, load_secrets(settings, registry), registry


def _check_config(env: Mapping[str, str], out: TextIO, err: TextIO) -> int:
    """Validate the configuration and print a summary without any secret."""
    from brokersre_sidecar.config import ConfigError
    from brokersre_sidecar.fsutil import is_dir_writable

    try:
        settings, _secrets, _registry = _load(env)
    except ConfigError as error:
        for problem in error.problems:
            err.write(f"{problem}\n")
        return EXIT_USAGE
    out.write("configuration ok\n")
    out.write(f"instance: {settings.instance} ({settings.trading_mode})\n")
    if settings.shared_namespace():
        orphan = (
            "exits with 75 when orphaned"
            if settings.exit_when_orphaned
            else "EXIT_WHEN_ORPHANED=no"
        )
        out.write(f"network mode: shared with the gateway ({orphan})\n")
    else:
        out.write("network mode: own network namespace\n")
    if settings.probe_enabled:
        out.write(
            f"probe: enabled, {settings.gateway_endpoint()}, client id "
            f"{settings.health_client_id}, every {settings.probe_interval_s:g} s\n"
        )
    else:
        out.write("probe: disabled (PROBE_ENABLED=no)\n")
    if settings.ibkr_region == "none":
        out.write("reset windows: none (IBKR_REGION=none; API alerts are never held back)\n")
    else:
        out.write(f"reset windows: {settings.ibkr_region} (IBKR_REGION)\n")
    out.write(f"endpoints: {settings.bind}:{settings.port}\n")
    channels = settings.configured_channels()
    if channels:
        out.write(
            f"notifier: {', '.join(settings.primary_channels())}; escalation: "
            f"{', '.join(settings.escalation_channels())}\n"
        )
        writable = is_dir_writable(settings.state_dir)
        note = "writable" if writable else "not writable: state will be kept in memory"
        out.write(f"state directory: {settings.state_dir} ({note})\n")
    else:
        out.write("notifier: disabled (no channel configured)\n")
    present = "present" if settings.log_dir.is_dir() else "missing"
    out.write(f"gateway log volume: {settings.log_dir} ({present})\n")
    return EXIT_OK


def _status(env: Mapping[str, str], out: TextIO, err: TextIO) -> int:
    """Print the local sidecar's status document; 0 only when its status is ``ready``."""
    try:
        code, body = _get(env, "/status")
        if code != _HTTP_OK:
            raise _Unreachable(f"HTTP {code}")
        document = json.loads(body)
        if not isinstance(document, dict):
            raise _Unreachable("unexpected answer")
    except (_Unreachable, ValueError) as error:
        err.write(f"the sidecar is not reachable on its local endpoint ({error})\n")
        return EXIT_UNREACHABLE
    out.write(body.decode("utf-8", errors="replace").rstrip("\n") + "\n")
    return EXIT_OK if document.get("status") == "ready" else EXIT_NOT_READY


def _healthcheck(env: Mapping[str, str]) -> int:
    """Return 0 when ``/livez`` answers 200, otherwise 1 (standard library only)."""
    try:
        code, _body = _get(env, "/livez")
    except _Unreachable:
        return EXIT_NOT_READY
    return EXIT_OK if code == _HTTP_OK else EXIT_NOT_READY


async def _send_tests(
    settings: Settings, secrets: ChannelSecrets, registry: SecretRegistry
) -> list[tuple[str, str | None]]:
    """Send one test message to every configured channel; return ``(name, error)`` pairs."""
    import httpx

    from brokersre_sidecar.clock import SystemClock
    from brokersre_sidecar.notify import Dispatcher, HttpTransport, MessageFactory, build_channels
    from brokersre_sidecar.tail import read_phase

    clock = SystemClock()
    transport = HttpTransport(httpx.AsyncClient(follow_redirects=False))
    try:
        dispatcher = Dispatcher(build_channels(settings, secrets, transport), clock, asyncio.sleep)
        phase = read_phase(settings.log_dir / "state" / "phase")
        message = MessageFactory(
            settings.instance, settings.time_zone, settings.runbook_base, registry
        ).build_test(
            phase=phase.token if phase is not None else None,
            api_status="not_measured",
            now=clock.now(),
        )
        return [
            (name, await dispatcher.send_now(name, message)) for name in dispatcher.channel_names()
        ]
    finally:
        await transport.aclose()


def _notify_test(env: Mapping[str, str], out: TextIO, err: TextIO) -> int:
    """Send a test message to every configured channel and report each result."""
    from brokersre_sidecar.config import ConfigError

    try:
        settings, secrets, registry = _load(env)
    except ConfigError as error:
        for problem in error.problems:
            err.write(f"{problem}\n")
        return EXIT_USAGE
    if not settings.configured_channels():
        err.write(
            "no notification channel is configured: set at least one NOTIFY_*_FILE variable\n"
        )
        return EXIT_USAGE
    results = asyncio.run(_send_tests(settings, secrets, registry))
    for name, error_category in results:
        out.write(
            f"{name}: ok\n" if error_category is None else f"{name}: FAILED ({error_category})\n"
        )
    return EXIT_NOT_READY if any(error for _, error in results) else EXIT_OK


def _support_bundle(
    env: Mapping[str, str],
    out_dir: Path,
    lines: int,
    redact_files: Sequence[str],
    out: TextIO,
    err: TextIO,
) -> int:
    """Write the redacted support bundle into ``out_dir`` and print its path.

    ``redact_files`` name files whose content must not appear in the bundle (typically the
    IBKR username secret): pattern-based redaction cannot know a username in free text.
    """
    from brokersre_sidecar.clock import SystemClock
    from brokersre_sidecar.config import (
        ConfigError,
        SecretFileError,
        load_secrets,
        load_settings,
        read_secret_file,
    )
    from brokersre_sidecar.redaction import SecretRegistry
    from brokersre_sidecar.support import create_bundle

    if not out_dir.is_dir():
        err.write("--out: not an existing directory\n")
        return EXIT_USAGE
    try:
        settings = load_settings(env)
    except ConfigError as error:
        for problem in error.problems:
            err.write(f"{problem}\n")
        return EXIT_USAGE
    registry = SecretRegistry()
    for name in redact_files:
        try:
            registry.add(read_secret_file(Path(name), "--redact-file"))
        except SecretFileError as error:
            err.write(f"{error}\n")
            return EXIT_USAGE
    # Best effort: the secrets are loaded only so they can be scrubbed from the bundle; a
    # shell that cannot read the secret files still gets a (pattern-redacted) bundle.
    with contextlib.suppress(ConfigError):
        load_secrets(settings, registry)
    status_json: str | None
    try:
        code, body = _get(env, "/status")
        status_json = body.decode("utf-8", errors="replace") if code == _HTTP_OK else None
    except _Unreachable:
        status_json = None
    try:
        path = create_bundle(
            out_dir,
            settings=settings,
            registry=registry,
            status_json=status_json,
            now=SystemClock().now(),
            max_lines=max(1, lines),
        )
    except OSError as error:
        err.write(f"--out: the bundle could not be written ({type(error).__name__})\n")
        return EXIT_USAGE
    out.write(f"{path}\n")
    return EXIT_OK


def _install_signal_handlers(loop: asyncio.AbstractEventLoop, stop: asyncio.Event) -> None:
    """Make SIGTERM and SIGINT set ``stop`` (no-op outside the main thread)."""
    if threading.current_thread() is not threading.main_thread():
        return
    for signum in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(signum, stop.set)
        except NotImplementedError:
            # Windows event loops have no add_signal_handler; used for local runs only.
            signal.signal(signum, lambda *_: loop.call_soon_threadsafe(stop.set))


async def _serve(
    settings: Settings,
    secrets: ChannelSecrets,
    registry: SecretRegistry,
    external_stop: threading.Event | None,
) -> int:
    """Run the application until a signal (or ``external_stop``) asks it to stop."""
    from brokersre_sidecar.app import Application

    stop = asyncio.Event()
    _install_signal_handlers(asyncio.get_running_loop(), stop)
    watcher: asyncio.Task[None] | None = None
    if external_stop is not None:

        async def watch() -> None:
            """Turn the thread-level stop request into the asyncio stop event."""
            await asyncio.to_thread(external_stop.wait)
            stop.set()

        watcher = asyncio.ensure_future(watch())
    application = Application(settings, secrets, registry)
    try:
        await application.run(stop)
    finally:
        if watcher is not None:
            watcher.cancel()
            await asyncio.gather(watcher, return_exceptions=True)
    if application.exit_code != EXIT_OK:
        return application.exit_code
    return EXIT_OK if stop.is_set() else EXIT_NOT_READY


def _run(env: Mapping[str, str], out: TextIO, external_stop: threading.Event | None) -> int:
    """Validate the configuration, set up JSON logging on ``out`` and run the sidecar."""
    from brokersre_sidecar.config import ConfigError
    from brokersre_sidecar.logsetup import configure_logging, log_event
    from brokersre_sidecar.redaction import SecretRegistry

    try:
        settings, secrets, registry = _load(env)
    except ConfigError as error:
        configure_logging("info", SecretRegistry(), out)
        for problem in error.problems:
            log_event(logging.getLogger(__name__), logging.ERROR, "config_invalid", problem)
        return EXIT_USAGE
    configure_logging(settings.log_level, registry, out)
    return asyncio.run(_serve(settings, secrets, registry, external_stop))


def main(
    argv: Sequence[str] | None = None,
    *,
    env: Mapping[str, str] | None = None,
    out: TextIO | None = None,
    err: TextIO | None = None,
    stop: threading.Event | None = None,
) -> int:
    """Entry point of ``brokersre-sidecar``.

    Args:
        argv: Arguments without the program name (``sys.argv[1:]`` by default).
        env: Environment (``os.environ`` by default).
        out: Standard output stream (logs of ``run``, results of the other commands).
        err: Standard error stream (problems and usage).
        stop: Test hook: ``run`` stops when this event is set.

    Returns:
        The process exit code (see the module docstring).
    """
    environment = os.environ if env is None else env
    stdout = sys.stdout if out is None else out
    stderr = sys.stderr if err is None else err
    try:
        arguments = _build_parser(stderr).parse_args(sys.argv[1:] if argv is None else argv)
    except _UsageError:
        return EXIT_USAGE
    if arguments.version:
        stdout.write(f"brokersre-sidecar {__version__}\n")
        return EXIT_OK
    command = arguments.command or "run"
    if command == "run":
        return _run(environment, stdout, stop)
    if command == "status":
        return _status(environment, stdout, stderr)
    if command == "healthcheck":
        return _healthcheck(environment)
    if command == "check-config":
        return _check_config(environment, stdout, stderr)
    if command == "notify":
        return _notify_test(environment, stdout, stderr)
    if command == "print-schema":
        from brokersre_sidecar.model import status_json_schema

        stdout.write(json.dumps(status_json_schema(), indent=2, sort_keys=True) + "\n")
        return EXIT_OK
    return _support_bundle(
        environment,
        Path(arguments.out),
        arguments.lines,
        arguments.redact_file,
        stdout,
        stderr,
    )
