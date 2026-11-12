"""Proof that the sidecar cannot touch orders and requests nothing but the server time.

Two scans over the sidecar's files (and its documents elsewhere in the repository):

1. No order-related IB API name appears anywhere: not as an identifier, not in a string or
   docstring, not in a document or an example. The names are assembled at run time so this
   file does not contain them either.
2. In the package source, the only IB API request method referenced at all is the
   server-time request: any other identifier of the form ``req<Name>`` is refused. That is
   what "the probe never subscribes to market data or account data" means in code.
"""

from __future__ import annotations

import ast
import os
import re
from collections.abc import Iterator
from pathlib import Path

SIDECAR_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = SIDECAR_ROOT.parent
SOURCE = SIDECAR_ROOT / "src"

# Assembled from halves: the scanner must not find these names in its own source.
ORDER_NAMES = [
    "place" + "Order",
    "cancel" + "Order",
    "req" + "Global" + "Cancel",
    "what" + "If" + "Order",
    "exercise" + "Options",
    "req" + "Auto" + "Open" + "Orders",
]
ORDER_PATTERN = re.compile("|".join(ORDER_NAMES), re.IGNORECASE)

ALLOWED_REQUESTS = {"req" + "CurrentTime"}
REQUEST_IDENTIFIER = re.compile(r"^req[A-Z]\w*$")

SKIPPED_DIRECTORIES = {
    ".venv",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    ".hypothesis",
    ".git",
    "htmlcov",
}
# Documents and configuration that belong to the sidecar but live outside its directory.
RELATED_FILES = [
    "docs/sidecar.md",
    "docs/adr/0010-sidecar-for-probe-status-and-alerts.md",
    "compose/docker-compose.sidecar.yml",
    ".github/workflows/sidecar.yml",
    ".github/workflows/sidecar-publish.yml",
]


def sidecar_files() -> Iterator[Path]:
    """Yield every file of the sidecar, skipping tool caches and the virtual environment."""
    for directory, subdirectories, names in os.walk(SIDECAR_ROOT):
        # Prune in place so the virtual environment is never descended into.
        subdirectories[:] = sorted(set(subdirectories) - SKIPPED_DIRECTORIES)
        for name in sorted(names):
            yield Path(directory) / name
    for relative in RELATED_FILES:
        path = REPOSITORY_ROOT / relative
        if path.is_file():
            yield path


def identifiers_and_strings(tree: ast.AST) -> Iterator[tuple[str, int]]:
    """Yield every identifier and string constant of a module with its line."""
    for node in ast.walk(tree):
        line = getattr(node, "lineno", 0)
        if isinstance(node, ast.Name):
            yield node.id, line
        elif isinstance(node, ast.Attribute):
            yield node.attr, line
        elif isinstance(node, ast.FunctionDef | ast.AsyncFunctionDef | ast.ClassDef):
            yield node.name, line
        elif isinstance(node, ast.arg | ast.keyword):
            if node.arg is not None:
                yield node.arg, line
        elif isinstance(node, ast.alias):
            yield node.name, line
            if node.asname is not None:
                yield node.asname, line
        elif isinstance(node, ast.Constant) and isinstance(node.value, str):
            yield node.value, line


def test_no_order_related_api_name_appears_in_any_python_file() -> None:
    scanned = 0
    for path in sidecar_files():
        if path.suffix != ".py":
            continue
        scanned += 1
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        for text, line in identifiers_and_strings(tree):
            match = ORDER_PATTERN.search(text)
            assert match is None, f"{path.relative_to(REPOSITORY_ROOT)}:{line}: order API name"
    assert scanned > 60, "the scan did not find the package"


def test_no_order_related_api_name_appears_in_any_other_file() -> None:
    scanned = 0
    for path in sidecar_files():
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue  # binary
        scanned += 1
        match = ORDER_PATTERN.search(text)
        assert match is None, f"{path.relative_to(REPOSITORY_ROOT)}: order API name in text"
    assert scanned > 80


def test_the_only_api_request_the_package_can_make_is_the_time_request() -> None:
    seen: set[str] = set()
    for path in sorted(SOURCE.rglob("*.py")):
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        for node in ast.walk(tree):
            name = None
            if isinstance(node, ast.Attribute):
                name = node.attr
            elif isinstance(node, ast.Name):
                name = node.id
            elif isinstance(node, ast.FunctionDef | ast.AsyncFunctionDef):
                name = node.name
            if name is not None and REQUEST_IDENTIFIER.fullmatch(name):
                seen.add(name)
                where = f"{path.relative_to(REPOSITORY_ROOT)}:{getattr(node, 'lineno', 0)}"
                assert name in ALLOWED_REQUESTS, f"{where}: {name} is not allowed"
    assert seen == ALLOWED_REQUESTS, "the time request itself was not found: the scan is broken"


def test_the_scanner_catches_a_planted_call() -> None:
    """Guard against a vacuous test: planted source must trip both scans."""
    planted = f"class X:\n    def run(self, ib):\n        ib.{ORDER_NAMES[0]}(1)\n        ib.reqMktData()\n"
    tree = ast.parse(planted)
    assert any(ORDER_PATTERN.search(text) for text, _ in identifiers_and_strings(tree))
    assert ORDER_PATTERN.search(f"docs say: never call {ORDER_NAMES[1].upper()}")
    names = {node.attr for node in ast.walk(tree) if isinstance(node, ast.Attribute)}
    assert any(
        REQUEST_IDENTIFIER.fullmatch(name) and name not in ALLOWED_REQUESTS for name in names
    )
