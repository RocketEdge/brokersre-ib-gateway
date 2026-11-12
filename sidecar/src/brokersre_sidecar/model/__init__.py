"""Model layer: what the sidecar knows about the gateway and how it reports it."""

from brokersre_sidecar.model.events import (
    METRIC_KEYS,
    GatewayEvent,
    MetricsSample,
    parse_event,
    parse_metrics,
)
from brokersre_sidecar.model.feed import GatewayFeed
from brokersre_sidecar.model.state import (
    BOOT_WINDOW,
    CONDITION_PAIRS,
    GatewaySnapshot,
    GatewayState,
    PairState,
)
from brokersre_sidecar.model.status import (
    STATUS_SCHEMA,
    StatusDocument,
    build_status,
    status_json_schema,
)

__all__ = [
    "BOOT_WINDOW",
    "CONDITION_PAIRS",
    "METRIC_KEYS",
    "STATUS_SCHEMA",
    "GatewayEvent",
    "GatewayFeed",
    "GatewaySnapshot",
    "GatewayState",
    "MetricsSample",
    "PairState",
    "StatusDocument",
    "build_status",
    "parse_event",
    "parse_metrics",
    "status_json_schema",
]
