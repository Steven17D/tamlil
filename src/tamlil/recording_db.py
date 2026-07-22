# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

"""SQLite state updates for the Tamlil app-owned recording database."""

from __future__ import annotations

import json
import os
import sqlite3
from pathlib import Path
from typing import Any


class RecordingDB:
    def __init__(self, path: str | Path | None, recording_id: str | None):
        self.path = Path(path) if path else None
        self.recording_id = recording_id

    @classmethod
    def from_env(cls, recording_dir: str | Path) -> RecordingDB:
        return cls(
            os.environ.get("TAMLIL_DB_PATH"),
            os.environ.get("TAMLIL_RECORDING_ID") or Path(recording_dir).name,
        )

    @property
    def enabled(self) -> bool:
        return bool(self.path and self.recording_id)

    def set_state(self, state: str, stage: str | None = None) -> None:
        if not self.enabled:
            return
        self._execute(
            "UPDATE recordings SET state = ?, stage = ? WHERE id = ?",
            (state, stage, self.recording_id),
        )

    def set_roster(self, title: str, attendees: list[str], rooms: list[str]) -> None:
        if not self.enabled:
            return
        self._execute(
            """
            UPDATE recordings
            SET event_title = ?, roster_json = ?, rooms_json = ?
            WHERE id = ?
            """,
            (
                title,
                json.dumps(attendees, ensure_ascii=False),
                json.dumps(rooms, ensure_ascii=False),
                self.recording_id,
            ),
        )

    def set_transcription_engine(self, engine: str | None) -> None:
        if not self.enabled:
            return
        # The column is added at most once (older app DBs predate it); the
        # per-run path is then a plain UPDATE rather than an ALTER every call.
        self._ensure_column("recordings", "transcription_engine", "TEXT")
        self._execute(
            "UPDATE recordings SET transcription_engine = ? WHERE id = ?",
            (engine, self.recording_id),
        )

    def save_clarifications(self, cards: list[dict[str, Any]]) -> None:
        if not self.enabled:
            return
        self._execute(
            """
            INSERT INTO clarifications (recording_id, json) VALUES (?, ?)
            ON CONFLICT(recording_id) DO UPDATE SET json = excluded.json
            """,
            (self.recording_id, json.dumps(cards, ensure_ascii=False, indent=2)),
        )

    def get_speaker_names(self) -> dict[str, str]:
        """User-assigned voice -> name map for this recording (empty if the app
        never named anyone, the db is disabled, or the table predates naming)."""
        if not self.enabled:
            return {}
        assert self.path is not None
        con = sqlite3.connect(self.path)
        try:
            rows = con.execute(
                "SELECT voice, name FROM speaker_names WHERE recording_id = ?",
                (self.recording_id,),
            ).fetchall()
        except sqlite3.OperationalError:
            return {}
        finally:
            con.close()
        return dict(rows)

    def _ensure_column(self, table: str, column: str, decl: str) -> None:
        """Add a column only if the table lacks it, so the ALTER runs at most
        once. The duplicate-column guard still covers a writer racing us."""
        assert self.path is not None
        con = sqlite3.connect(self.path)
        try:
            existing = {row[1] for row in con.execute(f"PRAGMA table_info({table})")}
            if column in existing:
                return
            try:
                con.execute(f"ALTER TABLE {table} ADD COLUMN {column} {decl}")
            except sqlite3.OperationalError as e:
                if "duplicate column name" not in str(e):
                    raise
            con.commit()
        finally:
            con.close()

    def _execute(self, sql: str, params: tuple) -> None:
        assert self.path is not None
        con = sqlite3.connect(self.path)
        try:
            con.execute(sql, params)
            con.commit()
        finally:
            con.close()
