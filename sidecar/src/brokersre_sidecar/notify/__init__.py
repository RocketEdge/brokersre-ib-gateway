"""Notifier layer: alert rules, the escalation ladder, message rendering and delivery."""

from brokersre_sidecar.notify.catalog import CATALOG, CONDITION_CLASSES, AlertSpec
from brokersre_sidecar.notify.channels import (
    Channel,
    DeliveryError,
    HttpTransport,
    build_channels,
)
from brokersre_sidecar.notify.deadman import DeadmanPinger, alerting_classes
from brokersre_sidecar.notify.dispatcher import Dispatcher
from brokersre_sidecar.notify.ladder import STATE_SCHEMA, LadderConfig, LadderEngine, Outbound
from brokersre_sidecar.notify.message import ALERT_SCHEMA, Message, MessageFactory
from brokersre_sidecar.notify.rules import (
    Condition,
    Evaluation,
    RuleConfig,
    RuleEngine,
    skew_exceeds,
)
from brokersre_sidecar.notify.service import Notifier
from brokersre_sidecar.notify.store import NotifierStore

__all__ = [
    "ALERT_SCHEMA",
    "CATALOG",
    "CONDITION_CLASSES",
    "STATE_SCHEMA",
    "AlertSpec",
    "Channel",
    "Condition",
    "DeadmanPinger",
    "DeliveryError",
    "Dispatcher",
    "Evaluation",
    "HttpTransport",
    "LadderConfig",
    "LadderEngine",
    "Message",
    "MessageFactory",
    "Notifier",
    "NotifierStore",
    "Outbound",
    "RuleConfig",
    "RuleEngine",
    "alerting_classes",
    "build_channels",
    "skew_exceeds",
]
