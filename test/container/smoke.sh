#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

# Runs inside the container. Mirrors the portable (non-macOS) steps of
# scripts/install.sh from an empty environment, then drives the installed MCP
# server the same way Claude Code does. Any failure aborts non-zero.
set -euo pipefail

say() { printf '\n\033[36m== %s ==\033[0m\n' "$1"; }

say "Assert empty environment"
if command -v uv >/dev/null 2>&1; then echo "uv unexpectedly present"; exit 1; fi
if command -v tamlil-mcp >/dev/null 2>&1; then echo "tamlil-mcp unexpectedly present"; exit 1; fi
echo "uv: absent, tamlil-mcp: absent (good)"

say "Install uv (as scripts/install.sh does when missing)"
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
command -v uv

say "uv tool install --force . (production MCP install path)"
cd /repo
uv tool install --force .
export PATH="$HOME/.local/bin:$PATH"
TAMLIL_MCP_BIN="$(command -v tamlil-mcp)"
echo "installed: $TAMLIL_MCP_BIN"

say "Stage a recordings db + transcript"
export TAMLIL_DB_PATH=/tmp/tamlil/tamlil.sqlite
export TAMLIL_RECORDINGS_ROOT=/tmp/tamlil/recordings
# uv-managed interpreter: the base image has no system python, same as a real
# install where uv owns the runtime. --no-project keeps it stdlib-only.
uv run --no-project --python 3.12 python /repo/test/container/stage.py

say "Drive the installed tamlil-mcp like Claude (mcp stdio client)"
export TAMLIL_MCP_BIN
uv run --no-project --python 3.12 --with mcp python /repo/test/container/mcp_smoke.py

say "ALL GOOD: empty box -> tamlil-mcp serving staged recordings"
