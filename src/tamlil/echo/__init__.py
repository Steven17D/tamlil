# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

"""Reconcile the two tracks: drop each utterance's secondary cross-track copy.

Speech can cross between the mic and system tracks along two paths, told apart
by the sign of the mic<->system lag:

  - playback echo: the meeting app plays remote participants through the
    speakers and the mic re-records them tens of milliseconds later. The
    system copy is primary; the mic copy drops.
  - rebroadcast: room speech reaches other in-room participants' meeting
    clients and returns in the app's output a network round trip (~1-2 s)
    later. The mic copy is primary; the system copy drops. Getting this
    direction wrong deletes the primary record of an all-in-one-room meeting.
    Rebroadcast can only happen when the mic shares a room with participants
    the meeting app echoes back, so it is gated on ``shared_room``: a
    remote-only call has no such path, and a spurious mic-leads envelope peak
    there (conversational turn-taking correlates just as well) must not be
    allowed to delete the clean remote copy.

Both delays are estimated per session by envelope cross-correlation, each
direction gated on its own confidence. Per segment, classification is
acoustic (waveform NCC at the measured delay): a garbled or hallucinated
transcription of a copy still has matching audio. Text near-duplicates back
this up, each pair assigned to the direction its time offset matches; the
voice-level remote rule (drop a whole diarized mic voice) only ever acts on
playback-direction evidence, and never deletes every mic voice. For a voice
the text stage judged genuine, an acoustic match alone is not echo — the
user talking over remote playback correlates at the playback delay too — so
those segments drop only when their words also track the remote track.

Best-effort: if the audio can't be decoded, only long nearby text duplicates
are dropped (legacy behavior, mic side).

This is a package split along four concern seams — ``dsp`` (waveform math),
``text`` (near-duplicate detection + retiming), ``report`` (drop bookkeeping)
— with the orchestration, audio I/O (``_load``) and the public surface
(``suppress_with_report``, ``enrich_report_with_alignment``) kept here. The
submodule symbols are re-exported so ``tamlil.echo.<name>`` keeps working.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import numpy as np

from ..recording_layout import RecordingLayout
from ..util import ffmpeg_path
from .dsp import (
    BROAD_DELAY_FPS,
    BROAD_DELAY_MAX_S,
    BROAD_DELAY_MIN_CONFIDENCE,
    LAG_TOL_S,
    MAX_LAG_S,
    MIN_DUR,
    NCC_MIN,
    PLAYBACK_LAG_S,
    REBROADCAST_LAG_S,
    REBROADCAST_LAG_TOL_S,
    REBROADCAST_NCC_MIN,
    SEARCH_S,
    SECONDARY_VALLEY_RATIO,
    SR,
    _correlation_curve,
    _directional_delays,
    _energy_envelope,
    _estimate_broad_delay,
    _estimate_delay,
    _is_echo,
    _is_rebroadcast,
    _peak_ncc,
)
from .report import (
    _empty_report,
    _log_report,
    _record_drop,
    report_has_alignment,
)
from .text import (
    LOCAL_ECHO_DELAY_TOL_S,
    LOCAL_ECHO_TEXT_MIN_CHARS,
    RETIME_TEXT_SIMILARITY_MIN,
    TEXT_MIN_CHARS,
    TEXT_SIMILARITY_MIN,
    TEXT_WINDOW_S,
    VOICE_ECHO_LOOSE_SIMILARITY,
    VOICE_ECHO_MAX_UNIQUE_RATIO,
    VOICE_ECHO_MIN_DUPLICATES,
    VOICE_ECHO_UNIQUE_MIN_CHARS,
    _best_nearby_similarity,
    _is_text_echo,
    _is_voice_remote_echo,
    _local_system_echo_ids,
    _normalized_text,
    _playback_pair_test,
    _retime_remote_from_mic_echo,
    _suppress_text_echo,
    _text_similarity,
)

# Re-export the full surface so `from tamlil import echo; echo.<name>` (and the
# tests that monkeypatch echo._load / echo._estimate_broad_delay) keep working
# after the split into dsp / text / report submodules.
__all__ = [
    "BROAD_DELAY_FPS",
    "BROAD_DELAY_MAX_S",
    "BROAD_DELAY_MIN_CONFIDENCE",
    "LAG_TOL_S",
    "LOCAL_ECHO_DELAY_TOL_S",
    "LOCAL_ECHO_TEXT_MIN_CHARS",
    "MAX_LAG_S",
    "MIN_DUR",
    "NCC_MIN",
    "PLAYBACK_LAG_S",
    "REBROADCAST_LAG_S",
    "REBROADCAST_LAG_TOL_S",
    "REBROADCAST_NCC_MIN",
    "RETIME_TEXT_SIMILARITY_MIN",
    "SEARCH_S",
    "SECONDARY_VALLEY_RATIO",
    "SR",
    "TEXT_MIN_CHARS",
    "TEXT_SIMILARITY_MIN",
    "TEXT_WINDOW_S",
    "VOICE_ECHO_LOOSE_SIMILARITY",
    "VOICE_ECHO_MAX_UNIQUE_RATIO",
    "VOICE_ECHO_MIN_DUPLICATES",
    "VOICE_ECHO_UNIQUE_MIN_CHARS",
    "_best_nearby_similarity",
    "_correlation_curve",
    "_directional_delays",
    "_empty_report",
    "_energy_envelope",
    "_estimate_broad_delay",
    "_estimate_delay",
    "_is_echo",
    "_is_rebroadcast",
    "_is_text_echo",
    "_is_voice_remote_echo",
    "_load",
    "_local_system_echo_ids",
    "_log_report",
    "_normalized_text",
    "_peak_ncc",
    "_playback_pair_test",
    "_record_drop",
    "_retime_remote_from_mic_echo",
    "_suppress",
    "_suppress_text_echo",
    "_text_similarity",
    "enrich_report_with_alignment",
    "report_has_alignment",
    "suppress_with_report",
]


def _load(path: Path) -> np.ndarray | None:
    ff = ffmpeg_path()
    if not (ff and path.exists()):
        return None
    try:
        proc = subprocess.run(
            [ff, "-v", "error", "-i", str(path), "-ac", "1", "-ar", str(SR), "-f", "s16le", "-"],
            capture_output=True,
            timeout=300,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    a = np.frombuffer(proc.stdout, dtype=np.int16).astype(np.float32) / 32768.0
    return a if len(a) else None


def enrich_report_with_alignment(meeting_dir: Path, report: dict) -> dict:
    if report_has_alignment(report):
        return report
    layout = RecordingLayout(meeting_dir)
    mic = _load(layout.raw_mic_audio)
    sysv = _load(layout.raw_system_audio)
    if mic is None or sysv is None:
        return report
    broad = _estimate_broad_delay(mic, sysv)
    if broad is None:
        return report
    tau, confidence = broad
    enriched = dict(report)
    enriched["system_mic_offset_s"] = tau / SR
    enriched["system_mic_offset_source"] = "broad_envelope"
    enriched["system_mic_offset_confidence"] = confidence
    return enriched


def suppress_with_report(
    meeting_dir: Path, segments: list[dict], *, shared_room: bool = True
) -> dict:
    """Return {"segments", "report"} after echo suppression.

    ``shared_room`` reflects whether the meeting had co-located participants
    (a booked room). When it is false the mic can only be re-recording remote
    playback, so the destructive rebroadcast direction (drop the clean system
    copy) is disabled and cross-track duplicates resolve as playback instead.
    """
    report = _empty_report()
    try:
        return _suppress(meeting_dir, segments, report, shared_room=shared_room)
    except Exception as e:  # noqa: BLE001 - echo suppression must never break the pipeline
        print(f"== echo: suppression failed ({e}); keeping all segments ==", file=sys.stderr)
        report["error"] = str(e)
        return {"segments": segments, "report": report}


def _suppress(
    meeting_dir: Path, segments: list[dict], report: dict, *, shared_room: bool = True
) -> dict:
    layout = RecordingLayout(meeting_dir)
    mic = _load(layout.raw_mic_audio)
    sysv = _load(layout.raw_system_audio)
    them = [s for s in segments if s.get("speaker") == "Them"]
    if mic is None or sysv is None or not them:
        kept, _ = _suppress_text_echo(segments, report)
        _log_report(report)
        return {"segments": kept, "report": report}

    delays = _directional_delays(mic, sysv)
    if not shared_room:
        # No shared room => no rebroadcast path. Drop the rebroadcast direction
        # so a spurious mic-leads peak can't delete the clean remote copy; what
        # remains routes through the playback/legacy fallbacks below, which drop
        # the mic copy of a cross-track duplicate instead.
        delays.pop("rebroadcast", None)
    source = "broad_envelope"
    if not delays:
        tau = _estimate_delay(mic, sysv, them)
        if tau is not None:
            delays = {"playback": (tau, None)}  # type: ignore[dict-item]  # None confidence handled downstream
            source = "segment_correlation"
    if not delays:
        kept, _ = _suppress_text_echo(segments, report)
        _log_report(report)
        return {"segments": kept, "report": report}

    dominant_tau, dominant_conf = max(delays.values(), key=lambda d: -1.0 if d[1] is None else d[1])
    report["system_mic_offset_s"] = dominant_tau / SR
    report["system_mic_offset_source"] = source
    if dominant_conf is not None:
        report["system_mic_offset_confidence"] = dominant_conf

    delays_s = {name: tau / SR for name, (tau, _) in delays.items()}
    kept, local_voices = _suppress_text_echo(segments, report, delays_s)

    playback = delays.get("playback")
    rebroadcast = delays.get("rebroadcast")
    is_playback_pair = _playback_pair_test(delays_s)
    reconciled = []
    for s in kept:
        if s.get("speaker") != "Them":
            # A mic segment whose copy shows up one rebroadcast delay later is
            # the room original — never echo, whatever else it matches.
            if (
                playback is not None
                and _is_echo(mic, sysv, playback[0], s)
                and not (rebroadcast is not None and _is_echo(mic, sysv, rebroadcast[0], s))
            ):
                # A genuine voice speaking over remote playback correlates at
                # the playback delay too (the bleed is in the same slice), so
                # doubletalk needs the words to corroborate: unique text from
                # a judged-genuine voice is the user, not echo.
                if str(s.get("voice")) in local_voices and (
                    _best_nearby_similarity(
                        s, them, accept=lambda remote, mic_seg=s: is_playback_pair(mic_seg, remote)
                    )
                    < VOICE_ECHO_LOOSE_SIMILARITY
                ):
                    reconciled.append(s)
                    continue
                _record_drop(report, s, "acoustic_echo")
                continue
        elif rebroadcast is not None and _is_rebroadcast(mic, sysv, rebroadcast[0], s):
            _record_drop(report, s, "rebroadcast")
            continue
        reconciled.append(s)

    detail = ", ".join(f"{name} {tau / SR * 1000:.0f}ms" for name, (tau, _) in delays.items())
    _log_report(report, f", delay {detail} ({source})")
    return {"segments": reconciled, "report": report}
