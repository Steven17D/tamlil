# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

"""Collapse ASR hallucination loops: runs of near-identical filler segments.

On chaotic audio (overlapping speakers, meeting-app echo mush) the ASR decoder
can fall into a repetition loop, emitting hundreds of consecutive segments that
all say the same one or two filler words — many with start == end and the
diarizer flapping between voices. Word confidence does not separate these from
real speech, but the structure does: no human produces the same short utterance
in five-plus consecutive segments with nothing else in between on one track.

Detection is per track (the "speaker" field): a run is a maximal sequence of
consecutive segments whose combined vocabulary stays within a few distinct
words (single-letter split-word fragments don't count). A vocabulary of one or
two words collapses when the run is extremely long, whatever its timestamps;
any run collapses once it holds several degenerate segments — near-zero
duration, or the same word crammed in many times over ("אה" eleven times in
300 ms) — since real speech never produces those, however long the
plausible-looking tail around them stretches. A collapsed run keeps its first
segment. Finally, a loop tail welded onto a real utterance is squeezed in
place: a word repeated four-plus times in a row inside one segment keeps a
single instance.
"""

from __future__ import annotations

import re

RUN_MIN = 5  # shortest run that can collapse...
DEGENERATE_MIN = 3  # ...when it holds this many degenerate segments
RUN_MIN_ANY = 10  # 1-2 word runs this long collapse regardless
NEAR_ZERO_S = 0.05  # below the ASR's own timestamp grid
MAX_DISTINCT_WORDS = 3
LOOP_VOCABULARY_MAX = 2  # vocabulary small enough for the length-only rule
REPEAT_MIN = 4  # same word this often in one segment = stutter

_REPEAT_RE = re.compile(rf"(\S+)(?:\s+\1){{{REPEAT_MIN - 1},}}")


def _words(text: str) -> frozenset[str]:
    return frozenset(w for w in re.findall(r"\w+", text.casefold()) if len(w) > 1)


def _is_degenerate(seg: dict) -> bool:
    if float(seg["end"]) - float(seg["start"]) < NEAR_ZERO_S:
        return True
    counts: dict[str, int] = {}
    for w in re.findall(r"\w+", seg["text"].casefold()):
        counts[w] = counts.get(w, 0) + 1
    return bool(counts) and max(counts.values()) >= REPEAT_MIN


def _run_collapses(run: list[dict], vocabulary: frozenset[str]) -> bool:
    if len(vocabulary) <= LOOP_VOCABULARY_MAX and len(run) >= RUN_MIN_ANY:
        return True
    if len(run) < RUN_MIN:
        return False
    return sum(1 for s in run if _is_degenerate(s)) >= DEGENERATE_MIN


def collapse_loops(segments: list[dict]) -> dict:
    """Return {"segments", "report"} with hallucination runs collapsed to their
    first segment. Segment order is preserved."""
    report: dict = {"dropped": 0, "runs": [], "squeezed": 0}
    drop_ids: set[int] = set()

    by_track: dict[str | None, list[int]] = {}
    for i, seg in enumerate(segments):
        by_track.setdefault(seg.get("speaker"), []).append(i)

    for track_ids in by_track.values():
        run: list[int] = []
        run_words: frozenset[str] = frozenset()

        def close_run() -> None:
            nonlocal run, run_words
            run_segs = [segments[i] for i in run]
            if _run_collapses(run_segs, run_words):
                drop_ids.update(run[1:])
                report["dropped"] += len(run) - 1
                report["runs"].append(
                    {
                        "speaker": run_segs[0].get("speaker"),
                        "start": run_segs[0]["start"],
                        "end": run_segs[-1]["end"],
                        "text": run_segs[0]["text"],
                        "count": len(run),
                    }
                )
            run = []
            run_words = frozenset()

        for i in track_ids:
            has_text = bool(segments[i]["text"].strip())
            words = _words(segments[i]["text"])
            merged = run_words | words
            if has_text and len(merged) <= MAX_DISTINCT_WORDS:
                run.append(i)
                run_words = merged
            else:
                close_run()
                if has_text and len(words) <= MAX_DISTINCT_WORDS:
                    run = [i]
                    run_words = words
        close_run()

    kept = [s for i, s in enumerate(segments) if i not in drop_ids]
    for s in kept:
        squeezed = _REPEAT_RE.sub(r"\1", s["text"])
        if squeezed != s["text"]:
            s["text"] = squeezed
            report["squeezed"] += 1
    return {"segments": kept, "report": report}
