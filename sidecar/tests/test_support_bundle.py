"""The support bundle: enough to diagnose, nothing that identifies the account holder."""

from __future__ import annotations

import io
import json
import tarfile
from pathlib import Path

from brokersre_sidecar.config import load_settings
from brokersre_sidecar.redaction import ACCOUNT_RE, SecretRegistry
from brokersre_sidecar.support import create_bundle
from testkit import T0, iso

USERNAME = "CANARY_USERNAME"
ACCOUNT = "DU7654321"


def write_volume(root: Path, *, events: int = 5) -> None:
    for name in ("state", "events", "metrics", "ibc", "jts"):
        (root / name).mkdir(parents=True)
    (root / "state" / "phase").write_bytes(b"logged-in\n")
    lines = [
        {
            "ts": iso(T0),
            "src": "ibc",
            "level": "info",
            "event": f"event_{number}",
            "msg": f"IBC: login for user={USERNAME} account {ACCOUNT}",
            "boot_id": "00000000000000aa",
            "seq": number,
            "username": USERNAME,
            "extra": {"account": ACCOUNT},
        }
        for number in range(events)
    ]
    (root / "events" / "events.jsonl").write_text(
        "".join(json.dumps(line) + "\n" for line in lines) + "not json at all CANARY\n",
        encoding="utf-8",
        newline="\n",
    )
    (root / "metrics" / "metrics.jsonl").write_text(
        json.dumps(
            {"ts": iso(T0), "src": "metrics", "pids": 41, "account": ACCOUNT, "phase": "logged-in"}
        )
        + "\n",
        encoding="utf-8",
        newline="\n",
    )
    key = "IbLogin" + "Id"
    (root / "ibc" / "ibc.log").write_text(
        "\n".join(
            [
                f"2026-11-12 15:00:00:000 IBC: {key}={USERNAME}",
                f"2026-11-12 15:00:01:000 IBC: Login has completed for {ACCOUNT}",
                f"JTextField: {USERNAME}",  # a dialog dump line: not an IBC: line
                f"some other raw line with {USERNAME}",
                "2026-11-12 15:00:02:000 IBC: detected frame entitled: IB Gateway; event=Opened",
            ]
        )
        + "\n",
        encoding="utf-8",
        newline="\n",
    )
    (root / "jts" / "launcher.log").write_text(f"raw gateway log {USERNAME}\n", encoding="utf-8")


def read_bundle(path: Path) -> dict[str, str]:
    with tarfile.open(path, "r:gz") as archive:
        members = archive.getmembers()
        assert all(member.isfile() for member in members)
        assert all(member.uname == "" and member.gname == "" for member in members)
        assert all(member.uid == 0 and member.gid == 0 for member in members)
        return {
            member.name: archive.extractfile(member).read().decode("utf-8")  # type: ignore[union-attr]
            for member in members
        }


def make(tmp_path: Path, **options: object) -> tuple[Path, dict[str, str]]:
    volume = tmp_path / "volume"
    write_volume(volume)
    out = tmp_path / "out"
    out.mkdir()
    registry = SecretRegistry()
    registry.add("CANARY_WEBHOOK_SECRET_URL")
    settings = load_settings({"GATEWAY_LOG_DIR": str(volume), "IBGW_INSTANCE": "desk-1"})
    path = create_bundle(
        out,
        settings=settings,
        registry=registry,
        status_json='{"schema":"brokersre.sidecar.status.v1","status":"ready"}',
        now=T0,
        **options,  # type: ignore[arg-type]
    )
    return path, read_bundle(path)


def test_the_bundle_is_a_tar_gz_with_a_fixed_set_of_files(tmp_path: Path) -> None:
    path, files = make(tmp_path)
    assert path.name == "brokersre-sidecar-support-desk-1-20261112T150000Z.tar.gz"
    assert path.parent == tmp_path / "out"
    assert set(files) == {
        "MANIFEST.txt",
        "phase.txt",
        "events.jsonl",
        "metrics.jsonl",
        "ibc-redacted.txt",
        "status.json",
        "versions.json",
        "settings.json",
    }
    assert files["phase.txt"] == "logged-in\n"
    assert json.loads(files["status.json"])["status"] == "ready"
    assert json.loads(files["versions.json"])["sidecar"] == "0.1.0"
    assert json.loads(files["settings.json"])["instance"] == "desk-1"


def test_the_bundle_says_how_the_sidecar_reaches_the_gateway(tmp_path: Path) -> None:
    # Whoever reads a bundle must see the network mode and the probed endpoint first.
    _, files = make(tmp_path)
    settings = json.loads(files["settings.json"])
    assert settings["network_mode"] == "own_network"
    assert settings["gateway_endpoint"] == "ib-gateway:4004"
    assert settings["ibkr_region"] == "none"
    assert settings["exit_when_orphaned"] is False
    assert settings["deadman_ping_configured"] is False


def test_no_username_or_full_account_id_is_in_any_file(tmp_path: Path) -> None:
    _, files = make(tmp_path)
    whole = io.StringIO()
    for name, content in files.items():
        whole.write(name + "\n" + content)
    text = whole.getvalue()
    assert USERNAME not in text
    assert "CANARY" not in text
    assert not ACCOUNT_RE.search(text)
    assert "***321" in text  # the account's last three characters are kept


def test_events_keep_their_contract_fields_and_a_redacted_message(tmp_path: Path) -> None:
    _, files = make(tmp_path)
    events = [json.loads(line) for line in files["events.jsonl"].splitlines()]
    assert len(events) == 5  # the non-JSON line is dropped, not copied
    assert set(events[0]) == {"ts", "src", "level", "event", "msg", "boot_id", "seq"}
    assert events[0]["msg"] == "IBC: login for user=[REDACTED] account ***321"
    metrics = [json.loads(line) for line in files["metrics.jsonl"].splitlines()]
    assert metrics == [
        {"ts": iso(T0), "boot_id": None, "seq": None, "phase": "logged-in", "pids": 41.0}
    ]


def test_only_ibc_lines_of_the_raw_log_are_included_and_only_redacted(tmp_path: Path) -> None:
    _, files = make(tmp_path)
    lines = files["ibc-redacted.txt"].splitlines()
    assert len(lines) == 3
    assert all("IBC:" in line for line in lines)
    assert lines[0].endswith("=[REDACTED]")
    assert lines[1].endswith("Login has completed for ***321")
    assert "launcher.log" not in "".join(files)


def test_the_number_of_lines_is_bounded(tmp_path: Path) -> None:
    volume = tmp_path / "volume"
    write_volume(volume, events=300)
    out = tmp_path / "out"
    out.mkdir()
    path = create_bundle(
        out,
        settings=load_settings({"GATEWAY_LOG_DIR": str(volume)}),
        registry=SecretRegistry(),
        status_json=None,
        now=T0,
        max_lines=20,
    )
    files = read_bundle(path)
    events = [json.loads(line) for line in files["events.jsonl"].splitlines()]
    assert [event["event"] for event in events] == [f"event_{n}" for n in range(280, 300)]
    assert "not available" in files["status.json"]


def test_a_missing_volume_still_produces_a_bundle_that_says_so(tmp_path: Path) -> None:
    out = tmp_path / "out"
    out.mkdir()
    path = create_bundle(
        out,
        settings=load_settings({"GATEWAY_LOG_DIR": str(tmp_path / "absent")}),
        registry=SecretRegistry(),
        status_json=None,
        now=T0,
    )
    files = read_bundle(path)
    assert files["phase.txt"] == "not_measured\n"
    assert files["events.jsonl"] == ""
    assert files["ibc-redacted.txt"] == ""
    assert "redacted" in files["MANIFEST.txt"].lower()


def test_a_status_document_is_scrubbed_like_everything_else(tmp_path: Path) -> None:
    volume = tmp_path / "volume"
    write_volume(volume)
    out = tmp_path / "out"
    out.mkdir()
    registry = SecretRegistry()
    registry.add("CANARY_WEBHOOK_SECRET_URL")
    path = create_bundle(
        out,
        settings=load_settings({"GATEWAY_LOG_DIR": str(volume)}),
        registry=registry,
        status_json=f'{{"note":"CANARY_WEBHOOK_SECRET_URL {ACCOUNT}"}}',
        now=T0,
    )
    assert read_bundle(path)["status.json"] == '{"note":"[REDACTED] ***321"}\n'
