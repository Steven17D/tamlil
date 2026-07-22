#!/bin/zsh
# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

# Install and control Tamlil's user LaunchAgent.
#
# The agent starts Tamlil at login and relaunches it only after a crash. A
# normal Quit exits with status 0, so launchd leaves it closed.
set -euo pipefail

LABEL=dev.dashevsky.tamlil
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP=/Applications/Tamlil.app/Contents/MacOS/Tamlil
LOG_DIR="$HOME/Library/Logs/Tamlil"
DOMAIN="gui/$(id -u)"

write_plist() {
  mkdir -p "$(dirname "$PLIST")" "$LOG_DIR"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>Crashed</key>
    <true/>
  </dict>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/launchd.err.log</string>
</dict>
</plist>
EOF
}

bootout_agent() {
  /bin/launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 \
    || /bin/launchctl bootout "$DOMAIN" "$PLIST" >/dev/null 2>&1 \
    || true
}

bootstrap_agent() {
  /bin/launchctl bootstrap "$DOMAIN" "$PLIST"
}

case "${1:-install}" in
  install)
    write_plist
    ;;
  restart)
    [ -x "$APP" ] || { print -u2 "missing executable: $APP"; exit 1; }
    write_plist
    bootout_agent
    bootstrap_agent
    ;;
  uninstall)
    bootout_agent
    rm -f "$PLIST"
    ;;
  status)
    /bin/launchctl print "$DOMAIN/$LABEL"
    ;;
  *)
    print -u2 "usage: $0 [install|restart|uninstall|status]"
    exit 2
    ;;
esac
