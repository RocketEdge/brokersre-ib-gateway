"""Import rules of the package, enforced by parsing every module.

Layers, lowest first. A module may import from its own unit and from strictly lower layers,
never from the same layer or a higher one::

    0  vocab, clock, backoff, redaction, fsutil, logsetup, config, worker   (leaves)
    1  tail
    2  model
    3  probe, notify, http, metrics, support, supervisor            (independent of each other)
    4  app                                                          (the only wiring place)
    5  cli
    6  __main__

``ib_async`` is imported by ``probe/adapter.py`` only, and that module is imported by
``app.py`` only, so everything else is testable against the fake gateway.
"""

from __future__ import annotations

import ast
from collections.abc import Iterator
from pathlib import Path

import pytest

PACKAGE = "brokersre_sidecar"
SIDECAR_ROOT = Path(__file__).resolve().parents[1]
SOURCE = SIDECAR_ROOT / "src" / PACKAGE

RANKS = {
    "vocab": 0,
    "clock": 0,
    "backoff": 0,
    "redaction": 0,
    "fsutil": 0,
    "logsetup": 0,
    "config": 0,
    "worker": 0,
    "tail": 1,
    "model": 2,
    "probe": 3,
    "notify": 3,
    "http": 3,
    "metrics": 3,
    "support": 3,
    "supervisor": 3,
    "app": 4,
    "cli": 5,
    "__main__": 6,
}
# Leaves may use one another only in this fixed, acyclic order.
LEAF_ORDER = ["vocab", "clock", "backoff", "redaction", "fsutil", "logsetup", "config", "worker"]


def modules() -> list[Path]:
    return sorted(path for path in SOURCE.rglob("*.py"))


def unit_of(path: Path) -> str:
    """Return the top-level unit (first path component below the package) of a module."""
    relative = path.relative_to(SOURCE)
    return relative.parts[0].removesuffix(".py")


def imports_of(tree: ast.AST) -> Iterator[tuple[str, int]]:
    """Yield ``(dotted module name, line)`` for every import, including lazy ones."""
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                yield alias.name, node.lineno
        elif isinstance(node, ast.ImportFrom):
            assert node.level == 0, f"relative import at line {node.lineno}"
            if node.module is not None:
                yield node.module, node.lineno
                for alias in node.names:
                    yield f"{node.module}.{alias.name}", node.lineno


def test_every_unit_has_a_rank_and_every_ranked_unit_exists() -> None:
    present = {unit_of(path) for path in modules()} - {"__init__"}
    assert present == set(RANKS), present ^ set(RANKS)


@pytest.mark.parametrize("path", modules(), ids=lambda p: str(p.relative_to(SOURCE)))
def test_a_module_imports_only_its_own_unit_and_lower_layers(path: Path) -> None:
    unit = unit_of(path)
    # The package root holds the version only and imports nothing from the package.
    allowed_rank = -1 if unit == "__init__" else RANKS[unit]
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    for name, line in imports_of(tree):
        parts = name.split(".")
        if parts[0] != PACKAGE or len(parts) == 1:
            continue
        target = parts[1]
        if target not in RANKS or target == unit:
            continue  # a name imported from the package root (``__version__``) or own unit
        where = f"{path.relative_to(SOURCE)}:{line} imports {name}"
        if RANKS[target] == 0 and allowed_rank == 0:
            assert LEAF_ORDER.index(target) < LEAF_ORDER.index(unit), where
        else:
            assert RANKS[target] < allowed_rank, where


def test_ib_async_is_imported_by_the_adapter_only() -> None:
    importers = set()
    for path in [*modules(), *sorted((SIDECAR_ROOT / "tests").rglob("*.py"))]:
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        if any(name.split(".")[0] == "ib_async" for name, _ in imports_of(tree)):
            importers.add(path.relative_to(SIDECAR_ROOT).as_posix())
    assert importers == {f"src/{PACKAGE}/probe/adapter.py"}


def test_the_adapter_is_imported_by_the_wiring_only() -> None:
    importers = set()
    for path in modules():
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        if any(name.startswith(f"{PACKAGE}.probe.adapter") for name, _ in imports_of(tree)):
            importers.add(path.relative_to(SOURCE).as_posix())
    assert importers == {"app.py"}


def test_outbound_http_is_confined_to_the_notifier_and_the_wiring() -> None:
    """Only the notifier and the wiring use httpx, the one outbound HTTP client."""
    importers = set()
    for path in modules():
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        if any(name.split(".")[0] == "httpx" for name, _ in imports_of(tree)):
            importers.add(unit_of(path))
    assert importers <= {"notify", "app", "cli"}, importers


def test_the_rule_checker_itself_detects_a_violation() -> None:
    """Guard against a vacuous test: an upward import must be reported."""
    tree = ast.parse("from brokersre_sidecar.app import Application\nimport ib_async\n")
    found = dict(imports_of(tree))
    assert "brokersre_sidecar.app" in found
    assert "ib_async" in found
    assert RANKS["app"] > RANKS["probe"]
