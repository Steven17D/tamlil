# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

import json

from tamlil.util import write_outputs, write_srt

SEGMENTS = [
    {"start": 0.0, "end": 1.5, "text": "Hello"},
    {"start": 1.5, "end": 3.0, "text": "World"},
]
RESULT = {"text": "Hello World", "segments": SEGMENTS}


def test_write_srt_numbers_and_separates_blocks(tmp_path):
    out = tmp_path / "o.srt"
    write_srt(SEGMENTS, out)
    assert out.read_text(encoding="utf-8") == (
        "1\n00:00:00,000 --> 00:00:01,500\nHello\n\n2\n00:00:01,500 --> 00:00:03,000\nWorld\n"
    )


def test_write_srt_empty(tmp_path):
    out = tmp_path / "empty.srt"
    write_srt([], out)
    assert out.read_text(encoding="utf-8") == ""


def test_write_outputs_txt_appends_newline(tmp_path):
    base = tmp_path / "o"
    write_outputs(RESULT, base, "txt")
    assert (tmp_path / "o.txt").read_text(encoding="utf-8") == "Hello World\n"
    assert not (tmp_path / "o.json").exists()
    assert not (tmp_path / "o.srt").exists()


def test_write_outputs_json_roundtrips(tmp_path):
    base = tmp_path / "o"
    write_outputs(RESULT, base, "json")
    assert json.loads((tmp_path / "o.json").read_text(encoding="utf-8")) == RESULT
    assert not (tmp_path / "o.txt").exists()


def test_write_outputs_srt_only(tmp_path):
    base = tmp_path / "o"
    write_outputs(RESULT, base, "srt")
    assert (tmp_path / "o.srt").exists()
    assert not (tmp_path / "o.txt").exists()
    assert not (tmp_path / "o.json").exists()


def test_write_outputs_all_writes_three(tmp_path):
    base = tmp_path / "o"
    write_outputs(RESULT, base, "all")
    for ext in ("txt", "json", "srt"):
        assert (tmp_path / f"o.{ext}").exists()


def test_write_outputs_preserves_unicode(tmp_path):
    base = tmp_path / "o"
    result = {"text": "קוברנטיס", "segments": []}
    write_outputs(result, base, "json")
    raw = (tmp_path / "o.json").read_text(encoding="utf-8")
    assert "קוברנטיס" in raw
    assert json.loads(raw)["text"] == "קוברנטיס"
