"""Railway image tracks the newest supported runtimes."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCKERFILE = (ROOT / "Dockerfile.railway").read_text()


def test_python_base_is_newest_supported():
    supported = re.findall(r"'py3(\d+)'", (ROOT / "pyproject.toml").read_text())
    newest = f"3.{max(map(int, supported))}"
    assert set(re.findall(r"FROM python:(3\.\d+)-slim", DOCKERFILE)) == {newest}


def test_node_is_active_lts():
    assert "deb.nodesource.com/setup_24.x" in DOCKERFILE
