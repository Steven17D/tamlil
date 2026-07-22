# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

"""Find Hebrew-script spellings of English/domain terms in transcript segments."""

from __future__ import annotations

import re
from collections.abc import Iterable

_HEBREW = re.compile(r"[\u0590-\u05ff]")
_EDGE = " \t\r\n.,!?;:\"'()[]{}…-–—"
_VOWELS = str.maketrans("", "", "aeiouy")


def has_hebrew(text: str) -> bool:
    return _HEBREW.search(text) is not None


def phonetic_key(text: str) -> str:
    """Coarse Hebrew/English phonetic key for technical code-switch terms."""
    return _squash(_translit(text))


def _translit(text: str) -> str:
    """Un-squashed vowel-stripped transliteration underlying phonetic_key.

    phonetic_key squashes repeated letters on top of this, which is what lets a
    Hebrew spelling match its English term; the un-squashed form is kept for the
    closeness guard that rejects collisions the squash would otherwise bridge."""
    text = text.casefold()
    if has_hebrew(text):
        return _hebrew_translit(text)
    return _english_translit(text)


def _english_translit(text: str) -> str:
    s = text.casefold()
    for src, dst in (
        ("oauth", "ot"),
        ("flow", "flo"),
        ("ction", "kshn"),
        ("tion", "shn"),
        ("sion", "zhn"),
        ("ph", "f"),
        ("qu", "kv"),
        ("ch", "k"),
        ("c", "k"),
        ("x", "ks"),
    ):
        s = s.replace(src, dst)
    s = re.sub(r"[^a-z0-9]+", "", s)
    return s.translate(_VOWELS)


def _hebrew_translit(text: str) -> str:
    out: list[str] = []
    chars = list(text)
    for i, ch in enumerate(chars):
        nxt = chars[i + 1] if i + 1 < len(chars) else ""
        if ch == "פ":
            out.append("f" if nxt == "ל" else "p")
        else:
            out.append(_HEBREW_LATIN.get(ch, ""))
    return "".join(out).translate(_VOWELS)


_HEBREW_LATIN = {
    "א": "",
    "ב": "b",
    "ג": "g",
    "ד": "d",
    "ה": "h",
    "ו": "o",
    "ז": "z",
    "ח": "h",
    "ט": "t",
    "י": "i",
    "כ": "k",
    "ך": "k",
    "ל": "l",
    "מ": "m",
    "ם": "m",
    "נ": "n",
    "ן": "n",
    "ס": "s",
    "ע": "",
    "ף": "f",
    "צ": "ts",
    "ץ": "ts",
    "ק": "k",
    "ר": "r",
    "ש": "sh",
    "ת": "t",
}


def _squash(s: str) -> str:
    return re.sub(r"(.)\1+", r"\1", s)


# A matched span whose word tokens are Soniox-confident Hebrew is a real Hebrew
# word, not a phonetic mangling of an English term: don't flag it at all.
_HE_CONFIDENCE = 0.7


def _edit_distance(a: str, b: str) -> int:
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def _close(a: str, b: str) -> bool:
    """Closeness guard on the un-squashed transliterations: a real code-switch
    spelling shares the term's leading sound and is a near-match, so a pure
    squash collision (e.g. flow/פלא both squashing to "fl") is dropped.

    Hebrew script never geminates, so an English term's doubled consonants
    (rollback -> "rllbkk") vanish in the Hebrew rendering (רולבק -> "rlbk").
    That length gap is expected, not evidence of a collision, so the tolerance
    absorbs it — only substitutions beyond the length delta count against a
    match."""
    if not a or not b or a[0] != b[0]:
        return False
    tol = max(1, min(len(a), len(b)) // 3 + abs(len(a) - len(b)))
    return _edit_distance(a, b) <= tol


def _collapse(s: str) -> str:
    return re.sub(r"\s+", "", s.strip(_EDGE))


def _phrase_tokens(words: list[dict], phrase: str) -> list[dict] | None:
    """The contiguous run of word tokens whose text spells out `phrase`.

    Soniox tokens can be sub-word, so match by concatenation rather than by a
    one-token-per-word assumption. None if the phrase isn't found (e.g. the
    segment text was rewritten after the words were captured)."""
    target = _collapse(phrase)
    if not target:
        return None
    n = len(words)
    for i in range(n):
        acc = ""
        for j in range(i, n):
            acc += _collapse(words[j].get("text", ""))
            if acc == target:
                return words[i : j + 1]
            if not target.startswith(acc):
                break
    return None


def find_cards(segments: list[dict], terms: Iterable[str]) -> list[dict]:
    candidates = _candidate_terms(terms)
    cards: list[dict] = []
    seen: set[tuple[str, str, float]] = set()
    for seg in segments:
        text = seg.get("text", "")
        if not has_hebrew(text):
            continue
        words = seg.get("words")
        for phrase in _hebrew_phrases(text):
            guess = candidates.get(phonetic_key(phrase))
            if not guess:
                continue
            if not _close(_translit(phrase), _translit(guess)):
                continue
            confidence = _gate(phrase, words)
            if confidence is _SUPPRESS:
                continue
            key = (phrase.casefold(), guess.casefold(), float(seg.get("start", 0.0)))
            if key in seen:
                continue
            seen.add(key)
            cards.append(
                {
                    "original": phrase,
                    "guess": guess,
                    # A phonetic guess, never a confident error: the app underlines
                    # these softly and never auto-applies them.
                    "severity": "unsure",
                    "context": text,
                    "status": "pending",
                    "start": seg.get("start"),
                    "end": seg.get("end"),
                    "speaker": seg.get("speaker"),
                    "source": "codeswitch",
                    "confidence": confidence,
                }
            )
    return cards


# Sentinel distinguishing "suppress this card" from a None confidence (emit, but
# no per-token confidence was available).
_SUPPRESS = object()


def _gate(phrase: str, words: list[dict] | None) -> object:
    """Decide whether to emit a card for `phrase` and with what confidence.

    Returns _SUPPRESS to drop the card, else the card confidence: the real min
    token confidence over the matched span, or None when the span carries no
    token-level confidence (or the segment has no words at all — the text-only
    fallback, matching the pre-token behaviour of always emitting)."""
    if not words:
        return None
    tokens = _phrase_tokens(words, phrase)
    if not tokens:
        return None
    confs = [t["confidence"] for t in tokens if isinstance(t.get("confidence"), (int, float))]
    min_conf = min(confs) if confs else None
    langs = [t.get("language") for t in tokens]
    if (
        langs
        and all(lang == "he" for lang in langs)
        and min_conf is not None
        and min_conf >= _HE_CONFIDENCE
    ):
        return _SUPPRESS
    return min_conf


def _candidate_terms(terms: Iterable[str]) -> dict[str, str]:
    out: dict[str, str] = {}
    for term in terms:
        term = term.strip()
        if not term or has_hebrew(term):
            continue
        key = phonetic_key(term)
        # A 2-char squashed key (flow -> "fl") collides with unrelated Hebrew;
        # require >=3 and lean on _close() for the rest.
        if len(key) < 3:
            continue
        out.setdefault(key, term)
    return out


def _hebrew_phrases(text: str) -> list[str]:
    tokens = [t.strip(_EDGE) for t in text.split()]
    tokens = [t for t in tokens if t]
    phrases: list[str] = []
    seen: set[str] = set()
    for i, token in enumerate(tokens):
        if not has_hebrew(token):
            continue
        current: list[str] = []
        for token in tokens[i : i + 3]:
            if not has_hebrew(token):
                break
            current.append(token)
            phrase = " ".join(current)
            key = phrase.casefold()
            if key not in seen:
                seen.add(key)
                phrases.append(phrase)
    return phrases
