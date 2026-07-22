# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

import json
import sqlite3

import pytest

import tamlil.meeting_pipeline as mp
from tamlil import recording_db, transcribe_soniox
from tamlil.recording_layout import RecordingLayout


def _doc(text, **seg_extra):
    return {
        "model": "x",
        "segments": [{"start": 0.0, "end": 1.0, "text": text} | seg_extra],
        "text": text,
    }


@pytest.fixture
def meeting(tmp_path):
    layout = RecordingLayout(tmp_path)
    layout.prepare()
    layout.raw_mic.write_bytes(b"RIFF")
    layout.raw_system.write_bytes(b"RIFF")
    return layout


def test_tracks_transcribe_concurrently_with_terms_context(meeting, monkeypatch):
    calls = []

    def fake_soniox(audio, **kwargs):
        calls.append((audio, kwargs))
        return _doc("hello")

    monkeypatch.setattr(transcribe_soniox, "transcribe_file", fake_soniox)

    segments = mp.transcribe_tracks(meeting, terms="a,b", me_name="Me")

    assert [s["speaker"] for s in segments] == ["Me", "Them"]
    assert all(kw["terms"] == ["a", "b"] for _, kw in calls)
    assert json.loads(meeting.work_mic_asr.read_text())["text"] == "hello"


def test_transcribe_tracks_threads_general_and_client_reference(meeting, monkeypatch):
    calls = []
    monkeypatch.setattr(
        transcribe_soniox, "transcribe_file", lambda audio, **kw: calls.append(kw) or _doc("hi")
    )

    general = [{"key": "meeting", "value": "Sync"}]
    mp.transcribe_tracks(
        meeting, terms=None, me_name="Me", general=general, client_reference_id="rec-9"
    )

    assert len(calls) == 2
    assert all(kw["general"] == general for kw in calls)
    assert all(kw["client_reference_id"] == "rec-9" for kw in calls)


def test_cap_context_terms_keeps_names_and_trims_glossary_by_budget():
    names = ["Alice", "Bob"]
    glossary = [f"term{i:03d}" for i in range(100)]
    capped = mp.cap_context_terms(names, glossary, char_budget=40)

    assert capped[:2] == ["Alice", "Bob"]  # roster names always kept, first
    assert len(capped) < len(names) + len(glossary)  # glossary trimmed to budget
    # a glossary entry equal to a name (case-insensitively) is not duplicated
    assert mp.cap_context_terms(["Alice"], ["alice", "Zed"]) == ["Alice", "Zed"]


def test_meeting_metadata_skips_empty_and_always_includes_languages():
    assert mp.meeting_metadata("", []) == [{"key": "languages", "value": "Hebrew, English"}]
    assert mp.meeting_metadata("Sync", ["Alice", "Bob"]) == [
        {"key": "meeting", "value": "Sync"},
        {"key": "participants", "value": "Alice, Bob"},
        {"key": "languages", "value": "Hebrew, English"},
    ]


def test_diarized_voice_survives_speaker_relabel(meeting, monkeypatch):
    monkeypatch.setattr(
        transcribe_soniox, "transcribe_file", lambda audio, **kw: _doc("hi", speaker=2)
    )

    segments = mp.transcribe_tracks(meeting, terms=None, me_name="Me")

    # Each track's engine id 2 lands in the shared keyspace without colliding.
    assert [s["voice"] for s in segments] == ["1", "2"]
    assert [s["speaker"] for s in segments] == ["Me", "Them"]
    # the per-track artifact keeps the raw engine speaker id
    assert json.loads(meeting.work_system_asr.read_text())["segments"][0]["speaker"] == 2


def test_merge_assigns_stable_cross_track_voice_ids(meeting, monkeypatch):
    # Voice ids are fixed at merge time, from every transcribed segment, so
    # whatever later suppression stages drop can never renumber the survivors
    # -- user-assigned names are keyed by these ids, and a 2026-07-22 echo-fix
    # re-run that shifted the numbering put a colleague's name on the user.
    def fake(audio, **kw):
        if "mic" in audio:
            return {
                "model": "x",
                "segments": [
                    {"start": 0.0, "end": 1.0, "text": "a", "speaker": 5},
                    {"start": 2.0, "end": 3.0, "text": "b", "speaker": 9},
                ],
                "text": "a b",
            }
        return {
            "model": "x",
            "segments": [{"start": 1.0, "end": 2.0, "text": "c", "speaker": 5}],
            "text": "c",
        }

    monkeypatch.setattr(transcribe_soniox, "transcribe_file", fake)

    segments = mp.transcribe_tracks(meeting, terms=None, me_name="Me")

    assert [(s["speaker"], s["voice"]) for s in segments] == [
        ("Me", "1"),
        ("Them", "2"),
        ("Me", "3"),
    ]


def test_write_merged_raw_preserves_gapped_voice_ids(tmp_path):
    # A voice fully deleted by suppression leaves a gap in the id sequence;
    # compacting it away here would renumber the survivors and reattach their
    # user-assigned names to the wrong people on the next re-run.
    layout = RecordingLayout(tmp_path)
    layout.prepare()
    segs = [
        {"start": 1.0, "end": 2.0, "text": "hi", "speaker": "Them", "voice": "2"},
        {"start": 3.0, "end": 4.0, "text": "yo", "speaker": "Me", "voice": "4"},
    ]

    mp._write_merged_raw(layout, segs, {}, {}, [], [])

    merged = json.loads(layout.work_merged_raw.read_text(encoding="utf-8"))
    assert [s["voice"] for s in merged["segments"]] == ["2", "4"]


def test_soniox_failure_raises(meeting, monkeypatch):
    def fail(audio, **kwargs):
        raise RuntimeError("organization_balance_exhausted")

    monkeypatch.setattr(transcribe_soniox, "transcribe_file", fail)

    with pytest.raises(RuntimeError, match="organization_balance_exhausted"):
        mp.transcribe_tracks(meeting, terms=None, me_name="Me")


def test_one_track_failing_degrades_to_the_survivor(meeting, monkeypatch):
    def soniox(audio, **kwargs):
        if audio.endswith("system.wav"):
            raise RuntimeError("upload interrupted")
        return _doc("cloud")

    monkeypatch.setattr(transcribe_soniox, "transcribe_file", soniox)

    report = {}
    segments = mp.transcribe_tracks(meeting, terms=None, me_name="Me", report=report)

    # the surviving mic track is kept (single-track transcript), not discarded
    assert [(s["speaker"], s["text"]) for s in segments] == [("Me", "cloud")]
    assert report["failed_tracks"] == ["system.wav"]
    assert report["transcribed_tracks"] == ["mic.wav"]
    # the survivor's asr.json is persisted; the failed track leaves none
    assert json.loads(meeting.work_mic_asr.read_text())["text"] == "cloud"
    assert not meeting.work_system_asr.exists()


def test_all_tracks_failing_raises_with_underlying_cause(meeting, monkeypatch):
    monkeypatch.setattr(
        transcribe_soniox,
        "transcribe_file",
        lambda audio, **kw: (_ for _ in ()).throw(RuntimeError("boom-cause")),
    )

    with pytest.raises(RuntimeError, match="boom-cause"):
        mp.transcribe_tracks(meeting, terms=None, me_name="Me")


def test_existing_decodable_asr_is_reused_not_rebilled(meeting, monkeypatch):
    # A prior run already produced work/mic.asr.json; only the missing track
    # (system) should be re-submitted, so the mic is never re-billed.
    meeting.work_mic_asr.write_text(json.dumps(_doc("cached mic")), encoding="utf-8")
    calls = []

    def soniox(audio, **kwargs):
        calls.append(audio)
        return _doc("fresh system")

    monkeypatch.setattr(transcribe_soniox, "transcribe_file", soniox)

    segments = mp.transcribe_tracks(meeting, terms=None, me_name="Me")

    assert [c.endswith("system.wav") for c in calls] == [True]  # mic not resubmitted
    assert sorted((s["speaker"], s["text"]) for s in segments) == [
        ("Me", "cached mic"),
        ("Them", "fresh system"),
    ]


def test_corrupt_asr_cache_is_re_transcribed(meeting, monkeypatch):
    meeting.work_mic_asr.write_text("{ not json", encoding="utf-8")
    calls = []
    monkeypatch.setattr(
        transcribe_soniox, "transcribe_file", lambda audio, **kw: calls.append(audio) or _doc("re")
    )

    mp.transcribe_tracks(meeting, terms=None, me_name="Me")

    # both tracks submitted: the undecodable cache does not count as a result
    assert {c.rsplit("/", 1)[1] for c in calls} == {"mic.wav", "system.wav"}
    assert json.loads(meeting.work_mic_asr.read_text())["text"] == "re"


def test_overall_engine_classifies_only_soniox():
    assert transcribe_soniox.DEFAULT_MODEL == "stt-async-v5"
    assert (
        mp.overall_engine(
            [
                {"model": "soniox:stt-async-v5"},
                {"model": "soniox:stt-async-v5"},
            ]
        )
        == "soniox"
    )
    assert mp.overall_engine([{"model": "unknown"}]) is None


def test_collect_low_confidence_spans_merges_low_words_across_spacing_tokens():
    tokens = [
        {"text": "good", "start_ms": 0, "end_ms": 100, "confidence": 0.98},
        {"text": " ", "start_ms": 100, "end_ms": 110},
        {"text": "gar", "start_ms": 110, "end_ms": 200, "confidence": 0.42},
        {"text": " ", "start_ms": 200, "end_ms": 210},
        {"text": "bled", "start_ms": 210, "end_ms": 320, "confidence": 0.31},
        {"text": " clear", "start_ms": 320, "end_ms": 450, "confidence": 0.93},
    ]

    assert transcribe_soniox.low_confidence_spans(tokens) == [
        {"text": "gar bled", "start": 0.11, "end": 0.32, "confidence": 0.31}
    ]


def test_soniox_transcribe_file_attaches_low_confidence_doc_field(monkeypatch, tmp_path):
    audio = tmp_path / "audio.wav"
    audio.write_bytes(b"RIFF")
    tokens = [
        {"text": "bad", "start_ms": 0, "end_ms": 100, "confidence": 0.4},
        {"text": " ok", "start_ms": 100, "end_ms": 220, "confidence": 0.95},
    ]
    monkeypatch.setattr(transcribe_soniox, "_auth", lambda: {"Authorization": "Bearer x"})
    monkeypatch.setattr(transcribe_soniox, "_audio_duration", lambda audio: 1.0)
    monkeypatch.setattr(transcribe_soniox, "_compressed_copy", lambda audio: None)
    monkeypatch.setattr(transcribe_soniox, "upload", lambda audio: "file")
    monkeypatch.setattr(transcribe_soniox, "create_transcription", lambda *a, **k: "tid")
    monkeypatch.setattr(transcribe_soniox, "wait", lambda *a, **k: None)
    monkeypatch.setattr(transcribe_soniox, "fetch_tokens", lambda tid: ("bad ok", tokens))
    monkeypatch.setattr(transcribe_soniox.requests, "delete", lambda *a, **k: _OkResp({}))

    doc = transcribe_soniox.transcribe_file(str(audio))

    assert doc["segments"] == [
        {
            "start": 0.0,
            "end": 0.22,
            "text": "bad ok",
            "words": [
                {"text": "bad", "start": 0.0, "end": 0.1, "confidence": 0.4},
                {"text": "ok", "start": 0.1, "end": 0.22, "confidence": 0.95},
            ],
        }
    ]
    assert doc["low_confidence"] == [{"text": "bad", "start": 0.0, "end": 0.1, "confidence": 0.4}]


def test_tokens_to_segments_attaches_word_timings_and_skips_punctuation():
    tokens = [
        {
            "text": "Hello",
            "start_ms": 4,
            "end_ms": 456,
            "confidence": 0.99,
            "language": "en",
            "speaker": 1,
        },
        {"text": ",", "start_ms": 456, "end_ms": 470, "confidence": 0.99},
        {"text": " ", "start_ms": 470, "end_ms": 480},
        {
            "text": "world",
            "start_ms": 480,
            "end_ms": 955,
            "confidence": 0.98,
            "language": "en",
            "speaker": 1,
        },
        {"text": "!", "start_ms": 955, "end_ms": 970, "confidence": 0.98},
    ]

    segments = transcribe_soniox.tokens_to_segments(tokens)

    assert segments == [
        {
            "start": 0.004,
            "end": 0.97,
            "text": "Hello, world!",
            "speaker": 1,
            "languages": ["en"],
            "words": [
                {
                    "text": "Hello",
                    "start": 0.0,
                    "end": 0.46,
                    "confidence": 0.99,
                    "language": "en",
                    "speaker": "1",
                },
                {
                    "text": "world",
                    "start": 0.48,
                    "end": 0.95,
                    "confidence": 0.98,
                    "language": "en",
                    "speaker": "1",
                },
            ],
        }
    ]


def test_transcribe_file_uses_preprocessed_audio_and_restores_raw_times(monkeypatch, tmp_path):
    raw = tmp_path / "raw.wav"
    speech = tmp_path / "speech.flac"
    raw.write_bytes(b"RIFF")
    speech.write_bytes(b"FLAC")
    tokens = [{"text": "hello", "start_ms": 200, "end_ms": 800, "confidence": 0.99}]
    mapping = [{"processed_start": 0.0, "processed_end": 1.0, "raw_start": 10.0, "raw_end": 11.0}]
    uploads = []

    monkeypatch.setattr(transcribe_soniox, "_auth", lambda: {"Authorization": "Bearer x"})
    monkeypatch.setattr(transcribe_soniox, "_audio_duration", lambda audio: 20.0)
    monkeypatch.setattr(
        transcribe_soniox,
        "speech_only_copy",
        lambda audio: (speech, mapping),
    )
    monkeypatch.setattr(transcribe_soniox, "_compressed_copy", lambda audio: None)
    monkeypatch.setattr(transcribe_soniox, "upload", lambda audio: uploads.append(audio) or "file")
    monkeypatch.setattr(transcribe_soniox, "create_transcription", lambda *a, **k: "tid")
    monkeypatch.setattr(transcribe_soniox, "wait", lambda *a, **k: None)
    monkeypatch.setattr(transcribe_soniox, "fetch_tokens", lambda tid: ("hello", tokens))
    monkeypatch.setattr(transcribe_soniox.requests, "delete", lambda *a, **k: _OkResp({}))

    doc = transcribe_soniox.transcribe_file(str(raw))

    assert uploads == [str(speech)]
    assert doc["segments"][0]["start"] == 10.2
    assert doc["segments"][0]["end"] == 10.8
    assert doc["preprocessing"]["speech_only"] is True


def test_speech_trim_restores_tokens_before_segment_grouping(monkeypatch, tmp_path):
    raw = tmp_path / "raw.wav"
    speech = tmp_path / "speech.flac"
    raw.write_bytes(b"RIFF")
    speech.write_bytes(b"FLAC")
    tokens = [
        {"text": "first", "start_ms": 200, "end_ms": 800, "speaker": 1, "confidence": 0.99},
        {"text": " second", "start_ms": 1300, "end_ms": 1800, "speaker": 1, "confidence": 0.99},
    ]
    mapping = [
        {"processed_start": 0.0, "processed_end": 1.0, "raw_start": 10.0, "raw_end": 11.0},
        {"processed_start": 1.0, "processed_end": 2.0, "raw_start": 100.0, "raw_end": 101.0},
    ]

    monkeypatch.setattr(transcribe_soniox, "_auth", lambda: {"Authorization": "Bearer x"})
    monkeypatch.setattr(transcribe_soniox, "_audio_duration", lambda audio: 120.0)
    monkeypatch.setattr(transcribe_soniox, "speech_only_copy", lambda audio: (speech, mapping))
    monkeypatch.setattr(transcribe_soniox, "_compressed_copy", lambda audio: None)
    monkeypatch.setattr(transcribe_soniox, "upload", lambda audio: "file")
    monkeypatch.setattr(transcribe_soniox, "create_transcription", lambda *a, **k: "tid")
    monkeypatch.setattr(transcribe_soniox, "wait", lambda *a, **k: None)
    monkeypatch.setattr(transcribe_soniox, "fetch_tokens", lambda tid: ("first second", tokens))
    monkeypatch.setattr(transcribe_soniox.requests, "delete", lambda *a, **k: _OkResp({}))

    doc = transcribe_soniox.transcribe_file(str(raw))

    assert [(s["start"], s["end"], s["text"]) for s in doc["segments"]] == [
        (10.2, 10.8, "first"),
        (100.3, 100.8, "second"),
    ]


def test_tokens_to_segments_splits_on_restored_word_gaps():
    tokens = [
        {"text": "first", "start_ms": 10000, "end_ms": 10800, "speaker": 1, "confidence": 0.99},
        {"text": " second", "start_ms": 100300, "end_ms": 100800, "speaker": 1, "confidence": 0.99},
    ]

    segments = transcribe_soniox.tokens_to_segments(tokens)

    assert [(s["start"], s["end"], s["text"]) for s in segments] == [
        (10.0, 10.8, "first"),
        (100.3, 100.8, "second"),
    ]


def test_tokens_to_segments_does_not_extend_segment_to_late_punctuation():
    tokens = [
        {"text": "hello", "start_ms": 10000, "end_ms": 10800, "speaker": 1, "confidence": 0.99},
        {"text": ".", "start_ms": 100000, "end_ms": 100100, "speaker": 1, "confidence": 0.99},
    ]

    segments = transcribe_soniox.tokens_to_segments(tokens)

    assert segments == [
        {
            "start": 10.0,
            "end": 10.8,
            "text": "hello.",
            "speaker": 1,
            "languages": [],
            "words": [
                {"text": "hello", "start": 10.0, "end": 10.8, "confidence": 0.99, "speaker": "1"}
            ],
        }
    ]


def test_upload_filters_highpass_by_default_and_loudnorm_opt_in(monkeypatch):
    monkeypatch.delenv("TAMLIL_ASR_LOUDNORM", raising=False)
    assert transcribe_soniox._upload_filters() == ["highpass=f=80"]

    monkeypatch.setenv("TAMLIL_ASR_LOUDNORM", "1")
    assert transcribe_soniox._upload_filters() == ["highpass=f=80", "dynaudnorm"]

    # any value other than exactly "1" leaves loudnorm off
    monkeypatch.setenv("TAMLIL_ASR_LOUDNORM", "0")
    assert transcribe_soniox._upload_filters() == ["highpass=f=80"]


def test_compressed_copy_applies_highpass_before_resample(monkeypatch, tmp_path):
    monkeypatch.delenv("TAMLIL_ASR_LOUDNORM", raising=False)
    captured = {}
    monkeypatch.setattr(transcribe_soniox, "ffmpeg_path", lambda: "/bin/ffmpeg")
    monkeypatch.setattr(
        transcribe_soniox.subprocess,
        "run",
        lambda cmd, **kw: captured.update(cmd=cmd),
    )

    out = transcribe_soniox._compressed_copy(str(tmp_path / "in.wav"))
    assert out is not None
    out.unlink(missing_ok=True)

    cmd = captured["cmd"]
    assert "-af" in cmd
    assert cmd[cmd.index("-af") + 1] == "highpass=f=80"
    # highpass filter runs, then the output is resampled to 16 kHz
    assert cmd[cmd.index("-af")] and cmd.index("-af") < cmd.index("-ar")


def test_speech_only_copy_filtergraph_carries_highpass_and_50db_trim(monkeypatch, tmp_path):
    monkeypatch.delenv("TAMLIL_ASR_LOUDNORM", raising=False)
    assert transcribe_soniox.SILENCE_NOISE == "-50dB"

    monkeypatch.setattr(transcribe_soniox, "ffmpeg_path", lambda: "/bin/ffmpeg")
    monkeypatch.setattr(transcribe_soniox, "_audio_duration", lambda audio: 100.0)

    detect_stderr = (
        "[silencedetect @ 0x0] silence_start: 10.0\n"
        "[silencedetect @ 0x0] silence_end: 40.0 | silence_duration: 30.0\n"
    )
    captured = {}

    class _Detected:
        stderr = detect_stderr

    def fake_run(cmd, **kw):
        if "silencedetect" in " ".join(cmd):
            # the -50dB constant reaches the silencedetect filter
            assert "noise=-50dB" in " ".join(cmd)
            return _Detected()
        captured["cmd"] = cmd
        return None

    monkeypatch.setattr(transcribe_soniox.subprocess, "run", fake_run)

    result = transcribe_soniox.speech_only_copy(str(tmp_path / "in.wav"))
    assert result is not None
    result[0].unlink(missing_ok=True)

    graph = captured["cmd"][captured["cmd"].index("-filter_complex") + 1]
    # highpass runs after aformat and before the final resample
    assert "highpass=f=80" in graph
    assert graph.index("aformat") < graph.index("highpass=f=80") < graph.index("aresample=16000")


def test_pipeline_writes_final_transcript_echo_report_and_timings_on_skip_transcribe(
    tmp_path, monkeypatch
):
    monkeypatch.setenv("TAMLIL_LEXICON_ROOT", str(tmp_path))
    layout = RecordingLayout(tmp_path)
    layout.prepare()
    segments = [
        {
            "start": 1.0,
            "end": 3.0,
            "text": "I think we should ship the API change",
            "speaker": "Me",
        },
        {
            "start": 2.0,
            "end": 4.0,
            "text": "I think we should ship the API change",
            "speaker": "Them",
        },
    ]
    layout.work_merged_raw.write_text(
        json.dumps(
            {
                "model": "merged",
                "segments": segments,
                "text": " ".join(s["text"] for s in segments),
            }
        ),
        encoding="utf-8",
    )

    assert mp.main([str(tmp_path), "--skip-transcribe"]) == 0

    report = json.loads(layout.work_echo_report.read_text(encoding="utf-8"))
    timings = json.loads(layout.work_pipeline_timings.read_text(encoding="utf-8"))
    merged = json.loads(layout.work_merged_raw.read_text(encoding="utf-8"))
    final = json.loads(layout.final_transcript_json.read_text(encoding="utf-8"))
    assert report["reasons"] == {"text_duplicate": 1}
    assert merged["echo_report"]["dropped"] == 1
    assert final["segments"] == [segments[1]]
    assert "total" in timings
    assert "echo" in timings


def test_pipeline_applies_learned_lexicon_rewrites(tmp_path, monkeypatch):
    lexdir = tmp_path / "lexicon"
    lexdir.mkdir()
    (lexdir / "dictionary.json").write_text(
        json.dumps(
            {
                "version": 2,
                "ingested": 0,
                "terms": [
                    {
                        "canonical": "Kubernetes",
                        "variants": ["kubernetis"],
                        "count": 2,
                        "last_seen": "2026-06-01",
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setenv("TAMLIL_LEXICON_ROOT", str(lexdir))

    meeting_dir = tmp_path / "meeting"
    meeting_dir.mkdir()
    layout = RecordingLayout(meeting_dir)
    layout.prepare()
    layout.work_merged_raw.write_text(
        json.dumps(
            {
                "model": "soniox:merged",
                "segments": [
                    {"start": 0.0, "end": 2.0, "text": "deploy to kubernetis now", "speaker": "Me"}
                ],
                "echo_suppressed": True,
                "text": "deploy to kubernetis now",
            }
        ),
        encoding="utf-8",
    )

    assert mp.main([str(meeting_dir), "--skip-transcribe"]) == 0

    final = json.loads(layout.final_transcript_json.read_text(encoding="utf-8"))
    assert final["segments"][0]["text"] == "deploy to Kubernetes now"
    # merged.raw.json stays pre-lexicon so re-runs re-apply newer rules
    merged = json.loads(layout.work_merged_raw.read_text(encoding="utf-8"))
    assert merged["segments"][0]["text"] == "deploy to kubernetis now"


def test_skip_transcribe_backfills_missing_echo_offset(tmp_path, monkeypatch):
    from tamlil import echo

    meeting_dir = tmp_path / "meeting"
    meeting_dir.mkdir()
    layout = RecordingLayout(meeting_dir)
    layout.prepare()
    layout.raw_mic.write_bytes(b"RIFF")
    layout.raw_system.write_bytes(b"RIFF")
    layout.work_merged_raw.write_text(
        json.dumps(
            {
                "model": "soniox:merged",
                "segments": [{"start": 0.0, "end": 1.0, "text": "hello", "speaker": "Me"}],
                "echo_suppressed": True,
                "echo_report": {"dropped": 0, "reasons": {}, "drops": []},
                "text": "hello",
            }
        ),
        encoding="utf-8",
    )

    monkeypatch.setattr(echo, "_load", lambda path: [0.0, 1.0, 0.0])
    monkeypatch.setattr(echo, "_estimate_broad_delay", lambda mic, sysv: (16000 * 5, 0.4))

    assert mp.main([str(meeting_dir), "--skip-transcribe"]) == 0

    report = json.loads(layout.work_echo_report.read_text(encoding="utf-8"))
    merged = json.loads(layout.work_merged_raw.read_text(encoding="utf-8"))
    final = json.loads(layout.final_transcript_json.read_text(encoding="utf-8"))
    assert report["system_mic_offset_s"] == 5.0
    assert merged["echo_report"]["system_mic_offset_s"] == 5.0
    assert final["echo_report"]["system_mic_offset_s"] == 5.0


def test_default_me_name_is_nonempty_capitalized():
    name = mp.default_me_name()
    assert name
    assert not name.islower()


def test_error_state_collapses_whitespace_and_caps_length():
    multiline = mp.error_state(RuntimeError("upload failed:\n  500\n  retry"))
    assert multiline == "error: upload failed: 500 retry"

    huge = mp.error_state(RuntimeError("x" * 1000))
    assert len(huge) == len("error: ") + mp.ERROR_STATE_MAX_LEN
    assert huge.endswith("...")

    assert mp.error_state(KeyboardInterrupt()) == "error: KeyboardInterrupt"


def _recordings_db(tmp_path, rec_id):
    db = tmp_path / "tamlil.sqlite"
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE recordings (id TEXT PRIMARY KEY, state TEXT NOT NULL, stage TEXT)")
    con.execute(
        "INSERT INTO recordings (id, state, stage) VALUES (?, 'processing', 'transcribing')",
        (rec_id,),
    )
    con.commit()
    con.close()
    return db


def _pipeline_db(tmp_path, rec_id):
    """A recording db with the tables main touches on a full run (recordings +
    clarifications); speaker_names is intentionally absent to exercise the
    get_speaker_names fallback."""
    db = tmp_path / "tamlil.sqlite"
    con = sqlite3.connect(db)
    con.executescript(
        "CREATE TABLE recordings (id TEXT PRIMARY KEY, state TEXT NOT NULL, stage TEXT);"
        "CREATE TABLE clarifications (recording_id TEXT PRIMARY KEY, json TEXT NOT NULL);"
    )
    con.execute(
        "INSERT INTO recordings (id, state, stage) VALUES (?, 'processing', 'transcribing')",
        (rec_id,),
    )
    con.commit()
    con.close()
    return db


def test_pipeline_discards_unanswered_call_when_no_speech(tmp_path, monkeypatch):
    meeting_dir = tmp_path / "meeting"
    meeting_dir.mkdir()
    rec_id = meeting_dir.name
    db = _pipeline_db(tmp_path, rec_id)
    monkeypatch.setenv("TAMLIL_LEXICON_ROOT", str(tmp_path))
    monkeypatch.setenv("TAMLIL_DB_PATH", str(db))
    monkeypatch.setenv("TAMLIL_RECORDING_ID", rec_id)

    layout = RecordingLayout(meeting_dir)
    layout.prepare()
    layout.raw_mic.write_bytes(b"RIFF")
    layout.raw_system.write_bytes(b"RIFF")

    # Slack rang but nobody answered: both tracks record, transcribe to nothing.
    monkeypatch.setattr(mp, "lookup_roster", lambda db, started: {})
    monkeypatch.setattr(mp, "transcribe_tracks", lambda *a, **k: [])

    assert mp.main([str(meeting_dir)]) == 0

    state, stage = (
        sqlite3.connect(db)
        .execute("SELECT state, stage FROM recordings WHERE id = ?", (rec_id,))
        .fetchone()
    )
    assert state == "discarded (call not answered)"
    # An empty final transcript is written (not an error), so the app's
    # finalTranscriptIsEmpty discard/notification path can pick it up.
    final = json.loads(layout.final_transcript_json.read_text(encoding="utf-8"))
    assert final["segments"] == []
    assert layout.final_transcript_md.read_text(encoding="utf-8").startswith("# Transcript")


def test_pipeline_records_single_line_error_state_on_failure(tmp_path, monkeypatch):
    meeting_dir = tmp_path / "meeting"
    meeting_dir.mkdir()
    rec_id = meeting_dir.name
    db = _recordings_db(tmp_path, rec_id)
    monkeypatch.setenv("TAMLIL_LEXICON_ROOT", str(tmp_path))
    monkeypatch.setenv("TAMLIL_DB_PATH", str(db))
    monkeypatch.setenv("TAMLIL_RECORDING_ID", rec_id)

    # No audio tracks present -> pipeline raises in transcribe stage.
    with pytest.raises(RuntimeError, match="no audio tracks found"):
        mp.main([str(meeting_dir)])

    state, stage = (
        sqlite3.connect(db)
        .execute("SELECT state, stage FROM recordings WHERE id = ?", (rec_id,))
        .fetchone()
    )
    assert state.startswith("error: ")
    assert "\n" not in state
    # stage cleared so the UI does not show a stale "transcribing" beside the error
    assert stage is None


def test_pipeline_failure_to_record_error_does_not_mask_cause(tmp_path, monkeypatch):
    meeting_dir = tmp_path / "meeting"
    meeting_dir.mkdir()
    monkeypatch.setenv("TAMLIL_LEXICON_ROOT", str(tmp_path))

    def explode(self, state, stage=None):
        if state.startswith("error:"):
            raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(recording_db.RecordingDB, "set_state", explode)

    with pytest.raises(RuntimeError, match="no audio tracks found"):
        mp.main([str(meeting_dir)])


def _http_error(status, body):
    import requests

    resp = requests.Response()
    resp.status_code = status
    resp.encoding = "utf-8"
    resp._content = (body if isinstance(body, str) else json.dumps(body)).encode()
    return requests.HTTPError(response=resp)


def test_http_error_message_extracts_detail_and_key_hint():
    msg = transcribe_soniox._http_error_message(_http_error(401, {"message": "invalid api key"}))
    assert "401" in msg
    assert "invalid api key" in msg
    assert "Keychain" in msg


def test_http_error_message_falls_back_to_text_body():
    msg = transcribe_soniox._http_error_message(_http_error(500, "upstream boom"))
    assert "500" in msg
    assert "upstream boom" in msg
    assert "Keychain" not in msg


def test_main_reports_missing_audio_cleanly(tmp_path):
    with pytest.raises(SystemExit) as ei:
        transcribe_soniox.main([str(tmp_path / "nope.wav")])
    assert "not found" in str(ei.value.code)


def test_main_reports_http_error_cleanly(monkeypatch, tmp_path):
    audio = tmp_path / "a.wav"
    audio.write_bytes(b"RIFF")

    def boom(*a, **k):
        raise _http_error(400, {"message": "bad audio file"})

    monkeypatch.setattr(transcribe_soniox, "transcribe_file", boom)
    with pytest.raises(SystemExit) as ei:
        transcribe_soniox.main([str(audio)])
    assert "bad audio file" in str(ei.value.code)


def test_main_reports_network_error_cleanly(monkeypatch, tmp_path):
    import requests

    audio = tmp_path / "a.wav"
    audio.write_bytes(b"RIFF")

    def down(*a, **k):
        raise requests.ConnectionError("connection refused")

    monkeypatch.setattr(transcribe_soniox, "transcribe_file", down)
    with pytest.raises(SystemExit) as ei:
        transcribe_soniox.main([str(audio)])
    assert "network error" in str(ei.value.code)


class _FakeResp:
    def __init__(self, *, status=None, http_error_code=None):
        self._status = status
        self.status_code = http_error_code
        self._http_error_code = http_error_code

    def raise_for_status(self):
        if self._http_error_code:
            err = transcribe_soniox.requests.HTTPError(str(self._http_error_code))
            err.response = self
            raise err

    def json(self):
        return {"status": self._status}


def test_wait_retries_transient_poll_errors_then_completes(monkeypatch):
    monkeypatch.setattr(transcribe_soniox, "_auth", lambda: {})
    monkeypatch.setattr(transcribe_soniox.time, "sleep", lambda s: None)

    calls = []

    def fake_get(url, **kw):
        calls.append(url)
        if len(calls) == 1:
            raise transcribe_soniox.requests.ConnectionError("reset")
        if len(calls) == 2:
            raise transcribe_soniox.requests.HTTPError(
                "503", response=_FakeResp(http_error_code=503)
            )
        return _FakeResp(status="completed")

    monkeypatch.setattr(transcribe_soniox.requests, "get", fake_get)

    assert transcribe_soniox.wait("tid", poll_s=0.0, deadline_s=600.0) is None
    assert len(calls) == 3


def test_wait_aborts_immediately_on_4xx(monkeypatch):
    monkeypatch.setattr(transcribe_soniox, "_auth", lambda: {})
    monkeypatch.setattr(transcribe_soniox.time, "sleep", lambda s: None)

    calls = []

    def fake_get(url, **kw):
        calls.append(url)
        return _FakeResp(http_error_code=401)

    monkeypatch.setattr(transcribe_soniox.requests, "get", fake_get)

    with pytest.raises(RuntimeError, match="polling tid failed"):
        transcribe_soniox.wait("tid", poll_s=0.0, deadline_s=600.0)
    assert len(calls) == 1


def test_wait_gives_up_after_transient_retry_cap(monkeypatch):
    monkeypatch.setattr(transcribe_soniox, "_auth", lambda: {})
    monkeypatch.setattr(transcribe_soniox.time, "sleep", lambda s: None)

    calls = []

    def fake_get(url, **kw):
        calls.append(url)
        raise transcribe_soniox.requests.ConnectionError("down")

    monkeypatch.setattr(transcribe_soniox.requests, "get", fake_get)

    with pytest.raises(RuntimeError, match="consecutive"):
        transcribe_soniox.wait("tid", poll_s=0.0, deadline_s=600.0)
    assert len(calls) == transcribe_soniox.POLL_MAX_TRANSIENT_RETRIES + 1


class _OkResp:
    def __init__(self, payload):
        self._payload = payload

    def raise_for_status(self):
        pass

    def json(self):
        return self._payload


def test_create_transcription_sends_structured_context_and_reference(monkeypatch):
    captured = {}
    monkeypatch.setattr(transcribe_soniox, "_auth", lambda: {})
    monkeypatch.setattr(
        transcribe_soniox.requests,
        "post",
        lambda url, **kw: captured.update(body=kw["json"]) or _OkResp({"id": "tid"}),
    )

    tid = transcribe_soniox.create_transcription(
        "file",
        model="m",
        lang_hints=["he", "en"],
        diarize=True,
        terms=["Foo", "Bar"],
        general=[{"key": "meeting", "value": "Sync"}],
        client_reference_id="rec-1",
    )

    assert tid == "tid"
    # v5 structured context object: general first (broadest influence), then terms
    assert captured["body"]["context"] == {
        "general": [{"key": "meeting", "value": "Sync"}],
        "terms": ["Foo", "Bar"],
    }
    assert captured["body"]["client_reference_id"] == "rec-1"


def test_create_transcription_omits_empty_context_sections(monkeypatch):
    captured = {}
    monkeypatch.setattr(transcribe_soniox, "_auth", lambda: {})
    monkeypatch.setattr(
        transcribe_soniox.requests,
        "post",
        lambda url, **kw: captured.update(body=kw["json"]) or _OkResp({"id": "tid"}),
    )

    transcribe_soniox.create_transcription(
        "file",
        model="m",
        lang_hints=["he"],
        diarize=False,
        terms=[],
        general=[{"key": "languages", "value": "Hebrew, English"}],
    )

    # only the non-empty section is present, and no client_reference_id key
    assert captured["body"]["context"] == {
        "general": [{"key": "languages", "value": "Hebrew, English"}]
    }
    assert "client_reference_id" not in captured["body"]

    captured.clear()
    transcribe_soniox.create_transcription(
        "file",
        model="m",
        lang_hints=["he"],
        diarize=False,
        terms=[],
    )
    assert "context" not in captured["body"]


def test_upload_retries_5xx_then_succeeds(monkeypatch, tmp_path):
    # A 5xx means Soniox explicitly did not commit the upload, so retrying the
    # non-idempotent POST is safe.
    audio = tmp_path / "a.wav"
    audio.write_bytes(b"RIFF")
    monkeypatch.setattr(transcribe_soniox, "_auth", lambda: {})
    monkeypatch.setattr(transcribe_soniox.time, "sleep", lambda s: None)

    calls = []

    def fake_post(url, **kw):
        calls.append(url)
        if len(calls) <= 2:
            return _FakeResp(http_error_code=503)
        return _OkResp({"id": "fid"})

    monkeypatch.setattr(transcribe_soniox.requests, "post", fake_post)

    assert transcribe_soniox.upload(str(audio)) == "fid"
    assert len(calls) == 3


def test_upload_does_not_retry_response_less_error(monkeypatch, tmp_path):
    # A connection/timeout error carries no response, so Soniox may already have
    # stored the file; retrying the non-idempotent POST would orphan it. The
    # error must propagate on the first attempt, not retry.
    audio = tmp_path / "a.wav"
    audio.write_bytes(b"RIFF")
    monkeypatch.setattr(transcribe_soniox, "_auth", lambda: {})
    monkeypatch.setattr(transcribe_soniox.time, "sleep", lambda s: None)

    calls = []

    def fake_post(url, **kw):
        calls.append(url)
        raise transcribe_soniox.requests.ConnectionError("reset")

    monkeypatch.setattr(transcribe_soniox.requests, "post", fake_post)

    with pytest.raises(transcribe_soniox.requests.ConnectionError):
        transcribe_soniox.upload(str(audio))
    assert len(calls) == 1


def test_create_transcription_aborts_immediately_on_4xx(monkeypatch):
    monkeypatch.setattr(transcribe_soniox, "_auth", lambda: {})
    monkeypatch.setattr(transcribe_soniox.time, "sleep", lambda s: None)

    calls = []

    def fake_post(url, **kw):
        calls.append(url)
        return _FakeResp(http_error_code=400)

    monkeypatch.setattr(transcribe_soniox.requests, "post", fake_post)

    with pytest.raises(transcribe_soniox.requests.HTTPError):
        transcribe_soniox.create_transcription(
            "file", model="m", lang_hints=["he"], diarize=True, terms=["x"]
        )
    assert len(calls) == 1


def test_setup_retry_gives_up_after_cap(monkeypatch, tmp_path):
    audio = tmp_path / "a.wav"
    audio.write_bytes(b"RIFF")
    monkeypatch.setattr(transcribe_soniox, "_auth", lambda: {})
    monkeypatch.setattr(transcribe_soniox.time, "sleep", lambda s: None)

    calls = []

    def fake_post(url, **kw):
        calls.append(url)
        return _FakeResp(http_error_code=503)

    monkeypatch.setattr(transcribe_soniox.requests, "post", fake_post)

    with pytest.raises(transcribe_soniox.requests.HTTPError):
        transcribe_soniox.upload(str(audio))
    assert len(calls) == transcribe_soniox.SETUP_MAX_TRANSIENT_RETRIES + 1


def test_transcribe_file_deletes_the_transcription_not_just_the_file(monkeypatch, tmp_path):
    # Soniox's async API stores the transcription (the transcript text) alongside
    # the file; deleting the transcription removes both, so cleanup must target
    # the transcription — deleting only the file would leave the transcript text
    # persisting on Soniox.
    audio = tmp_path / "a.wav"
    audio.write_bytes(b"RIFF")
    deletes = []
    monkeypatch.setattr(transcribe_soniox, "_auth", lambda: {"Authorization": "Bearer x"})
    monkeypatch.setattr(transcribe_soniox, "_audio_duration", lambda audio: 1.0)
    monkeypatch.setattr(transcribe_soniox, "speech_only_copy", lambda audio: None)
    monkeypatch.setattr(transcribe_soniox, "_compressed_copy", lambda audio: None)
    monkeypatch.setattr(transcribe_soniox, "upload", lambda audio: "fid")
    monkeypatch.setattr(transcribe_soniox, "create_transcription", lambda *a, **k: "tid")
    monkeypatch.setattr(transcribe_soniox, "wait", lambda *a, **k: None)
    monkeypatch.setattr(transcribe_soniox, "fetch_tokens", lambda tid: ("hi", []))
    monkeypatch.setattr(
        transcribe_soniox.requests, "delete", lambda url, **k: deletes.append(url) or _OkResp({})
    )

    transcribe_soniox.transcribe_file(str(audio))

    assert deletes == [f"{transcribe_soniox.API}/transcriptions/tid"]


def test_transcribe_file_deletes_the_file_when_no_transcription_created(monkeypatch, tmp_path):
    # If the job never got created (upload ok, create_transcription blew up) there
    # is no transcription to delete, but the uploaded file must still be cleaned.
    audio = tmp_path / "a.wav"
    audio.write_bytes(b"RIFF")
    deletes = []
    monkeypatch.setattr(transcribe_soniox, "_auth", lambda: {"Authorization": "Bearer x"})
    monkeypatch.setattr(transcribe_soniox, "_audio_duration", lambda audio: 1.0)
    monkeypatch.setattr(transcribe_soniox, "speech_only_copy", lambda audio: None)
    monkeypatch.setattr(transcribe_soniox, "_compressed_copy", lambda audio: None)
    monkeypatch.setattr(transcribe_soniox, "upload", lambda audio: "fid")
    monkeypatch.setattr(
        transcribe_soniox,
        "create_transcription",
        lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom")),
    )
    monkeypatch.setattr(
        transcribe_soniox.requests, "delete", lambda url, **k: deletes.append(url) or _OkResp({})
    )

    with pytest.raises(RuntimeError, match="boom"):
        transcribe_soniox.transcribe_file(str(audio))

    assert deletes == [f"{transcribe_soniox.API}/files/fid"]


def test_transcribe_file_warns_but_survives_a_failed_remote_delete(monkeypatch, tmp_path, capsys):
    # A cleanup failure must never fail the run or alter output — it is logged.
    audio = tmp_path / "a.wav"
    audio.write_bytes(b"RIFF")
    monkeypatch.setattr(transcribe_soniox, "_auth", lambda: {"Authorization": "Bearer x"})
    monkeypatch.setattr(transcribe_soniox, "_audio_duration", lambda audio: 1.0)
    monkeypatch.setattr(transcribe_soniox, "speech_only_copy", lambda audio: None)
    monkeypatch.setattr(transcribe_soniox, "_compressed_copy", lambda audio: None)
    monkeypatch.setattr(transcribe_soniox, "upload", lambda audio: "fid")
    monkeypatch.setattr(transcribe_soniox, "create_transcription", lambda *a, **k: "tid")
    monkeypatch.setattr(transcribe_soniox, "wait", lambda *a, **k: None)
    monkeypatch.setattr(transcribe_soniox, "fetch_tokens", lambda tid: ("kept text", []))
    monkeypatch.setattr(
        transcribe_soniox.requests,
        "delete",
        lambda *a, **k: (_ for _ in ()).throw(transcribe_soniox.requests.ConnectionError("down")),
    )

    doc = transcribe_soniox.transcribe_file(str(audio))

    assert doc["text"] == "kept text"
    assert "could not delete transcription tid" in capsys.readouterr().err
