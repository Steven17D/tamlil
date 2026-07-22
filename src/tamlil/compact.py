# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

"""Compact a finished recording: transcode its wav artifacts to AAC.

Capture writes PCM wavs (historically up to 96 kHz Float32 — gigabytes per
meeting), but nothing downstream needs PCM once final/transcript.json exists:
Soniox uploads are prepped to 16 kHz mono anyway, and in-app playback goes
through AVAudioPlayer, which reads m4a. Each wav is transcoded next to itself
(mic.wav -> mic.m4a), verified by duration, and only then deleted; a failure
at any point keeps the original.

Run standalone on old recordings:
  uv run tamlil-compact <recording-dir>...    # or --all for the whole root
The pipeline also compacts automatically after a successful run.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

from .recording_layout import RecordingLayout
from .util import ffmpeg_path, ffprobe_path

# Speech at AAC-LC: mono tracks (mic, denoised mic) vs the stereo system mix.
BITRATE_MONO = "64k"
BITRATE_MULTI = "96k"
MAX_SAMPLE_RATE = 48_000

# A verified transcode must cover the original within this margin (AAC adds
# ~50 ms of encoder priming; anything worse means a truncated encode).
DURATION_TOLERANCE_S = 1.0


class CompactError(RuntimeError):
    pass


def _probe(path: Path) -> dict:
    """duration (s), channels, sample_rate of the first audio stream."""
    ffprobe = ffprobe_path()
    if not ffprobe:
        raise CompactError("ffprobe not available")
    proc = subprocess.run(
        [
            ffprobe,
            "-v",
            "error",
            "-select_streams",
            "a:0",
            "-show_entries",
            "stream=channels,sample_rate:format=duration",
            "-of",
            "json",
            str(path),
        ],
        capture_output=True,
        text=True,
        timeout=120,
    )
    if proc.returncode != 0:
        raise CompactError(f"ffprobe failed for {path.name}: {proc.stderr.strip()}")
    doc = json.loads(proc.stdout)
    streams = doc.get("streams") or [{}]
    duration = float(doc.get("format", {}).get("duration", 0) or 0)
    return {
        "duration": duration,
        "channels": int(streams[0].get("channels", 1) or 1),
        "sample_rate": int(streams[0].get("sample_rate", 0) or 0),
    }


def compact_file(wav: Path) -> int:
    """Transcode one wav to a sibling .m4a and delete the wav.

    Returns the bytes freed (wav size minus m4a size). The wav is removed only
    after the m4a's duration matches; any failure raises and leaves it intact.
    """
    ffmpeg = ffmpeg_path()
    if not ffmpeg:
        raise CompactError("ffmpeg not available")
    src = _probe(wav)
    if src["duration"] <= 0:
        raise CompactError(f"{wav.name}: no decodable audio")
    m4a = wav.with_suffix(".m4a")
    cmd = [ffmpeg, "-v", "error", "-y", "-i", str(wav)]
    if src["sample_rate"] > MAX_SAMPLE_RATE:
        cmd += ["-ar", str(MAX_SAMPLE_RATE)]
    bitrate = BITRATE_MULTI if src["channels"] > 1 else BITRATE_MONO
    cmd += ["-c:a", "aac", "-b:a", bitrate, str(m4a)]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
    if proc.returncode != 0:
        m4a.unlink(missing_ok=True)
        raise CompactError(f"transcode failed for {wav.name}: {proc.stderr.strip()}")
    out = _probe(m4a)
    if abs(out["duration"] - src["duration"]) > DURATION_TOLERANCE_S:
        m4a.unlink(missing_ok=True)
        raise CompactError(
            f"{wav.name}: transcode duration {out['duration']:.1f}s "
            f"!= source {src['duration']:.1f}s"
        )
    saved = wav.stat().st_size - m4a.stat().st_size
    wav.unlink()
    return saved


def compact_recording(layout: RecordingLayout, *, log=None) -> int:
    """Compact every wav artifact of one recording; returns bytes freed.

    Per-file failures are logged and skipped — a wav is never deleted unless
    its replacement verified, and one bad track must not block the others.
    """
    log = log or (lambda msg: print(msg, file=sys.stderr))
    freed = 0
    for wav in (layout.raw_mic, layout.raw_system, layout.work_mic_denoised):
        if not wav.exists():
            continue
        try:
            freed += compact_file(wav)
            log(f"compacted {wav.name} -> {wav.with_suffix('.m4a').name}")
        except (CompactError, OSError, subprocess.SubprocessError) as e:
            log(f"compact skipped {wav.name}: {e}")
    return freed


def _finished(directory: Path) -> bool:
    return RecordingLayout(directory).final_transcript_json.exists()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("dirs", nargs="*", help="recording directories to compact")
    ap.add_argument(
        "--all",
        action="store_true",
        help="compact every finished recording under the recordings root",
    )
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="list what would be compacted without touching anything",
    )
    args = ap.parse_args(argv)

    if args.all:
        root = Path(os.environ.get("TAMLIL_RECORDINGS_ROOT") or Path.home() / "Recordings/Tamlil")
        dirs = sorted(d for d in root.iterdir() if d.is_dir())
    else:
        dirs = [Path(d) for d in args.dirs]
    if not dirs:
        ap.error("pass recording directories or --all")

    total = 0
    for directory in dirs:
        layout = RecordingLayout(directory)
        if not _finished(directory):
            print(f"skip {directory.name}: no final/transcript.json", file=sys.stderr)
            continue
        wavs = [
            w for w in (layout.raw_mic, layout.raw_system, layout.work_mic_denoised) if w.exists()
        ]
        if not wavs:
            continue
        if args.dry_run:
            size = sum(w.stat().st_size for w in wavs)
            print(
                f"would compact {directory.name}: "
                f"{', '.join(w.name for w in wavs)} ({size / 1e9:.2f} GB)"
            )
            continue
        freed = compact_recording(layout)
        total += freed
        print(f"{directory.name}: freed {freed / 1e9:.2f} GB", file=sys.stderr)
    if not args.dry_run:
        print(f"total freed: {total / 1e9:.2f} GB", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
