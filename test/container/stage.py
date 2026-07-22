# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

"""Stage a minimal recordings db + transcript at TAMLIL_DB_PATH /
TAMLIL_RECORDINGS_ROOT so the MCP server has something to serve. Pure stdlib
(no tamlil import) so it runs before the package env exists. Mirrors the shape
of tests/test_mcp_server.py's fixture."""

import json
import os
import sqlite3
from pathlib import Path

SCHEMA = """
CREATE TABLE recordings (
  id TEXT PRIMARY KEY,
  directory TEXT NOT NULL UNIQUE,
  app TEXT NOT NULL,
  bundle_id TEXT NOT NULL,
  started_at TEXT NOT NULL,
  ended_at TEXT,
  state TEXT NOT NULL,
  stage TEXT,
  event_title TEXT,
  roster_json TEXT,
  rooms_json TEXT,
  transcription_engine TEXT
);
CREATE TABLE speaker_names (
  recording_id TEXT NOT NULL,
  voice TEXT NOT NULL,
  name TEXT NOT NULL,
  PRIMARY KEY (recording_id, voice)
);
CREATE TABLE clarifications (
  recording_id TEXT PRIMARY KEY,
  json TEXT NOT NULL
);
"""

REC_ID = "2026-06-10-zoom"
ROOT = Path(os.environ["TAMLIL_RECORDINGS_ROOT"])
DB = Path(os.environ["TAMLIL_DB_PATH"])

DB.parent.mkdir(parents=True, exist_ok=True)
rec_dir = ROOT / REC_ID
(rec_dir / "final").mkdir(parents=True, exist_ok=True)
(rec_dir / "final" / "transcript.json").write_text(
    json.dumps(
        {
            "segments": [
                {"start": 0.0, "end": 2.0, "text": "let's review the deploy", "speaker": "Me"},
                {
                    "start": 2.5,
                    "end": 5.0,
                    "text": "the pipeline is green",
                    "speaker": "Them",
                    "voice": "1",
                },
                {
                    "start": 5.5,
                    "end": 8.0,
                    "text": "ship it after standup",
                    "speaker": "Them",
                    "voice": "2",
                },
            ],
        }
    ),
    encoding="utf-8",
)

con = sqlite3.connect(DB)
con.executescript(SCHEMA)
con.execute(
    "INSERT INTO recordings (id, directory, app, bundle_id, started_at, ended_at,"
    " state, stage, event_title, roster_json, rooms_json, transcription_engine)"
    " VALUES (?, ?, 'zoom.us', 'us.zoom.xos', ?, ?, 'done', NULL, ?, ?, NULL, 'soniox')",
    (
        REC_ID,
        str(rec_dir),
        "2026-06-10T10:00:00Z",
        "2026-06-10T10:30:00Z",
        "Deploy review",
        json.dumps(["Maya", "Steven"]),
    ),
)
con.execute("INSERT INTO speaker_names VALUES (?, '1', 'Maya')", (REC_ID,))
con.commit()
con.close()
print(f"staged {REC_ID} at {rec_dir}")
