# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

import subprocess

import pytest

from tamlil import compact
from tamlil.recording_layout import RecordingLayout
from tamlil.util import ffmpeg_path


def _write_wav(path, seconds=1.0, channels=1, rate=48000):
    # Callers carry @pytest.mark.requires_ffmpeg, so ffmpeg_path() is non-None
    # here; the marker (see conftest) skips the test when the binary is absent.
    ff = ffmpeg_path()
    subprocess.run(
        [
            ff,
            "-v",
            "error",
            "-y",
            "-f",
            "lavfi",
            "-i",
            f"sine=frequency=440:duration={seconds}",
            "-ac",
            str(channels),
            "-ar",
            str(rate),
            str(path),
        ],
        check=True,
        capture_output=True,
    )


@pytest.mark.requires_ffmpeg
def test_compact_file_replaces_wav_with_verified_m4a(tmp_path):
    wav = tmp_path / "mic.wav"
    _write_wav(wav)
    saved = compact.compact_file(wav)
    m4a = tmp_path / "mic.m4a"
    assert not wav.exists()
    assert m4a.exists()
    assert saved > 0
    assert abs(compact._probe(m4a)["duration"] - 1.0) < compact.DURATION_TOLERANCE_S


def test_compact_file_keeps_wav_when_input_is_garbage(tmp_path):
    wav = tmp_path / "mic.wav"
    wav.write_bytes(b"RIFF not really audio")
    with pytest.raises(compact.CompactError):
        compact.compact_file(wav)
    assert wav.exists()
    assert not (tmp_path / "mic.m4a").exists()


@pytest.mark.requires_ffmpeg
def test_compact_recording_skips_bad_tracks_and_compacts_the_rest(tmp_path):
    layout = RecordingLayout(tmp_path)
    layout.prepare()
    _write_wav(layout.raw_mic)
    layout.raw_system.write_bytes(b"garbage")
    messages = []
    freed = compact.compact_recording(layout, log=messages.append)
    assert freed > 0
    assert not layout.raw_mic.exists()
    assert (layout.raw_dir / "mic.m4a").exists()
    assert layout.raw_system.exists()
    assert any("skipped system.wav" in m for m in messages)


def test_layout_audio_resolver_prefers_wav_then_m4a(tmp_path):
    layout = RecordingLayout(tmp_path)
    layout.prepare()
    # Neither exists: canonical path, so callers' .exists() checks still work.
    assert layout.raw_mic_audio == layout.raw_mic
    m4a = layout.raw_dir / "mic.m4a"
    m4a.write_bytes(b"x")
    assert layout.raw_mic_audio == m4a
    layout.raw_mic.write_bytes(b"x")
    assert layout.raw_mic_audio == layout.raw_mic
    denoised_m4a = layout.work_dir / "mic.denoised.m4a"
    denoised_m4a.write_bytes(b"x")
    assert layout.work_mic_denoised_audio == denoised_m4a


def test_cli_skips_recordings_without_final_transcript(tmp_path):
    rec = tmp_path / "rec"
    layout = RecordingLayout(rec)
    layout.prepare()
    layout.raw_mic.write_bytes(b"garbage")
    assert compact.main([str(rec)]) == 0
    assert layout.raw_mic.exists()


def test_cli_dry_run_touches_nothing(tmp_path):
    rec = tmp_path / "rec"
    layout = RecordingLayout(rec)
    layout.prepare()
    layout.raw_mic.write_bytes(b"garbage")
    layout.final_transcript_json.write_text("{}", encoding="utf-8")
    assert compact.main(["--dry-run", str(rec)]) == 0
    assert layout.raw_mic.exists()
    assert not (layout.raw_dir / "mic.m4a").exists()
