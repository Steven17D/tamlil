#!/bin/zsh
# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

# In-app updater: pull the latest snapshot, rebuild, reinstall, relaunch.
# Non-interactive (no tty prompts) — the menu bar app launches it detached so
# it outlives the app being replaced. Safe to run by hand too.
set -euo pipefail

DIR=${TAMLIL_DIR:-$HOME/Library/Application Support/Tamlil/repo}
# Post via the app so a tap activates Tamlil. osascript notifications are owned
# by Script Editor and open it on tap; the app's --notify mode posts as Tamlil.
TAMLIL_APP=${TAMLIL_APP:-/Applications/Tamlil.app/Contents/MacOS/Tamlil}
notify() { "$TAMLIL_APP" --notify "$1" >/dev/null 2>&1 || true; }
fail() { notify "Update failed: $1"; exit 1; }

[ -d "$DIR/.git" ] || fail "no checkout at $DIR"
cd "$DIR"

# Gate on commit identity, not CFBundleShortVersionString: releases ship as
# squash snapshots and the version string is bumped by hand, so it wouldn't
# move on most snapshots. A new upstream commit is the exact update signal.
before=$(git rev-parse HEAD)
git pull --ff-only || fail "git pull (diverged? resolve in $DIR)"
after=$(git rev-parse HEAD)
if [ "$before" = "$after" ]; then
  notify "Already up to date"
  exit 0
fi

export PATH="$HOME/.local/bin:$PATH"
uv sync || fail "uv sync"
uv tool install --force . || fail "uv tool install"
make app || fail "build"

# Boot the agent out before killing: its KeepAlive.Crashed treats a signal
# death as a crash and would respawn the old binary mid-replace.
launchctl bootout "gui/$(id -u)/dev.dashevsky.tamlil" 2>/dev/null || true
pkill -x Tamlil 2>/dev/null || true
rm -rf /Applications/Tamlil.app
cp -R Tamlil/dist/Tamlil.app /Applications/
notify "Updated to $(git rev-parse --short HEAD) — relaunching"
scripts/launch-agent.sh restart || fail "launch agent"
