#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0
#
# SPDX header gate: every first-party Python, Swift, Objective-C, and shell
# source must carry an `SPDX-License-Identifier: Apache-2.0` line so a license
# scanner or SBOM bot can resolve per-file provenance. Run from `make check`
# and CI.
#
# Scope comes from `git ls-files`, so only tracked first-party sources are
# checked: build trees under Tamlil/.build/ and Tamlil/dist/ are gitignored and
# never listed, and vendored assets (the RNNoise model) are not code files.
# Populate missing headers with scripts/add-spdx.sh.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

marker='SPDX-License-Identifier: Apache-2.0'
missing=0

while IFS= read -r f; do
  [ -n "$f" ] || continue
  if ! grep -q "$marker" "$f"; then
    echo "missing SPDX header: $f"
    missing=1
  fi
done < <(git ls-files '*.py' '*.swift' '*.m' '*.h' '*.sh' .githooks/pre-push)

if [ "$missing" -ne 0 ]; then
  echo "error: the files above lack a '$marker' header; run scripts/add-spdx.sh" >&2
  exit 1
fi

echo "SPDX headers OK"
