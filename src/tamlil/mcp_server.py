# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

"""Read-only MCP server exposing Tamlil meetings to agents.

Claude Code / Codex connect over stdio and pull meeting metadata and
transcripts; summarization and analysis happen on the agent side. The server
never mutates your data: the SQLite database is opened read-only and the
recording artifacts under TAMLIL_RECORDINGS_ROOT are only ever read.

The one thing it does write is a rendered copy of the transcript a caller
asked for, into a private per-user scratch dir (see _rendered_transcript_path),
so an agent can page through a long meeting with file tools instead of loading
it all into context. That file holds the same transcript text the caller is
already reading, is created 0600 inside a 0700 dir this user owns, and is
overwritten on each call — never a new secret and never world-readable.

Storage locations match the app's defaults and honor the same overrides:
  TAMLIL_DB_PATH           ~/Library/Application Support/Tamlil/tamlil.sqlite
  TAMLIL_RECORDINGS_ROOT   ~/Recordings/Tamlil

Register with Claude Code:
  claude mcp add tamlil -- uv run --project <repo> tamlil-mcp
Codex (~/.codex/config.toml):
  [mcp_servers.tamlil]
  command = "uv"
  args = ["run", "--project", "<repo>", "tamlil-mcp"]
"""

from __future__ import annotations

import json
import os
import sqlite3
import stat
import tempfile
from contextlib import closing
from datetime import datetime
from pathlib import Path

from mcp.server.fastmcp import FastMCP

from . import speaker_labels
from .recording_layout import RecordingLayout
from .util import fmt_clock

mcp = FastMCP("tamlil")

_COLUMNS = (
    "id, directory, app, started_at, ended_at, state, stage, "
    "event_title, roster_json, transcription_engine"
)


def db_path() -> Path:
    return Path(
        os.environ.get("TAMLIL_DB_PATH")
        or Path.home() / "Library/Application Support/Tamlil/tamlil.sqlite"
    )


def recordings_root() -> Path:
    return Path(os.environ.get("TAMLIL_RECORDINGS_ROOT") or Path.home() / "Recordings/Tamlil")


def _validate_meeting_id(meeting_id: str) -> str:
    """Reject anything that isn't a plain recording-dir basename.

    Meeting ids are directory names the app minted (e.g. '2026-06-10-zoom').
    A caller-supplied id also names the on-disk render file, so a path
    separator, a '..', or a control character has no legitimate place in one —
    rejecting them here keeps the render write (_rendered_transcript_path)
    inside its scratch dir no matter what an agent passes.
    """
    if (
        not meeting_id
        or ".." in meeting_id
        or "/" in meeting_id
        or "\\" in meeting_id
        or any(ord(c) < 0x20 for c in meeting_id)
    ):
        raise ValueError(f"invalid meeting id: {meeting_id!r}")
    return meeting_id


def _connect() -> sqlite3.Connection:
    path = db_path()
    if not path.exists():
        raise FileNotFoundError(
            f"Tamlil database not found at {path} — has the app recorded anything yet?"
        )
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    return con


def _duration_seconds(started: str | None, ended: str | None) -> float | None:
    if not started or not ended:
        return None
    try:
        delta = datetime.fromisoformat(ended) - datetime.fromisoformat(started)
    except ValueError:
        return None
    return round(delta.total_seconds(), 1)


def _meeting_dict(row: sqlite3.Row) -> dict:
    return {
        "id": row["id"],
        "app": row["app"],
        "title": row["event_title"] or None,
        "started_at": row["started_at"],
        "ended_at": row["ended_at"],
        "duration_seconds": _duration_seconds(row["started_at"], row["ended_at"]),
        "state": row["state"],
        "stage": row["stage"],
        "roster": json.loads(row["roster_json"]) if row["roster_json"] else [],
        "engine": row["transcription_engine"],
    }


def _layout(row: sqlite3.Row) -> RecordingLayout:
    stored = Path(row["directory"])
    if stored.is_dir():
        return RecordingLayout(stored)
    # The db may come from another machine (or a staged copy); fall back to
    # resolving the recording id under the local recordings root.
    return RecordingLayout(recordings_root() / row["id"])


def _row(con: sqlite3.Connection, meeting_id: str) -> sqlite3.Row:
    row = con.execute(f"SELECT {_COLUMNS} FROM recordings WHERE id = ?", (meeting_id,)).fetchone()
    if row is None:
        raise ValueError(f"no meeting with id {meeting_id!r}")
    return row


def _segments(layout: RecordingLayout) -> list[dict]:
    for path in (layout.final_transcript_json, layout.work_merged_raw):
        if path.exists():
            try:
                return json.loads(path.read_text(encoding="utf-8")).get("segments", [])
            except (json.JSONDecodeError, OSError):
                # A single corrupt/unreadable transcript must not abort a
                # cross-meeting search; treat it as having no segments.
                return []
    return []


def _speaker_names(con: sqlite3.Connection, meeting_id: str) -> dict[str, str]:
    rows = con.execute(
        "SELECT voice, name FROM speaker_names WHERE recording_id = ?", (meeting_id,)
    ).fetchall()
    return {r["voice"]: r["name"] for r in rows}


def _transcript_lines(
    seg_list: list[dict],
    names: dict[str, str],
    voice_counts: dict[str, int] | None = None,
    roster: list[str] | None = None,
) -> list[str]:
    # voice_counts must reflect the whole meeting, not the lines being rendered:
    # search excerpts pass a subset of segments but the "Speaker N" decision
    # has to match the full transcript's labelling.
    if voice_counts is None:
        voice_counts = speaker_labels.voice_counts(seg_list)
    return [
        f"[{fmt_clock(s.get('start', 0.0))}] "
        f"{speaker_labels.label(s, names, voice_counts, roster)}: {s.get('text', '')}"
        for s in seg_list
    ]


@mcp.tool()
def list_meetings(
    limit: int = 20,
    from_date: str | None = None,
    to_date: str | None = None,
    app: str | None = None,
) -> list[dict]:
    """List recorded meetings, newest first.

    from_date/to_date are inclusive ISO dates (YYYY-MM-DD); app filters on the
    meeting app name (case-insensitive substring, e.g. "zoom").
    """
    sql = f"SELECT {_COLUMNS} FROM recordings"
    where: list[str] = []
    params: list[object] = []  # SQL bind values: date/text filters plus the int LIMIT
    if from_date:
        where.append("date(started_at) >= ?")
        params.append(from_date)
    if to_date:
        where.append("date(started_at) <= ?")
        params.append(to_date)
    if app:
        where.append("lower(app) LIKE ?")
        params.append(f"%{app.lower()}%")
    if where:
        sql += " WHERE " + " AND ".join(where)
    sql += " ORDER BY started_at DESC LIMIT ?"
    params.append(max(1, min(int(limit), 200)))
    with closing(_connect()) as con:
        return [_meeting_dict(r) for r in con.execute(sql, params).fetchall()]


@mcp.tool()
def get_meeting(meeting_id: str) -> dict:
    """Full metadata for one meeting: roster, named speakers, transcript
    availability, and pending clarification count."""
    _validate_meeting_id(meeting_id)
    with closing(_connect()) as con:
        row = _row(con, meeting_id)
        meeting = _meeting_dict(row)
        meeting["speaker_names"] = _speaker_names(con, meeting_id)
        cl = con.execute(
            "SELECT json FROM clarifications WHERE recording_id = ?", (meeting_id,)
        ).fetchone()
        cards = json.loads(cl["json"]) if cl else []
        meeting["clarifications_pending"] = sum(1 for c in cards if c.get("status") == "pending")
        layout = _layout(row)
        meeting["has_transcript"] = (
            layout.final_transcript_json.exists() or layout.work_merged_raw.exists()
        )
        return meeting


def _render_cache_dir() -> Path:
    """A private scratch dir for rendered transcripts, mode 0700, this-user-owned.

    tempfile.gettempdir() may resolve to a world-writable location (/tmp when
    TMPDIR is unset), so we cannot trust the ambient perms: create the dir 0700,
    tighten it if it pre-existed looser, and refuse to render into it if it is a
    symlink or owned by anyone else — the transcript can carry customer speech.
    """
    cache = Path(tempfile.gettempdir()) / "tamlil-mcp"
    cache.mkdir(mode=0o700, exist_ok=True)
    info = cache.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise RuntimeError(f"refusing to render into {cache}: not a directory this user owns")
    os.chmod(cache, 0o700)
    return cache


def _rendered_transcript_path(meeting_id: str, body: str) -> Path:
    # Render the resolved transcript to a temp file so an agent can read just
    # the ranges it needs instead of pulling a long meeting into context. This
    # is NOT the recordings dir: the on-disk final/transcript.md is written at
    # pipeline time and lacks app-assigned speaker names + roster collapse, so
    # it must be re-rendered here from the live db labels. Overwrite every call
    # to stay fresh when names change. meeting_id is validated at the tool entry
    # so it is a single path component; write 0600 and never follow a symlink at
    # the final name, so a co-tenant can neither read nor pre-plant the target.
    path = _render_cache_dir() / f"{_validate_meeting_id(meeting_id)}.transcript.md"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(body)
    os.chmod(path, 0o600)
    return path


@mcp.tool()
def get_transcript(meeting_id: str, offset: int = 0, limit: int | None = None) -> dict:
    """The meeting transcript, with resolved speaker names and clock timestamps.

    By default this does NOT return the transcript text — a long meeting would
    flood your context. It returns metadata plus `path`: a rendered transcript
    file you should open with your own file tools, reading only the ranges you
    need. To pull lines inline instead (e.g. no filesystem access), pass `limit`
    (and optional `offset`) to get that slice of segment lines directly.
    """
    _validate_meeting_id(meeting_id)
    with closing(_connect()) as con:
        row = _row(con, meeting_id)
        names = _speaker_names(con, meeting_id)
        roster = _meeting_dict(row)["roster"]
    seg_list = _segments(_layout(row))
    if not seg_list:
        raise ValueError(f"meeting {meeting_id!r} has no transcript (state: {row['state']})")
    lines = _transcript_lines(seg_list, names, roster=roster)
    vc = speaker_labels.voice_counts(seg_list)
    info = {
        "meeting_id": meeting_id,
        "segment_count": len(lines),
        "duration_seconds": _duration_seconds(row["started_at"], row["ended_at"]),
        "speakers": sorted({speaker_labels.label(s, names, vc, roster) for s in seg_list}),
    }
    if limit is not None:
        start = max(0, offset)
        sliced = lines[start : start + max(0, limit)]
        return info | {
            "offset": start,
            "returned": len(sliced),
            "has_more": start + len(sliced) < len(lines),
            "lines": sliced,
        }
    return info | {
        "path": str(_rendered_transcript_path(meeting_id, "\n".join(lines) + "\n")),
        "preview": lines[:8],
        "hint": "Read `path` (supports offset/limit) for the full transcript, "
        "or call get_transcript again with `limit`/`offset` for inline lines.",
    }


@mcp.tool()
def search_transcripts(query: str, limit: int = 10) -> list[dict]:
    """Search all transcripts for a phrase (case-insensitive). Returns matching
    meetings, newest first, with the matching transcript lines as excerpts."""
    needle = query.strip().casefold()
    if not needle:
        raise ValueError("empty query")
    results: list[dict] = []
    with closing(_connect()) as con:
        rows = con.execute(f"SELECT {_COLUMNS} FROM recordings ORDER BY started_at DESC").fetchall()
        for row in rows:
            seg_list = _segments(_layout(row))
            hits = [s for s in seg_list if needle in s.get("text", "").casefold()]
            if not hits:
                continue
            names = _speaker_names(con, row["id"])
            roster = _meeting_dict(row)["roster"]
            results.append(
                _meeting_dict(row)
                | {
                    "excerpts": _transcript_lines(
                        hits[:5], names, speaker_labels.voice_counts(seg_list), roster
                    ),
                    "match_count": len(hits),
                }
            )
            if len(results) >= max(1, min(int(limit), 50)):
                break
    return results


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
