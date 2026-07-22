# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

import types

import pytest

from tamlil import meeting_pipeline, speaker_labels, util

SEG_ME = {"start": 0.0, "end": 2.0, "text": "let's review", "speaker": "Me"}
SEG_V1 = {"start": 2.5, "end": 5.0, "text": "pipeline green", "speaker": "Them", "voice": "1"}
SEG_V2 = {"start": 5.5, "end": 8.0, "text": "ship it", "speaker": "Them", "voice": "2"}


@pytest.fixture(autouse=True)
def _local_account(monkeypatch):
    # Pin the local account name so sole-attendee resolution is machine-independent.
    monkeypatch.setattr(
        util.pwd,
        "getpwuid",
        lambda _uid: types.SimpleNamespace(pw_gecos="Alice Smith,,,"),
    )


def test_mic_heard_multiple_voices():
    them = {"speaker": "Them", "voice": "9"}
    # Solo mic (one voice) is not a shared room, whatever the system heard.
    assert not speaker_labels.mic_heard_multiple_voices(
        [{"speaker": "Me", "voice": "1"}, them, {"speaker": "Them", "voice": "8"}]
    )
    # Two distinct voices on the mic track => co-located people => shared room.
    assert speaker_labels.mic_heard_multiple_voices(
        [{"speaker": "Me", "voice": "1"}, {"speaker": "Me", "voice": "2"}, them]
    )
    # Nothing diarized (no voice ids) is not a shared room.
    assert not speaker_labels.mic_heard_multiple_voices([{"speaker": "Me"}])


def test_label_assigned_name_wins():
    assert speaker_labels.label(SEG_V1, {"1": "Maya"}, {"Them": 2}) == "Maya"


def test_label_sole_remote_attendee_collapses_voices():
    roster = ["Maya", "Alice"]
    assert speaker_labels.label(SEG_V1, {}, {"Them": 2}, roster) == "Maya"
    assert speaker_labels.label(SEG_V2, {}, {"Them": 2}, roster) == "Maya"


def test_label_speaker_n_when_several_unnamed_voices():
    assert speaker_labels.label(SEG_V1, {}, {"Them": 2}) == "Speaker 1"
    assert speaker_labels.label(SEG_V2, {}, {"Them": 2}) == "Speaker 2"


def test_label_stays_them_for_single_unnamed_voice():
    assert speaker_labels.label(SEG_V1, {}, {"Them": 1}) == "Them"


def test_label_passes_through_mic_speaker():
    assert speaker_labels.label(SEG_ME, {"1": "Maya"}, {"Them": 2}, ["Maya", "Alice"]) == "Me"


def test_label_mic_sole_voice_is_the_local_user():
    seg = {"speaker": "Alice", "voice": "3", "text": "hi", "start": 0.0, "end": 1.0}
    assert speaker_labels.label(seg, {}, {"Alice": 1, "Them": 2}) == "Alice"


def test_label_mic_voices_get_speaker_n_when_room_is_shared():
    # Several people on the mic track (shared room): unnamed voices must be
    # tellable apart, and an assigned name wins exactly like a system voice.
    seg_a = {"speaker": "Alice", "voice": "3", "text": "hi", "start": 0.0, "end": 1.0}
    seg_b = {"speaker": "Alice", "voice": "4", "text": "yo", "start": 1.0, "end": 2.0}
    counts = {"Alice": 2, "Them": 1}
    assert speaker_labels.label(seg_a, {}, counts) == "Speaker 3"
    assert speaker_labels.label(seg_b, {"4": "Danield"}, counts) == "Danield"


def test_label_roster_shortcut_never_applies_to_mic_voices():
    seg = {"speaker": "Alice", "voice": "3", "text": "hi", "start": 0.0, "end": 1.0}
    assert speaker_labels.label(seg, {}, {"Alice": 2}, ["Maya", "Alice"]) == "Speaker 3"


def test_voice_counts_are_per_track():
    mic = {"speaker": "Alice", "voice": "1", "text": "a", "start": 0.0, "end": 1.0}
    assert speaker_labels.voice_counts([SEG_ME, SEG_V1, SEG_V2, dict(SEG_V1), mic]) == {
        "Them": 2,
        "Alice": 1,
    }


def test_renumber_voices_unifies_tracks_without_collision():
    segments = [
        {"speaker": "Alice", "voice": "2", "text": "a", "start": 0.0, "end": 1.0},
        {"speaker": "Them", "voice": "2", "text": "b", "start": 1.0, "end": 2.0},
        {"speaker": "Alice", "voice": "1", "text": "c", "start": 2.0, "end": 3.0},
        {"speaker": "Alice", "voice": "2", "text": "d", "start": 3.0, "end": 4.0},
        {"speaker": "Them", "text": "no voice", "start": 4.0, "end": 5.0},
    ]
    speaker_labels.renumber_voices(segments)
    assert [s.get("voice") for s in segments] == ["1", "2", "3", "1", None]


def test_renumber_voices_is_idempotent():
    segments = [
        {"speaker": "Alice", "voice": "7", "text": "a", "start": 0.0, "end": 1.0},
        {"speaker": "Them", "voice": "7", "text": "b", "start": 1.0, "end": 2.0},
    ]
    speaker_labels.renumber_voices(segments)
    first = [s["voice"] for s in segments]
    speaker_labels.renumber_voices(segments)
    assert [s["voice"] for s in segments] == first == ["1", "2"]


def test_write_transcript_md_resolves_assigned_and_sole_attendee(tmp_path):
    doc = {"segments": [SEG_ME, SEG_V1, SEG_V2]}
    out = tmp_path / "t.md"
    meeting_pipeline.write_transcript_md(doc, out, names={"1": "Maya"}, roster=["Bob", "Alice"])
    text = out.read_text(encoding="utf-8")
    assert "Them" not in text
    assert "**[0:02] Maya:**" in text
    assert "**[0:05] Bob:**" in text
    assert "**[0:00] Me:**" in text


def test_write_transcript_md_speaker_n_without_roster(tmp_path):
    doc = {"segments": [SEG_V1, SEG_V2]}
    out = tmp_path / "t.md"
    meeting_pipeline.write_transcript_md(doc, out)
    text = out.read_text(encoding="utf-8")
    assert "**[0:02] Speaker 1:**" in text
    assert "**[0:05] Speaker 2:**" in text
    assert "Them" not in text


def test_write_transcript_md_single_voice_stays_them(tmp_path):
    doc = {"segments": [SEG_V1]}
    out = tmp_path / "t.md"
    meeting_pipeline.write_transcript_md(doc, out)
    assert "**[0:02] Them:**" in out.read_text(encoding="utf-8")


def test_write_transcript_md_room_meeting_mixes_mic_and_system_voices(tmp_path):
    doc = {
        "segments": [
            {"start": 0.0, "end": 2.0, "text": "room a", "speaker": "Alice", "voice": "1"},
            {"start": 2.0, "end": 4.0, "text": "room b", "speaker": "Alice", "voice": "2"},
            {"start": 4.0, "end": 6.0, "text": "remote", "speaker": "Them", "voice": "3"},
        ]
    }
    out = tmp_path / "t.md"
    meeting_pipeline.write_transcript_md(doc, out, names={"2": "Danield"})
    text = out.read_text(encoding="utf-8")
    assert "**[0:00] Speaker 1:**" in text
    assert "**[0:02] Danield:**" in text
    assert "**[0:04] Them:**" in text
