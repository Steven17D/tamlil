#!/bin/zsh
# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

# Build Tamlil.app from the SwiftPM executable and ad-hoc sign it.
# TCC permission grants (mic, system audio) are keyed to the bundle id and
# survive rebuilds as long as the signature stays consistent.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=dist/Tamlil.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Tamlil "$APP/Contents/MacOS/Tamlil"
cp Info.plist "$APP/Contents/Info.plist"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "built: $PWD/$APP"
echo "install: cp -R $APP /Applications/ && ../scripts/launch-agent.sh restart"
