#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

# Build and run the empty-environment install simulation for the Tamlil MCP.
# Covers the consumer data-access path only; the macOS app needs a real Mac.
set -euo pipefail
cd "$(dirname "$0")/../.."

# Apple's `container` (Containerization framework) is a Docker-compatible
# runtime for Linux guests on Apple Silicon — preferred on a Docker-Desktop-free
# machine. Override with CONTAINER_RUNTIME=docker if both are installed.
RUNTIME=${CONTAINER_RUNTIME:-}
if [ -z "$RUNTIME" ]; then
  if command -v container >/dev/null 2>&1; then RUNTIME=container
  elif command -v docker >/dev/null 2>&1; then RUNTIME=docker
  else echo "need docker or Apple's container CLI" >&2; exit 1
  fi
fi

"$RUNTIME" build -f test/container/Dockerfile -t tamlil-install-test .
"$RUNTIME" run --rm tamlil-install-test
