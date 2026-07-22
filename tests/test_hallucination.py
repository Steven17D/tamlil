# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

import json

import tamlil.meeting_pipeline as mp
from tamlil import hallucination
from tamlil.recording_layout import RecordingLayout


def seg(start, end, text, speaker="Them", voice=None):
    s = {"start": start, "end": end, "text": text, "speaker": speaker}
    if voice is not None:
        s["voice"] = voice
    return s


def test_collapses_zero_duration_filler_flood():
    # The Soniox loop signature: hundreds of consecutive filler segments on one
    # track, most with start == end, diarization flapping between voices.
    flood = []
    for i in range(20):
        t = 88.11 + i * 0.001
        text = "לא." if i % 2 else "אה... לא."
        flood.append(seg(t, t, text, voice=str(1 + i % 2)))
    segments = (
        [seg(60.0, 62.0, "אני מסתכל על הלוח עכשיו")]
        + flood
        + [seg(95.0, 97.0, "בוא נתחיל את הפגישה")]
    )
    result = hallucination.collapse_loops(segments)
    kept = result["segments"]
    assert len(kept) == 3
    assert kept[0]["text"] == "אני מסתכל על הלוח עכשיו"
    assert kept[1] == flood[0]
    assert kept[2]["text"] == "בוא נתחיל את הפגישה"
    assert result["report"]["dropped"] == 19
    assert result["report"]["runs"][0]["count"] == 20


def test_keeps_genuine_isolated_backchannels():
    segments = [
        seg(10.0, 12.0, "אתה מגיע מחר למשרד?"),
        seg(12.5, 12.74, "לא.", speaker="Me"),
        seg(13.0, 15.0, "חבל, רציתי לעבור על המסמך"),
        seg(15.5, 15.74, "אה... לא,", speaker="Me"),
        seg(16.0, 18.0, "אז נדבר בזום"),
    ]
    result = hallucination.collapse_loops(segments)
    assert result["segments"] == segments
    assert result["report"]["dropped"] == 0


def test_keeps_short_runs_with_real_durations():
    segments = [seg(10.0 + i, 10.3 + i, "לא.") for i in range(4)]
    result = hallucination.collapse_loops(segments)
    assert result["segments"] == segments
    assert result["report"]["dropped"] == 0


def test_collapses_long_uniform_run_even_with_real_durations():
    # No human says the same word in 12 consecutive segments with nothing in
    # between; collapse even when the timestamps look plausible.
    segments = [seg(10.0 + i * 0.5, 10.3 + i * 0.5, "לא.") for i in range(12)]
    result = hallucination.collapse_loops(segments)
    assert len(result["segments"]) == 1
    assert result["segments"][0] == segments[0]
    assert result["report"]["dropped"] == 11


def test_runs_are_per_track_and_survive_interleaving():
    # Real mic speech interleaved in time must not break the system-track run,
    # and must itself be kept.
    flood = [seg(20.0 + i * 0.01, 20.0 + i * 0.01, "לא.") for i in range(8)]
    mic = [
        seg(20.02, 21.5, "אני חושב שזה רעיון טוב", speaker="Me"),
        seg(21.6, 23.0, "בוא נבדוק את זה ביחד", speaker="Me"),
    ]
    segments = sorted(flood + mic, key=lambda s: s["start"])
    result = hallucination.collapse_loops(segments)
    kept_texts = [s["text"] for s in result["segments"]]
    assert kept_texts.count("לא.") == 1
    assert "אני חושב שזה רעיון טוב" in kept_texts
    assert "בוא נבדוק את זה ביחד" in kept_texts
    assert result["report"]["dropped"] == 7


def test_varied_short_texts_are_not_a_loop():
    words = ["כן.", "טוב.", "מחר.", "אולי.", "רגע.", "כן.", "לא.", "אולי."]
    segments = [seg(10.0 + i, 10.3 + i, w) for i, w in enumerate(words)]
    result = hallucination.collapse_loops(segments)
    assert result["segments"] == segments
    assert result["report"]["dropped"] == 0


def test_collapses_degenerate_cluster_with_three_filler_words_and_fragments():
    # Loop residue: three distinct filler words plus split-word fragments,
    # zero durations and identical start times. Collapses only because of the
    # degeneracy signal — the vocabulary alone would be allowed.
    cluster = [
        seg(193.05, 193.05, "אה... לא. סתם... לא.", voice="1"),
        seg(193.05, 193.05, "אה...", voice="2"),
        seg(193.05, 193.23, "אה... א", voice="1"),
        seg(194.43, 194.55, "ה... לא. לא.", voice="1"),
        seg(194.55, 194.55, "אה... לא.", voice="2"),
    ]
    segments = [seg(190.0, 192.0, "בוא נעבור על המשימות")] + cluster
    result = hallucination.collapse_loops(segments)
    assert len(result["segments"]) == 2
    assert result["segments"][1] == cluster[0]
    assert result["report"]["dropped"] == 4


def test_collapses_dilute_long_run_with_few_zero_duration_segments():
    # A loop tail can stretch for minutes with plausible durations, diluting
    # any degenerate-fraction measure. A handful of zero-duration segments is
    # already impossible in real speech, whatever the run length.
    segments = []
    for i in range(20):
        t = 100.0 + i * 8
        text = ["אה... לא.", "לא.", "סתם... אה..."][i % 3]
        dur = 0.0 if i in (2, 5, 9) else 0.4
        segments.append(seg(t, t + dur, text))
    result = hallucination.collapse_loops(segments)
    assert len(result["segments"]) == 1
    assert result["segments"][0] == segments[0]
    assert result["report"]["dropped"] == 19


def test_collapses_run_of_stuttered_segments_with_plausible_durations():
    # Another loop shape: each segment crams the same word many times into a
    # fraction of a second. Durations look non-zero, but no one says "אה"
    # eleven times in 300 milliseconds.
    texts = [
        "אה... אה... אה... אה... אה... אה... אה... פה... אה...",
        "ה... אה... אה... אה... אה... אה... ו... אה... אה...",
        "אה...",
        "ה... אה... אה... אה... אה... אה... אה... אה... אה...",
        "אה... אה... אה... אה... אה...",
        "ה... אה... אה... אה... אה... אה... אה... אה...",
    ]
    segments = [seg(413.0 + i * 3, 413.3 + i * 3, t) for i, t in enumerate(texts)]
    result = hallucination.collapse_loops(segments)
    assert len(result["segments"]) == 1
    assert result["report"]["dropped"] == 5


def test_squeezes_word_repetition_inside_mixed_segments():
    # Real speech with a loop tail welded onto it: keep the speech, squeeze
    # the repetition down to a single hesitation.
    segments = [
        seg(449.2, 450.8, "אני ראיתי את זה... אה... אה... אה... אה... אה... אה..."),
    ]
    result = hallucination.collapse_loops(segments)
    assert result["segments"][0]["text"] == "אני ראיתי את זה... אה..."
    assert result["report"]["squeezed"] == 1


def test_short_genuine_emphasis_is_not_squeezed():
    segments = [seg(10.0, 11.2, "לא. לא. לא, זה לא נכון")]
    result = hallucination.collapse_loops(segments)
    assert result["segments"][0]["text"] == "לא. לא. לא, זה לא נכון"
    assert result["report"]["squeezed"] == 0


def test_three_word_runs_with_real_durations_never_collapse():
    # Rapid genuine backchannel drawing on three words must survive even in a
    # long consecutive run — without degenerate timestamps there is no loop.
    words = ["כן.", "לא.", "טוב.", "כן.", "לא.", "כן.", "טוב.", "לא.", "כן.", "טוב.", "לא.", "כן."]
    segments = [seg(10.0 + i, 10.4 + i, w) for i, w in enumerate(words)]
    result = hallucination.collapse_loops(segments)
    assert result["segments"] == segments
    assert result["report"]["dropped"] == 0


def test_pipeline_skip_transcribe_collapses_flood(tmp_path, monkeypatch):
    monkeypatch.setenv("TAMLIL_LEXICON_ROOT", str(tmp_path))
    meeting_dir = tmp_path / "meeting"
    meeting_dir.mkdir()
    layout = RecordingLayout(meeting_dir)
    layout.prepare()
    flood = [seg(88.11 + i * 0.001, 88.11 + i * 0.001, "לא.") for i in range(20)]
    segments = [seg(1.0, 3.0, "בוקר טוב לכולם", speaker="Me")] + flood
    layout.work_merged_raw.write_text(
        json.dumps(
            {
                "model": "soniox:merged",
                "segments": segments,
                "echo_suppressed": True,
                "echo_report": {
                    "dropped": 0,
                    "reasons": {},
                    "drops": [],
                    "system_mic_offset_s": 1.4,
                },
                "text": " ".join(s["text"] for s in segments),
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    assert mp.main([str(meeting_dir), "--skip-transcribe"]) == 0

    final = json.loads(layout.final_transcript_json.read_text(encoding="utf-8"))
    assert [s["text"] for s in final["segments"]] == ["בוקר טוב לכולם", "לא."]
    assert final["hallucination_report"]["dropped"] == 19
