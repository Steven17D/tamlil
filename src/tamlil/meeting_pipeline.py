# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

"""Process a recorded meeting directory into a transcript.

Input: a directory produced by the Tamlil menu bar app containing
  raw/system.wav   everyone else (process-tap capture of the meeting app)
  raw/mic.wav      the local user (optional)

Steps:
  1. transcribe each track with Soniox
  2. merge segments by start time, labeled Me / Them
  3. suppress mic echo of the system track
  4. write final/transcript.json and final/transcript.md

When launched by the app, state is reported into the app SQLite database via
TAMLIL_DB_PATH/TAMLIL_RECORDING_ID. Run from the repo root:
  uv run python meeting_pipeline.py <dir>
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import contextmanager, suppress
from pathlib import Path
from typing import NamedTuple

from . import codeswitch, hallucination, lexicon, recording_db, speaker_labels, transcribe_soniox
from .recording_layout import RecordingLayout
from .util import account_full_name, fmt_clock, load_terms, package_file


def default_me_name() -> str:
    """Speaker label for the mic track: first name from the macOS account's
    full name, then the login name, then "Me"."""
    full = account_full_name()
    first = full.split()[0] if full.split() else ""
    first = first or os.environ.get("USER", "") or "Me"
    return first.capitalize() if first.islower() else first


def tracks(layout: RecordingLayout, me_name: str) -> list[tuple[Path, str]]:
    return [(layout.raw_mic_audio, me_name), (layout.raw_system_audio, "Them")]


# The app surfaces `state` verbatim and keys on it ("processing", "done",
# "error:" prefix), so a failure message must stay a single bounded line.
ERROR_STATE_MAX_LEN = 300


def error_state(exc: BaseException) -> str:
    msg = " ".join((str(exc) or type(exc).__name__).split())
    if len(msg) > ERROR_STATE_MAX_LEN:
        msg = msg[: ERROR_STATE_MAX_LEN - 3] + "..."
    return f"error: {msg}"


class PipelineTimings:
    def __init__(self) -> None:
        self.started = time.monotonic()
        self.stages: dict[str, float] = {}
        # Name of the stage that raised, so a failed run still leaves a marker.
        self.failed_stage: str | None = None

    @contextmanager
    def measure(self, name: str, *, critical: bool = True):
        """Time a stage. On exception the innermost `critical` stage records
        itself as the failure point; best-effort stages pass critical=False so
        they never mark the run failed."""
        start = time.monotonic()
        try:
            yield
        except BaseException:
            if critical and self.failed_stage is None:
                self.failed_stage = name
            raise
        finally:
            self.stages[name] = round(self.stages.get(name, 0.0) + time.monotonic() - start, 3)

    def write(self, path: Path, *, failed_stage: str | None = None) -> None:
        data: dict[str, object] = dict(self.stages)
        data["total"] = round(time.monotonic() - self.started, 3)
        if failed_stage:
            data["failed_stage"] = failed_stage
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def engine_name(model: str | None) -> str | None:
    if model and model.startswith("soniox:"):
        return "soniox"
    return None


def overall_engine(docs: list[dict]) -> str | None:
    engines = {engine_name(d.get("model")) for d in docs}
    engines.discard(None)
    if not engines:
        return None
    return engines.pop() if len(engines) == 1 else "mixed"


# Soniox caps the whole context object at ~8000 tokens / ~10000 chars. Terms
# share that budget with the `general` metadata, so keep the joined terms well
# under it. Roster names are always kept; canonicals (pre-sorted by use) fill
# the remaining budget.
CONTEXT_TERMS_CHAR_BUDGET = 6000


def cap_context_terms(
    names: list[str], glossary: list[str], char_budget: int = CONTEXT_TERMS_CHAR_BUDGET
) -> list[str]:
    """Roster names first (always kept), then most-used canonicals until the
    joined length would exceed `char_budget`. `glossary` is pre-sorted by use."""
    seen = {n.casefold() for n in names}
    terms = list(names)
    used = sum(len(n) + 2 for n in names)  # +2 approximates the ", " join
    for term in glossary:
        if term.casefold() in seen:
            continue
        cost = len(term) + 2
        if used + cost > char_budget:
            break
        seen.add(term.casefold())
        terms.append(term)
        used += cost
    return terms


def meeting_metadata(title: str, names: list[str]) -> list[dict]:
    """Soniox context.general pairs: meeting title, participants, languages.
    Empty sections are skipped; languages is a fixed Hebrew/English hint."""
    general: list[dict] = []
    if title:
        general.append({"key": "meeting", "value": title})
    if names:
        general.append({"key": "participants", "value": ", ".join(names)})
    general.append({"key": "languages", "value": "Hebrew, English"})
    return general


def _load_asr_cache(path: Path) -> dict | None:
    """Return a previously written, still-decodable per-track ASR doc, or None
    if it is absent, unreadable, or malformed (so we re-transcribe it)."""
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return doc if isinstance(doc, dict) and isinstance(doc.get("segments"), list) else None


def transcribe_tracks(
    layout: RecordingLayout,
    terms: str,
    me_name: str,
    *,
    general: list[dict] | None = None,
    client_reference_id: str | None = None,
    report: dict | None = None,
) -> list[dict]:
    """Transcribe each present track; return segments tagged with speaker.

    The tracks are independent Soniox jobs, so they upload and transcribe
    concurrently, and each track's work/<track>.asr.json is written the moment
    its future completes. A track whose asr.json already decodes is reused
    rather than re-submitted (re-billed). If some but not all tracks fail the
    survivor is kept (single-track transcript); only an all-tracks failure
    raises. `report` (if given) is populated with the failed track names.
    `general` (meeting metadata) and `client_reference_id` are threaded into
    the Soniox context.
    """
    present = [(wav, speaker) for wav, speaker in tracks(layout, me_name) if wav.exists()]
    if not present:
        return []

    term_list = load_terms(terms)
    docs: dict[Path, dict] = {}
    failed: list[str] = []
    errors: list[str] = []

    # Reuse any track already transcribed (e.g. a prior crashed run) instead of
    # paying Soniox for it again; only submit the tracks still missing a result.
    pending: list[tuple[Path, str]] = []
    for wav, speaker in present:
        cached = _load_asr_cache(layout.asr_json_for(wav))
        if cached is not None:
            print(f"== reuse {layout.asr_json_for(wav).name} ==", file=sys.stderr)
            docs[wav] = cached
        else:
            pending.append((wav, speaker))

    if pending:
        with ThreadPoolExecutor(max_workers=len(pending)) as pool:
            futures = {
                pool.submit(
                    transcribe_soniox.transcribe_file,
                    str(wav),
                    terms=term_list,
                    general=general,
                    client_reference_id=client_reference_id,
                ): wav
                for wav, _ in pending
            }
            for future in as_completed(futures):
                wav = futures[future]
                try:
                    doc = future.result()
                except Exception as exc:  # noqa: BLE001 - isolate a single track's failure
                    failed.append(wav.name)
                    errors.append(f"{wav.name}: {exc}")
                    print(f"== transcribe {wav.name} FAILED: {exc} ==", file=sys.stderr)
                    continue
                docs[wav] = doc
                # Persist immediately so a later track failing (or a re-run)
                # reuses this result rather than re-billing it.
                layout.asr_json_for(wav).write_text(
                    json.dumps(doc, ensure_ascii=False, indent=2), encoding="utf-8"
                )

    if report is not None:
        report["failed_tracks"] = failed
        report["transcribed_tracks"] = [wav.name for wav, _ in present if wav in docs]

    if failed and not docs:
        raise RuntimeError(f"all {len(present)} track(s) failed transcription: {'; '.join(errors)}")

    merged: list[dict] = []
    for wav, speaker in present:
        doc = docs.get(wav)  # type: ignore[assignment]  # None means this track failed
        if doc is None:  # this track failed; continue single-track with the rest
            continue
        print(f"== transcribe {wav.name} ==", file=sys.stderr)
        for seg in doc["segments"]:
            # Diarization within the track (Soniox numeric ids) survives as
            # "voice"; "speaker" stays the track identity the rest of the
            # pipeline and the app key on.
            if (voice := seg.get("speaker")) is not None:
                seg["voice"] = str(voice)
            seg["speaker"] = speaker
            merged.append(seg)
    merged.sort(key=lambda s: s["start"])
    # Voice ids are fixed here, before any suppression stage, so they are a
    # pure function of the per-track ASR: a re-run over cached asr.json files
    # keeps every id even when changed suppression logic keeps different
    # segments. The app's user-assigned names are keyed by these ids, so a
    # renumbering would silently reattach names to the wrong people. A voice
    # dropped wholesale later just leaves a gap in the sequence.
    speaker_labels.renumber_voices(merged)
    return merged


def apply_lexicon_rules(segments: list[dict], lex: dict, base_terms: list[str]) -> int:
    """Rewrite known garbles in place via the learned lexicon; returns how many
    segments changed. This is what makes a Clarify confirmation pay off on every
    future meeting."""
    rules = lexicon.compile_rules(lex, base_terms=base_terms)
    changed = 0
    for seg in segments:
        fixed = lexicon.apply(seg["text"], rules)
        if fixed != seg["text"]:
            seg["text"] = fixed
            changed += 1
    return changed


def lookup_roster(db: recording_db.RecordingDB, started: str | None) -> dict:
    """Find the calendar event for this meeting and persist roster into SQLite."""
    from . import google_client
    from . import roster as roster_mod

    if not started:
        return {}
    if not google_client.configured():
        print(f"== roster skipped: {google_client.SETUP_HINT} ==", file=sys.stderr)
        return {}
    info = roster_mod.lookup(started)
    if info:
        db.set_roster(info.get("title", ""), info.get("attendees", []), info.get("rooms", []))
    return info


def asr_low_confidence_spans(layout: RecordingLayout, me_name: str) -> list[dict]:
    spans: list[dict] = []
    for path, speaker in ((layout.work_mic_asr, me_name), (layout.work_system_asr, "Them")):
        if not path.exists():
            continue
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue
        for span in doc.get("low_confidence", []):
            spans.append({**span, "speaker": speaker})
    return spans


def _matched_phrase(line: str, phrase: str) -> str | None:
    words = phrase.strip().split()
    if not words:
        return None
    pattern = r"(?<!\w)" + r"\s+".join(re.escape(w) for w in words) + r"(?!\w)"
    match = re.search(pattern, line, flags=re.IGNORECASE)
    return match.group(0) if match else None


def merge_low_confidence_cards(
    cards: list[dict], spans: list[dict], corrected_segments: list[dict]
) -> list[dict]:
    merged = list(cards)
    seen = {c.get("original", "").casefold() for c in cards if c.get("original")}
    for span in spans:
        phrase = span.get("text", "").strip()
        if not phrase or phrase.casefold() in seen:
            continue
        candidates = corrected_segments
        if span.get("speaker") is not None:
            same_speaker = [
                s for s in corrected_segments if s.get("speaker") == span.get("speaker")
            ]
            if same_speaker:
                candidates = same_speaker
        for seg in candidates:
            original = _matched_phrase(seg.get("text", ""), phrase)
            if original is None:
                continue
            merged.append(
                {
                    "original": original,
                    "severity": "unsure",
                    "context": seg.get("text", ""),
                    "status": "pending",
                    "start": seg.get("start"),
                    "end": seg.get("end"),
                    "speaker": seg.get("speaker"),
                    "source": "asr_confidence",
                    "confidence": span.get("confidence"),
                }
            )
            seen.add(original.casefold())
            break
    return merged


def build_clarification_cards(
    spans: list[dict], corrected_segments: list[dict], terms: list[str], lex: dict | None = None
) -> list[dict]:
    cards = merge_low_confidence_cards([], spans, corrected_segments)
    seen = {
        (c.get("original", "").casefold(), c.get("context", "")) for c in cards if c.get("original")
    }
    for card in codeswitch.find_cards(corrected_segments, terms):
        key = (card.get("original", "").casefold(), card.get("context", ""))
        if key in seen:
            continue
        seen.add(key)
        cards.append(card)
    # Never re-ask about a term the user already confirmed: a single-confirmation
    # variant stays in the transcript (apply() needs MIN_RULE_COUNT), but the
    # lexicon knows it, so it must not surface as a question again.
    if lex is not None:
        cards = [c for c in cards if not lexicon.knows(lex, c.get("original", ""))]
    return cards


def locate_term(card: dict, segments: list[dict]) -> dict:
    """Attach start/end/speaker of the segment where the flagged term was said.

    Anchors only to a segment that actually contains the term — that is the one
    the app can underline and play. Among those, the context quote disambiguates
    the right line when the term recurs. A card whose term appears in no segment
    is left unlocated (and later dropped), so the badge count and the in-app
    review list always agree.
    """
    needle = card.get("original", "").strip()
    if not needle:
        return card
    ctx = card.get("context", "").strip()[:40]
    seg = None
    if ctx:
        seg = next((s for s in segments if needle in s["text"] and ctx in s["text"]), None)
    if seg is None:
        seg = next((s for s in segments if needle in s["text"]), None)
    if seg is not None:
        card["start"] = seg["start"]
        card["end"] = seg["end"]
        card["speaker"] = seg.get("speaker")
    return card


def write_transcript_md(
    doc: dict, path: Path, *, names: dict[str, str] | None = None, roster: list[str] | None = None
) -> None:
    """Write final/transcript.md with the same speaker naming the app and MCP
    server use (assigned name > sole calendar attendee > "Speaker N" > track)."""
    names = names or {}
    segments = doc["segments"]
    voices = speaker_labels.voice_counts(segments)
    lines = ["# Transcript", ""]
    for s in segments:
        spk = speaker_labels.label(s, names, voices, roster)
        lines.append(f"**[{fmt_clock(s['start'])}] {spk}:** {s['text']}")
        lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("meeting_dir", help="recording directory with raw/system.wav (+ raw/mic.wav)")
    ap.add_argument("--terms", default=str(package_file("terms.txt")))
    ap.add_argument(
        "--me-name",
        default=None,
        help="speaker label for the mic track (default: your macOS first name)",
    )
    ap.add_argument(
        "--skip-transcribe", action="store_true", help="reuse existing work/merged.raw.json"
    )
    ap.add_argument(
        "--no-compact",
        action="store_true",
        help="keep wav artifacts instead of compacting them to AAC",
    )
    args = ap.parse_args(argv)
    if not args.me_name:
        args.me_name = default_me_name()
    return args


def _run_roster(db: recording_db.RecordingDB, timings: PipelineTimings) -> tuple[dict, list[str]]:
    """Who was on the calendar invite; the attendee names feed Soniox context."""
    started = os.environ.get("TAMLIL_STARTED_AT")
    with timings.measure("roster"):
        roster = lookup_roster(db, started)
    names = roster.get("attendees", [])
    if roster:
        print(f"== roster: {', '.join(names) or '(none)'} ==", file=sys.stderr)
    return roster, names


def _build_lexicon_context(
    layout: RecordingLayout, args: argparse.Namespace, names: list[str]
) -> tuple[dict, list[str], str]:
    """Fold any confirmations the app logged since last run into the lexicon,
    then build this meeting's Soniox context = learned canonicals (ranked by
    use) + base seed + participant names, written to work/terms.local.txt. The
    lexicon is the one source of truth. Returns (lexicon, terms, terms path)."""
    # TAMLIL_LEXICON_ROOT points tests/staging at a scratch dictionary.
    repo = Path(os.environ.get("TAMLIL_LEXICON_ROOT") or Path(__file__).parent.parent.parent)
    lex = lexicon.load(repo)
    added = lexicon.ingest(repo, lex, datetime.date.today().isoformat())
    lexicon.save(repo, lex)
    if added:
        print(f"== lexicon: folded {added} new correction(s) ==", file=sys.stderr)
    glossary = lexicon.glossary(lex, base=load_terms(args.terms))
    local_terms = cap_context_terms(names, glossary)
    local = layout.work_terms_local
    local.write_text("\n".join(local_terms) + "\n", encoding="utf-8")
    return lex, local_terms, str(local)


def _start_mic_denoise(
    layout: RecordingLayout, timings: PipelineTimings
) -> threading.Thread | None:
    """Denoise the mic track for clearer Clarify playback (not used for ASR). It
    is CPU-bound, so run it in the background overlapping the network-bound
    Soniox jobs instead of blocking them; the caller joins it before compaction
    (and in its finally). Best-effort: any failure is swallowed and must never
    mark the run failed. Returns the running thread, or None if there is nothing
    to denoise."""
    mic, mic_clean = layout.raw_mic_audio, layout.work_mic_denoised
    if not (mic.exists() and not layout.work_mic_denoised_audio.exists()):
        return None

    def _denoise_mic() -> None:
        try:
            from . import denoise

            with timings.measure("denoise", critical=False):
                if denoise.denoise(mic, mic_clean):
                    print("== denoised raw/mic.wav -> work/mic.denoised.wav ==", file=sys.stderr)
        except Exception as exc:  # noqa: BLE001 - best-effort playback aid only
            print(f"== denoise failed (best-effort): {exc} ==", file=sys.stderr)

    thread = threading.Thread(target=_denoise_mic, name="denoise")
    thread.start()
    return thread


class _Transcription(NamedTuple):
    segments: list[dict]
    low_confidence: list[dict]
    failed_tracks: list[str]
    echo_done: bool
    merged_doc: dict | None
    discarded: bool = False


def _finalize_discarded(
    layout: RecordingLayout,
    db: recording_db.RecordingDB,
    names: list[str],
    failed_tracks: list[str],
) -> None:
    """An unanswered call/huddle: Slack holds the mic through the ring, so both
    tracks record but transcribe to nothing. That's not a pipeline failure —
    finalize an empty transcript and mark it discarded (the app shows "Discarded
    (call not answered)") instead of raising an error the user has to clear by
    hand."""
    print("== no speech on any track — discarding (unanswered call) ==", file=sys.stderr)
    empty_doc = {
        "model": "soniox:merged",
        "segments": [],
        "text": "",
        "failed_tracks": failed_tracks,
    }
    layout.final_transcript_json.write_text(
        json.dumps(empty_doc, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    write_transcript_md(
        empty_doc, layout.final_transcript_md, names=db.get_speaker_names(), roster=names
    )
    db.save_clarifications([])
    db.set_state("discarded (call not answered)")


def _load_or_transcribe(
    layout: RecordingLayout,
    db: recording_db.RecordingDB,
    timings: PipelineTimings,
    args: argparse.Namespace,
    roster: dict,
    names: list[str],
    terms_file: str,
) -> _Transcription:
    """Reuse an existing merged.raw.json (--skip-transcribe) or transcribe each
    present track with Soniox, returning the merged segments and the flags the
    rest of the pipeline keys on. A no-speech run is finalized as discarded."""
    merged_path = layout.work_merged_raw
    if args.skip_transcribe and merged_path.exists():
        print("== reusing work/merged.raw.json ==", file=sys.stderr)
        merged_doc = json.loads(merged_path.read_text(encoding="utf-8"))
        segments = merged_doc["segments"]
        if not segments:
            raise RuntimeError("work/merged.raw.json contains no segments")
        # Carry a prior degraded run's marker forward; a --skip-transcribe rerun
        # reuses that transcript and must not silently claim both tracks succeeded.
        return _Transcription(
            segments,
            merged_doc.get("low_confidence", []),
            merged_doc.get("failed_tracks") or [],
            merged_doc.get("echo_suppressed", False),
            merged_doc,
        )

    if not any(wav.exists() for wav, _ in tracks(layout, args.me_name)):
        raise RuntimeError("no audio tracks found (expected raw/system.wav / raw/mic.wav)")
    db.set_state("processing", stage="transcribing")
    general = meeting_metadata(roster.get("title", ""), names)
    transcribe_report: dict = {}
    with timings.measure("transcribe"):
        segments = transcribe_tracks(
            layout,
            terms_file,
            args.me_name,
            general=general,
            client_reference_id=db.recording_id,
            report=transcribe_report,
        )
    failed_tracks = transcribe_report.get("failed_tracks") or []
    if failed_tracks:
        print(
            f"== degraded: continuing without failed track(s): {', '.join(failed_tracks)} ==",
            file=sys.stderr,
        )
    low_confidence = asr_low_confidence_spans(layout, args.me_name)
    asr_docs = []
    for path in (layout.work_mic_asr, layout.work_system_asr):
        if path.exists():
            asr_docs.append(json.loads(path.read_text(encoding="utf-8")))
    db.set_transcription_engine(overall_engine(asr_docs))
    if not segments:
        _finalize_discarded(layout, db, names, failed_tracks)
        return _Transcription([], low_confidence, failed_tracks, False, None, discarded=True)
    return _Transcription(segments, low_confidence, failed_tracks, False, None)


def _collapse_hallucinations(
    segments: list[dict], timings: PipelineTimings
) -> tuple[list[dict], dict]:
    """ASR decoders can loop on chaotic audio, emitting hundreds of consecutive
    filler segments. Collapse those before echo suppression so the loop segments
    can't pollute its per-voice duplicate stats."""
    with timings.measure("hallucination"):
        loops = hallucination.collapse_loops(segments)
    report = loops["report"]
    if report["dropped"]:
        print(
            f"== hallucination: collapsed {report['dropped']} "
            f"segment(s) in {len(report['runs'])} loop run(s) ==",
            file=sys.stderr,
        )
    return loops["segments"], report


def _suppress_echo(
    layout: RecordingLayout,
    segments: list[dict],
    timings: PipelineTimings,
    *,
    echo_done: bool,
    merged_doc: dict | None,
    shared_room: bool,
) -> tuple[list[dict], dict]:
    """Drop mic segments that are just the remote audio echoing off the speakers
    (the same words, garbled, duplicated on the mic). On a --skip-transcribe
    re-run the echo_suppressed marker means suppression already happened, so only
    backfill the report's cross-track alignment rather than re-decoding both
    wavs. Returns (segments, echo report) and writes work/echo.report.json."""
    from . import echo

    if not echo_done:
        with timings.measure("echo"):
            echo_result = echo.suppress_with_report(
                layout.directory, segments, shared_room=shared_room
            )
        segments = echo_result["segments"]
        echo_report = echo_result["report"]
    else:
        # echo_done implies merged_doc was loaded above; not a real None here.
        echo_report = merged_doc.get("echo_report", {"dropped": 0, "reasons": {}, "drops": []})  # type: ignore[union-attr]
        with timings.measure("echo_alignment"):
            echo_report = echo.enrich_report_with_alignment(layout.directory, echo_report)
    layout.work_echo_report.write_text(
        json.dumps(echo_report, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return segments, echo_report


def _write_merged_raw(
    layout: RecordingLayout,
    segments: list[dict],
    echo_report: dict,
    hallucination_report: dict,
    low_confidence: list[dict],
    failed_tracks: list[str],
) -> dict:
    """Write the pre-lexicon merged.raw.json. It stays pre-lexicon on purpose
    so a --skip-transcribe re-run re-applies rules with whatever the dictionary
    has learned since. Voice ids were fixed at merge time (transcribe_tracks)
    and must not be compacted here — suppression gaps are load-bearing."""
    raw_doc = {
        "model": "soniox:merged",
        "segments": segments,
        "echo_suppressed": True,
        "echo_report": echo_report,
        "hallucination_report": hallucination_report,
        "low_confidence": low_confidence,
        "failed_tracks": failed_tracks,
        "text": " ".join(s["text"] for s in segments).strip(),
    }
    layout.work_merged_raw.write_text(
        json.dumps(raw_doc, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return raw_doc


def _apply_lexicon_and_write_final(
    layout: RecordingLayout,
    segments: list[dict],
    lex: dict,
    local_terms: list[str],
    raw_doc: dict,
    timings: PipelineTimings,
) -> dict:
    """Rewrite known garbles via the learned lexicon (in place) and write the
    corrected final/transcript.json. Returns the transcript doc."""
    with timings.measure("lexicon"):
        rewritten = apply_lexicon_rules(segments, lex, local_terms)
    if rewritten:
        print(f"== lexicon: rewrote {rewritten} segment(s) ==", file=sys.stderr)
    transcript_doc = {
        **raw_doc,
        "segments": segments,
        "text": " ".join(s["text"] for s in segments).strip(),
    }
    layout.final_transcript_json.write_text(
        json.dumps(transcript_doc, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return transcript_doc


def _write_clarifications(
    layout: RecordingLayout,
    db: recording_db.RecordingDB,
    low_confidence: list[dict],
    segments: list[dict],
    local_terms: list[str],
    lex: dict,
) -> None:
    """Surface low-confidence Soniox spans for the app's Clarify UI, each located
    back to its audio segment so the app can play the slice. Clear stale
    uncertain-span sidecars from older runs; clarification cards now live in
    SQLite (save_clarifications below)."""
    layout.work_merged_raw.with_suffix("").with_suffix(".raw.uncertain.json").unlink(
        missing_ok=True
    )
    layout.work_merged_uncertain.unlink(missing_ok=True)
    cards = build_clarification_cards(low_confidence, segments, local_terms, lex)
    db.save_clarifications(cards)


def _write_markdown(
    layout: RecordingLayout, db: recording_db.RecordingDB, transcript_doc: dict, names: list[str]
) -> None:
    write_transcript_md(
        transcript_doc, layout.final_transcript_md, names=db.get_speaker_names(), roster=names
    )
    layout.final_summary_md.unlink(missing_ok=True)


def _maybe_compact(
    layout: RecordingLayout, args: argparse.Namespace, timings: PipelineTimings
) -> None:
    """Shrink the wavs to AAC now that the transcript is final. Best-effort: a
    failed transcode keeps its wav and must not fail the meeting."""
    if args.no_compact:
        return
    from . import compact as compact_mod

    with timings.measure("compact"):
        freed = compact_mod.compact_recording(layout)
    if freed:
        print(f"== compacted audio, freed {freed / 1e9:.2f} GB ==", file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    meeting_dir = Path(args.meeting_dir)
    if not meeting_dir.is_dir():
        sys.exit(f"not a directory: {meeting_dir}")
    layout = RecordingLayout(meeting_dir)
    layout.prepare()
    db = recording_db.RecordingDB.from_env(meeting_dir)
    timings = PipelineTimings()

    db.set_state("processing")
    completed = False
    denoise_thread: threading.Thread | None = None
    try:
        roster, names = _run_roster(db, timings)
        lex, local_terms, terms_file = _build_lexicon_context(layout, args, names)
        denoise_thread = _start_mic_denoise(layout, timings)

        tr = _load_or_transcribe(layout, db, timings, args, roster, names, terms_file)
        if tr.discarded:
            completed = True
            print(f"discarded (call not answered): {meeting_dir}", file=sys.stderr)
            return 0

        segments, hallucination_report = _collapse_hallucinations(tr.segments, timings)
        # Rebroadcast suppression (dropping the clean remote copy) only applies
        # when the mic shared a room with participants the app echoed back. Two
        # independent signals say so: a booked room on the calendar event, or --
        # the calendar-free case -- the mic itself diarizing more than one voice
        # (co-located people). A solo remote call has neither, so echo treats
        # cross-track duplicates as playback and drops the mic copy instead.
        shared_room = bool(roster.get("rooms")) or speaker_labels.mic_heard_multiple_voices(
            segments
        )
        segments, echo_report = _suppress_echo(
            layout,
            segments,
            timings,
            echo_done=tr.echo_done,
            merged_doc=tr.merged_doc,
            shared_room=shared_room,
        )
        raw_doc = _write_merged_raw(
            layout, segments, echo_report, hallucination_report, tr.low_confidence, tr.failed_tracks
        )
        transcript_doc = _apply_lexicon_and_write_final(
            layout, segments, lex, local_terms, raw_doc, timings
        )
        _write_clarifications(layout, db, tr.low_confidence, segments, local_terms, lex)
        _write_markdown(layout, db, transcript_doc, names)

        # The denoise must have finished before compaction touches its output.
        if denoise_thread is not None:
            denoise_thread.join()
        _maybe_compact(layout, args, timings)

        db.set_state("done")
        completed = True
        print(f"done: {meeting_dir}", file=sys.stderr)
        return 0
    except BaseException as e:
        # Best-effort: recording the failure must never mask its cause.
        with suppress(Exception):
            db.set_state(error_state(e))
        raise
    finally:
        # Always leave a timing record, even for a failed run (marked with the
        # stage that raised) so a run that never reached "done" is still
        # measurable. Best-effort: a timing-write failure must not mask the run.
        if denoise_thread is not None:
            denoise_thread.join()
        with suppress(Exception):
            timings.write(
                layout.work_pipeline_timings,
                failed_stage=None if completed else (timings.failed_stage or "unknown"),
            )


if __name__ == "__main__":
    raise SystemExit(main())
