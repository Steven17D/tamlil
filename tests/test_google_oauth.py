# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

import json

import pytest

from tamlil import google_client, google_oauth
from tamlil.util import load_google_creds_info


@pytest.fixture
def _no_client(monkeypatch):
    """A fresh clone: no client env vars, no local config file."""
    monkeypatch.delenv("TAMLIL_GOOGLE_CLIENT_ID", raising=False)
    monkeypatch.delenv("TAMLIL_GOOGLE_CLIENT_SECRET", raising=False)
    monkeypatch.setattr(google_client, "_local_config", dict)


class _FakeCreds:
    refresh_token = "rt"
    client_id = "cid"
    client_secret = "csec"
    token_uri = "https://oauth2.googleapis.com/token"

    def to_json(self):
        return json.dumps(
            {
                "refresh_token": self.refresh_token,
                "client_id": self.client_id,
                "client_secret": self.client_secret,
                "token_uri": self.token_uri,
            }
        )


def test_creds_to_info_round_trips(monkeypatch):
    blob = google_oauth.creds_to_storage_json(_FakeCreds())
    monkeypatch.setenv("TAMLIL_GOOGLE_CREDS", blob)
    info = load_google_creds_info()
    assert info["refresh_token"] == "rt"
    assert info["client_id"] == "cid"


def test_no_live_secret_shipped():
    """The rotated live secret must not be reintroduced as a constant."""
    assert google_client.CLIENT_ID == ""
    assert google_client.CLIENT_SECRET == ""


def test_unconfigured_by_default(_no_client):
    assert not google_client.configured()
    with pytest.raises(RuntimeError):
        google_client.client_config()


def test_config_from_env(monkeypatch):
    monkeypatch.setenv("TAMLIL_GOOGLE_CLIENT_ID", "cid.apps.googleusercontent.com")
    monkeypatch.setenv("TAMLIL_GOOGLE_CLIENT_SECRET", "shh")
    assert google_client.configured()
    installed = google_client.client_config()["installed"]
    assert installed["client_id"] == "cid.apps.googleusercontent.com"
    assert installed["client_secret"] == "shh"


def test_config_from_local_file(monkeypatch):
    monkeypatch.delenv("TAMLIL_GOOGLE_CLIENT_ID", raising=False)
    monkeypatch.delenv("TAMLIL_GOOGLE_CLIENT_SECRET", raising=False)
    monkeypatch.setattr(
        google_client,
        "_local_config",
        lambda: {"client_id": "file-cid", "client_secret": "file-secret"},
    )
    assert google_client.configured()
    assert google_client.client_config()["installed"]["client_id"] == "file-cid"


def test_auth_reports_unconfigured(_no_client, capsys):
    assert google_oauth.main([]) == 1
    assert "not configured" in capsys.readouterr().err.lower()
