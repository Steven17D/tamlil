# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

"""Resolve display names for transcript speakers.

Shared by the pipeline (the static ``final/transcript.md``) and the MCP server
(live-rendered transcript lines) so both agree on how a track/voice becomes a
human name: a user-assigned name wins, then an unambiguous one-on-one calendar
attendee, then a diarized "Speaker N", and finally the raw track identity.
"""

from __future__ import annotations

import os

from . import util


def sole_remote_attendee(roster: list[str]) -> str | None:
    """The one attendee who is not the local user, or None if that is ambiguous."""
    full = util.account_full_name().casefold()
    local = (full.split() or [os.environ.get("USER", "").casefold()])[0]
    others = [name for name in roster if name.casefold() != local and name.casefold() not in full]
    return others[0] if len(others) == 1 else None


def voice_counts(segments: list[dict]) -> dict[str, int]:
    """Distinct diarized voices per track (keyed by the segment "speaker"
    identity). Per-track counts keep the solo UX intact: a mic track with one
    voice is just the local user, however many voices the system track has."""
    tracks: dict[str, set] = {}
    for s in segments:
        if s.get("voice") is not None and s.get("speaker") is not None:
            tracks.setdefault(s["speaker"], set()).add(str(s["voice"]))
    return {track: len(voices) for track, voices in tracks.items()}


def mic_heard_multiple_voices(segments: list[dict]) -> bool:
    """True when the mic track diarized more than one voice -- co-located people
    in one room, the acoustic signature of a shared room. Calendar-independent:
    it holds for a booked room and for an unplanned huddle alike. The system
    track's own voice count is irrelevant (that is just the remote side)."""
    return any(track != "Them" and count > 1 for track, count in voice_counts(segments).items())


def renumber_voices(segments: list[dict]) -> dict:
    """Rewrite diarized voice ids into one sequential keyspace ("1", "2", ...)
    by first appearance, so mic and system voices can't collide in the
    speaker_names table. Idempotent, so --skip-transcribe re-runs are stable.
    Returns the (track, original voice) -> new voice map."""
    mapping: dict[tuple[str | None, str], str] = {}
    for s in segments:
        if (voice := s.get("voice")) is None:
            continue
        key = (s.get("speaker"), str(voice))
        if key not in mapping:
            mapping[key] = str(len(mapping) + 1)
        s["voice"] = mapping[key]
    return mapping


def label(
    seg: dict, names: dict[str, str], voices: dict[str, int], roster: list[str] | None = None
) -> str:
    """Display name for one segment. Mirrors the app's speakerDisplayName: a
    user-assigned name wins; for a system voice an unambiguous one-on-one
    roster wins over fragmented diarization; otherwise an unnamed diarized
    voice gets "Speaker N" only when its track heard several voices — a mic
    track with one voice stays the local user's name."""
    voice = seg.get("voice")
    track = seg.get("speaker")
    if voice is not None:
        if str(voice) in names:
            return names[str(voice)]
        if track == "Them" and roster and (name := sole_remote_attendee(roster)):
            return name
        if voices.get(track, 0) > 1:  # type: ignore[arg-type]  # track may be None; dict.get handles it
            return f"Speaker {voice}"
    return track or "?"
