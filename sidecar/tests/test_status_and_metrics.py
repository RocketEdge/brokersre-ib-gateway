"""The versioned /status document, its JSON Schema, and the Prometheus exposition."""

from __future__ import annotations

import json
import re
from datetime import timedelta
from pathlib import Path
from typing import Any

import jsonschema
import pytest

from brokersre_sidecar.metrics import CONTENT_TYPE, render_metrics
from brokersre_sidecar.model import STATUS_SCHEMA, build_status, status_json_schema
from brokersre_sidecar.model.health import (
    ActiveAlertSnapshot,
    ChannelSnapshot,
    FarmState,
    NotifierSnapshot,
    TaskSnapshot,
)
from brokersre_sidecar.vocab import ProbeStatus
from testkit import T0, gateway_snapshot, metrics_sample, probe_snapshot

SCHEMA_FILE = Path(__file__).resolve().parents[1] / "schemas" / "status.v1.schema.json"

NOTIFIER_OFF = NotifierSnapshot(
    enabled=False,
    channels=(),
    active_alerts=(),
    state_persistence="disabled",
    state_persistence_reason=None,
)
NOTIFIER_ON = NotifierSnapshot(
    enabled=True,
    channels=(
        ChannelSnapshot("teams", 3, 1, 0, 0, T0, T0, "http_503"),
        ChannelSnapshot("pagerduty", 0, 0, 0, 2, None, None, None),
    ),
    active_alerts=(
        ActiveAlertSnapshot("twofa_pending", "critical", T0, True, 1, 0),
        ActiveAlertSnapshot("api_unhealthy", "error", T0, False, 0, 3),
    ),
    state_persistence="memory",
    state_persistence_reason="the state directory is not writable",
)
TASKS = (
    TaskSnapshot("follow", "running", 0, None, None),
    TaskSnapshot("probe", "backoff", 2, "RuntimeError", T0),
)


def status(**overrides: Any) -> dict[str, Any]:
    fields: dict[str, Any] = {
        "instance": "desk-1",
        "trading_mode": "paper",
        "gateway": gateway_snapshot(),
        "probe": probe_snapshot(
            farms=(FarmState("market_data", "usfarm", "ok"),), clock_skew_s=-0.4
        ),
        "notifier": NOTIFIER_ON,
        "tasks": TASKS,
        "now": T0,
    }
    fields.update(overrides)
    document = build_status(**fields)
    parsed: dict[str, Any] = json.loads(document.model_dump_json(by_alias=True))
    return parsed


def validate(document: dict[str, Any]) -> None:
    schema = json.loads(SCHEMA_FILE.read_text(encoding="utf-8"))
    jsonschema.Draft202012Validator.check_schema(schema)
    jsonschema.Draft202012Validator(schema, format_checker=jsonschema.FormatChecker()).validate(
        document
    )


def test_the_committed_schema_file_is_exactly_what_the_model_generates() -> None:
    generated = json.dumps(status_json_schema(), indent=2, sort_keys=True) + "\n"
    assert (
        SCHEMA_FILE.read_text(encoding="utf-8") == generated
    ), "regenerate with: uv run brokersre-sidecar print-schema status > schemas/status.v1.schema.json"


def test_a_ready_gateway_is_reported_with_every_contract_field() -> None:
    document = status()
    validate(document)
    assert document["schema"] == STATUS_SCHEMA == "brokersre.sidecar.status.v1"
    assert document["generated_at"] == "2026-11-12T15:00:00.000Z"
    assert document["instance"] == "desk-1"
    assert document["trading_mode"] == "paper"
    assert document["phase"] == "logged-in"
    assert document["phase_since"] == "2026-11-12T14:00:00.000Z"
    assert document["status"] == "ready"
    assert document["reason"] == "time round trip ok, connectivity up, no farm broken"
    assert document["farms"] == [{"kind": "market_data", "name": "usfarm", "condition": "ok"}]
    assert document["last_probe"] == {
        "at": "2026-11-12T14:59:30.000Z",
        "ok": True,
        "rtt_s": 0.05,
        "error": None,
        "consecutive_failures": 0,
    }
    assert document["clock_skew_s"] == -0.4
    assert document["boot_id"] == "00000000000000aa"
    assert document["boots_30m"] == 0
    assert document["last_login"] == "2026-11-12T14:00:00.000Z"
    assert set(document["versions"]) == {"sidecar", "python", "ib_async"}
    assert document["notifier"]["enabled"] is True
    assert document["notifier"]["state_persistence"] == "memory"
    assert document["notifier"]["channels"][0] == {
        "name": "teams",
        "sent_total": 3,
        "failures_total": 1,
        "dropped_total": 0,
        "queue_depth": 0,
        "last_success_at": "2026-11-12T15:00:00.000Z",
        "last_failure_at": "2026-11-12T15:00:00.000Z",
        "last_error": "http_503",
    }
    assert document["notifier"]["active_alerts"] == [
        {
            "class": "twofa_pending",
            "severity": "critical",
            "since": "2026-11-12T15:00:00.000Z",
            "notified": True,
            "escalation_step": 1,
            "failed_attempts": 0,
        },
        {
            "class": "api_unhealthy",
            "severity": "error",
            "since": "2026-11-12T15:00:00.000Z",
            "notified": False,
            "escalation_step": 0,
            "failed_attempts": 3,
        },
    ]
    assert document["tasks"][1] == {
        "name": "probe",
        "state": "backoff",
        "restarts": 2,
        "last_error": "RuntimeError",
        "last_crash_at": "2026-11-12T15:00:00.000Z",
    }


def test_unmeasured_values_are_null_never_zero_or_ok() -> None:
    document = status(
        gateway=gateway_snapshot(
            volume_present=False,
            phase=None,
            phase_since=None,
            boot_id=None,
            boots_30m=None,
            last_login=None,
            last_event_at=None,
            last_activity_at=None,
            feeds_seen=False,
        ),
        probe=probe_snapshot(
            status=ProbeStatus.NOT_MEASURED,
            reason="gateway phase is not measured; the API is probed only while it is logged-in",
            connectivity="not_measured",
            last_probe_at=None,
            last_probe_ok=None,
            last_rtt_s=None,
            clock_skew_s=None,
            close_wait_sockets=None,
        ),
        notifier=NOTIFIER_OFF,
        tasks=(),
    )
    validate(document)
    for key in ("phase", "phase_since", "boot_id", "boots_30m", "last_login", "clock_skew_s"):
        assert document[key] is None, key
    assert document["close_wait_sockets"] is None
    assert document["status"] == "not_measured"
    assert document["connectivity"] == "not_measured"
    assert document["last_probe"]["ok"] is None
    assert document["gateway_feed"] == {
        "volume_present": False,
        "feeds_seen": False,
        "last_event_at": None,
        "last_metrics_at": None,
        "rejected_lines": 0,
    }
    assert document["notifier"] == {
        "enabled": False,
        "channels": [],
        "active_alerts": [],
        "state_persistence": "disabled",
        "state_persistence_reason": None,
    }


@pytest.mark.parametrize("status_value", list(ProbeStatus))
def test_every_probe_status_is_valid_against_the_schema(status_value: ProbeStatus) -> None:
    validate(status(probe=probe_snapshot(status=status_value)))


def test_the_schema_rejects_unknown_fields_and_wrong_vocabulary() -> None:
    document = status()
    with pytest.raises(jsonschema.ValidationError):
        validate(document | {"username": "CANARY"})
    with pytest.raises(jsonschema.ValidationError):
        validate(document | {"status": "fine"})
    with pytest.raises(jsonschema.ValidationError):
        validate(document | {"generated_at": "yesterday"})


SAMPLE_LINE = re.compile(
    r'^(?P<name>[a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(?P<labels>[a-zA-Z_][a-zA-Z0-9_]*="[^"\\\n]*"'
    r'(?:,[a-zA-Z_][a-zA-Z0-9_]*="[^"\\\n]*")*)\})? (?P<value>-?[0-9.]+(?:e[+-]?[0-9]+)?)$'
)


def parse(text: str) -> dict[str, float]:
    """Parse the exposition strictly; return ``name{labels}`` -> value."""
    assert text.endswith("\n")
    samples: dict[str, float] = {}
    typed: set[str] = set()
    for line in text.splitlines():
        if line.startswith("# TYPE "):
            _, _, name, kind = line.split(" ")
            assert kind in {"gauge", "counter"}
            assert name not in typed, f"duplicate TYPE for {name}"
            typed.add(name)
            continue
        if line.startswith("# HELP "):
            continue
        match = SAMPLE_LINE.match(line)
        assert match is not None, f"unparseable line: {line!r}"
        assert match["name"] in typed, f"sample before its TYPE line: {line!r}"
        key = match["name"] + (f"{{{match['labels']}}}" if match["labels"] else "")
        assert key not in samples
        samples[key] = float(match["value"])
    return samples


def metrics(**overrides: Any) -> dict[str, float]:
    fields: dict[str, Any] = {
        "gateway": gateway_snapshot(
            last_metrics=metrics_sample(
                T0 - timedelta(seconds=20),
                mem_working_set_bytes=900_000_000,
                mem_limit_bytes=2_000_000_000,
                oom_kills=0,
                cpu_usage_usec=12_500_000,
                cpu_throttled_usec=250_000,
                pids=140,
                java_rss_bytes=700_000_000,
                java_threads=96,
                open_fds=312,
            )
        ),
        "probe": probe_snapshot(),
        "notifier": NOTIFIER_ON,
        "tasks": TASKS,
    }
    fields.update(overrides)
    return parse(render_metrics(**fields))


def test_the_frozen_metric_names_are_exposed_with_measured_values() -> None:
    samples = metrics()
    assert samples == {
        'ibgw_sidecar_info{version="0.1.0"}': 1,
        'ibgw_phase{phase="logged-in"}': 1,
        "ibgw_api_ready": 1,
        "ibgw_api_rtt_seconds": 0.05,
        "ibgw_clock_offset_seconds": -0.4,
        "ibgw_api_close_wait_sockets": 0,
        "ibgw_boots_30m": 0,
        "ibgw_memory_working_set_bytes": 900_000_000,
        "ibgw_memory_limit_bytes": 2_000_000_000,
        "ibgw_oom_kills_total": 0,
        "ibgw_cpu_usage_seconds_total": 12.5,
        "ibgw_cpu_throttled_seconds_total": 0.25,
        "ibgw_pids": 140,
        "ibgw_java_rss_bytes": 700_000_000,
        "ibgw_java_threads": 96,
        "ibgw_open_fds": 312,
        'ibgw_notify_failures_total{channel="teams"}': 1,
        'ibgw_notify_failures_total{channel="pagerduty"}': 0,
        'ibgw_notify_sent_total{channel="teams"}': 3,
        'ibgw_notify_sent_total{channel="pagerduty"}': 0,
        'ibgw_notify_dropped_total{channel="teams"}': 0,
        'ibgw_notify_dropped_total{channel="pagerduty"}': 0,
        "ibgw_notify_undelivered_alerts": 1,
        'ibgw_sidecar_task_restarts_total{task="follow"}': 0,
        'ibgw_sidecar_task_restarts_total{task="probe"}': 2,
    }


def test_a_value_that_was_not_measured_is_omitted_never_zero() -> None:
    samples = metrics(
        gateway=gateway_snapshot(phase=None, boots_30m=None, last_metrics=None),
        probe=probe_snapshot(
            status=ProbeStatus.NOT_MEASURED,
            last_rtt_s=None,
            clock_skew_s=None,
            close_wait_sockets=None,
        ),
        notifier=NOTIFIER_OFF,
        tasks=(),
    )
    assert samples == {'ibgw_sidecar_info{version="0.1.0"}': 1}


def test_partial_samples_expose_only_what_they_contain() -> None:
    partial = metrics_sample(T0 - timedelta(seconds=5), pids=7, api_close_wait_sockets=4)
    samples = metrics(
        gateway=gateway_snapshot(last_metrics=partial),
        probe=probe_snapshot(close_wait_sockets=None),
    )
    assert samples["ibgw_pids"] == 7
    assert samples["ibgw_api_close_wait_sockets"] == 4  # the gateway's own count as fallback
    assert "ibgw_memory_working_set_bytes" not in samples
    assert "ibgw_open_fds" not in samples


def test_a_stale_gateway_sample_is_not_re_exported_as_current() -> None:
    stale = metrics_sample(T0 - timedelta(minutes=10), pids=7, mem_working_set_bytes=1)
    samples = metrics(gateway=gateway_snapshot(last_metrics=stale))
    assert "ibgw_pids" not in samples
    assert "ibgw_memory_working_set_bytes" not in samples


@pytest.mark.parametrize(
    ("status_value", "expected"),
    [
        (ProbeStatus.READY, 1),
        (ProbeStatus.DEGRADED, 0),
        (ProbeStatus.DOWN, 0),
        (ProbeStatus.CLIENT_ID_IN_USE, 0),
    ],
)
def test_api_ready_is_one_only_when_ready(status_value: ProbeStatus, expected: int) -> None:
    samples = metrics(probe=probe_snapshot(status=status_value, last_rtt_s=None))
    assert samples["ibgw_api_ready"] == expected
    assert "ibgw_api_rtt_seconds" not in samples


def test_an_unknown_phase_token_is_exported_as_unknown() -> None:
    samples = metrics(gateway=gateway_snapshot(phase="unknown"))
    assert samples['ibgw_phase{phase="unknown"}'] == 1


def test_the_content_type_is_the_prometheus_text_format() -> None:
    assert CONTENT_TYPE == "text/plain; version=0.0.4; charset=utf-8"
