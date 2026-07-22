# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

"""tamlil.__version__ is exposed and matches the packaging metadata."""

from __future__ import annotations

import tomllib
from pathlib import Path

import tamlil


def test_version_is_nonempty():
    assert isinstance(tamlil.__version__, str)
    assert tamlil.__version__


def test_version_matches_pyproject():
    pyproject = Path(__file__).resolve().parent.parent / "pyproject.toml"
    data = tomllib.loads(pyproject.read_text(encoding="utf-8"))
    assert tamlil.__version__ == data["project"]["version"]
