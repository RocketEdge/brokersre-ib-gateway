"""The examples are read-only by construction: no order, cancel or what-if call anywhere.

This repository's rule is that nothing it ships places, changes or cancels an order, not even
an example. The test reads every text file under ``examples/`` and fails on the first
forbidden API name. The names are assembled at run time, so this file does not contain them
and does not flag itself; the READMEs describe the rule in words for the same reason.

A second check keeps the two sample clients free of market-data subscriptions: their only
request is the server time.
"""

from pathlib import Path

import pytest

EXAMPLES_DIR = Path(__file__).resolve().parents[2]

#: Directories that hold tool output or third-party code, never this repository's sources.
SKIPPED_DIRECTORIES = frozenset(
    {
        ".venv",
        "__pycache__",
        ".pytest_cache",
        ".mypy_cache",
        ".ruff_cache",
        "bin",
        "obj",
        "TestResults",
    }
)

#: Order-entry, cancel and what-if calls of the TWS API and of ib_async (matched without
#: regard to letter case, which also covers the C# spelling).
FORBIDDEN_ORDER_NAMES = (
    "place" + "Order",
    "cancel" + "Order",
    "req" + "Global" + "Cancel",
    "what" + "If" + "Order",
    "exercise" + "Options",
)

#: Market-data subscriptions; the sample clients must not contain any of them.
FORBIDDEN_SUBSCRIPTION_NAMES = (
    "req" + "Mkt" + "Data",
    "req" + "Mkt" + "Depth",
    "req" + "Tick" + "By" + "Tick" + "Data",
    "req" + "Real" + "Time" + "Bars",
    "req" + "Historical" + "Data",
)


def text_files(root: Path) -> list[Path]:
    """Return every regular file under ``root`` outside ``SKIPPED_DIRECTORIES``, sorted.

    Skipped directories are pruned during the walk, not filtered afterwards: a virtual
    environment holds thousands of files that need not be visited.
    """
    found: list[Path] = []
    for directory, subdirectories, files in root.walk():
        subdirectories[:] = [name for name in subdirectories if name not in SKIPPED_DIRECTORIES]
        found.extend(directory / name for name in files)
    return sorted(found)


def find_names(paths: list[Path], names: tuple[str, ...]) -> list[str]:
    """Return ``file:line: name`` for every occurrence of a name, ignoring letter case.

    A file that is not UTF-8 text is skipped: source code and documentation always are.
    """
    lowered = [name.lower() for name in names]
    findings: list[str] = []
    for path in paths:
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except UnicodeDecodeError:
            continue
        for number, line in enumerate(lines, start=1):
            folded = line.lower()
            findings.extend(f"{path}:{number}: {name}" for name in lowered if name in folded)
    return findings


def test_no_file_under_examples_names_an_order_cancel_or_what_if_call() -> None:
    """Every text file of the examples is free of the forbidden API names."""
    paths = text_files(EXAMPLES_DIR)

    assert find_names(paths, FORBIDDEN_ORDER_NAMES) == []


def test_the_scan_really_covers_the_samples() -> None:
    """An empty scan would pass vacuously: the files that matter must be in it."""
    scanned = {path.relative_to(EXAMPLES_DIR).as_posix() for path in text_files(EXAMPLES_DIR)}

    assert {
        "wait-for-gateway.sh",
        "compose-with-client.yml",
        "python/resilient_client.py",
        "python/tests/test_no_order_api.py",
    } <= scanned


def test_the_sample_clients_subscribe_to_no_market_data() -> None:
    """The Python client and every C# source file ask for the server time and nothing else."""
    clients = [
        path
        for path in text_files(EXAMPLES_DIR)
        if path.name == "resilient_client.py" or path.suffix == ".cs"
    ]

    assert clients, "no sample client found"
    assert find_names(clients, FORBIDDEN_SUBSCRIPTION_NAMES) == []


@pytest.mark.parametrize("name", FORBIDDEN_ORDER_NAMES)
def test_the_scanner_finds_a_planted_name_in_any_letter_case(tmp_path: Path, name: str) -> None:
    """The scanner itself is tested: a planted call is found, upper-cased or not."""
    (tmp_path / "nested").mkdir()
    planted = tmp_path / "nested" / "strategy.txt"
    planted.write_text(f"first line\nclient.{name.upper()}(contract)\n", encoding="utf-8")

    findings = find_names(text_files(tmp_path), FORBIDDEN_ORDER_NAMES)

    assert findings == [f"{planted}:2: {name.lower()}"]


def test_the_scanner_skips_tool_directories_and_binary_files(tmp_path: Path) -> None:
    """Build output and virtual environments hold third-party code and are not scanned."""
    forbidden = FORBIDDEN_ORDER_NAMES[0]
    (tmp_path / ".venv" / "lib").mkdir(parents=True)
    (tmp_path / ".venv" / "lib" / "module.py").write_text(forbidden, encoding="utf-8")
    (tmp_path / "bin").mkdir()
    (tmp_path / "bin" / "library.dll").write_bytes(b"\xff\xfe" + forbidden.encode())
    (tmp_path / "binary.dat").write_bytes(b"\xff\xfe\x00" + forbidden.encode())

    assert find_names(text_files(tmp_path), FORBIDDEN_ORDER_NAMES) == []
