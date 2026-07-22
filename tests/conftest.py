# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

import os
import sys
from pathlib import Path

import pytest

# Importable even when the package isn't installed (pyproject also sets
# pythonpath = ["src"] for the normal `uv run pytest` path).
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))


@pytest.fixture(autouse=True, scope="session")
def _isolate_tamlil_env(tmp_path_factory):
    """Scrub every ambient TAMLIL_* override for the whole test run.

    The invoking shell may legitimately export these (TAMLIL_DB_PATH is a
    documented MCP override), but inherited values would let tests write into
    the real recording database or learned dictionary: meeting_pipeline reports
    state into TAMLIL_DB_PATH when set, and falls back to the repo root for the
    lexicon. Dropping them all — not just defaulting the unset ones — enforces
    the isolation rule for every test; a test that needs one sets it itself
    (monkeypatch.setenv runs after this session fixture).
    """
    for var in [v for v in os.environ if v.startswith("TAMLIL_")]:
        del os.environ[var]
    os.environ["TAMLIL_LEXICON_ROOT"] = str(tmp_path_factory.mktemp("lexicon"))
    yield


def pytest_runtest_setup(item):
    """Skip tests marked `requires_ffmpeg` when the ffmpeg binary is absent, so
    the gate stays green on runners (CI) that don't install it."""
    if item.get_closest_marker("requires_ffmpeg"):
        from tamlil.util import ffmpeg_path

        if not ffmpeg_path():
            pytest.skip("ffmpeg binary unavailable")
