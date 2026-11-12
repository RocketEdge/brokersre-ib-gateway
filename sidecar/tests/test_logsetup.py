"""Structured JSON logging with redaction."""

from __future__ import annotations

import io
import json
import logging
from collections.abc import Iterator

import pytest

from brokersre_sidecar.logsetup import configure_logging, log_event
from brokersre_sidecar.redaction import SecretRegistry


@pytest.fixture
def stream() -> Iterator[io.StringIO]:
    """Capture the sidecar's log stream and restore the root logger afterwards."""
    root = logging.getLogger()
    saved_handlers, saved_level = list(root.handlers), root.level
    buffer = io.StringIO()
    registry = SecretRegistry()
    registry.add("CANARY_WEBHOOK_URL")
    configure_logging("debug", registry, buffer)
    try:
        yield buffer
    finally:
        root.handlers[:] = saved_handlers
        root.setLevel(saved_level)


def lines(stream: io.StringIO) -> list[dict[str, object]]:
    return [json.loads(line) for line in stream.getvalue().splitlines()]


def test_every_record_is_one_json_object_with_the_contract_keys(stream: io.StringIO) -> None:
    log_event(
        logging.getLogger("brokersre_sidecar.test"),
        logging.WARNING,
        "probe_failed",
        "round trip timed out",
        attempt=3,
    )
    (record,) = lines(stream)
    assert record["src"] == "sidecar"
    assert record["level"] == "warn"
    assert record["event"] == "probe_failed"
    assert record["msg"] == "round trip timed out"
    assert record["attempt"] == 3
    assert isinstance(record["ts"], str)
    assert record["ts"].endswith("Z")


def test_secrets_and_account_ids_are_redacted_in_messages_and_fields(stream: io.StringIO) -> None:
    logger = logging.getLogger("brokersre_sidecar.test")
    log_event(
        logger,
        logging.ERROR,
        "send_failed",
        "POST CANARY_WEBHOOK_URL failed for DU1234567",
        detail={"url": "CANARY_WEBHOOK_URL", "accounts": ["U7654321"]},
    )
    text = stream.getvalue()
    assert "CANARY_WEBHOOK_URL" not in text
    assert "DU1234567" not in text
    assert "U7654321" not in text
    (record,) = lines(stream)
    assert record["level"] == "error"
    assert record["detail"] == {"url": "[REDACTED]", "accounts": ["***321"]}


def test_third_party_records_are_wrapped_and_redacted_too(stream: io.StringIO) -> None:
    logging.getLogger("some.library").error("Peer closed connection for %s", "DU1234567")
    (record,) = lines(stream)
    assert record["event"] == "log"
    assert record["logger"] == "some.library"
    assert record["msg"] == "Peer closed connection for ***567"


def test_an_exception_is_reported_by_type_and_redacted_message_without_a_traceback(
    stream: io.StringIO,
) -> None:
    logger = logging.getLogger("brokersre_sidecar.test")
    try:
        raise ValueError("bad value CANARY_WEBHOOK_URL")
    except ValueError:
        logger.exception("task crashed")
    (record,) = lines(stream)
    assert record["error_type"] == "ValueError"
    assert record["error"] == "bad value [REDACTED]"
    assert "Traceback" not in stream.getvalue()


def test_library_noise_below_warning_is_dropped(stream: io.StringIO) -> None:
    logging.getLogger("httpx").info("HTTP Request: POST https://example.invalid/secret-path")
    logging.getLogger("ib_async.client").error("raw fields DU1234567")
    logging.getLogger("eventkit").error("Value (b'DU1234567',) caused exception")
    assert stream.getvalue() == ""


def test_an_unknown_level_name_is_refused() -> None:
    with pytest.raises(ValueError, match="LOG_LEVEL"):
        configure_logging("chatty", SecretRegistry(), io.StringIO())
