# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

import numpy as np

from tamlil import echo


def test_estimate_delay_mic_shorter_than_system_no_crash():
    # Mic track ends well before a 'Them' segment that lives only on the system
    # track — the pre-fix code sliced mic[a:b] out of bounds and np.correlate
    # raised ValueError. It must now skip that segment and return safely.
    sr = echo.SR
    mic = np.zeros(int(2 * sr), dtype=np.float32)
    sysv = np.zeros(int(20 * sr), dtype=np.float32)
    them = [{"start": 10.0, "end": 11.0, "speaker": "Them"}]
    assert echo._estimate_delay(mic, sysv, them) is None


def test_peak_ncc_mic_too_short_returns_zero():
    sr = echo.SR
    mic = np.zeros(int(1 * sr), dtype=np.float32)
    sysv = np.zeros(int(20 * sr), dtype=np.float32)
    ncc, offset = echo._peak_ncc(mic, sysv, tau=0, s0=10.0, e0=11.0)
    assert ncc == 0.0 and offset == 0


def test_suppress_reports_text_duplicate_reason_when_triggered(tmp_path):
    segs = [
        {
            "start": 189.0,
            "end": 193.0,
            "text": "אז חכה רגע סליחה אני פשוט רוצה להוציא את זה",
            "speaker": "Me",
        },
        {
            "start": 194.0,
            "end": 198.0,
            "text": "אז חכה רגע, סליחה, אני פשוט רוצה להוציא את זה.",
            "speaker": "Them",
        },
    ]

    result = echo.suppress_with_report(tmp_path, segs)

    assert result["segments"] == [segs[1]]
    assert result["report"]["dropped"] == 1
    assert result["report"]["reasons"] == {"text_duplicate": 1}
    assert result["report"]["drops"][0]["reason"] == "text_duplicate"
    assert result["report"]["drops"][0]["text"] == segs[0]["text"]


def test_suppress_keeps_unique_mic_speech_from_voice_that_had_an_echo(tmp_path):
    segs = [
        {
            "start": 10.0,
            "end": 12.0,
            "text": "I think we should ship the API change",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 10.5,
            "end": 12.5,
            "text": "I think we should ship the API change",
            "speaker": "Me",
            "voice": "2",
        },
        {
            "start": 20.0,
            "end": 22.0,
            "text": "also the budget question is open",
            "speaker": "Me",
            "voice": "2",
        },
        {
            "start": 30.0,
            "end": 32.0,
            "text": "I will follow up with Amit",
            "speaker": "Me",
            "voice": "1",
        },
    ]

    result = echo.suppress_with_report(tmp_path, segs)

    assert result["segments"] == [segs[0], segs[2], segs[3]]
    assert result["report"]["reasons"] == {"text_duplicate": 1}


def test_suppress_drops_mic_voice_with_repeated_text_duplicate_evidence(tmp_path):
    segs = [
        {
            "start": 10.0,
            "end": 13.0,
            "text": "the system transcript has this remote sentence",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 10.4,
            "end": 13.4,
            "text": "the system transcript has this remote sentence",
            "speaker": "Me",
            "voice": "1",
        },
        {
            "start": 20.0,
            "end": 23.0,
            "text": "another remote sentence also appears on system",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 20.4,
            "end": 23.4,
            "text": "another remote sentence also appears on system",
            "speaker": "Me",
            "voice": "1",
        },
        {
            "start": 29.8,
            "end": 33.8,
            "text": "this remote echo fragment was transcribed cleanly differently",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 30.0,
            "end": 34.0,
            "text": "this remote echo fragment is mistranscribed differently",
            "speaker": "Me",
            "voice": "1",
        },
        {
            "start": 31.0,
            "end": 32.0,
            "text": "my actual microphone speech",
            "speaker": "Me",
            "voice": "2",
        },
    ]

    result = echo.suppress_with_report(tmp_path, segs)

    assert result["segments"] == [segs[0], segs[2], segs[4], segs[6]]
    assert result["report"]["reasons"] == {
        "text_duplicate": 2,
        "diarized_remote_voice": 1,
    }


def test_suppress_drops_mic_voice_with_repeated_evidence_even_when_echo_text_varies(tmp_path):
    segs = [
        {
            "start": 10.0,
            "end": 12.0,
            "text": "first remote duplicate sentence",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 10.1,
            "end": 12.1,
            "text": "first remote duplicate sentence",
            "speaker": "Me",
            "voice": "1",
        },
        {
            "start": 20.0,
            "end": 22.0,
            "text": "second remote duplicate sentence",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 20.1,
            "end": 22.1,
            "text": "second remote duplicate sentence",
            "speaker": "Me",
            "voice": "1",
        },
        {
            "start": 29.9,
            "end": 44.9,
            "text": (
                "a long remote echo fragment which Soniox rendered a bit differently avoiding "
                "the direct text matching while it still tracks the clean system copy of this "
                "thought"
            ),
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 30.0,
            "end": 45.0,
            "text": (
                "a long remote echo fragment that Soniox rendered differently enough to avoid "
                "direct text matching though it still tracks the clean system copy of this thought"
            ),
            "speaker": "Me",
            "voice": "1",
        },
        {
            "start": 50.0,
            "end": 52.0,
            "text": "my actual microphone speech",
            "speaker": "Me",
            "voice": "2",
        },
    ]

    result = echo.suppress_with_report(tmp_path, segs)

    assert result["segments"] == [segs[0], segs[2], segs[4], segs[6]]
    assert result["report"]["reasons"] == {
        "text_duplicate": 2,
        "diarized_remote_voice": 1,
    }


def test_suppress_uses_dropped_mic_echo_timing_for_matching_remote_segment(tmp_path):
    segs = [
        {
            "start": 100.0,
            "end": 102.0,
            "text": "previous remote sentence",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 110.0,
            "end": 113.0,
            "text": "repeated remote evidence one",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 110.2,
            "end": 113.2,
            "text": "repeated remote evidence one",
            "speaker": "Me",
            "voice": "1",
        },
        {
            "start": 120.0,
            "end": 123.0,
            "text": "repeated remote evidence two",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 120.2,
            "end": 123.2,
            "text": "repeated remote evidence two",
            "speaker": "Me",
            "voice": "1",
        },
        {
            "start": 133.0,
            "end": 134.5,
            "text": "my local interjection",
            "speaker": "Me",
            "voice": "2",
        },
        {
            "start": 135.0,
            "end": 136.5,
            "text": "yes exactly why not",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 131.0,
            "end": 132.5,
            "text": "yes exactly why not",
            "speaker": "Me",
            "voice": "1",
        },
    ]

    result = echo.suppress_with_report(tmp_path, segs)

    assert result["segments"] == [
        segs[0],
        segs[1],
        segs[3],
        {**segs[6], "start": 131.0, "end": 132.5, "audio_start": 135.0, "audio_end": 136.5},
        segs[5],
    ]


def test_suppress_drops_system_copy_of_local_mic_speech(tmp_path):
    segs = [
        {
            "start": 100.0,
            "end": 102.0,
            "text": "remote duplicate evidence one",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 95.0,
            "end": 97.0,
            "text": "remote duplicate evidence one",
            "speaker": "Me",
            "voice": "1",
        },
        {
            "start": 110.0,
            "end": 112.0,
            "text": "remote duplicate evidence two",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 105.0,
            "end": 107.0,
            "text": "remote duplicate evidence two",
            "speaker": "Me",
            "voice": "1",
        },
        {
            "start": 120.0,
            "end": 121.5,
            "text": "this is my local sentence",
            "speaker": "Me",
            "voice": "2",
        },
        {
            "start": 125.0,
            "end": 126.5,
            "text": "this is my local sentence",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 130.0,
            "end": 132.0,
            "text": "real remote reply",
            "speaker": "Them",
            "voice": "7",
        },
    ]

    result = echo.suppress_with_report(tmp_path, segs)

    assert result["segments"] == [
        {**segs[0], "start": 95.0, "end": 97.0, "audio_start": 100.0, "audio_end": 102.0},
        {**segs[2], "start": 105.0, "end": 107.0, "audio_start": 110.0, "audio_end": 112.0},
        segs[4],
        segs[6],
    ]
    assert result["report"]["reasons"] == {
        "text_duplicate": 2,
        "system_local_echo": 1,
    }


def test_suppress_drops_short_system_copy_only_at_learned_local_delay(tmp_path):
    segs = [
        {
            "start": 100.0,
            "end": 102.0,
            "text": "remote duplicate evidence one",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 95.0,
            "end": 97.0,
            "text": "remote duplicate evidence one",
            "speaker": "Me",
            "voice": "1",
        },
        {
            "start": 110.0,
            "end": 112.0,
            "text": "remote duplicate evidence two",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 105.0,
            "end": 107.0,
            "text": "remote duplicate evidence two",
            "speaker": "Me",
            "voice": "1",
        },
        {
            "start": 120.0,
            "end": 121.0,
            "text": "local anchor phrase",
            "speaker": "Me",
            "voice": "2",
        },
        {
            "start": 125.0,
            "end": 126.0,
            "text": "local anchor phrase",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 130.0,
            "end": 130.2,
            "text": "yes",
            "speaker": "Me",
            "voice": "2",
        },
        {
            "start": 135.1,
            "end": 135.3,
            "text": "yes",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 140.0,
            "end": 140.2,
            "text": "yes",
            "speaker": "Them",
            "voice": "7",
        },
    ]

    result = echo.suppress_with_report(tmp_path, segs)

    assert result["segments"] == [
        {**segs[0], "start": 95.0, "end": 97.0, "audio_start": 100.0, "audio_end": 102.0},
        {**segs[2], "start": 105.0, "end": 107.0, "audio_start": 110.0, "audio_end": 112.0},
        segs[4],
        segs[6],
        segs[8],
    ]
    assert result["report"]["reasons"] == {
        "text_duplicate": 2,
        "system_local_echo": 2,
    }


def test_estimate_delay_detects_known_shift():
    # A loud 'Them' burst copied into the mic at a known delay must be recovered
    # (within a couple of samples) by the cross-correlation.
    sr = echo.SR
    rng = np.random.default_rng(0)
    sysv = (rng.standard_normal(int(20 * sr)) * 0.1).astype(np.float32)
    burst = rng.standard_normal(int(1.0 * sr)).astype(np.float32)
    a = int(10.0 * sr)
    sysv[a : a + len(burst)] += burst
    tau = 240  # ~15 ms speaker->mic delay
    mic = np.zeros_like(sysv)
    mic[a - tau : a - tau + len(burst)] = burst
    them = [{"start": 10.0, "end": 11.0, "speaker": "Them"}]
    est = echo._estimate_delay(mic, sysv, them)
    assert est is not None and abs(est - tau) <= 2


def test_estimate_broad_delay_detects_multi_second_system_lag():
    sr = echo.SR
    rng = np.random.default_rng(1)
    mic = np.zeros(int(25 * sr), dtype=np.float32)
    sysv = np.zeros_like(mic)
    burst = rng.standard_normal(int(1.5 * sr)).astype(np.float32)
    mic[int(10.0 * sr) : int(10.0 * sr) + len(burst)] = burst
    sysv[int(15.2 * sr) : int(15.2 * sr) + len(burst)] = burst

    estimate = echo._estimate_broad_delay(mic, sysv)

    assert estimate is not None
    tau, confidence = estimate
    assert abs((tau / sr) - 5.2) <= 0.04
    assert confidence >= echo.BROAD_DELAY_MIN_CONFIDENCE


def test_suppress_multi_second_mic_lead_drops_system_copy_not_mic(
    monkeypatch,
    tmp_path,
):
    # A mic copy that precedes the system copy by seconds is room speech
    # rebroadcast through the meeting app — the mic is the original. The old
    # model dropped the mic here and deleted the primary record.
    sr = echo.SR
    rng = np.random.default_rng(2)
    mic = np.zeros(int(25 * sr), dtype=np.float32)
    sysv = np.zeros_like(mic)
    burst = rng.standard_normal(int(1.2 * sr)).astype(np.float32)
    mic[int(10.0 * sr) : int(10.0 * sr) + len(burst)] = burst
    sysv[int(15.2 * sr) : int(15.2 * sr) + len(burst)] = burst

    def fake_load(path):
        return mic if path.name == "mic.wav" else sysv

    monkeypatch.setattr(echo, "_load", fake_load)
    segs = [
        {"start": 15.2, "end": 16.4, "text": "remote", "speaker": "Them"},
        {"start": 10.0, "end": 11.2, "text": "remote", "speaker": "Me"},
        {"start": 18.0, "end": 19.0, "text": "local", "speaker": "Me"},
    ]

    result = echo.suppress_with_report(tmp_path, segs)

    assert result["segments"] == [segs[1], segs[2]]
    assert result["report"]["dropped"] == 1
    assert set(result["report"]["reasons"]) <= {"rebroadcast", "rebroadcast_duplicate"}
    assert abs(result["report"]["system_mic_offset_s"] - 5.2) <= 0.04
    assert result["report"]["system_mic_offset_source"] == "broad_envelope"


def test_suppress_rebroadcast_drops_garbled_system_copy_acoustically(
    monkeypatch,
    tmp_path,
):
    # The system copy of room speech may be transcribed as garbage (that is
    # how the hallucination incident started) — the audio still matches, so
    # the drop must not depend on text similarity. A system segment with no
    # mic counterpart (genuine remote speech) survives.
    sr = echo.SR
    mic, sysv = _burst_pair(1.4, direction="rebroadcast")
    rng = np.random.default_rng(5)
    remote_only = rng.standard_normal(int(1.0 * sr)).astype(np.float32) * 0.3
    sysv[int(55.0 * sr) : int(55.0 * sr) + len(remote_only)] += remote_only

    def fake_load(path):
        return mic if path.name == "mic.wav" else sysv

    monkeypatch.setattr(echo, "_load", fake_load)
    segs = [
        {"start": 5.0, "end": 5.7, "text": "הספה הגיעה עכשיו למשרד", "speaker": "Me", "voice": "2"},
        {"start": 6.38, "end": 7.08, "text": "אה... לא. אה...", "speaker": "Them", "voice": "1"},
        {"start": 55.0, "end": 56.0, "text": "שלום מרחוק לכולם", "speaker": "Them", "voice": "1"},
    ]

    result = echo.suppress_with_report(tmp_path, segs)

    assert result["segments"] == [segs[0], segs[2]]
    assert result["report"]["reasons"] == {"rebroadcast": 1}
    assert result["report"]["drops"][0]["text"] == "אה... לא. אה..."


def test_suppress_playback_direction_still_drops_mic_echo(monkeypatch, tmp_path):
    mic, sysv = _burst_pair(0.08, direction="playback")

    def fake_load(path):
        return mic if path.name == "mic.wav" else sysv

    monkeypatch.setattr(echo, "_load", fake_load)
    segs = [
        {
            "start": 5.0,
            "end": 5.7,
            "text": "remote speaker sentence",
            "speaker": "Them",
            "voice": "1",
        },
        {
            "start": 5.08,
            "end": 5.78,
            "text": "remote speaker sentence",
            "speaker": "Me",
            "voice": "3",
        },
        {"start": 30.0, "end": 31.0, "text": "my own local remark", "speaker": "Me", "voice": "2"},
    ]

    result = echo.suppress_with_report(tmp_path, segs)

    assert result["segments"] == [segs[0], segs[2]]
    assert (
        "acoustic_echo" in result["report"]["reasons"]
        or "text_duplicate" in result["report"]["reasons"]
    )


def test_voice_rule_disabled_when_only_rebroadcast_direction(monkeypatch, tmp_path):
    # Repeated text duplicates used to promote a mic voice to "remote" and
    # delete all its segments. With the mic leading, that evidence means the
    # opposite: the voice is in the room and the system copies must go.
    mic, sysv = _burst_pair(1.4, direction="rebroadcast")

    def fake_load(path):
        return mic if path.name == "mic.wav" else sysv

    monkeypatch.setattr(echo, "_load", fake_load)
    segs = [
        {
            "start": 5.0,
            "end": 5.7,
            "text": "the couch arrived at the office today",
            "speaker": "Me",
            "voice": "2",
        },
        {
            "start": 6.4,
            "end": 7.1,
            "text": "the couch arrived at the office today",
            "speaker": "Them",
            "voice": "1",
        },
        {
            "start": 11.4,
            "end": 12.1,
            "text": "we should try it before the standup",
            "speaker": "Me",
            "voice": "2",
        },
        {
            "start": 12.8,
            "end": 13.5,
            "text": "we should try it before the standup",
            "speaker": "Them",
            "voice": "1",
        },
        {
            "start": 20.7,
            "end": 21.4,
            "text": "unique line with no duplicate anywhere",
            "speaker": "Me",
            "voice": "2",
        },
    ]

    result = echo.suppress_with_report(tmp_path, segs)

    assert [s["text"] for s in result["segments"]] == [
        "the couch arrived at the office today",
        "we should try it before the standup",
        "unique line with no duplicate anywhere",
    ]
    assert all(s["speaker"] == "Me" for s in result["segments"])
    assert "diarized_remote_voice" not in result["report"]["reasons"]


def test_suppress_keeps_talkative_voice_with_only_two_stray_duplicates(tmp_path):
    # A genuine local speaker who happens to duplicate two short remote lines but
    # otherwise carries the meeting must NOT be deleted wholesale: the long
    # proposal exists nowhere on the remote track, so the voice's unique share is
    # far above VOICE_ECHO_MAX_UNIQUE_RATIO. Earlier duplicate-share metrics
    # promoted this voice to "remote" and dropped every segment, erasing the real
    # speaker. Each duplicated line still drops as a text_duplicate; the voice's
    # own speech survives.
    segs = [
        {
            "start": 10.0,
            "end": 12.0,
            "text": "we should ship the API change",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 10.4,
            "end": 12.4,
            "text": "we should ship the API change",
            "speaker": "Me",
            "voice": "1",
        },
        {
            "start": 20.0,
            "end": 22.0,
            "text": "the budget question is open",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 20.4,
            "end": 22.4,
            "text": "the budget question is open",
            "speaker": "Me",
            "voice": "1",
        },
        # Voice "1"'s genuine, non-duplicated contribution -- the bulk of what it
        # says. This is a normal in-person participant.
        {
            "start": 30.0,
            "end": 45.0,
            "text": (
                "so my proposal for the quarter is that we prioritize the migration "
                "work first and then circle back to the reporting dashboards once the "
                "new data model has actually landed and the team has bandwidth to "
                "review it properly without rushing the whole thing at the deadline "
                "and I also think we should schedule a short design review before any "
                "of that starts so everyone is aligned on the interface boundaries "
                "and we do not end up rewriting the same modules twice next month"
            ),
            "speaker": "Me",
            "voice": "1",
        },
    ]

    result = echo.suppress_with_report(tmp_path, segs)

    kept_v1 = [s for s in result["segments"] if s.get("voice") == "1"]
    assert kept_v1 == [segs[4]]
    assert result["report"]["reasons"] == {"text_duplicate": 2}
    assert "diarized_remote_voice" not in result["report"]["reasons"]


def test_suppress_spares_local_voice_contaminated_with_bleed_duplicates(tmp_path):
    # 2026-07-22 regression: on a speakers-on call, diarization misfiled enough
    # bleed segments into the local speaker's cluster that duplicates made up
    # 36% of its characters -- past the old 15% duplicate-share bar -- and the
    # user's entire side of the meeting was deleted. Duplicate share cannot
    # separate a contaminated genuine voice (0.36) from a real bleed voice
    # (0.38); unique content can (47% vs 5-11%). A voice with substantial
    # speech the remote track has no copy of must survive, however many bleed
    # duplicates were filed under it.
    segs = [
        {
            "start": 10.0,
            "end": 12.0,
            "text": "we already reviewed the deployment checklist yesterday",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 10.1,
            "end": 12.1,
            "text": "we already reviewed the deployment checklist yesterday",
            "speaker": "Me",
            "voice": "1",
        },
        {
            "start": 20.0,
            "end": 22.0,
            "text": "the staging environment mirrors production settings now",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 20.1,
            "end": 22.1,
            "text": "the staging environment mirrors production settings now",
            "speaker": "Me",
            "voice": "1",
        },
        # Voice "1"'s garbled bleed: too different for TEXT_SIMILARITY_MIN but
        # loosely similar to the clean system copy right next to it.
        {
            "start": 30.0,
            "end": 33.0,
            "text": (
                "the cleaner copy of the quarterly revenue discussion that the mic "
                "picked up from the speakers"
            ),
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 30.1,
            "end": 33.1,
            "text": (
                "the garbled bleed of the quarterly revenue discussion that the mic "
                "picked up from the speakers"
            ),
            "speaker": "Me",
            "voice": "1",
        },
        # Voice "2" is the local speaker: two bleed duplicates diarization
        # misfiled under it (36% of its characters, past the old bar)...
        {
            "start": 39.9,
            "end": 41.9,
            "text": "let us circle back to the hiring plan next week",
            "speaker": "Them",
            "voice": "8",
        },
        {
            "start": 40.0,
            "end": 42.0,
            "text": "let us circle back to the hiring plan next week",
            "speaker": "Me",
            "voice": "2",
        },
        {
            "start": 49.9,
            "end": 51.9,
            "text": "the security review is scheduled for thursday morning",
            "speaker": "Them",
            "voice": "8",
        },
        {
            "start": 50.0,
            "end": 52.0,
            "text": "the security review is scheduled for thursday morning",
            "speaker": "Me",
            "voice": "2",
        },
        # ...but most of what it said exists nowhere on the remote track.
        {
            "start": 60.0,
            "end": 62.0,
            "text": "I can bring the signed guarantee to the office tomorrow",
            "speaker": "Me",
            "voice": "2",
        },
        {
            "start": 70.0,
            "end": 73.0,
            "text": "my part of the integration work landed in the main branch this morning",
            "speaker": "Me",
            "voice": "2",
        },
        {
            "start": 80.0,
            "end": 82.0,
            "text": "let me walk you through what I changed in the pipeline",
            "speaker": "Me",
            "voice": "2",
        },
    ]

    result = echo.suppress_with_report(tmp_path, segs)

    kept_v2 = [s for s in result["segments"] if s.get("voice") == "2"]
    assert [s["start"] for s in kept_v2] == [40.0, 50.0, 60.0, 70.0, 80.0]
    assert not [s for s in result["segments"] if s.get("voice") == "1"]
    assert result["report"]["reasons"] == {
        "text_duplicate": 2,
        "diarized_remote_voice": 1,
    }


def test_suppress_never_deletes_every_mic_voice(tmp_path):
    # Both mic voices look bleed-dominated, but the user was in the meeting, so
    # deleting every mic voice is near-certainly wrong: the rule must spare the
    # voice with the most unique content and let the per-segment checks handle
    # its duplicates.
    segs = [
        {
            "start": 10.0,
            "end": 12.0,
            "text": "alpha release notes are ready for review today",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 10.1,
            "end": 12.1,
            "text": "alpha release notes are ready for review today",
            "speaker": "Me",
            "voice": "1",
        },
        {
            "start": 20.0,
            "end": 22.0,
            "text": "beta feedback arrived from the customer this morning",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 20.1,
            "end": 22.1,
            "text": "beta feedback arrived from the customer this morning",
            "speaker": "Me",
            "voice": "1",
        },
        {
            "start": 40.0,
            "end": 42.0,
            "text": "gamma milestone slipped by a week overall",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 40.1,
            "end": 42.1,
            "text": "gamma milestone slipped by a week overall",
            "speaker": "Me",
            "voice": "2",
        },
        {
            "start": 50.0,
            "end": 52.0,
            "text": "delta budget was approved by finance yesterday",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 50.1,
            "end": 52.1,
            "text": "delta budget was approved by finance yesterday",
            "speaker": "Me",
            "voice": "2",
        },
        # Voice "2"'s sliver of unique speech -- below the promotion bar on its
        # own, but the tie-breaker that makes it the voice worth sparing.
        {
            "start": 60.0,
            "end": 61.0,
            "text": "sure I agree",
            "speaker": "Me",
            "voice": "2",
        },
    ]

    result = echo.suppress_with_report(tmp_path, segs)

    kept_mic = [s for s in result["segments"] if s["speaker"] == "Me"]
    assert kept_mic and all(s["voice"] == "2" for s in kept_mic)


def test_suppress_playback_pairs_never_delete_the_system_copy(monkeypatch, tmp_path):
    # ASR timestamps jitter a few tens of ms, so a playback-bleed pair can put
    # the mic copy nominally first. The local-system-echo rule then read the
    # pair backwards -- mic said it first, so the system copy must be the echo
    # -- and deleted the clean remote record while the mic bleed copy dropped as
    # a duplicate: the utterance vanished from the transcript entirely
    # (2026-07-22). A pair whose direction resolves to playback must only ever
    # drop the mic copy.
    mic, sysv = _burst_pair(0.08, direction="playback")

    def fake_load(path):
        return mic if path.name == "mic.wav" else sysv

    monkeypatch.setattr(echo, "_load", fake_load)
    segs = [
        # Mic voice "1" is promoted bleed, which is what arms the
        # local-system-echo rule in the first place.
        {
            "start": 10.0,
            "end": 12.0,
            "text": "we already reviewed the deployment checklist yesterday",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 10.1,
            "end": 12.1,
            "text": "we already reviewed the deployment checklist yesterday",
            "speaker": "Me",
            "voice": "1",
        },
        {
            "start": 20.0,
            "end": 22.0,
            "text": "the staging environment mirrors production settings now",
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 20.1,
            "end": 22.1,
            "text": "the staging environment mirrors production settings now",
            "speaker": "Me",
            "voice": "1",
        },
        {
            "start": 29.9,
            "end": 32.9,
            "text": (
                "the cleaner copy of the quarterly revenue discussion that the mic "
                "picked up from the speakers"
            ),
            "speaker": "Them",
            "voice": "7",
        },
        {
            "start": 30.0,
            "end": 33.0,
            "text": (
                "the garbled bleed of the quarterly revenue discussion that the mic "
                "picked up from the speakers"
            ),
            "speaker": "Me",
            "voice": "1",
        },
        # The jittered pair on the surviving local voice "2": the mic bleed
        # copy nominally starts first, over a burst so the audio really is
        # playback.
        {
            "start": 38.9,
            "end": 39.6,
            "text": "and this decision is final for the quarter",
            "speaker": "Me",
            "voice": "2",
        },
        {
            "start": 38.95,
            "end": 39.65,
            "text": "and this decision is final for the quarter",
            "speaker": "Them",
            "voice": "7",
        },
    ]

    result = echo.suppress_with_report(tmp_path, segs)

    assert segs[7] in result["segments"]
    assert "system_local_echo" not in result["report"]["reasons"]
    assert not [s for s in result["segments"] if s.get("voice") == "1"]


def test_suppress_keeps_genuine_voice_doubletalk_despite_acoustic_match(monkeypatch, tmp_path):
    # The user interjecting while remote playback bleeds into the mic: the mic
    # slice correlates with the system track at exactly the playback delay, so
    # the acoustic check alone reads genuine doubletalk as echo (2026-07-22: it
    # deleted the user's interjection). For a voice already judged genuine, an
    # acoustic match must be corroborated by the words also tracking the remote
    # track; unique words during overlap are the user, not echo.
    mic, sysv = _burst_pair(0.08, direction="playback")

    def fake_load(path):
        return mic if path.name == "mic.wav" else sysv

    monkeypatch.setattr(echo, "_load", fake_load)
    segs = [
        {
            "start": 5.0,
            "end": 5.7,
            "text": "the remote sentence playing through the speakers now",
            "speaker": "Them",
            "voice": "1",
        },
        # Genuine interjection over the burst: acoustically matched, textually
        # unique -- doubletalk, must survive.
        {
            "start": 5.02,
            "end": 5.72,
            "text": "my own words spoken while they talk",
            "speaker": "Me",
            "voice": "2",
        },
        {
            "start": 11.4,
            "end": 12.1,
            "text": "another remote sentence through the speakers arriving",
            "speaker": "Them",
            "voice": "1",
        },
        # Garbled bleed in the same genuine voice: acoustically matched AND
        # loosely tracking the remote text -- still echo, still drops.
        {
            "start": 11.42,
            "end": 12.12,
            "text": "another remote sentence garbled by the speakers arriving",
            "speaker": "Me",
            "voice": "2",
        },
        # Away from any burst: plain speech, untouched.
        {
            "start": 25.0,
            "end": 25.6,
            "text": "quiet room and only my voice",
            "speaker": "Me",
            "voice": "2",
        },
    ]

    result = echo.suppress_with_report(tmp_path, segs)

    assert result["segments"] == [segs[0], segs[1], segs[2], segs[4]]
    assert result["report"]["reasons"] == {"acoustic_echo": 1}


def test_is_rebroadcast_rejects_marginal_ncc_peak(tmp_path):
    # A weak, noise-dominated correlation at the rebroadcast lag clears the old
    # NCC_MIN (0.25) but is not a confident acoustic match. With the wide
    # +-0.25s rebroadcast window it would delete the primary remote record on a
    # near-coincidence. _is_rebroadcast now demands REBROADCAST_NCC_MIN (0.4);
    # the same peak would still satisfy the narrow, high-precision playback test.
    sr = echo.SR
    rng = np.random.default_rng(42)
    mic = np.zeros(int(30 * sr), dtype=np.float32)
    sysv = (rng.standard_normal(int(30 * sr)) * 0.3).astype(np.float32)
    burst = rng.standard_normal(int(1.0 * sr)).astype(np.float32)
    mic[int(10.0 * sr) : int(10.0 * sr) + len(burst)] = burst
    tau = int(1.4 * sr)
    a = int(10.0 * sr) + tau
    sysv[a : a + len(burst)] += burst * 0.09  # weak partial copy -> NCC ~0.29

    seg = {"start": a / sr, "end": (a + len(burst)) / sr}
    ncc, offset = echo._peak_ncc(sysv, mic, -tau, seg["start"], seg["end"])
    assert echo.NCC_MIN < ncc < echo.REBROADCAST_NCC_MIN
    assert offset == 0
    # Below the stronger rebroadcast bar: the system copy is kept.
    assert echo._is_rebroadcast(mic, sysv, tau, seg) is False


def _burst_pair(
    delay_s,
    *,
    gain=0.6,
    direction="rebroadcast",
    seconds=60,
    times=(5.0, 11.4, 20.7, 29.2, 38.9, 47.3),
    seed=7,
):
    """Synthetic mic/system tracks: short noise bursts (utterances) on the
    originating track, the same bursts delayed and attenuated on the other.
    direction "rebroadcast" originates on the mic (room speech), "playback"
    on the system (remote)."""
    sr = echo.SR
    rng = np.random.default_rng(seed)
    origin = np.zeros(seconds * sr, dtype=np.float32)
    for t in times:
        a = int(t * sr)
        origin[a : a + int(0.7 * sr)] = rng.standard_normal(int(0.7 * sr)).astype(np.float32) * 0.3
    copy = np.zeros_like(origin)
    shift = int(delay_s * sr)
    copy[shift:] = origin[: len(origin) - shift] * gain
    copy += rng.standard_normal(len(copy)).astype(np.float32) * 0.003
    if direction == "rebroadcast":
        return origin, copy  # mic first, system carries the delayed copy
    return copy, origin  # system first, mic carries the delayed echo


def test_directional_delays_detects_rebroadcast_only():
    mic, sysv = _burst_pair(1.4, direction="rebroadcast")
    delays = echo._directional_delays(mic, sysv)
    assert "playback" not in delays
    tau, confidence = delays["rebroadcast"]
    assert abs(tau / echo.SR - 1.4) < 0.1
    assert confidence >= echo.BROAD_DELAY_MIN_CONFIDENCE


def test_directional_delays_detects_playback_only():
    mic, sysv = _burst_pair(0.08, direction="playback")
    delays = echo._directional_delays(mic, sysv)
    assert "rebroadcast" not in delays
    tau, confidence = delays["playback"]
    assert -0.15 < tau / echo.SR <= 0.0
    assert confidence >= echo.BROAD_DELAY_MIN_CONFIDENCE


def test_directional_delays_detects_both_directions():
    sr = echo.SR
    mic_room, sys_room = _burst_pair(1.4, direction="rebroadcast")
    mic_echo, sys_remote = _burst_pair(
        0.08, direction="playback", times=(3.2, 13.7, 22.9, 34.4, 43.1, 52.6), seed=11
    )
    # room speech in the first half of the session, remote in the second
    mic = np.concatenate([mic_room, mic_echo])
    sysv = np.concatenate([sys_room, sys_remote])
    delays = echo._directional_delays(mic, sysv)
    assert abs(delays["rebroadcast"][0] / sr - 1.4) < 0.1
    assert -0.15 < delays["playback"][0] / sr <= 0.0


def test_directional_delays_empty_on_uncorrelated_audio():
    rng = np.random.default_rng(3)
    mic = rng.standard_normal(30 * echo.SR).astype(np.float32) * 0.05
    sysv = rng.standard_normal(30 * echo.SR).astype(np.float32) * 0.05
    assert echo._directional_delays(mic, sysv) == {}


def test_remote_only_meeting_drops_mic_bleed_not_the_remote_copy(monkeypatch, tmp_path):
    # The Slack-huddle regression: the mic re-recorded the remote participant
    # (playback bleed) and the cross-track duplicates read as a mic-leads
    # ("rebroadcast") envelope peak -- the same shape conversational turn-taking
    # produces. With a real shared room the app echoes room speech back and the
    # mic IS primary, so the system copies drop. With shared_room=False there is
    # no such path: the clean remote ("Them") copies must survive and the mic
    # bleed voice must drop, or the remote speaker's words end up stranded under
    # the local user's mic label (and the mic track's extra voice suppresses the
    # user's name downstream).
    mic, sysv = _burst_pair(1.4, direction="rebroadcast")

    def fake_load(path):
        return mic if path.name == "mic.wav" else sysv

    monkeypatch.setattr(echo, "_load", fake_load)
    segs = [
        {
            "start": 5.0,
            "end": 5.7,
            "text": "the remote speaker walked through the roadmap",
            "speaker": "Me",
            "voice": "1",
        },
        {
            "start": 6.4,
            "end": 7.1,
            "text": "the remote speaker walked through the roadmap",
            "speaker": "Them",
            "voice": "9",
        },
        {
            "start": 11.4,
            "end": 12.1,
            "text": "and then he asked about the delivery timeline",
            "speaker": "Me",
            "voice": "1",
        },
        {
            "start": 12.8,
            "end": 13.5,
            "text": "and then he asked about the delivery timeline",
            "speaker": "Them",
            "voice": "9",
        },
        {
            "start": 20.7,
            "end": 21.4,
            "text": "yes that works for me on my end",
            "speaker": "Me",
            "voice": "2",
        },
    ]

    remote = echo.suppress_with_report(tmp_path, segs, shared_room=False)

    assert [(s["speaker"], s["text"]) for s in remote["segments"]] == [
        ("Them", "the remote speaker walked through the roadmap"),
        ("Them", "and then he asked about the delivery timeline"),
        ("Me", "yes that works for me on my end"),
    ]
    assert all(s.get("voice") != "1" for s in remote["segments"])  # mic bleed gone
    assert remote["report"]["reasons"].get("rebroadcast", 0) == 0
    assert remote["report"]["reasons"].get("rebroadcast_duplicate", 0) == 0

    # Same audio and segments, but a shared room: the rebroadcast interpretation
    # is legitimate and it is the clean remote copies that drop instead.
    shared = echo.suppress_with_report(tmp_path, segs, shared_room=True)
    assert [s["speaker"] for s in shared["segments"]] == ["Me", "Me", "Me"]


def test_remote_only_meeting_keeps_system_copy_the_acoustic_rule_would_drop(monkeypatch, tmp_path):
    # test_suppress_rebroadcast_drops_garbled_system_copy_acoustically in reverse:
    # a mic-leads waveform match must not delete a system segment when there is
    # no room to rebroadcast from, even when the text can't back the decision up.
    sr = echo.SR
    mic, sysv = _burst_pair(1.4, direction="rebroadcast")
    rng = np.random.default_rng(5)
    remote_only = rng.standard_normal(int(1.0 * sr)).astype(np.float32) * 0.3
    sysv[int(55.0 * sr) : int(55.0 * sr) + len(remote_only)] += remote_only

    def fake_load(path):
        return mic if path.name == "mic.wav" else sysv

    monkeypatch.setattr(echo, "_load", fake_load)
    segs = [
        {"start": 5.0, "end": 5.7, "text": "הספה הגיעה עכשיו למשרד", "speaker": "Me", "voice": "2"},
        {"start": 6.38, "end": 7.08, "text": "אה... לא. אה...", "speaker": "Them", "voice": "1"},
        {"start": 55.0, "end": 56.0, "text": "שלום מרחוק לכולם", "speaker": "Them", "voice": "1"},
    ]

    result = echo.suppress_with_report(tmp_path, segs, shared_room=False)

    # The middle "Them" segment (dropped as rebroadcast when shared_room=True) stays.
    assert segs[1] in result["segments"]
    assert result["report"]["reasons"].get("rebroadcast", 0) == 0


def test_short_exact_rebroadcast_duplicates_drop_at_measured_delay(monkeypatch, tmp_path):
    # Backchannels are too short for waveform correlation and the long-text
    # rule; an exact text match one rebroadcast delay after a mic segment is
    # still the returning copy. A short system segment with no mic counterpart
    # at that delay stays.
    mic, sysv = _burst_pair(1.4, direction="rebroadcast")

    def fake_load(path):
        return mic if path.name == "mic.wav" else sysv

    monkeypatch.setattr(echo, "_load", fake_load)
    segs = [
        {"start": 5.0, "end": 5.2, "text": "לא.", "speaker": "Me", "voice": "2"},
        {"start": 6.42, "end": 6.62, "text": "לא.", "speaker": "Them", "voice": "1"},
        {"start": 20.7, "end": 20.9, "text": "כן.", "speaker": "Them", "voice": "1"},
    ]

    result = echo.suppress_with_report(tmp_path, segs)

    assert [(s["speaker"], s["text"]) for s in result["segments"]] == [
        ("Me", "לא."),
        ("Them", "כן."),
    ]
    assert result["report"]["reasons"] == {"rebroadcast_duplicate": 1}
