"""The command line: check-config, print-schema, status, healthcheck, notify test, bundle, run."""

from __future__ import annotations

import io
import json
import logging
import tarfile
import threading
from collections.abc import Iterator
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

import pytest

from brokersre_sidecar.cli import main
from testkit import free_port

SCHEMA_FILE = Path(__file__).resolve().parents[1] / "schemas" / "status.v1.schema.json"


class LocalServer:
    """A stdlib HTTP server on loopback with scripted GET answers and recorded POSTs."""

    def __init__(self) -> None:
        self.get_answers: dict[str, tuple[int, str]] = {}
        self.post_status = 200
        self.posts: list[tuple[str, dict[str, str], bytes]] = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                status, body = owner.get_answers.get(self.path, (404, "not found\n"))
                self._answer(status, body.encode())

            def do_POST(self) -> None:
                length = int(self.headers.get("Content-Length", "0"))
                owner.posts.append((self.path, dict(self.headers.items()), self.rfile.read(length)))
                self._answer(owner.post_status, b"ok")

            def _answer(self, status: int, body: bytes) -> None:
                self.send_response(status)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, format: str, *args: Any) -> None:
                """Keep the test output quiet."""

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self._server.server_address[1]
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()

    def close(self) -> None:
        self._server.shutdown()
        self._server.server_close()
        self._thread.join(5)


@pytest.fixture
def server() -> Iterator[LocalServer]:
    instance = LocalServer()
    yield instance
    instance.close()


@pytest.fixture(autouse=True)
def restore_logging() -> Iterator[None]:
    """``run`` reconfigures the root logger; put it back after each test."""
    root = logging.getLogger()
    handlers, level = list(root.handlers), root.level
    yield
    root.handlers[:] = handlers
    root.setLevel(level)


def run_cli(*argv: str, env: dict[str, str] | None = None) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    code = main(list(argv), env=env or {}, out=out, err=err)
    return code, out.getvalue(), err.getvalue()


def test_check_config_accepts_the_defaults_and_summarises_them() -> None:
    code, out, err = run_cli("check-config")
    assert code == 0
    assert err == ""
    assert "configuration ok" in out
    assert "network mode: own network namespace\n" in out
    assert "probe: enabled, ib-gateway:4004, client id 999" in out
    assert "reset windows: none (IBKR_REGION=none; API alerts are never held back)\n" in out
    assert "notifier: disabled (no channel configured)" in out


def test_check_config_lists_every_problem_without_echoing_values(tmp_path: Path) -> None:
    utf16 = tmp_path / "teams-url"
    utf16.write_bytes("https://CANARY.example.com/hook".encode("utf-16"))
    code, out, err = run_cli(
        "check-config",
        env={
            "TRADING_MODE": "both",
            "NOTIFY_SLACK_URL": "https://hooks.slack.com/CANARY_PLAIN",
            "NOTIFY_TEAMS_URL_FILE": str(utf16),
        },
    )
    assert code == 2
    assert out == ""
    assert "TRADING_MODE" in err
    assert "NOTIFY_SLACK_URL_FILE" in err
    assert "CANARY" not in err
    # Secret files are only read once the variables themselves are valid.
    code, _, err = run_cli("check-config", env={"NOTIFY_TEAMS_URL_FILE": str(utf16)})
    assert code == 2
    assert "NOTIFY_TEAMS_URL_FILE" in err
    assert "UTF-16" in err
    assert "CANARY" not in err


def test_check_config_reports_the_configured_channels(tmp_path: Path) -> None:
    url = tmp_path / "slack"
    url.write_text("https://hooks.slack.com/services/CANARY\r\n", encoding="utf-8")
    code, out, _ = run_cli(
        "check-config", env={"NOTIFY_SLACK_URL_FILE": str(url), "PROBE_ENABLED": "no"}
    )
    assert code == 0
    assert "probe: disabled" in out
    assert "notifier: slack" in out
    assert "CANARY" not in out


def test_print_schema_status_prints_the_committed_schema() -> None:
    code, out, _ = run_cli("print-schema", "status")
    assert code == 0
    assert out == SCHEMA_FILE.read_text(encoding="utf-8")


def test_an_unknown_command_or_schema_is_a_usage_error() -> None:
    assert run_cli("print-schema", "nonsense")[0] == 2
    assert run_cli("frobnicate")[0] == 2
    code, out, _ = run_cli("--version")
    assert code == 0
    assert out.strip() == "brokersre-sidecar 0.1.0"


def endpoint_env(server: LocalServer) -> dict[str, str]:
    return {"SIDECAR_BIND": "0.0.0.0", "SIDECAR_PORT": str(server.port)}


def test_status_prints_the_document_and_exits_zero_only_when_ready(server: LocalServer) -> None:
    server.get_answers["/status"] = (200, '{"status":"ready","phase":"logged-in"}\n')
    code, out, _ = run_cli("status", env=endpoint_env(server))
    assert code == 0
    assert json.loads(out) == {"status": "ready", "phase": "logged-in"}
    server.get_answers["/status"] = (200, '{"status":"not_measured","phase":"login"}\n')
    code, out, _ = run_cli("status", env=endpoint_env(server))
    assert code == 1
    assert json.loads(out)["status"] == "not_measured"


def test_status_without_a_running_sidecar_exits_three_with_a_reason() -> None:
    code, out, err = run_cli(
        "status", env={"SIDECAR_BIND": "127.0.0.1", "SIDECAR_PORT": str(free_port())}
    )
    assert code == 3
    assert out == ""
    assert "not reachable" in err


def test_status_with_an_unusable_answer_exits_three(server: LocalServer) -> None:
    server.get_answers["/status"] = (200, "this is not json")
    assert run_cli("status", env=endpoint_env(server))[0] == 3
    server.get_answers["/status"] = (500, "boom")
    assert run_cli("status", env=endpoint_env(server))[0] == 3


def test_healthcheck_follows_livez(server: LocalServer) -> None:
    server.get_answers["/livez"] = (200, "ok\n")
    assert run_cli("healthcheck", env=endpoint_env(server))[0] == 0
    server.get_answers["/livez"] = (503, "the supervisor is not running\n")
    assert run_cli("healthcheck", env=endpoint_env(server))[0] == 1
    assert run_cli("healthcheck", env={"SIDECAR_PORT": str(free_port())})[0] == 1
    assert run_cli("healthcheck", env={"SIDECAR_PORT": "not-a-port"})[0] == 1


def webhook_env(tmp_path: Path, server: LocalServer, **extra: str) -> dict[str, str]:
    url = tmp_path / "webhook-url"
    url.write_text(f"http://127.0.0.1:{server.port}/hook/CANARY_PATH\n", encoding="utf-8")
    return {
        "NOTIFY_WEBHOOK_URL_FILE": str(url),
        "NOTIFY_ALLOW_HTTP": "yes",
        "IBGW_INSTANCE": "desk-1",
        "GATEWAY_LOG_DIR": str(tmp_path / "no-volume"),
    } | extra


def test_notify_test_sends_to_every_channel_and_reports_each_result(
    tmp_path: Path, server: LocalServer
) -> None:
    ntfy = tmp_path / "ntfy-url"
    ntfy.write_text(f"http://127.0.0.1:{server.port}/topic", encoding="utf-8")
    code, out, _ = run_cli(
        "notify", "test", env=webhook_env(tmp_path, server, NOTIFY_NTFY_URL_FILE=str(ntfy))
    )
    assert code == 0
    assert out.splitlines() == ["webhook: ok", "ntfy: ok"]
    paths = [path for path, _, _ in server.posts]
    assert paths == ["/hook/CANARY_PATH", "/topic"]
    body = json.loads(server.posts[0][2])
    assert (body["kind"], body["class"], body["instance"]) == ("test", "test", "desk-1")
    assert body["phase"] == "not_measured"
    assert "CANARY" not in out


def test_notify_test_exits_non_zero_when_a_channel_fails(
    tmp_path: Path, server: LocalServer
) -> None:
    server.post_status = 403
    code, out, _ = run_cli("notify", "test", env=webhook_env(tmp_path, server))
    assert code == 1
    assert out.splitlines() == ["webhook: FAILED (http_403)"]
    assert len(server.posts) == 1  # one attempt, no retries: fast feedback for a human


def test_notify_test_without_a_channel_is_a_configuration_error() -> None:
    code, _, err = run_cli("notify", "test")
    assert code == 2
    assert "no notification channel is configured" in err


def test_support_bundle_writes_an_archive_and_prints_its_path(
    tmp_path: Path, server: LocalServer
) -> None:
    server.get_answers["/status"] = (200, '{"status":"ready"}\n')
    out_dir = tmp_path / "out"
    out_dir.mkdir()
    env = endpoint_env(server) | {"GATEWAY_LOG_DIR": str(tmp_path / "volume")}
    code, out, _ = run_cli("support-bundle", "--out", str(out_dir), env=env)
    assert code == 0
    path = Path(out.strip())
    assert path.parent == out_dir
    with tarfile.open(path, "r:gz") as archive:
        status = archive.extractfile("status.json")
        assert status is not None
        assert json.loads(status.read()) == {"status": "ready"}


def test_support_bundle_works_without_a_running_sidecar_and_refuses_a_missing_directory(
    tmp_path: Path,
) -> None:
    env = {"SIDECAR_PORT": str(free_port()), "GATEWAY_LOG_DIR": str(tmp_path / "volume")}
    code, out, _ = run_cli("support-bundle", "--out", str(tmp_path), env=env)
    assert code == 0
    assert Path(out.strip()).is_file()
    code, _, err = run_cli("support-bundle", "--out", str(tmp_path / "absent"), env=env)
    assert code == 2
    assert "--out" in err


def test_run_with_an_invalid_configuration_logs_each_problem_as_json_and_exits_two() -> None:
    code, out, _ = run_cli("run", env={"TRADING_MODE": "both", "SIDECAR_PORT": "x"})
    assert code == 2
    records = [json.loads(line) for line in out.splitlines()]
    assert [record["event"] for record in records] == ["config_invalid", "config_invalid"]
    assert all(record["level"] == "error" for record in records)
    assert "TRADING_MODE" in records[0]["msg"]


def test_run_starts_serves_and_stops_cleanly_when_told_to(tmp_path: Path) -> None:
    port = free_port()
    (tmp_path / "state").mkdir()
    out, err = io.StringIO(), io.StringIO()
    stop = threading.Event()
    result: list[int] = []
    env = {
        "SIDECAR_BIND": "127.0.0.1",
        "SIDECAR_PORT": str(port),
        "GATEWAY_LOG_DIR": str(tmp_path / "volume"),
        "SIDECAR_STATE_DIR": str(tmp_path / "state"),
        "PROBE_ENABLED": "no",
    }
    thread = threading.Thread(
        target=lambda: result.append(main(["run"], env=env, out=out, err=err, stop=stop))
    )
    thread.start()
    try:
        for _ in range(400):
            if run_cli("healthcheck", env=env)[0] == 0:
                break
            stop.wait(0.025)
        assert run_cli("healthcheck", env=env)[0] == 0
        code, text, _ = run_cli("status", env=env)
        assert code == 1  # live, but not ready: the probe is disabled
        assert json.loads(text)["status"] == "not_measured"
    finally:
        stop.set()
        thread.join(15)
    assert result == [0]
    events = [json.loads(line)["event"] for line in out.getvalue().splitlines()]
    assert events[0] == "sidecar_started"
    assert events[-1] == "sidecar_stopped"


def test_support_bundle_scrubs_the_values_of_redact_files_that_patterns_cannot_know(
    tmp_path: Path,
) -> None:
    volume = tmp_path / "volume"
    (volume / "events").mkdir(parents=True)
    line = {
        "ts": "2026-11-12T15:00:00.000Z",
        "src": "ibc",
        "level": "info",
        "event": "login_dialog",
        "msg": "window of CANARY_USERNAME opened",
    }
    (volume / "events" / "events.jsonl").write_text(json.dumps(line) + "\n", encoding="utf-8")
    username = tmp_path / "ib-username"
    username.write_bytes(b"\xef\xbb\xbfCANARY_USERNAME\r\n")
    env = {"SIDECAR_PORT": str(free_port()), "GATEWAY_LOG_DIR": str(volume)}

    def bundle_text(*extra: str) -> str:
        out_dir = tmp_path / f"out{len(extra)}"
        out_dir.mkdir()
        code, out, _ = run_cli("support-bundle", "--out", str(out_dir), *extra, env=env)
        assert code == 0
        with tarfile.open(out.strip(), "r:gz") as archive:
            member = archive.extractfile("events.jsonl")
            assert member is not None
            return member.read().decode()

    assert "CANARY_USERNAME" in bundle_text()  # free text: no pattern can know a username
    scrubbed = bundle_text("--redact-file", str(username))
    assert "CANARY_USERNAME" not in scrubbed
    assert "window of [REDACTED] opened" in scrubbed
    code, _, err = run_cli(
        "support-bundle", "--out", str(tmp_path), "--redact-file", str(tmp_path / "absent"), env=env
    )
    assert code == 2
    assert "--redact-file" in err


def test_check_config_names_the_shared_namespace_mode() -> None:
    code, out, _ = run_cli("check-config", env={"GATEWAY_HOST": "127.0.0.1"})
    assert code == 0
    assert "network mode: shared with the gateway (exits with 75 when orphaned)\n" in out
    assert "probe: enabled, 127.0.0.1:4002, client id 999" in out


def test_check_config_names_the_region_whose_reset_windows_apply() -> None:
    code, out, _ = run_cli("check-config", env={"IBKR_REGION": "asia"})
    assert code == 0
    assert "reset windows: asia (IBKR_REGION)\n" in out
