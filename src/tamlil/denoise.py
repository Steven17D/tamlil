# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

"""Denoise the mic track with RNNoise (ffmpeg arnndn) for clearer playback.

A laptop's fan/AC hum is broadband and sits in the speech band, so the built-in
FFT denoisers (afftdn/anlmdn) barely touch it; RNNoise is trained to keep speech
and strip stationary noise. Its purpose here is playback: it makes the Clarify
slice easier to hear. Whether feeding RNNoise-cleaned audio to the ASR upload
would help or hurt Soniox is an untested A/B, not a settled fact — so this output
is NOT routed into the transcription path. Best-effort: any failure leaves the
raw mic untouched.

Model: GregorR/rnnoise-models "beguiling-drafter" (bd.rnnn); its author
disclaims copyright on the weights. The RNNoise software that ffmpeg's arnndn
filter implements is separate (Xiph.Org / Jean-Marc Valin, BSD-3-Clause). See
THIRD_PARTY_LICENSES.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from .util import ffmpeg_path, package_file

MODEL = package_file("assets", "rnnoise", "bd.rnnn")
_FALLBACK_SR = 48000


def _sample_rate(src: Path) -> int:
    """The input's native sample rate, so the output drops in next to mic.wav
    unchanged except for the noise."""
    ffprobe = shutil.which("ffprobe")
    if not ffprobe:
        return _FALLBACK_SR
    try:
        out = subprocess.run(
            [
                ffprobe,
                "-v",
                "error",
                "-select_streams",
                "a:0",
                "-show_entries",
                "stream=sample_rate",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(src),
            ],
            capture_output=True,
            text=True,
            check=True,
            timeout=60,
        ).stdout.strip()
        rate = int(out.splitlines()[0])
        return rate if rate > 0 else _FALLBACK_SR
    except (OSError, subprocess.SubprocessError, ValueError, IndexError):
        return _FALLBACK_SR


def denoise(src: Path, dst: Path) -> bool:
    ff = ffmpeg_path()
    if not (ff and MODEL.exists() and src.exists()):
        return False
    # arnndn requires 48 kHz; resample in, then back to the input's native rate.
    filt = f"highpass=f=80,aresample=48000,arnndn=m={MODEL},aresample={_sample_rate(src)}"
    try:
        subprocess.run(
            [
                ff,
                "-hide_banner",
                "-v",
                "error",
                "-y",
                "-i",
                str(src),
                "-af",
                filt,
                "-c:a",
                "pcm_f32le",
                str(dst),
            ],
            check=True,
            timeout=900,
        )
        return True
    except (OSError, subprocess.SubprocessError):
        dst.unlink(missing_ok=True)
        return False


if __name__ == "__main__":
    import sys

    src = Path(sys.argv[1])
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else src.with_suffix(".denoised.wav")
    raise SystemExit(0 if denoise(src, dst) else 1)
