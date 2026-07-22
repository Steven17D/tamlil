#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0
#
# Insert the Apache-2.0 SPDX header into every first-party Python, Swift, and
# shell source that lacks one. Idempotent: files that already carry
# the identifier are left untouched, so this is safe to re-run after adding new
# sources. The header goes after a `#!` shebang or a `// swift-tools-version:`
# line so those stay first; otherwise it goes at the very top. Third-party and
# vendored files (the RNNoise asset, the fetched ffmpeg) are never stamped —
# their provenance is tracked separately in NOTICE / THIRD_PARTY_LICENSES.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

marker='SPDX-License-Identifier: Apache-2.0'
copyright='Copyright 2026 Steven Dashevsky'

emit_header() {
  local c="$1" # comment prefix: # or //
  printf '%s SPDX-FileCopyrightText: %s\n' "$c" "$copyright"
  printf '%s %s\n' "$c" "$marker"
  printf '\n'
}

stamp() {
  local f="$1" c="$2"
  grep -q "$marker" "$f" && return 0
  local first tmp
  first=$(head -1 "$f")
  tmp=$(mktemp)
  case "$first" in
  '#!'* | '// swift-tools-version:'*)
    # Keep the shebang / tools-version line first, header on the next lines.
    { head -1 "$f"; emit_header "$c"; tail -n +2 "$f"; } >"$tmp" ;;
  *)
    { emit_header "$c"; cat "$f"; } >"$tmp" ;;
  esac
  # Write back through the existing file so its mode (e.g. +x) is preserved.
  cat "$tmp" >"$f"
  rm -f "$tmp"
  echo "stamped: $f"
}

while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
  *.swift) stamp "$f" '//' ;;
  *) stamp "$f" '#' ;;
  esac
done < <(git ls-files '*.py' '*.swift' '*.sh' .githooks/pre-push)
