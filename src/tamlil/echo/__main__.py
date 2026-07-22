# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

"""Dev CLI: re-run echo suppression on a recording's merged.raw.json.

python -m tamlil.echo <recording-dir> [--write]
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from tamlil.echo import suppress_with_report
from tamlil.recording_layout import RecordingLayout

if __name__ == "__main__":
    d = Path(sys.argv[1])
    layout = RecordingLayout(d)
    doc = json.loads(layout.work_merged_raw.read_text(encoding="utf-8"))
    before = len(doc["segments"])
    result = suppress_with_report(d, doc["segments"])
    doc["segments"] = result["segments"]
    doc["echo_report"] = result["report"]
    doc["text"] = " ".join(s["text"] for s in doc["segments"]).strip()
    if "--write" in sys.argv:
        layout.work_merged_raw.write_text(
            json.dumps(doc, ensure_ascii=False, indent=2), encoding="utf-8"
        )
    print(f"{before} -> {len(doc['segments'])} segments")
