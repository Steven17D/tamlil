# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

"""The learned lexicon: confirmed corrections + glossary, managed in one place.

Every clarification the user confirms is folded in as a (garbled variant ->
canonical term) mapping with a use count and a last-seen date. The lexicon is
leveraged three ways:

  - apply(): deterministic replacement of known garbles in the transcript — it
    does not rely on an external model obeying a prompt instruction. A variant becomes a
    blind rewrite rule only after MIN_RULE_COUNT confirmations and never when it
    collides with a glossary term.
  - glossary(): the canonical terms ranked by how often / recently they were
    confirmed, used as Soniox context.
  - knows(): so a term already learned is never surfaced as a question again.

Storage is dictionary.json (schema v2). Confirmations arrive as append-only
lines in learned.jsonl (written by the app); ingest() folds new lines in
idempotently via a line offset. A legacy flat {heard: correct} dictionary is
migrated and de-duplicated on load.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

from .util import package_file

# Stripped from the edges of a garbled variant before it becomes a match key.
_EDGE = " \t\r\n.,!?;:\"'()[]{}…-–—"


def _norm(s: str) -> str:
    """Match key for a variant: trimmed, edge-depunctuated, whitespace-collapsed,
    casefolded. Canonical text is preserved separately, with its real casing."""
    return re.sub(r"\s+", " ", s.strip().strip(_EDGE)).strip().casefold()


def load(repo: Path) -> dict:
    path = repo / "dictionary.json"
    raw: dict = {}
    if path.exists():
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except ValueError:
            corrupt = path.with_name(path.name + ".corrupt")
            os.replace(path, corrupt)
            print(
                f"lexicon: {path} unreadable; moved aside to {corrupt}, starting empty",
                file=sys.stderr,
            )
    if isinstance(raw, dict) and raw.get("version") == 2:
        return raw
    # Migrate a legacy flat {heard: correct} map (or empty) -> v2, grouping the
    # many garbled forms of one term under a single canonical entry.
    lex = {"version": 2, "ingested": 0, "terms": []}
    if isinstance(raw, dict):
        for heard, correct in raw.items():
            record(lex, heard, correct, today="")
    return lex


def _entry(lex: dict, canonical: str) -> dict:
    cf = canonical.casefold()
    for e in lex["terms"]:
        if e["canonical"].casefold() == cf:
            return e
    e = {"canonical": canonical, "variants": [], "count": 0, "last_seen": ""}
    lex["terms"].append(e)
    return e


def record(lex: dict, heard: str, correct: str, today: str) -> None:
    correct = correct.strip()
    variant = _norm(heard)
    if not correct or not variant:
        return
    # Latest confirmation wins: detach the variant from any other canonical,
    # including when the confirmation says the heard form was correct as-is.
    cf = correct.casefold()
    for old in list(lex["terms"]):
        if old["canonical"].casefold() != cf and variant in old["variants"]:
            old["variants"].remove(variant)
            if not old["variants"]:
                lex["terms"].remove(old)
    if variant == _norm(correct):
        return
    e = _entry(lex, correct)
    if variant not in e["variants"]:
        e["variants"].append(variant)
    e["count"] += 1
    if today:
        e["last_seen"] = today


def ingest(repo: Path, lex: dict, today: str) -> int:
    """Fold new learned.jsonl confirmations in; idempotent via a line offset."""
    log = repo / "learned.jsonl"
    if not log.exists():
        return 0
    lines = log.read_text(encoding="utf-8").splitlines()
    added = 0
    parsed = lex.get("ingested", 0)
    last = len(lines) - 1
    i = parsed
    while i < len(lines):
        ln = lines[i]
        if not ln.strip():
            parsed = i + 1
            i += 1
            continue
        try:
            rec = json.loads(ln)
        except ValueError:
            # A malformed FINAL line is a partial write still being appended:
            # stop so the next run retries it once complete. A malformed line
            # mid-file is committed garbage — skip it so it can't freeze ingest.
            if i == last:
                break
            parsed = i + 1
            i += 1
            continue
        parsed = i + 1
        i += 1
        if rec.get("heard") and rec.get("correct"):
            record(lex, rec["heard"], rec["correct"], today)
            added += 1
    lex["ingested"] = parsed
    return added


def save(repo: Path, lex: dict) -> None:
    # Most-used / most-recent first: stable, and the order glossary() relies on.
    lex["terms"].sort(
        key=lambda e: (-e["count"], _neg(e.get("last_seen", "")), e["canonical"].casefold())
    )
    path = repo / "dictionary.json"
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(lex, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(tmp, path)


def _neg(date: str) -> str:
    # Sort descending by ISO date as a secondary key (later dates first);
    # a missing date sorts oldest, after every real date.
    if not date:
        return chr(0xFFFF)
    return "".join(chr(255 - ord(c)) for c in date)


_LATIN_DIGIT = re.compile(r"[A-Za-z0-9]")

# Confirmations needed for an entry before its variants become deterministic
# rewrite rules; below this the mapping only biases Soniox via glossary().
MIN_RULE_COUNT = 2


def _applicable(variant: str, canonical: str) -> bool:
    """Whether a fix is safe to apply blindly everywhere. A safe fix must carry a
    Latin/digit distinctiveness marker (in the variant or its canonical): this
    excludes pure-Hebrew fixes — both single-token word->word grammar fixes
    (e.g. שם->סתם, עושה->עשה) and pure-Hebrew multi-word phrases, whose blind
    global rewrite would corrupt unrelated text — so those only bias Soniox
    through the glossary context. Beyond the marker, a multi-word phrase is
    distinctive enough on its own; a single token must also be long enough to
    not be a short common word (run)."""
    if not _LATIN_DIGIT.search(variant + canonical):
        return False
    if " " in variant:
        return True
    return len(variant) >= 5


def _base_terms() -> list[str]:
    path = package_file("terms.txt")
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    return [t for t in (ln.strip() for ln in lines) if t and not t.startswith("#")]


def compile_rules(lex: dict, base_terms: list[str] | None = None) -> list[tuple[re.Pattern, str]]:
    """(pattern, canonical) for every safely-applicable variant, longest variant
    first so a multi-word phrase wins over a single word it contains.

    A variant only becomes a blind rewrite when its entry was confirmed at
    least MIN_RULE_COUNT times, and never when the variant is itself a known
    term — another entry's canonical or a base-glossary term — since rewriting
    those would corrupt legitimate occurrences."""
    if base_terms is None:
        base_terms = _base_terms()
    reserved = {_norm(t) for t in base_terms}
    reserved.update(_norm(e["canonical"]) for e in lex["terms"])
    pairs = sorted(
        (
            (v, e["canonical"])
            for e in lex["terms"]
            for v in e["variants"]
            if e["count"] >= MIN_RULE_COUNT
            and _norm(v) not in reserved
            and _applicable(v, e["canonical"])
        ),
        key=lambda p: -len(p[0]),
    )
    return [
        (re.compile(rf"(?<!\w){re.escape(v)}(?!\w)", re.IGNORECASE | re.UNICODE), c)
        for v, c in pairs
    ]


def apply(text: str, rules: list[tuple[re.Pattern, str]]) -> str:
    """Deterministically replace every known garble with its canonical term.

    Single left-to-right pass: at each position the leftmost match wins, and for
    matches sharing a start the longest variant wins (rules are longest-first).
    A canonical produced by one rule is never re-scanned, so a replacement that
    happens to contain a shorter variant (threat intel -> ...intel...) can't be
    mangled by a later rule."""
    if not rules:
        return text
    out: list[str] = []
    pos = 0
    while pos <= len(text):
        best_start = best_end = -1
        best_canon = ""
        for pat, canonical in rules:
            m = pat.search(text, pos)
            if m is None:
                continue
            if (
                best_start == -1
                or m.start() < best_start
                or (m.start() == best_start and m.end() - m.start() > best_end - best_start)
            ):
                best_start, best_end, best_canon = m.start(), m.end(), canonical
        if best_start == -1:
            out.append(text[pos:])
            break
        out.append(text[pos:best_start])
        out.append(best_canon)
        pos = best_end
    return "".join(out)


def knows(lex: dict, term: str) -> bool:
    cf, v = term.casefold(), _norm(term)
    return any(e["canonical"].casefold() == cf or v in e["variants"] for e in lex["terms"])


def glossary(lex: dict, base: list[str] | None = None, limit: int | None = None) -> list[str]:
    """Canonical terms (most-used first) then any base-seed terms, de-duplicated."""
    seen: set[str] = set()
    out: list[str] = []
    for term in [e["canonical"] for e in lex["terms"]] + list(base or []):
        if term and term.casefold() not in seen:
            seen.add(term.casefold())
            out.append(term)
    return out[:limit] if limit else out
