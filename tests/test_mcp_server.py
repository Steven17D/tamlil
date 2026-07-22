# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

import json
import os
import sqlite3
import stat
import types
from pathlib import Path

import pytest

from tamlil import mcp_server, util
from tamlil.recording_layout import RecordingLayout

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


def _insert(
    con, rec_id, directory, started, ended, *, app="zoom.us", state="done", title=None, roster=None
):
    con.execute(
        "INSERT INTO recordings (id, directory, app, bundle_id, started_at,"
        " ended_at, state, stage, event_title, roster_json, rooms_json,"
        " transcription_engine) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, NULL, 'soniox')",
        (
            rec_id,
            str(directory),
            app,
            "us.zoom.xos",
            started,
            ended,
            state,
            title,
            json.dumps(roster) if roster else None,
        ),
    )


@pytest.fixture(autouse=True)
def _local_account(monkeypatch):
    # Pin the local account name so sole-attendee resolution (the roster's local
    # entry filtered out) is machine-independent regardless of who runs the suite.
    monkeypatch.setattr(
        util.pwd,
        "getpwuid",
        lambda _uid: types.SimpleNamespace(pw_gecos="Alice Smith,,,"),
    )


@pytest.fixture
def staged(tmp_path, monkeypatch):
    root = tmp_path / "recordings"
    db = tmp_path / "tamlil.sqlite"
    monkeypatch.setenv("TAMLIL_DB_PATH", str(db))
    monkeypatch.setenv("TAMLIL_RECORDINGS_ROOT", str(root))

    con = sqlite3.connect(db)
    con.executescript(SCHEMA)

    a = root / "2026-06-10-zoom"
    layout = RecordingLayout(a)
    layout.prepare()
    layout.final_transcript_json.write_text(
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
    _insert(
        con,
        "2026-06-10-zoom",
        a,
        "2026-06-10T10:00:00Z",
        "2026-06-10T10:30:00Z",
        title="Deploy review",
        roster=["Maya", "Alice"],
    )
    con.execute("INSERT INTO speaker_names VALUES ('2026-06-10-zoom', '1', 'Maya')")
    con.execute(
        "INSERT INTO clarifications VALUES ('2026-06-10-zoom', ?)",
        (
            json.dumps(
                [{"original": "x", "status": "pending"}, {"original": "y", "status": "resolved"}]
            ),
        ),
    )

    b = root / "2026-06-11-meet"
    RecordingLayout(b).prepare()
    _insert(
        con,
        "2026-06-11-meet",
        b,
        "2026-06-11T09:00:00Z",
        None,
        app="Google Meet",
        state="recording",
    )

    con.commit()
    con.close()
    return root


def test_list_meetings_orders_and_filters(staged):
    meetings = mcp_server.list_meetings()
    assert [m["id"] for m in meetings] == ["2026-06-11-meet", "2026-06-10-zoom"]
    assert meetings[1]["title"] == "Deploy review"
    assert meetings[1]["duration_seconds"] == 1800.0
    assert meetings[1]["roster"] == ["Maya", "Alice"]

    assert [m["id"] for m in mcp_server.list_meetings(app="zoom")] == ["2026-06-10-zoom"]
    assert [m["id"] for m in mcp_server.list_meetings(to_date="2026-06-10")] == ["2026-06-10-zoom"]
    assert [m["id"] for m in mcp_server.list_meetings(from_date="2026-06-11")] == [
        "2026-06-11-meet"
    ]


def test_get_meeting_reports_clarifications_and_transcript(staged):
    meeting = mcp_server.get_meeting("2026-06-10-zoom")
    assert meeting["clarifications_pending"] == 1
    assert meeting["has_transcript"] is True
    assert meeting["speaker_names"] == {"1": "Maya"}

    assert mcp_server.get_meeting("2026-06-11-meet")["has_transcript"] is False
    with pytest.raises(ValueError):
        mcp_server.get_meeting("nope")


RESOLVED_LINES = [
    "[0:00] Me: let's review the deploy",
    "[0:02] Maya: the pipeline is green",
    "[0:05] Maya: ship it after standup",
]


def test_get_transcript_returns_path_and_metadata(staged):
    result = mcp_server.get_transcript("2026-06-10-zoom")
    assert "lines" not in result  # default must not dump the transcript
    assert result["segment_count"] == 3
    assert result["duration_seconds"] == 1800.0
    assert result["speakers"] == ["Maya", "Me"]
    assert result["preview"] == RESOLVED_LINES
    assert Path(result["path"]).read_text(encoding="utf-8").splitlines() == RESOLVED_LINES

    with pytest.raises(ValueError, match="no transcript"):
        mcp_server.get_transcript("2026-06-11-meet")


def test_get_transcript_paginates_inline(staged):
    page = mcp_server.get_transcript("2026-06-10-zoom", offset=1, limit=1)
    assert page["lines"] == ["[0:02] Maya: the pipeline is green"]
    assert page["offset"] == 1
    assert page["returned"] == 1
    assert page["has_more"] is True
    assert "path" not in page

    last = mcp_server.get_transcript("2026-06-10-zoom", offset=2, limit=10)
    assert last["lines"] == ["[0:05] Maya: ship it after standup"]
    assert last["has_more"] is False


def test_get_transcript_resolves_speakers(staged):
    assert mcp_server.get_transcript("2026-06-10-zoom", limit=100)["lines"] == RESOLVED_LINES


def test_get_transcript_collapses_fragmented_voices_for_one_remote_attendee(staged):
    layout = RecordingLayout(staged / "2026-06-11-meet")
    layout.final_transcript_json.write_text(
        json.dumps(
            {
                "segments": [
                    {"start": 0.0, "end": 1.0, "text": "first", "speaker": "Them", "voice": "1"},
                    {
                        "start": 2.0,
                        "end": 3.0,
                        "text": "same person",
                        "speaker": "Them",
                        "voice": "6",
                    },
                ],
            }
        ),
        encoding="utf-8",
    )

    db = sqlite3.connect(Path(staged).parent / "tamlil.sqlite")
    db.execute(
        "UPDATE recordings SET state = 'done', roster_json = ? WHERE id = ?",
        (json.dumps(["Maya", "Alice"]), "2026-06-11-meet"),
    )
    db.commit()
    db.close()

    assert mcp_server.get_transcript("2026-06-11-meet", limit=100)["lines"] == [
        "[0:00] Maya: first",
        "[0:02] Maya: same person",
    ]


def test_get_transcript_falls_back_to_merged_raw(staged):
    layout = RecordingLayout(staged / "2026-06-11-meet")
    layout.work_merged_raw.write_text(
        json.dumps(
            {
                "segments": [{"start": 0.0, "end": 1.0, "text": "hello", "speaker": "Me"}],
            }
        ),
        encoding="utf-8",
    )
    assert mcp_server.get_transcript("2026-06-11-meet", limit=100)["lines"] == ["[0:00] Me: hello"]


def test_search_transcripts_returns_excerpts(staged):
    hits = mcp_server.search_transcripts("PIPELINE")
    assert len(hits) == 1
    assert hits[0]["id"] == "2026-06-10-zoom"
    assert hits[0]["match_count"] == 1
    assert hits[0]["excerpts"] == ["[0:02] Maya: the pipeline is green"]
    assert mcp_server.search_transcripts("nonexistent phrase") == []
    with pytest.raises(ValueError):
        mcp_server.search_transcripts("   ")


def test_search_excerpt_labels_match_full_transcript(staged):
    # The "ship it" hit is voice 2 of a two-voice one-on-one meeting. The
    # excerpt must collapse it to the sole remote attendee, matching the full
    # transcript even though only one segment is rendered.
    hits = mcp_server.search_transcripts("ship it")
    assert hits[0]["excerpts"] == ["[0:05] Maya: ship it after standup"]


def test_search_tolerates_corrupt_transcript(staged):
    bad = RecordingLayout(staged / "2026-06-11-meet").final_transcript_json
    bad.write_text("{ not valid json", encoding="utf-8")
    hits = mcp_server.search_transcripts("pipeline")
    assert [h["id"] for h in hits] == ["2026-06-10-zoom"]


@pytest.mark.parametrize(
    "bad_id",
    ["../secret", "a/b", "..", "sub/../../etc/passwd", "id\x00.md", "back\\slash"],
)
def test_meeting_id_rejects_traversal(staged, bad_id):
    # A path separator, a '..', or a control char in a meeting id is rejected
    # before it can name a file or leave the render scratch dir.
    with pytest.raises(ValueError, match="invalid meeting id"):
        mcp_server.get_transcript(bad_id)
    with pytest.raises(ValueError, match="invalid meeting id"):
        mcp_server.get_meeting(bad_id)


def test_rendered_transcript_is_private(staged):
    result = mcp_server.get_transcript("2026-06-10-zoom")
    path = Path(result["path"])
    # The render stays inside the scratch dir under this recording's id.
    assert path.parent.name == "tamlil-mcp"
    assert path.name == "2026-06-10-zoom.transcript.md"
    # File 0600, dir 0700 — a co-tenant on the box cannot read the transcript.
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert stat.S_IMODE(path.parent.stat().st_mode) == 0o700
    assert path.parent.stat().st_uid == os.getuid()


def test_db_is_opened_read_only(staged, tmp_path):
    con = mcp_server._connect()
    with pytest.raises(sqlite3.OperationalError):
        con.execute("DELETE FROM recordings")
    con.close()


def test_missing_db_raises_helpful_error(monkeypatch, tmp_path):
    monkeypatch.setenv("TAMLIL_DB_PATH", str(tmp_path / "absent.sqlite"))
    with pytest.raises(FileNotFoundError, match="recorded anything"):
        mcp_server.list_meetings()
