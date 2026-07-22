# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

import json

from tamlil import lexicon


def empty_lex() -> dict:
    return {"version": 2, "ingested": 0, "terms": []}


def test_norm():
    assert lexicon._norm("  Hello,   World!  ") == "hello, world"
    assert lexicon._norm("(קוברנטיס)") == "קוברנטיס"
    assert lexicon._norm("...") == ""


def test_record_groups_variants_under_canonical():
    lex = empty_lex()
    lexicon.record(lex, "kubernetis", "Kubernetes", "2026-06-01")
    lexicon.record(lex, "Kuberneti!", "Kubernetes", "2026-06-02")
    assert len(lex["terms"]) == 1
    e = lex["terms"][0]
    assert e["canonical"] == "Kubernetes"
    assert e["variants"] == ["kubernetis", "kuberneti"]
    assert e["count"] == 2
    assert e["last_seen"] == "2026-06-02"


def test_record_latest_confirmation_wins():
    lex = empty_lex()
    lexicon.record(lex, "kubernetis", "Kubernetes", "2026-06-01")
    lexicon.record(lex, "kubernetis", "Cybernetics", "2026-06-02")
    assert [e["canonical"] for e in lex["terms"]] == ["Cybernetics"]
    assert lex["terms"][0]["variants"] == ["kubernetis"]


def test_record_correct_as_is_detaches_variant():
    lex = empty_lex()
    lexicon.record(lex, "ארגו", "Argo", "2026-06-01")
    lexicon.record(lex, "ארגו", "ארגו", "2026-06-02")
    assert lex["terms"] == []


def test_record_ignores_empty_inputs():
    lex = empty_lex()
    lexicon.record(lex, "...", "Kubernetes", "2026-06-01")
    lexicon.record(lex, "kubernetis", "  ", "2026-06-01")
    assert lex["terms"] == []


def test_applicable():
    assert lexicon._applicable("פרוד אינטל", "prod intel")  # multi-word, Latin canonical
    assert lexicon._applicable("prod אינטל", "prod intel")  # multi-word, Latin variant
    assert lexicon._applicable("kubernetis", "Kubernetes")
    assert not lexicon._applicable("שם", "סתם")  # pure-Hebrew grammar fix
    assert not lexicon._applicable("run", "ran")  # short common word


def test_applicable_excludes_pure_hebrew_multiword():
    # A learned pure-Hebrew two-word phrase must NOT become a blind global
    # rewrite (it would corrupt unrelated text); it only biases Soniox via the
    # glossary. It needs a Latin/digit distinctiveness marker to apply blindly.
    assert not lexicon._applicable("תודה רבה", "בבקשה רבה")
    assert not lexicon._applicable("שם טוב", "שם טוב")


def test_compile_rules_skips_pure_hebrew_multiword():
    lex = empty_lex()
    lex["terms"] = [
        make_entry("שלום עולם", ["חלון עולם"], 5),  # pure Hebrew: excluded
        make_entry("prod intel", ["פרוד אינטל"], 5),  # Latin marker: applied
    ]
    rules = lexicon.compile_rules(lex, base_terms=[])
    assert [c for _, c in rules] == ["prod intel"]


def make_entry(canonical, variants, count, last_seen=""):
    return {"canonical": canonical, "variants": variants, "count": count, "last_seen": last_seen}


def test_compile_rules_requires_min_count():
    lex = empty_lex()
    lex["terms"] = [make_entry("OAuth flow", ["wetflow"], 1)]
    assert lexicon.compile_rules(lex, base_terms=[]) == []
    lex["terms"][0]["count"] = lexicon.MIN_RULE_COUNT
    rules = lexicon.compile_rules(lex, base_terms=[])
    assert [c for _, c in rules] == ["OAuth flow"]


def test_compile_rules_never_rewrites_known_terms():
    lex = empty_lex()
    lex["terms"] = [
        make_entry("Docker Compose", ["docker"], 5),
        make_entry("Kafka", ["kafkah"], 5),
        make_entry("CockroachDB", ["kafka"], 5),
    ]
    rules = lexicon.compile_rules(lex, base_terms=["Docker"])
    pairs = {(p.pattern, c) for p, c in rules}
    # "docker" is a base-glossary term, "kafka" is another entry's canonical:
    # neither may become a blind rewrite. "kafkah" is fine.
    assert {c for _, c in pairs} == {"Kafka"}


def test_apply_word_boundaries():
    lex = empty_lex()
    lex["terms"] = [make_entry("OAuth flow", ["wetflow"], 2)]
    rules = lexicon.compile_rules(lex, base_terms=[])
    assert lexicon.apply("the wetflow broke", rules) == "the OAuth flow broke"
    assert lexicon.apply("The Wetflow broke", rules) == "The OAuth flow broke"
    assert lexicon.apply("wetflows are fine", rules) == "wetflows are fine"
    assert lexicon.apply("swetflow stays", rules) == "swetflow stays"


def test_apply_longest_variant_wins():
    lex = empty_lex()
    lex["terms"] = [
        make_entry("threat intel", ["flat intel"], 2),
        make_entry("intelligence", ["intel"], 2),
    ]
    rules = lexicon.compile_rules(lex, base_terms=[])
    assert lexicon.apply("the flat intel report", rules) == "the threat intel report"


def test_ingest_skips_malformed_midfile_line(tmp_path):
    # Committed garbage in the middle of the log must be skipped, not stall
    # ingest forever: both valid lines around it fold in.
    log = tmp_path / "learned.jsonl"
    log.write_text(
        json.dumps({"heard": "kubernetis", "correct": "Kubernetes"})
        + "\n"
        + "{not json\n"
        + json.dumps({"heard": "דוקר", "correct": "Docker"})
        + "\n",
        encoding="utf-8",
    )
    lex = empty_lex()
    added = lexicon.ingest(tmp_path, lex, "2026-06-09")
    assert added == 2
    assert lex["ingested"] == 3
    assert {e["canonical"] for e in lex["terms"]} == {"Kubernetes", "Docker"}


def test_ingest_retries_partial_final_line(tmp_path):
    # A malformed FINAL line is a half-written append; stop before it so the
    # next run picks it up once complete, without double-folding earlier lines.
    log = tmp_path / "learned.jsonl"
    log.write_text(
        json.dumps({"heard": "kubernetis", "correct": "Kubernetes"})
        + "\n"
        + '{"heard": "וופלו", "corre',  # partial, no newline
        encoding="utf-8",
    )
    lex = empty_lex()
    added = lexicon.ingest(tmp_path, lex, "2026-06-09")
    assert added == 1
    assert lex["ingested"] == 1
    assert [e["canonical"] for e in lex["terms"]] == ["Kubernetes"]

    # The app finishes writing the line; the next run retries from the offset.
    log.write_text(
        json.dumps({"heard": "kubernetis", "correct": "Kubernetes"})
        + "\n"
        + json.dumps({"heard": "וופלו", "correct": "OAuth flow"})
        + "\n",
        encoding="utf-8",
    )
    added = lexicon.ingest(tmp_path, lex, "2026-06-09")
    assert added == 1
    assert lex["ingested"] == 2
    assert {e["canonical"] for e in lex["terms"]} == {"Kubernetes", "OAuth flow"}
    assert lex["terms"][0]["count"] == 1  # first line not folded twice


def test_ingest_missing_log(tmp_path):
    lex = empty_lex()
    assert lexicon.ingest(tmp_path, lex, "2026-06-09") == 0
    assert lex["terms"] == []


def test_load_recovers_from_corrupt_dictionary(tmp_path, capsys):
    (tmp_path / "dictionary.json").write_text("{not json", encoding="utf-8")
    lex = lexicon.load(tmp_path)
    assert lex == {"version": 2, "ingested": 0, "terms": []}
    assert not (tmp_path / "dictionary.json").exists()
    assert (tmp_path / "dictionary.json.corrupt").read_text(encoding="utf-8") == "{not json"


def test_load_migrates_legacy_flat_dict(tmp_path):
    (tmp_path / "dictionary.json").write_text(
        json.dumps({"kubernetis": "Kubernetes", "kuberneti": "Kubernetes"}),
        encoding="utf-8",
    )
    lex = lexicon.load(tmp_path)
    assert lex["version"] == 2
    assert [e["canonical"] for e in lex["terms"]] == ["Kubernetes"]
    assert lex["terms"][0]["variants"] == ["kubernetis", "kuberneti"]


def test_save_load_round_trip(tmp_path):
    lex = empty_lex()
    lexicon.record(lex, "kubernetis", "Kubernetes", "2026-06-01")
    lexicon.record(lex, "kuberneti", "Kubernetes", "2026-06-01")
    lexicon.record(lex, "דוקר", "Docker", "2026-06-02")
    lexicon.save(tmp_path, lex)
    assert not (tmp_path / "dictionary.json.tmp").exists()
    raw = json.loads((tmp_path / "dictionary.json").read_text(encoding="utf-8"))
    assert raw == lex
    assert lexicon.load(tmp_path) == lex
    # Most-confirmed first: the order glossary() relies on.
    assert [e["canonical"] for e in lex["terms"]] == ["Kubernetes", "Docker"]


def test_knows():
    lex = empty_lex()
    lexicon.record(lex, "kubernetis", "Kubernetes", "2026-06-01")
    assert lexicon.knows(lex, "kubernetes")
    assert lexicon.knows(lex, "Kubernetis!")
    assert not lexicon.knows(lex, "Docker")
