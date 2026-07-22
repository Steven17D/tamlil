#!/bin/zsh
# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

# Tamlil installer for a fresh machine. One command:
#
#   curl -fsSL https://raw.githubusercontent.com/Steven17D/tamlil/main/scripts/install.sh | zsh
#
# Clones, builds, installs the app, puts the read-only MCP server on your PATH,
# and walks through the Soniox API key. Safe to re-run; an existing checkout is
# reused.
set -euo pipefail
autoload -Uz is-at-least

# Persistent home for an installed copy: the repo lives next to the app's own
# data under Application Support, not in a dev-style ~/Projects checkout.
DIR=${TAMLIL_DIR:-$HOME/Library/Application Support/Tamlil/repo}
BUNDLE_ID=dev.dashevsky.tamlil
MIN_MACOS=15.0   # LSMinimumSystemVersion; Core Audio process taps need 14.4+
MIN_SWIFT=6.0    # Package.swift declares swift-tools-version 6.0

step() { print -P "%F{cyan}==>%f $1"; }
warn() { print -P "%F{yellow}!!%f $1"; }
die() { print -u2 "$1"; exit 1; }

step "Checking prerequisites"

# macOS floor: the app won't run below 15.0 even if it builds, and the
# system-audio process tap silently fails on older releases.
os=$(sw_vers -productVersion)
is-at-least "$MIN_MACOS" "$os" \
  || die "macOS $MIN_MACOS+ required (Sequoia); this machine is $os."

# Apple Silicon only is tested; the static ffmpeg + rnnoise model and the
# native build are validated on arm64. Warn rather than block on Intel.
arch=$(uname -m)
[ "$arch" = "arm64" ] \
  || warn "Untested architecture '$arch' (Apple Silicon expected) — continuing."

if ! xcode-select -p >/dev/null 2>&1; then
  xcode-select --install >/dev/null 2>&1 || true
  die "Command Line Tools install started — rerun this script when it finishes."
fi

# git ships with the Command Line Tools but the clone/pull below depends on it
# directly, so fail loudly if it is somehow absent.
command -v git >/dev/null 2>&1 || die "git required (comes with the Command Line Tools)."

# swift build needs a Swift 6 toolchain; older CLT (pre-16) has Swift 5 and
# `make app` would fail deep in the build with a confusing error.
swift_ver=$(swift --version 2>/dev/null \
  | grep -oE 'Swift version [0-9]+(\.[0-9]+)+' | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)
[ -n "$swift_ver" ] \
  || die "Swift toolchain not found; install/repair the Command Line Tools: xcode-select --install"
is-at-least "$MIN_SWIFT" "$swift_ver" \
  || die "Swift $MIN_SWIFT+ required; found $swift_ver. Update the Command Line Tools (need CLT 16+)."

if ! command -v uv >/dev/null 2>&1; then
  step "Installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

if [ -d "$DIR/.git" ]; then
  step "Updating existing checkout at $DIR"
  git -C "$DIR" pull --ff-only
else
  step "Cloning into $DIR"
  mkdir -p "$(dirname "$DIR")"
  GIT_TERMINAL_PROMPT=0 git clone https://github.com/Steven17D/tamlil.git "$DIR" \
    || { command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 \
         && gh repo clone Steven17D/tamlil "$DIR"; } \
    || die "Clone failed — see git's error above."
fi
cd "$DIR"

step "Installing Python dependencies"
uv sync

# Warm the static ffmpeg binary now so the first recording's denoise/echo
# stages don't stall on a download (or fail offline) mid-pipeline.
step "Fetching the bundled ffmpeg"
if ! uv run python -c "from tamlil.util import ffmpeg_path; raise SystemExit(0 if ffmpeg_path() else 1)" >/dev/null 2>&1; then
  warn "Could not pre-fetch ffmpeg; it will download on first transcription (needs network)."
fi

step "Installing the MCP server on PATH (tamlil-mcp)"
uv tool install --force .
export PATH="$HOME/.local/bin:$PATH"
step "Building Tamlil.app"
make app
step "Installing to /Applications"
# Boot the agent out before killing: its KeepAlive.Crashed treats a signal
# death as a crash and would respawn the old binary mid-replace. The trailing
# launch-agent restart bootstraps it again against the new build.
launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
pkill -x Tamlil 2>/dev/null || true
rm -rf /Applications/Tamlil.app
cp -R Tamlil/dist/Tamlil.app /Applications/

# Point the pipeline at this checkout (the app has no baked-in default).
defaults write "$BUNDLE_ID" repoPath "$DIR"

# Register the read-only MCP at user scope so any Claude session can query
# recordings. The default db/recordings paths the server resolves are exactly
# the app's, so no env is needed. Absolute path so Claude can spawn it
# regardless of its own PATH.
if command -v claude >/dev/null 2>&1; then
  step "Registering the Tamlil MCP with Claude Code"
  MCP_BIN=$(command -v tamlil-mcp || print "$HOME/.local/bin/tamlil-mcp")
  claude mcp remove tamlil -s user >/dev/null 2>&1 || true
  claude mcp add tamlil --scope user -- "$MCP_BIN"
else
  step "Claude Code not found — skipping MCP registration (run: claude mcp add tamlil --scope user -- $HOME/.local/bin/tamlil-mcp)"
fi

if security find-generic-password -s tamlil-soniox -w >/dev/null 2>&1; then
  step "Soniox API key already in the Keychain"
else
  step "Soniox API key needed (console.soniox.com > API keys)"
  read -rs "key?Paste key (input hidden): " < /dev/tty
  print ""
  [ -n "$key" ] || die "No key entered. Add it later with:
  security add-generic-password -s tamlil-soniox -a soniox -w '<KEY>' -U"
  security add-generic-password -s tamlil-soniox -a soniox -w "$key" -U
  step "Key stored as Keychain item tamlil-soniox"
fi

if security find-generic-password -s tamlil-google -w >/dev/null 2>&1; then
  # A refresh token alone is not enough: refreshing it needs the OAuth client
  # (bring-your-own), which lives per-checkout and is absent in a fresh clone.
  if uv run python -c "from tamlil.google_client import configured; raise SystemExit(0 if configured() else 1)" 2>/dev/null; then
    step "Google Calendar already connected"
  else
    warn "Google refresh token found but no OAuth client in this checkout — roster lookups will fail. See docs/google-calendar-setup.md."
  fi
else
  step "Connecting Google Calendar (opens a browser to consent)"
  if ! uv run tamlil-auth; then
    step "Skipped Google Calendar — connect later from Settings or: uv run tamlil-auth"
  fi
fi

# Absolute path: GNU coreutils (Homebrew/Nix) shadows `id` and lacks -F.
step "Transcripts will label your side as: $(/usr/bin/id -F | cut -d' ' -f1)"
step "Launching under crash supervision — approve Microphone and System Audio Recording when prompted"
scripts/launch-agent.sh restart
