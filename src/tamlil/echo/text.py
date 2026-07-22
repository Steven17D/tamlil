# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

"""Text-level cross-track reconciliation: near-duplicate detection between the
mic and system transcripts, the per-voice echo statistics that promote a whole
diarized voice to "remote", and the retiming of a remote segment onto the mic
copy that said it first. Operates on segment dicts (text + timing), never audio.
"""

from __future__ import annotations

import re
from difflib import SequenceMatcher

import numpy as np

from .report import _record_drop

TEXT_WINDOW_S = 8.0  # Soniox per-track timestamps can skew by a few seconds
TEXT_MIN_CHARS = 24  # don't drop short backchannels like "yes" / "נכון"
TEXT_SIMILARITY_MIN = 0.94
LOCAL_ECHO_TEXT_MIN_CHARS = 12
LOCAL_ECHO_DELAY_TOL_S = 0.5
VOICE_ECHO_MIN_DUPLICATES = 2
# Dropping a whole diarized voice is destructive, and duplicate share cannot
# justify it: on a speakers-on call diarization misfiles bleed into the local
# speaker's cluster, and the genuine voice's duplicate share (0.36 on
# 2026-07-22, which cost the user their entire side) lands right next to a
# real bleed voice's (0.38). What does separate them is how much the voice
# said
# that the remote track has no copy of: bleed voices measure 5-11% unique
# characters, a genuine speaker ~47%. Promote a voice to remote only when
# almost nothing it said is unique to the mic.
VOICE_ECHO_MAX_UNIQUE_RATIO = 0.2
# A garbled transcription of bleed fails TEXT_SIMILARITY_MIN yet still tracks
# the clean system copy at this looser bar, so it must not count as unique.
VOICE_ECHO_LOOSE_SIMILARITY = 0.7
# Segments shorter than this are too short to judge either way; they count
# toward the voice's total but never as unique evidence.
VOICE_ECHO_UNIQUE_MIN_CHARS = 12
RETIME_TEXT_SIMILARITY_MIN = 0.82


def _normalized_text(text: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s]", " ", text.casefold())).strip()


def _is_text_echo(seg: dict, them: list[dict], accept=None) -> bool:
    text = _normalized_text(seg.get("text", ""))
    if len(text) < TEXT_MIN_CHARS:
        return False
    for remote in them:
        if abs(float(seg["start"]) - float(remote["start"])) > TEXT_WINDOW_S:
            continue
        if accept is not None and not accept(remote):
            continue
        remote_text = _normalized_text(remote.get("text", ""))
        if len(remote_text) < TEXT_MIN_CHARS:
            continue
        if SequenceMatcher(None, text, remote_text).ratio() >= TEXT_SIMILARITY_MIN:
            return True
    return False


def _text_similarity(a: str, b: str) -> float:
    return SequenceMatcher(None, _normalized_text(a), _normalized_text(b)).ratio()


def _best_nearby_similarity(seg: dict, them: list[dict], accept=None) -> float:
    """Best fuzzy similarity between a segment and any nearby remote segment
    the ``accept`` gate allows; 0.0 when nothing qualifies."""
    best = 0.0
    for remote in them:
        if abs(float(seg["start"]) - float(remote["start"])) > TEXT_WINDOW_S:
            continue
        if accept is not None and not accept(remote):
            continue
        best = max(best, _text_similarity(seg.get("text", ""), remote.get("text", "")))
    return best


def _is_voice_remote_echo(voice: str | None, remote_voices: set[str]) -> bool:
    return voice is not None and str(voice) in remote_voices


def _retime_remote_from_mic_echo(segments: list[dict], remote_voices: set[str]) -> None:
    if not remote_voices:
        return
    them = [(i, s) for i, s in enumerate(segments) if s.get("speaker") == "Them"]
    if not them:
        return
    for mic in segments:
        if (
            mic.get("speaker") == "Them"
            or mic.get("voice") is None
            or str(mic["voice"]) not in remote_voices
        ):
            continue
        best = None
        for them_pos, (remote_i, remote) in enumerate(them):
            if abs(float(mic["start"]) - float(remote["start"])) > TEXT_WINDOW_S:
                continue
            score = _text_similarity(mic.get("text", ""), remote.get("text", ""))
            if score < RETIME_TEXT_SIMILARITY_MIN:
                continue
            if best is None or score > best[0]:
                best = (score, them_pos, remote_i, remote)
        if best is None:
            continue
        _, them_pos, _, remote = best
        prev_end = float(them[them_pos - 1][1]["end"]) if them_pos > 0 else None
        next_start = float(them[them_pos + 1][1]["start"]) if them_pos + 1 < len(them) else None
        new_start = float(mic["start"])
        new_end = float(mic["end"])
        if prev_end is not None and new_start < prev_end:
            continue
        if next_start is not None and new_end > next_start:
            continue
        remote["audio_start"] = remote.get("audio_start", remote["start"])
        remote["audio_end"] = remote.get("audio_end", remote["end"])
        remote["start"] = new_start
        remote["end"] = new_end


def _local_system_echo_ids(
    segments: list[dict], remote_voices: set[str], skip_pair=None
) -> set[int]:
    """System segments that echo local mic speech (mic said it first). A pair
    ``skip_pair`` claims for the playback direction is contradictory evidence
    -- the mic copy is the echo there -- and never deletes the system copy."""
    if not remote_voices:
        return set()
    local_mic = [
        s
        for s in segments
        if s.get("speaker") != "Them" and not _is_voice_remote_echo(s.get("voice"), remote_voices)
    ]
    if not local_mic:
        return set()

    robust_matches: list[tuple[int, float]] = []
    for i, remote in enumerate(segments):
        if remote.get("speaker") != "Them":
            continue
        remote_text = _normalized_text(remote.get("text", ""))
        if len(remote_text) < LOCAL_ECHO_TEXT_MIN_CHARS:
            continue
        best = None
        for mic in local_mic:
            delta = float(remote["start"]) - float(mic["start"])
            if delta < 0 or delta > TEXT_WINDOW_S:
                continue
            if skip_pair is not None and skip_pair(mic, remote):
                continue
            mic_text = _normalized_text(mic.get("text", ""))
            if len(mic_text) < LOCAL_ECHO_TEXT_MIN_CHARS:
                continue
            score = SequenceMatcher(None, mic_text, remote_text).ratio()
            if score < TEXT_SIMILARITY_MIN:
                continue
            if best is None or score > best[0]:
                best = (score, delta)
        if best is not None:
            robust_matches.append((i, best[1]))

    ids = {i for i, _ in robust_matches}
    if not robust_matches:
        return ids
    learned_delay = float(np.median([delta for _, delta in robust_matches]))

    for i, remote in enumerate(segments):
        if i in ids or remote.get("speaker") != "Them":
            continue
        remote_text = _normalized_text(remote.get("text", ""))
        if not remote_text or len(remote_text) >= LOCAL_ECHO_TEXT_MIN_CHARS:
            continue
        for mic in local_mic:
            delta = float(remote["start"]) - float(mic["start"])
            if abs(delta - learned_delay) > LOCAL_ECHO_DELAY_TOL_S:
                continue
            if skip_pair is not None and skip_pair(mic, remote):
                continue
            if _normalized_text(mic.get("text", "")) == remote_text:
                ids.add(i)
                break
    return ids


def _playback_pair_test(delays_s: dict[str, float] | None):
    """The pair-direction gate: does a (mic, remote) duplicate's time offset
    say playback (mic copy is the echo)? Without measured delays every pair
    resolves to playback (the legacy, mic-drops behavior); with them, a pair
    is playback only when its offset sits closer to the playback delay than
    the rebroadcast one."""
    playback = (delays_s or {}).get("playback")
    rebroadcast = (delays_s or {}).get("rebroadcast")
    directional = delays_s is not None

    def is_playback_pair(mic_seg: dict, remote: dict) -> bool:
        if not directional:
            return True
        if playback is None:
            return False
        if rebroadcast is None:
            return True
        delta = float(remote["start"]) - float(mic_seg["start"])
        return abs(delta - playback) <= abs(delta - rebroadcast)

    return is_playback_pair


def _suppress_text_echo(
    segments: list[dict], report: dict, delays_s: dict[str, float] | None = None
) -> tuple[list[dict], set[str]]:
    """Text-level dedup across the tracks. Without measured delays (no audio)
    this is the legacy behavior: a mic near-duplicate of a "Them" segment is
    echo and the mic copy drops. With measured delays each duplicate pair is
    assigned to the direction its time offset matches: playback pairs drop the
    mic copy (and feed the remote-voice rule); rebroadcast pairs drop the
    system copy — the mic said it first.

    Returns (kept segments, mic voices judged genuine) so the acoustic pass
    can tell a genuine voice's doubletalk from bleed."""
    them = [s for s in segments if s.get("speaker") == "Them"]
    if not them:
        return segments, set()
    playback = (delays_s or {}).get("playback")
    rebroadcast = (delays_s or {}).get("rebroadcast")
    directional = delays_s is not None
    is_playback_pair = _playback_pair_test(delays_s)

    voice_stats: dict[str, dict[str, int]] = {}
    text_duplicate_ids = set()
    for i, s in enumerate(segments):
        if s.get("speaker") == "Them":
            continue
        accept = lambda remote, mic_seg=s: is_playback_pair(mic_seg, remote)  # noqa: E731
        text_len = len(_normalized_text(s.get("text", "")))
        is_text_duplicate = _is_text_echo(s, them, accept=accept)
        if is_text_duplicate:
            text_duplicate_ids.add(i)
        if s.get("voice") is None:
            continue
        voice = str(s["voice"])
        stats = voice_stats.setdefault(voice, {"chars": 0, "duplicates": 0, "unique_chars": 0})
        stats["chars"] += text_len
        if is_text_duplicate:
            stats["duplicates"] += 1
        elif (
            text_len >= VOICE_ECHO_UNIQUE_MIN_CHARS
            and _best_nearby_similarity(s, them, accept=accept) < VOICE_ECHO_LOOSE_SIMILARITY
        ):
            stats["unique_chars"] += text_len

    unique_ratios = {
        voice: stats["unique_chars"] / max(1, stats["chars"])
        for voice, stats in voice_stats.items()
    }
    remote_voices = {
        voice
        for voice, stats in voice_stats.items()
        if len(voice_stats) > 1
        and stats["duplicates"] >= VOICE_ECHO_MIN_DUPLICATES
        and unique_ratios[voice] < VOICE_ECHO_MAX_UNIQUE_RATIO
    }
    # The user is in the meeting, so at least one mic voice is genuine: if the
    # rule would delete every one of them, it is misreading the meeting -- spare
    # the voice with the most unique content and let the per-segment checks
    # handle its duplicates.
    if remote_voices and remote_voices == set(voice_stats):
        remote_voices.discard(max(remote_voices, key=lambda v: unique_ratios[v]))
    if voice_stats:
        report["mic_voices"] = {
            voice: {
                "chars": stats["chars"],
                "duplicates": stats["duplicates"],
                "unique_ratio": round(unique_ratios[voice], 3),
                "remote": voice in remote_voices,
            }
            for voice, stats in voice_stats.items()
        }
    _retime_remote_from_mic_echo(segments, remote_voices)
    if not directional or playback is not None:
        system_local_echo_ids = _local_system_echo_ids(
            segments, remote_voices, skip_pair=is_playback_pair if directional else None
        )
    else:
        system_local_echo_ids = set()

    rebroadcast_ids: set[int] = set()
    if directional and rebroadcast is not None:
        mic_segs = [s for s in segments if s.get("speaker") != "Them"]
        for i, remote in enumerate(segments):
            if remote.get("speaker") != "Them" or i in system_local_echo_ids:
                continue
            remote_text = _normalized_text(remote.get("text", ""))
            if len(remote_text) < TEXT_MIN_CHARS:
                continue
            for mic_seg in mic_segs:
                delta = float(remote["start"]) - float(mic_seg["start"])
                if abs(delta - rebroadcast) > TEXT_WINDOW_S:
                    continue
                if is_playback_pair(mic_seg, remote):
                    continue
                mic_text = _normalized_text(mic_seg.get("text", ""))
                if len(mic_text) < TEXT_MIN_CHARS:
                    continue
                if SequenceMatcher(None, mic_text, remote_text).ratio() >= TEXT_SIMILARITY_MIN:
                    rebroadcast_ids.add(i)
                    break
        # Backchannels are too short for fuzzy matching or waveform
        # correlation; an exact text match one rebroadcast delay after a mic
        # segment is still the returning copy.
        for i, remote in enumerate(segments):
            if (
                remote.get("speaker") != "Them"
                or i in rebroadcast_ids
                or i in system_local_echo_ids
            ):
                continue
            remote_text = _normalized_text(remote.get("text", ""))
            if not remote_text or len(remote_text) >= TEXT_MIN_CHARS:
                continue
            for mic_seg in mic_segs:
                delta = float(remote["start"]) - float(mic_seg["start"])
                if abs(delta - rebroadcast) > LOCAL_ECHO_DELAY_TOL_S:
                    continue
                if _normalized_text(mic_seg.get("text", "")) == remote_text:
                    rebroadcast_ids.add(i)
                    break

    kept = []
    for i, s in enumerate(segments):
        if i in system_local_echo_ids:
            _record_drop(report, s, "system_local_echo")
            continue
        if i in rebroadcast_ids:
            _record_drop(report, s, "rebroadcast_duplicate")
            continue
        if i in text_duplicate_ids and (
            s.get("voice") is None
            or _is_voice_remote_echo(s.get("voice"), remote_voices)
            or not remote_voices
        ):
            _record_drop(report, s, "text_duplicate")
            continue
        if s.get("speaker") != "Them" and _is_voice_remote_echo(s.get("voice"), remote_voices):
            _record_drop(report, s, "diarized_remote_voice")
            continue
        kept.append(s)
    local_voices = set(voice_stats) - remote_voices
    return sorted(kept, key=lambda s: s["start"]), local_voices
