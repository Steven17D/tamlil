# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

import tamlil.lexicon as lexicon
import tamlil.meeting_pipeline as mp


def _segs():
    return [
        {"start": 0.0, "end": 2.0, "text": "we use threat intelligence daily", "speaker": "Them"},
        {"start": 5.0, "end": 7.0, "text": "the threat from the new vendor", "speaker": "Me"},
    ]


def test_locate_term_prefers_context_over_first_term_hit():
    # 'threat' occurs first in segment 0, but the context quote uniquely
    # identifies segment 1 — the card must anchor there.
    card = {"original": "threat", "context": "the threat from the new vendor"}
    located = mp.locate_term(card, _segs())
    assert located["start"] == 5.0
    assert located["speaker"] == "Me"


def test_locate_term_falls_back_to_term_when_context_missing():
    card = {"original": "threat", "context": "nonexistent context line"}
    located = mp.locate_term(card, _segs())
    assert located["start"] == 0.0  # first segment containing 'threat'


def test_locate_term_leaves_unlocated_when_nothing_matches():
    card = {"original": "kubernetes", "context": "no such phrase"}
    located = mp.locate_term(card, _segs())
    assert located.get("start") is None


def test_merge_low_confidence_cards_matches_corrected_segments_and_dedupes_claude_cards():
    corrected = [
        {"start": 1.0, "end": 2.0, "text": "please confirm beta access", "speaker": "Them"},
        {"start": 3.0, "end": 4.0, "text": "already fixed phrase", "speaker": "Me"},
    ]
    cards = [
        {
            "original": "Beta",
            "guess": "beta",
            "severity": "wrong",
            "context": "please confirm beta access",
            "status": "pending",
        }
    ]
    spans = [
        {"text": "beta", "start": 1.1, "end": 1.4, "confidence": 0.44, "speaker": "Them"},
        {"text": "missing words", "start": 3.1, "end": 3.4, "confidence": 0.21, "speaker": "Me"},
    ]

    merged = mp.merge_low_confidence_cards(cards, spans, corrected)

    assert merged == cards


def test_merge_low_confidence_cards_adds_unsure_source_tagged_card():
    corrected = [
        {"start": 5.0, "end": 6.0, "text": "ship the gamma rollout", "speaker": "Me"},
    ]
    spans = [{"text": "gamma", "start": 5.2, "end": 5.45, "confidence": 0.49, "speaker": "Me"}]

    merged = mp.merge_low_confidence_cards([], spans, corrected)

    assert merged == [
        {
            "original": "gamma",
            "severity": "unsure",
            "context": "ship the gamma rollout",
            "status": "pending",
            "start": 5.0,
            "end": 6.0,
            "speaker": "Me",
            "source": "asr_confidence",
            "confidence": 0.49,
        }
    ]


def test_merge_low_confidence_cards_requires_whole_word_match():
    # 'beta' only appears inside 'betamax' — a substring hit must not anchor a
    # card, or the app would underline the wrong word.
    corrected = [
        {"start": 1.0, "end": 2.0, "text": "we shipped betamax tapes", "speaker": "Me"},
    ]
    spans = [{"text": "beta", "start": 1.1, "end": 1.3, "confidence": 0.4, "speaker": "Me"}]

    assert mp.merge_low_confidence_cards([], spans, corrected) == []


def test_merge_low_confidence_cards_anchors_to_span_speaker_segment():
    # Both speakers say the phrase; the span's own speaker decides which
    # segment the card anchors to, so playback lands on the right voice.
    corrected = [
        {"start": 1.0, "end": 2.0, "text": "the alpha rollout", "speaker": "Me"},
        {"start": 3.0, "end": 4.0, "text": "the alpha rollout", "speaker": "Them"},
    ]
    spans = [{"text": "alpha", "start": 3.1, "end": 3.3, "confidence": 0.4, "speaker": "Them"}]

    merged = mp.merge_low_confidence_cards([], spans, corrected)

    assert len(merged) == 1
    assert merged[0]["start"] == 3.0
    assert merged[0]["speaker"] == "Them"


def test_build_clarification_cards_merges_asr_and_codeswitch_sources():
    corrected = [
        {
            "start": 5.0,
            "end": 6.0,
            "text": "ship the פרודקשן rollout with gamma",
            "speaker": "Me",
        },
    ]
    spans = [{"text": "gamma", "start": 5.2, "end": 5.45, "confidence": 0.49, "speaker": "Me"}]

    cards = mp.build_clarification_cards(spans, corrected, terms=["production"])

    assert cards == [
        {
            "original": "gamma",
            "severity": "unsure",
            "context": "ship the פרודקשן rollout with gamma",
            "status": "pending",
            "start": 5.0,
            "end": 6.0,
            "speaker": "Me",
            "source": "asr_confidence",
            "confidence": 0.49,
        },
        {
            "original": "פרודקשן",
            "guess": "production",
            # Code-switch guesses are never hard "wrong"; this segment carries no
            # word tokens, so there is no per-token confidence to report.
            "severity": "unsure",
            "context": "ship the פרודקשן rollout with gamma",
            "status": "pending",
            "start": 5.0,
            "end": 6.0,
            "speaker": "Me",
            "source": "codeswitch",
            "confidence": None,
        },
    ]


def test_build_clarification_cards_skips_terms_the_lexicon_already_knows():
    # A term the user already confirmed once must never be re-asked. apply()
    # leaves a single-confirmation variant in place (below MIN_RULE_COUNT), so
    # without knows() gating the card, the low-confidence span would surface the
    # already-answered question again.
    corrected = [
        {"start": 5.0, "end": 6.0, "text": "deploy on kubernetis tonight", "speaker": "Me"},
    ]
    spans = [{"text": "kubernetis", "start": 5.1, "end": 5.6, "confidence": 0.42, "speaker": "Me"}]

    lex = {"version": 2, "ingested": 0, "terms": []}
    lexicon.record(lex, "kubernetis", "Kubernetes", today="2026-07-20")
    assert lexicon.knows(lex, "kubernetis")

    assert mp.build_clarification_cards(spans, corrected, terms=[], lex=lex) == []

    # Sanity: an empty lexicon knows nothing, so the same span still surfaces.
    empty = {"version": 2, "ingested": 0, "terms": []}
    cards = mp.build_clarification_cards(spans, corrected, terms=[], lex=empty)
    assert [c["original"] for c in cards] == ["kubernetis"]
