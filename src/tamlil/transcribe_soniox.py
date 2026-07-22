# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

"""Transcribe via the Soniox async API (stt-async-v5).

Soniox is the one engine architecturally built for intra-sentence
Hebrew<->English code-switching (per-token language ID, language hints that
bias rather than pin), which is why it is the pipeline's primary engine. This
backend produces .txt/.srt/.json outputs directly from Soniox tokens.

Auth: SONIOX_API_KEY env var, else Keychain item 'tamlil-soniox'. Audio is
uploaded to Soniox cloud; per their ToS they never train on it. After
transcription the stored transcription is deleted (`--keep-remote` to keep it),
which also removes its uploaded audio file — so under Soniox's async storage
neither the audio nor the transcript text lingers on their servers (see
docs/soniox-data-processing.md).
"""

from __future__ import annotations

import argparse
import copy
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import requests

from .util import ffmpeg_path, fmt_ts, load_terms, soniox_auth, write_outputs

API = "https://api.soniox.com/v1"
DEFAULT_MODEL = "stt-async-v5"
DEFAULT_LANG_HINTS = "he,en"
SILENCE_NOISE = "-50dB"
SILENCE_MIN_S = 1.0
SPEECH_PAD_S = 0.2

# Sub-speech rumble (laptop fans, HVAC, desk thumps) sits below the voice band;
# a highpass on the way up strips it without touching speech. denoise.py uses
# the same 80 Hz corner for playback cleanup.
ASR_UPLOAD_HIGHPASS_HZ = 80


def _upload_loudnorm_enabled() -> bool:
    """Loudness-normalize the ASR upload? OFF by default: dynaudnorm can help a
    quiet mic but also pumps room noise, so it stays opt-in behind
    TAMLIL_ASR_LOUDNORM=1 until an A/B on real meetings says it earns its place."""
    return os.environ.get("TAMLIL_ASR_LOUDNORM") == "1"


def _upload_filters() -> list[str]:
    """Pre-resample cleanup shared by both upload transcodes: strip sub-speech
    rumble, then (opt-in) level the loudness."""
    filters = [f"highpass=f={ASR_UPLOAD_HIGHPASS_HZ}"]
    if _upload_loudnorm_enabled():
        filters.append("dynaudnorm")
    return filters


def _auth() -> dict:
    return {"Authorization": f"Bearer {soniox_auth()}"}


SETUP_MAX_TRANSIENT_RETRIES = 5


def _is_retryable_setup_error(exc: requests.RequestException) -> bool:
    """POST /files and POST /transcriptions are NOT idempotent: a connection or
    read-timeout error carries no response, so we cannot tell whether Soniox
    already committed the file/job. Retrying such a case would orphan an
    undeleted file or create a second billed transcription. So retry only when
    the server explicitly reported it did not act — a 5xx response. (The GET
    poll's classifier treats a response-less error as retryable, which is only
    safe because a GET has no side effect; do not reuse it here.)"""
    resp = getattr(exc, "response", None)
    return resp is not None and resp.status_code >= 500


def _with_setup_retry(send):
    """Run `send` (returns a Response), retrying with bounded exponential
    backoff only on an explicit 5xx — the one case where the non-idempotent
    setup POST is known not to have committed. `send` is called fresh each
    attempt (so it can reopen the upload file)."""
    attempt = 0
    while True:
        try:
            r = send()
            r.raise_for_status()
            return r
        except requests.RequestException as e:
            attempt += 1
            if attempt > SETUP_MAX_TRANSIENT_RETRIES or not _is_retryable_setup_error(e):
                raise
            backoff = min(2 ** (attempt - 1), 30)
            print(
                f"  soniox: transient setup error ({attempt}), retrying in {backoff:g}s: {e}",
                file=sys.stderr,
            )
            time.sleep(backoff)


def upload(audio: str) -> str:
    def send():
        with open(audio, "rb") as f:
            return requests.post(
                f"{API}/files",
                headers=_auth(),
                files={"file": (Path(audio).name, f)},
                timeout=600,
            )

    return _with_setup_retry(send).json()["id"]


def create_transcription(
    file_id: str,
    *,
    model: str,
    lang_hints: list[str],
    diarize: bool,
    terms: list[str],
    general: list[dict] | None = None,
    client_reference_id: str | None = None,
) -> str:
    body = {
        "model": model,
        "file_id": file_id,
        "language_hints": lang_hints,
        "enable_speaker_diarization": diarize,
        "enable_language_identification": True,
    }
    # v5 context is a structured object; `general` (domain/topic metadata) is
    # broadest-influence and comes first, then `terms` for critical words. Only
    # non-empty sections are included.
    context: dict = {}
    if general:
        context["general"] = general
    if terms:
        context["terms"] = terms
    if context:
        body["context"] = context
    if client_reference_id:
        body["client_reference_id"] = client_reference_id
    r = _with_setup_retry(
        lambda: requests.post(f"{API}/transcriptions", headers=_auth(), json=body, timeout=60)  # type: ignore[arg-type]
    )
    return r.json()["id"]


def _compressed_copy(audio: str) -> Path | None:
    """16 kHz mono FLAC in a temp dir: ~20x smaller upload, no measurable ASR
    cost. None (upload the original) when ffmpeg is missing or fails."""
    ffmpeg = ffmpeg_path()
    if not ffmpeg:
        return None
    fd, name = tempfile.mkstemp(suffix=".flac", prefix="soniox-upload-")
    os.close(fd)
    out = Path(name)
    try:
        subprocess.run(
            [
                ffmpeg,
                "-v",
                "error",
                "-y",
                "-i",
                audio,
                "-ac",
                "1",
                "-af",
                ",".join(_upload_filters()),
                "-ar",
                "16000",
                str(out),
            ],
            check=True,
            capture_output=True,
            timeout=600,
        )
        return out
    except (OSError, subprocess.SubprocessError):
        out.unlink(missing_ok=True)
        return None


def _silence_ranges(stderr: str) -> list[tuple[float, float]]:
    starts: list[float] = []
    ranges: list[tuple[float, float]] = []
    for line in stderr.splitlines():
        if m := re.search(r"silence_start:\s*([0-9.]+)", line):
            starts.append(float(m.group(1)))
        elif (m := re.search(r"silence_end:\s*([0-9.]+)", line)) and starts:
            start = starts.pop(0)
            end = float(m.group(1))
            if end > start:
                ranges.append((start, end))
    return ranges


def _speech_ranges(
    duration: float, silences: list[tuple[float, float]], pad_s: float = SPEECH_PAD_S
) -> list[tuple[float, float]]:
    ranges: list[tuple[float, float]] = []
    cursor = 0.0
    for start, end in sorted(silences):
        if start > cursor:
            ranges.append((max(0.0, cursor - pad_s), min(duration, start + pad_s)))
        cursor = max(cursor, end)
    if cursor < duration:
        ranges.append((max(0.0, cursor - pad_s), duration))

    merged: list[tuple[float, float]] = []
    for start, end in ranges:
        if end <= start:
            continue
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


def _speech_mapping(ranges: list[tuple[float, float]]) -> list[dict]:
    mapping = []
    processed = 0.0
    for raw_start, raw_end in ranges:
        length = raw_end - raw_start
        mapping.append(
            {
                "processed_start": round(processed, 3),
                "processed_end": round(processed + length, 3),
                "raw_start": round(raw_start, 3),
                "raw_end": round(raw_end, 3),
            }
        )
        processed += length
    return mapping


def _at_processed_time(t: float, mapping: list[dict]) -> float:
    if not mapping:
        return t
    for item in mapping:
        if item["processed_start"] <= t <= item["processed_end"]:
            return round(item["raw_start"] + (t - item["processed_start"]), 3)
    if t < mapping[0]["processed_start"]:
        return round(mapping[0]["raw_start"], 3)
    tail = mapping[-1]
    return round(tail["raw_end"] + max(0.0, t - tail["processed_end"]), 3)


def restore_token_timestamps(tokens: list[dict], mapping: list[dict]) -> list[dict]:
    restored = copy.deepcopy(tokens)
    for token in restored:
        if "start_ms" in token:
            token["start_ms"] = int(
                round(_at_processed_time(token["start_ms"] / 1000, mapping) * 1000)
            )
        if "end_ms" in token:
            token["end_ms"] = int(round(_at_processed_time(token["end_ms"] / 1000, mapping) * 1000))
    return restored


def speech_only_copy(audio: str) -> tuple[Path, list[dict]] | None:
    ffmpeg = ffmpeg_path()
    if not ffmpeg:
        return None
    duration = _audio_duration(audio)
    if not duration or duration <= SILENCE_MIN_S:
        return None
    try:
        detected = subprocess.run(
            [
                ffmpeg,
                "-v",
                "info",
                "-i",
                audio,
                "-af",
                f"silencedetect=noise={SILENCE_NOISE}:d={SILENCE_MIN_S}",
                "-f",
                "null",
                "-",
            ],
            capture_output=True,
            text=True,
            timeout=600,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    silences = _silence_ranges(detected.stderr)
    if not silences:
        return None
    ranges = _speech_ranges(duration, silences)
    speech_duration = sum(end - start for start, end in ranges)
    if not ranges or speech_duration >= duration * 0.95:
        return None

    fd, name = tempfile.mkstemp(suffix=".flac", prefix="soniox-speech-")
    os.close(fd)
    out = Path(name)
    pieces = []
    labels = []
    for i, (start, end) in enumerate(ranges):
        label = f"a{i}"
        pieces.append(f"[0:a]atrim=start={start:.3f}:end={end:.3f},asetpts=PTS-STARTPTS[{label}]")
        labels.append(f"[{label}]")
    tail = ",".join(_upload_filters())
    filtergraph = ";".join(
        pieces
        + [
            "".join(labels) + f"concat=n={len(labels)}:v=0:a=1,"
            f"aformat=channel_layouts=mono,{tail},aresample=16000[out]"
        ]
    )
    try:
        subprocess.run(
            [
                ffmpeg,
                "-v",
                "error",
                "-y",
                "-i",
                audio,
                "-filter_complex",
                filtergraph,
                "-map",
                "[out]",
                str(out),
            ],
            check=True,
            capture_output=True,
            timeout=600,
        )
        return out, _speech_mapping(ranges)
    except (OSError, subprocess.SubprocessError):
        out.unlink(missing_ok=True)
        return None


def _audio_duration(audio: str) -> float | None:
    ffmpeg_path()  # puts the bundled ffprobe on PATH too
    ffprobe = shutil.which("ffprobe")
    if not ffprobe:
        return None
    try:
        out = subprocess.run(
            [
                ffprobe,
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                audio,
            ],
            capture_output=True,
            text=True,
            check=True,
            timeout=60,
        ).stdout.strip()
        return float(out)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


POLL_MAX_TRANSIENT_RETRIES = 5


def _is_transient_poll_error(exc: requests.RequestException) -> bool:
    """A blip we should retry rather than abort a long transcription for:
    connection/timeout errors (no response) and 5xx server-side responses.
    A 4xx (bad key, missing id) is the caller's fault and never recovers."""
    resp = getattr(exc, "response", None)
    if resp is None:
        return True
    return resp.status_code >= 500


def wait(tid: str, poll_s: float, deadline_s: float) -> None:
    started = time.monotonic()
    last_log = started
    transient = 0
    while True:
        try:
            r = requests.get(f"{API}/transcriptions/{tid}", headers=_auth(), timeout=60)
            r.raise_for_status()
            d = r.json()
        except requests.RequestException as e:
            now = time.monotonic()
            if not _is_transient_poll_error(e):
                raise RuntimeError(f"soniox: polling {tid} failed: {e}") from e
            transient += 1
            if transient > POLL_MAX_TRANSIENT_RETRIES or now - started > deadline_s:
                raise RuntimeError(
                    f"soniox: polling {tid} gave up after {transient} consecutive "
                    f"transient errors ({int(now - started)}s elapsed): {e}"
                ) from e
            print(f"  soniox: transient poll error ({transient}), retrying: {e}", file=sys.stderr)
            time.sleep(poll_s)
            continue
        transient = 0
        if d["status"] == "completed":
            return
        if d["status"] == "error":
            raise RuntimeError(f"soniox error: {d.get('error_type')}: {d.get('error_message')}")
        now = time.monotonic()
        if now - started > deadline_s:
            raise RuntimeError(
                f"soniox: transcription {tid} still '{d['status']}' after "
                f"{int(now - started)}s (deadline {int(deadline_s)}s); giving up"
            )
        if now - last_log >= 30:
            print(f"  soniox: {d['status']}, {int(now - started)}s elapsed", file=sys.stderr)
            last_log = now
        time.sleep(poll_s)


def fetch_tokens(tid: str) -> tuple[str, list[dict]]:
    r = requests.get(f"{API}/transcriptions/{tid}/transcript", headers=_auth(), timeout=120)
    r.raise_for_status()
    d = r.json()
    return d.get("text", ""), d.get("tokens", [])


LOW_CONFIDENCE_THRESHOLD = 0.5


def _is_word_token(text: str) -> bool:
    stripped = text.strip()
    return bool(stripped and any(ch.isalnum() for ch in stripped))


def low_confidence_spans(
    tokens: list[dict], threshold: float = LOW_CONFIDENCE_THRESHOLD
) -> list[dict]:
    spans: list[dict] = []
    cur: dict | None = None
    pending = ""
    for t in tokens:
        text = t.get("text", "")
        if not _is_word_token(text):
            if cur is not None:
                pending += text
            continue
        confidence = t.get("confidence")
        is_low = isinstance(confidence, (int, float)) and confidence < threshold
        if not is_low:
            if cur is not None:
                cur["text"] = cur["text"].strip()
                spans.append(cur)
                cur = None
            pending = ""
            continue
        start = t.get("start_ms", 0) / 1000
        end = t.get("end_ms", 0) / 1000
        # is_low above is only true when confidence is an int/float, so these
        # float() calls never see None — a narrowing mypy can't follow.
        if cur is None:
            cur = {"text": text, "start": start, "end": end, "confidence": float(confidence)}  # type: ignore[arg-type]
        else:
            cur["text"] += pending + text
            cur["end"] = end
            cur["confidence"] = min(cur["confidence"], float(confidence))  # type: ignore[arg-type]
        pending = ""
    if cur is not None:
        cur["text"] = cur["text"].strip()
        spans.append(cur)
    return [s for s in spans if s["text"]]


def _word_entry(token: dict) -> dict | None:
    text = token.get("text", "").strip()
    if not _is_word_token(text):
        return None
    word = {
        "text": text,
        "start": round(token.get("start_ms", 0) / 1000, 2),
        "end": round(token.get("end_ms", 0) / 1000, 2),
    }
    if isinstance(token.get("confidence"), (int, float)):
        word["confidence"] = float(token["confidence"])
    if token.get("language"):
        word["language"] = token["language"]
    if token.get("speaker") is not None:
        word["speaker"] = str(token["speaker"])
    return word


# Subtitle-sized segment lengths, in characters. Break at a sentence boundary
# once a segment is comfortably long; force a break at the hard cap even
# mid-sentence so no single segment runs unreadably long.
SEGMENT_SENTENCE_BREAK_CHARS = 160
SEGMENT_MAX_CHARS = 280


def tokens_to_segments(tokens: list[dict]) -> list[dict]:
    """Group sub-word tokens into subtitle-sized segments.

    Break on speaker change, a >1s silence gap, or length, preferring sentence
    punctuation. Tokens carry their own spacing, so texts concatenate directly.
    """
    segments: list[dict] = []
    cur: dict | None = None
    for t in tokens:
        text = t.get("text", "")
        start, end = t.get("start_ms", 0) / 1000, t.get("end_ms", 0) / 1000
        speaker = t.get("speaker")
        lang = t.get("language")
        word = _word_entry(t)
        last_word_end = (
            cur["words"][-1]["end"] if cur and cur["words"] else cur["end"] if cur else 0
        )
        word_gap = word is not None and word["start"] - last_word_end > 1.0
        brk = cur is not None and (
            (speaker is not None and speaker != cur["speaker"])
            or word_gap
            or (word is not None and start - cur["end"] > 1.0)
            or (
                len(cur["text"]) > SEGMENT_SENTENCE_BREAK_CHARS
                and cur["text"].rstrip().endswith((".", "?", "!"))
            )
            or len(cur["text"]) > SEGMENT_MAX_CHARS
        )
        if cur is None and word is None:
            continue
        if cur is None or brk:
            if cur:
                segments.append(cur)
            cur = {
                "start": start,
                "end": end,
                "text": text,
                "speaker": speaker,
                "languages": {lang} if lang else set(),
                "words": [],
            }
            if word:
                cur["words"].append(word)
        else:
            if word or end - cur["end"] <= 1.0:
                cur["end"] = end
            cur["text"] += text
            if lang:
                cur["languages"].add(lang)
            if word:
                cur["words"].append(word)
    if cur:
        segments.append(cur)
    for s in segments:
        s["text"] = s["text"].strip()
        s["languages"] = sorted(s["languages"])
        if not s["words"]:
            s.pop("words")
    return [s for s in segments if s["text"]]


def _delete_remote(*, tid: str | None, file_id: str) -> None:
    """Best-effort cleanup of the Soniox-side objects after a run. Deleting the
    transcription also removes its stored audio file, so that is preferred; when
    no transcription was created we fall back to deleting just the uploaded file.
    A failure is logged to stderr but never raised — losing cleanup must not fail
    a run or change transcript output. Soniox's async API stores both objects
    with no auto-expiry, so this is what keeps the audio and the transcript text
    from persisting on their servers (docs/soniox-data-processing.md)."""
    if tid is not None:
        what, url = f"transcription {tid}", f"{API}/transcriptions/{tid}"
    else:
        what, url = f"file {file_id}", f"{API}/files/{file_id}"
    try:
        requests.delete(url, headers=_auth(), timeout=60).raise_for_status()
    except requests.RequestException as e:
        print(
            f"  soniox: warning: could not delete {what}; it may still be stored on Soniox: {e}",
            file=sys.stderr,
        )


def transcribe_file(
    audio: str,
    *,
    model: str = DEFAULT_MODEL,
    lang_hints: str = DEFAULT_LANG_HINTS,
    terms: list[str] | None = None,
    general: list[dict] | None = None,
    client_reference_id: str | None = None,
    diarize: bool = True,
    poll_interval: float = 5.0,
    keep_remote: bool = False,
) -> dict:
    """Compress, upload, transcribe, fetch, and map Soniox tokens to segments."""
    _auth()  # fail fast (no key) before spending a transcode or an upload

    duration = _audio_duration(audio)
    deadline_s = max(600.0, 2 * duration) if duration else 1800.0

    try:
        speech_copy = speech_only_copy(audio)
        upload_audio = str(speech_copy[0]) if speech_copy else audio
        compressed = None if speech_copy else _compressed_copy(upload_audio)
        try:
            file_id = upload(str(compressed or upload_audio))
        finally:
            if compressed:
                compressed.unlink(missing_ok=True)
        tid: str | None = None
        try:
            tid = create_transcription(
                file_id,
                model=model,
                lang_hints=lang_hints.split(","),
                diarize=diarize,
                terms=terms or [],
                general=general,
                client_reference_id=client_reference_id,
            )
            wait(tid, poll_interval, deadline_s)
            text, tokens = fetch_tokens(tid)
        finally:
            if not keep_remote:
                # Delete the transcription — which also removes its uploaded
                # file — so no transcript text lingers on Soniox's async storage.
                _delete_remote(tid=tid, file_id=file_id)

        if speech_copy:
            tokens = restore_token_timestamps(tokens, speech_copy[1])
        segments = tokens_to_segments(tokens)
        doc = {
            "model": f"soniox:{model}",
            "detected_language": "multi",
            "language_probability": 1.0,
            "duration": segments[-1]["end"] if segments else 0.0,
            "segments": [
                {k: s[k] for k in ("start", "end", "text")}
                | ({"speaker": s["speaker"]} if s.get("speaker") is not None else {})
                | ({"languages": s["languages"]} if s.get("languages") else {})
                | ({"words": s["words"]} if s.get("words") else {})
                for s in segments
            ],
            "text": text.strip() or " ".join(s["text"] for s in segments),
            "low_confidence": low_confidence_spans(tokens),
        }
        if speech_copy:
            doc["preprocessing"] = {
                "speech_only": True,
                "mapping": speech_copy[1],
            }
        else:
            doc["preprocessing"] = {"speech_only": False}
        return doc
    finally:
        if "speech_copy" in locals() and speech_copy:
            speech_copy[0].unlink(missing_ok=True)


def _http_error_message(e: requests.HTTPError) -> str:
    """One-line, actionable message from a raw requests.HTTPError: surfaces
    Soniox's JSON error detail and hints at the likely cause."""
    resp = e.response
    if resp is None:
        return f"soniox request failed: {e}"
    detail = ""
    try:
        body = resp.json()
        if isinstance(body, dict):
            detail = str(
                body.get("message") or body.get("error_message") or body.get("error") or ""
            )
    except ValueError:
        detail = resp.text.strip()[:200]
    msg = f"soniox API error {resp.status_code}"
    if detail:
        msg += f": {detail}"
    if resp.status_code in (401, 403):
        msg += " (check the tamlil-soniox Keychain key or SONIOX_API_KEY)"
    return msg


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("audio", help="audio/video file (uploaded to Soniox)")
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument(
        "--lang-hints", default=DEFAULT_LANG_HINTS, help="comma list; biases, does not pin"
    )
    ap.add_argument("--terms", default=None, help="glossary file or comma list -> context")
    ap.add_argument("--no-diarize", action="store_true")
    ap.add_argument("--poll-interval", type=float, default=5.0)
    ap.add_argument("--keep-remote", action="store_true", help="don't delete the uploaded file")
    ap.add_argument("--format", default="all", choices=["txt", "srt", "json", "all", "none"])
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    if not Path(args.audio).is_file():
        sys.exit(f"audio file not found: {args.audio}")

    try:
        result = transcribe_file(
            args.audio,
            model=args.model,
            lang_hints=args.lang_hints,
            terms=load_terms(args.terms),
            diarize=not args.no_diarize,
            poll_interval=args.poll_interval,
            keep_remote=args.keep_remote,
        )
    except FileNotFoundError as e:
        sys.exit(str(e))
    except requests.HTTPError as e:
        sys.exit(_http_error_message(e))
    except requests.RequestException as e:
        sys.exit(f"soniox: network error: {e}")
    except RuntimeError as e:
        sys.exit(str(e))

    if not args.quiet:
        for s in result["segments"]:
            spk = f" [{s['speaker']}]" if "speaker" in s else ""
            print(f"[{fmt_ts(s['start'])} -> {fmt_ts(s['end'])}]{spk} {s['text']}")

    if args.format != "none":
        # write next to the input, suffixed so it never clobbers the local-ASR outputs
        write_outputs(result, f"{Path(args.audio).with_suffix('')}.soniox", args.format)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
