# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

import json
import os

import pytest

from tamlil import util
from tamlil.util import (
    fmt_ts,
    load_google_creds_info,
    load_terms,
    package_file,
    soniox_auth,
)


def test_package_file_resolves_bundled_data():
    terms = package_file("terms.txt")
    assert terms.is_file()
    assert terms.name == "terms.txt"

    model = package_file("assets", "rnnoise", "bd.rnnn")
    assert model.is_file()


def test_modules_use_package_file_for_data():
    from tamlil import denoise, lexicon

    assert package_file("assets", "rnnoise", "bd.rnnn") == denoise.MODEL
    assert denoise.MODEL.is_file()
    assert lexicon._base_terms()  # non-empty glossary seed loads


def test_load_terms_from_file(tmp_path):
    f = tmp_path / "terms.txt"
    f.write_text("# comment\ndeploy\n\nOAuth flow\n  staging  \n", encoding="utf-8")
    assert load_terms(str(f)) == ["deploy", "OAuth flow", "staging"]


def test_load_terms_from_comma_list():
    assert load_terms("deploy, OAuth flow ,staging") == ["deploy", "OAuth flow", "staging"]


def test_load_terms_empty_spec():
    assert load_terms(None) == []
    assert load_terms("") == []


def test_load_terms_missing_file_raises(tmp_path):
    with pytest.raises(FileNotFoundError):
        load_terms(str(tmp_path / "nope.txt"))


def test_fmt_ts():
    assert fmt_ts(0) == "00:00:00,000"
    assert fmt_ts(59.25) == "00:00:59,250"
    assert fmt_ts(3661.5) == "01:01:01,500"


def test_load_google_creds_info_from_env(monkeypatch):
    info = {
        "refresh_token": "rt",
        "client_id": "cid",
        "client_secret": "csec",
        "token_uri": "https://oauth2.googleapis.com/token",
    }
    monkeypatch.setenv("TAMLIL_GOOGLE_CREDS", json.dumps(info))
    assert load_google_creds_info() == info


def test_soniox_auth_does_not_leak_key_into_environ(monkeypatch):
    # The Keychain result must be memoized in-process, never written back into
    # os.environ, or every child process the pipeline spawns would inherit it.
    monkeypatch.delenv("SONIOX_API_KEY", raising=False)
    monkeypatch.setattr(util, "_key_cache", {})
    calls = {"n": 0}

    def fake_run(argv, **kwargs):
        calls["n"] += 1
        return type("R", (), {"stdout": "secret-key\n"})()

    monkeypatch.setattr(util.subprocess, "run", fake_run)

    assert soniox_auth() == "secret-key"
    assert soniox_auth() == "secret-key"
    assert calls["n"] == 1  # `security` subprocess runs at most once
    assert "SONIOX_API_KEY" not in os.environ  # not broadcast to child procs


def test_load_google_creds_info_absent(monkeypatch):
    monkeypatch.delenv("TAMLIL_GOOGLE_CREDS", raising=False)
    monkeypatch.setattr("tamlil.util._keychain_raw", lambda service: "")
    assert load_google_creds_info() is None
