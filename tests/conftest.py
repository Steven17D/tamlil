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
def _isolate_lexicon_root(tmp_path_factory):
    """Default TAMLIL_LEXICON_ROOT to a scratch dir for the whole test run.

    meeting_pipeline falls back to the repo root when this is unset, so a test
    exercising that path would mutate the real dictionary.json / learned.jsonl.
    Setting it here enforces the isolation rule for every test rather than
    relying on each test author to remember. A test may still override it.
    """
    if not os.environ.get("TAMLIL_LEXICON_ROOT"):
        os.environ["TAMLIL_LEXICON_ROOT"] = str(tmp_path_factory.mktemp("lexicon"))
    yield


def pytest_runtest_setup(item):
    """Skip tests marked `requires_ffmpeg` when the ffmpeg binary is absent, so
    the gate stays green on runners (CI) that don't install it."""
    if item.get_closest_marker("requires_ffmpeg"):
        from tamlil.util import ffmpeg_path

        if not ffmpeg_path():
            pytest.skip("ffmpeg binary unavailable")
