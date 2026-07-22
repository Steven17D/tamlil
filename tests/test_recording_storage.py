# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

import sqlite3

from tamlil import recording_db
from tamlil.recording_layout import RecordingLayout


def test_recording_layout_uses_ga_directories(tmp_path):
    layout = RecordingLayout(tmp_path / "2026-06-12-120000-Zoom")

    assert layout.raw_system == tmp_path / "2026-06-12-120000-Zoom/raw/system.wav"
    assert layout.raw_mic == tmp_path / "2026-06-12-120000-Zoom/raw/mic.wav"
    assert layout.work_system_asr == tmp_path / "2026-06-12-120000-Zoom/work/system.asr.json"
    assert layout.work_merged_raw == tmp_path / "2026-06-12-120000-Zoom/work/merged.raw.json"
    assert layout.final_transcript_json == tmp_path / "2026-06-12-120000-Zoom/final/transcript.json"
    assert layout.final_summary_md == tmp_path / "2026-06-12-120000-Zoom/final/summary.md"
    assert layout.pipeline_log == tmp_path / "2026-06-12-120000-Zoom/logs/pipeline.log"


def test_recording_layout_prepare_creates_directories(tmp_path):
    layout = RecordingLayout(tmp_path / "meeting")

    layout.prepare()

    assert layout.raw_dir.is_dir()
    assert layout.work_dir.is_dir()
    assert layout.final_dir.is_dir()
    assert layout.logs_dir.is_dir()


def test_recording_db_updates_state_stage_and_roster(tmp_path):
    db = tmp_path / "tamlil.sqlite"
    rec_id = "2026-06-12-120000-Zoom"
    con = sqlite3.connect(db)
    con.execute(
        """
        CREATE TABLE recordings (
          id TEXT PRIMARY KEY,
          directory TEXT NOT NULL,
          app TEXT NOT NULL,
          bundle_id TEXT NOT NULL,
          started_at TEXT NOT NULL,
          ended_at TEXT,
          state TEXT NOT NULL,
          stage TEXT,
          event_title TEXT,
          roster_json TEXT,
          rooms_json TEXT
        )
        """
    )
    con.execute(
        """
        INSERT INTO recordings
          (id, directory, app, bundle_id, started_at, state)
        VALUES (?, ?, 'Zoom', 'us.zoom.xos', '2026-06-12T12:00:00Z', 'recorded')
        """,
        (rec_id, str(tmp_path / rec_id)),
    )
    con.commit()
    con.close()

    store = recording_db.RecordingDB(db, rec_id)
    store.set_state("processing", "transcribing")
    store.set_roster("Planning", ["Alice", "Roy"], ["Room A"])
    store.set_state("done")

    row = (
        sqlite3.connect(db)
        .execute(
            "SELECT state, stage, event_title, roster_json, rooms_json "
            "FROM recordings WHERE id = ?",
            (rec_id,),
        )
        .fetchone()
    )
    assert row == ("done", None, "Planning", '["Alice", "Roy"]', '["Room A"]')


def test_set_transcription_engine_adds_column_once_then_updates(tmp_path, monkeypatch):
    db = tmp_path / "tamlil.sqlite"
    rec_id = "2026-06-12-120000-Zoom"
    con = sqlite3.connect(db)
    # An older app schema that predates the transcription_engine column.
    con.execute("CREATE TABLE recordings (id TEXT PRIMARY KEY, state TEXT NOT NULL)")
    con.execute("INSERT INTO recordings (id, state) VALUES (?, 'recorded')", (rec_id,))
    con.commit()
    con.close()

    store = recording_db.RecordingDB(db, rec_id)

    # Count how many times the gate actually issues an ALTER, across every
    # connection the store opens, via a counting Connection subclass.
    class _CountingConn(sqlite3.Connection):
        alters: list[str] = []

        def execute(self, sql, *a):
            if "ALTER TABLE" in sql:
                _CountingConn.alters.append(sql)
            return super().execute(sql, *a)

    real_connect = sqlite3.connect
    monkeypatch.setattr(
        recording_db.sqlite3,
        "connect",
        lambda p, *a, **k: real_connect(p, *a, factory=_CountingConn, **k),
    )

    store.set_transcription_engine("soniox")
    store.set_transcription_engine("mixed")  # second run: plain UPDATE, no ALTER

    assert len(_CountingConn.alters) == 1  # the column is added at most once
    engine = (
        real_connect(db)
        .execute("SELECT transcription_engine FROM recordings WHERE id = ?", (rec_id,))
        .fetchone()[0]
    )
    assert engine == "mixed"
