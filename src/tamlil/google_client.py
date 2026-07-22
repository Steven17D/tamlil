# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

"""Tamlil's Google OAuth *client* identity — bring your own.

This is the app-level OAuth client (a client_id/client_secret pair), distinct
from the per-user refresh token stored in the Keychain by google_oauth.py.
Tamlil ships no client of its own: the calendar/roster feature is optional and
stays off until you register an OAuth client in the Google Cloud Console and
point Tamlil at it. See the README "Google Cloud setup" section.

The pair is resolved at call time (first hit wins):

  1. environment: TAMLIL_GOOGLE_CLIENT_ID / TAMLIL_GOOGLE_CLIENT_SECRET
  2. a gitignored google_client.local.json next to this module, shaped
     {"client_id": "...", "client_secret": "..."}

When neither is set the client is "unconfigured": `tamlil-auth` reports the
setup hint and the pipeline runs with an empty roster. Nothing is ever written
back into tracked files. Under Google's installed-app model these values are
not user secrets, but keeping them out of the tree is what lets the public
snapshot ship clean.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

SCOPES = ["https://www.googleapis.com/auth/calendar.events.readonly"]

# Empty placeholders — Tamlil ships no client. Bring your own via env or the
# gitignored local config (see the module docstring / README).
CLIENT_ID = ""
CLIENT_SECRET = ""

_LOCAL_CONFIG = "google_client.local.json"

SETUP_HINT = (
    "Google OAuth client not configured. Set TAMLIL_GOOGLE_CLIENT_ID and "
    "TAMLIL_GOOGLE_CLIENT_SECRET (or drop a google_client.local.json beside "
    'src/tamlil/google_client.py); see the README "Google Cloud setup" section.'
)


def _local_config() -> dict:
    """The gitignored google_client.local.json beside this module, or {} when
    it is absent or unparseable."""
    try:
        raw = Path(__file__).with_name(_LOCAL_CONFIG).read_text(encoding="utf-8")
        cfg = json.loads(raw)
    except (OSError, ValueError):
        return {}
    return cfg if isinstance(cfg, dict) else {}


def _resolve() -> tuple[str, str]:
    """(client_id, client_secret) from env, then the local config, then the
    empty module placeholders."""
    cid = os.environ.get("TAMLIL_GOOGLE_CLIENT_ID", "")
    csec = os.environ.get("TAMLIL_GOOGLE_CLIENT_SECRET", "")
    if not (cid and csec):
        cfg = _local_config()
        cid = cid or cfg.get("client_id", "") or CLIENT_ID
        csec = csec or cfg.get("client_secret", "") or CLIENT_SECRET
    return cid, csec


def configured() -> bool:
    """True when both id and secret resolve — the OAuth flow can run."""
    cid, csec = _resolve()
    return bool(cid and csec)


def client_config() -> dict:
    """Shape google-auth-oauthlib's InstalledAppFlow.from_client_config expects.
    Raises RuntimeError with the setup hint when no client is configured."""
    cid, csec = _resolve()
    if not (cid and csec):
        raise RuntimeError(SETUP_HINT)
    return {
        "installed": {
            "client_id": cid,
            "client_secret": csec,
            "auth_uri": "https://accounts.google.com/o/oauth2/auth",
            "token_uri": "https://oauth2.googleapis.com/token",
        }
    }
