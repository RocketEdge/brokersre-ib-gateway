"""Leaf utilities: clock, back-off, redaction and atomic file writes."""

from __future__ import annotations

import os
import sys
from datetime import UTC
from pathlib import Path

import pytest
from hypothesis import given
from hypothesis import strategies as st

from brokersre_sidecar.backoff import Backoff
from brokersre_sidecar.clock import SystemClock, format_utc, parse_utc
from brokersre_sidecar.fsutil import atomic_write_text, is_dir_writable
from brokersre_sidecar.redaction import (
    REDACTED,
    SecretRegistry,
    redact_accounts,
    redact_log_line,
)
from testkit import T0


def test_system_clock_returns_aware_utc_and_a_monotonic_reading() -> None:
    clock = SystemClock()
    assert clock.now().tzinfo is UTC
    first = clock.monotonic()
    assert clock.monotonic() >= first


def test_format_utc_uses_milliseconds_and_z_suffix() -> None:
    assert format_utc(T0) == "2026-11-12T15:00:00.000Z"


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("2026-11-12T15:00:00.000Z", T0),
        ("2026-11-12T15:00:00Z", T0),
        ("2026-11-12T23:00:00.000+08:00", T0),
    ],
)
def test_parse_utc_accepts_gateway_timestamps(text: str, expected: object) -> None:
    assert parse_utc(text) == expected


@pytest.mark.parametrize(
    "text", ["", "yesterday", "2026-11-12T15:00:00", "2026-13-40T00:00:00Z", 5, None]
)
def test_parse_utc_returns_none_for_anything_else(text: object) -> None:
    assert parse_utc(text) is None


def test_backoff_doubles_from_the_base_up_to_the_cap() -> None:
    policy = Backoff(base_s=1.0, cap_s=10.0, jitter=0.0)
    assert [policy.delay(n, lambda: 0.5) for n in range(1, 7)] == [1.0, 2.0, 4.0, 8.0, 10.0, 10.0]


def test_backoff_jitter_spreads_around_the_nominal_delay() -> None:
    policy = Backoff(base_s=10.0, cap_s=100.0, jitter=0.2)
    assert policy.delay(1, lambda: 0.0) == pytest.approx(8.0)
    assert policy.delay(1, lambda: 1.0) == pytest.approx(12.0)


@given(
    attempt=st.integers(min_value=-5, max_value=10_000),
    rand=st.floats(min_value=0.0, max_value=1.0),
)
def test_backoff_delay_is_always_positive_and_never_above_the_cap(
    attempt: int, rand: float
) -> None:
    policy = Backoff(base_s=0.5, cap_s=30.0, jitter=0.25)
    delay = policy.delay(attempt, lambda: rand)
    assert 0.0 < delay <= 30.0


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("account DU1234567 ready", "account ***567 ready"),
        ("U7654321", "***321"),
        ("DF123456 and F1234567", "***456 and ***567"),
        ("no account here: BU1234567x", "no account here: BU1234567x"),
        ("U1234 is too short", "U1234 is too short"),
    ],
)
def test_account_ids_keep_only_their_last_three_characters(text: str, expected: str) -> None:
    assert redact_accounts(text) == expected


def test_secret_registry_replaces_every_registered_value() -> None:
    registry = SecretRegistry()
    registry.add("hunter2hunter2")
    registry.add("")  # an empty value must never match everything
    assert (
        registry.scrub("token=hunter2hunter2&x=hunter2hunter2") == f"token={REDACTED}&x={REDACTED}"
    )
    assert registry.scrub("nothing here") == "nothing here"


def test_secret_registry_also_scrubs_the_url_encoded_form() -> None:
    registry = SecretRegistry()
    registry.add("p@ss word/1")
    assert registry.scrub("smtp://user:p%40ss%20word%2F1@host") == f"smtp://user:{REDACTED}@host"


def test_log_line_redaction_masks_identity_assignments_accounts_and_emails() -> None:
    registry = SecretRegistry()
    registry.add("CANARY_TOKEN_VALUE")
    key = "IbLogin" + "Id"
    line = f"IBC: {key}=CANARY_USER user: someone@example.com account=DU1234567 CANARY_TOKEN_VALUE"
    redacted = redact_log_line(line, registry)
    assert "CANARY_USER" not in redacted
    assert "someone@example.com" not in redacted
    assert "DU1234567" not in redacted
    assert "CANARY_TOKEN_VALUE" not in redacted
    assert redacted.startswith("IBC: ")


def test_atomic_write_replaces_the_file_and_leaves_no_temporary(tmp_path: Path) -> None:
    target = tmp_path / "state.json"
    atomic_write_text(target, "one")
    atomic_write_text(target, "two")
    assert target.read_text(encoding="utf-8") == "two"
    assert [p.name for p in tmp_path.iterdir()] == ["state.json"]


def test_atomic_write_keeps_the_old_content_when_the_write_fails(tmp_path: Path) -> None:
    target = tmp_path / "state.json"
    atomic_write_text(target, "old")
    with pytest.raises(OSError, match="missing"):
        atomic_write_text(tmp_path / "missing" / "state.json", "new")
    assert target.read_text(encoding="utf-8") == "old"


def test_dir_writable_is_false_for_a_missing_directory(tmp_path: Path) -> None:
    assert is_dir_writable(tmp_path) is True
    assert is_dir_writable(tmp_path / "absent") is False


def test_dir_writable_is_false_for_a_read_only_directory(tmp_path: Path) -> None:
    if sys.platform == "win32":
        pytest.skip("POSIX modes")
    if os.geteuid() == 0:
        pytest.skip("root can write anywhere")
    locked = tmp_path / "locked"
    locked.mkdir()
    locked.chmod(0o500)
    try:
        assert is_dir_writable(locked) is False
    finally:
        locked.chmod(0o700)


def test_an_account_id_glued_to_other_text_is_still_shortened() -> None:
    # What ib_async's event library logs on a handler error: the raw socket bytes.
    data = b"\x00\x00\x00\x0f15\x001\x00DU1234567\x00"
    text = redact_accounts(f"Value ({data!r},) caused exception for event Event<hasData, []>")
    assert "DU1234567" not in text
    assert "***567" in text
    assert redact_accounts("acct_DU1234567_x") == "acct_***567_x"
    assert redact_accounts("accountU7654321") == "account***321"
    assert redact_accounts("['15', '1', 'DU1234567,U7654321']") == "['15', '1', '***567,***321']"


@pytest.mark.parametrize(
    "text",
    [
        "CPU12345 load",  # an upper-case word that merely ends in U
        "SHELF123456",
        "U1234567890",  # ten digits: not an account id
        "sha256:9aaaf1234567deadbeef",  # lower-case hex is never an account id
    ],
)
def test_text_that_only_resembles_an_account_id_is_left_alone(text: str) -> None:
    assert redact_accounts(text) == text


def test_a_refused_rename_is_retried_on_windows_and_final_elsewhere(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # Windows refuses a rename while another process (antivirus, indexer) has the target
    # open for a moment. On POSIX a rename never fails for that reason: the error is real.
    real_replace = os.replace
    attempts: list[str] = []

    def refused_twice(source: str | Path, target: str | Path) -> None:
        attempts.append("try")
        if len(attempts) < 3:
            raise PermissionError("the file is in use")
        real_replace(source, target)

    monkeypatch.setattr(os, "replace", refused_twice)
    target = tmp_path / "state.json"
    if sys.platform == "win32":
        atomic_write_text(target, "new")
        assert target.read_text(encoding="utf-8") == "new"
        assert len(attempts) == 3
    else:
        with pytest.raises(PermissionError):
            atomic_write_text(target, "new")
        assert len(attempts) == 1
    assert [p.name for p in tmp_path.iterdir() if p.name != "state.json"] == []
