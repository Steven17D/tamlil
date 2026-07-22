# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

from tamlil import codeswitch


def test_phonetic_key_matches_hebrew_spelled_english_to_candidate_term():
    assert codeswitch.phonetic_key("פרודקשן") == codeswitch.phonetic_key("production")
    assert codeswitch.phonetic_key("קוברנטיס") == codeswitch.phonetic_key("Kubernetes")
    assert codeswitch.phonetic_key("אוט פלואו") == codeswitch.phonetic_key("OAuth flow")


def test_find_cards_suggests_codeswitch_term_with_segment_anchor():
    # A segment with no "words" key (Soniox pops it when empty) falls back to
    # text-only matching: a card is still emitted, now at "unsure" severity and
    # with no per-token confidence.
    segments = [
        {
            "start": 28.05,
            "end": 34.2,
            "text": "אז נגיד את זה אתה תלמד אבל יכול להיות שיש דברים שהם אין לך פרודקשן",
            "speaker": "Amit",
        }
    ]

    cards = codeswitch.find_cards(segments, terms=["production", "Kubernetes"])

    assert cards == [
        {
            "original": "פרודקשן",
            "guess": "production",
            "severity": "unsure",
            "context": segments[0]["text"],
            "status": "pending",
            "start": 28.05,
            "end": 34.2,
            "speaker": "Amit",
            "source": "codeswitch",
            "confidence": None,
        }
    ]


def test_find_cards_dedupes_terms_and_ignores_known_hebrew_terms():
    segments = [
        {
            "start": 1.0,
            "end": 2.0,
            "text": "נריץ קוברנטיס ואז קוברנטיס",
            "speaker": "Them",
        }
    ]

    cards = codeswitch.find_cards(
        segments,
        terms=["Kubernetes", "Kubernetes", "קוברנטיס"],
    )

    assert [card["original"] for card in cards] == ["קוברנטיס"]
    assert cards[0]["guess"] == "Kubernetes"
    assert cards[0]["severity"] == "unsure"


def test_find_cards_sets_confidence_from_min_token_confidence():
    # When the matched span carries word tokens, the card confidence is the real
    # min token confidence over that span, not a fabricated 1.0.
    segments = [
        {
            "start": 1.0,
            "end": 2.0,
            "text": "פרודקשן",
            "speaker": "Them",
            "words": [
                {"text": "פרוד", "start": 1.0, "end": 1.5, "confidence": 0.55},
                {"text": "קשן", "start": 1.5, "end": 2.0, "confidence": 0.4},
            ],
        }
    ]

    cards = codeswitch.find_cards(segments, terms=["production"])

    assert len(cards) == 1
    assert cards[0]["confidence"] == 0.4
    assert cards[0]["severity"] == "unsure"


def test_find_cards_suppresses_confident_hebrew_span():
    # Tokens Soniox is confident are real Hebrew (language "he") are not a
    # phonetic mangling of an English term: no card is emitted.
    segments = [
        {
            "start": 1.0,
            "end": 2.0,
            "text": "פרודקשן",
            "speaker": "Them",
            "words": [
                {"text": "פרוד", "start": 1.0, "end": 1.5, "confidence": 0.95, "language": "he"},
                {"text": "קשן", "start": 1.5, "end": 2.0, "confidence": 0.92, "language": "he"},
            ],
        }
    ]

    assert codeswitch.find_cards(segments, terms=["production"]) == []


def test_find_cards_flags_low_confidence_hebrew_span():
    # Same Hebrew span but low confidence: this is exactly the phonetic guess we
    # want to surface, at "unsure" with the real (low) confidence.
    segments = [
        {
            "start": 1.0,
            "end": 2.0,
            "text": "פרודקשן",
            "speaker": "Them",
            "words": [
                {"text": "פרוד", "start": 1.0, "end": 1.5, "confidence": 0.5, "language": "he"},
                {"text": "קשן", "start": 1.5, "end": 2.0, "confidence": 0.45, "language": "he"},
            ],
        }
    ]

    cards = codeswitch.find_cards(segments, terms=["production"])
    assert len(cards) == 1
    assert cards[0]["severity"] == "unsure"
    assert cards[0]["confidence"] == 0.45


def test_find_cards_does_not_collide_hebrew_pela_with_flow():
    # פלא squashes to the same coarse key as "flow" ("fl"); the tightened
    # candidate minimum (>=3) and the closeness guard must drop the collision so
    # a real Hebrew word is never flagged as the English term "flow".
    segments = [
        {
            "start": 1.0,
            "end": 2.0,
            "text": "זה פלא של טכנולוגיה",
            "speaker": "Them",
        }
    ]

    assert codeswitch.find_cards(segments, terms=["flow"]) == []


def test_candidate_terms_drops_short_keys():
    # "flow" -> "fl" is only two chars and must not become a candidate.
    assert "flow" not in codeswitch._candidate_terms(["flow"]).values()
    assert "production" in codeswitch._candidate_terms(["production"]).values()


def test_find_cards_flags_geminated_english_term():
    # Hebrew script never doubles consonants, so רולבק ("rlbk") is shorter than
    # rollback ("rllbkk"); the closeness guard must absorb that gemination gap
    # and still flag the code-switch, not drop it as a collision.
    segments = [
        {
            "start": 1.0,
            "end": 2.0,
            "text": "צריך לעשות רולבק עכשיו",
            "speaker": "Them",
        }
    ]

    cards = codeswitch.find_cards(segments, terms=["rollback"])
    assert [c["original"] for c in cards] == ["רולבק"]
    assert cards[0]["guess"] == "rollback"
