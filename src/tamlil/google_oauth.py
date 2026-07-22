# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

"""One-time Google Calendar consent for Tamlil (the `tamlil-auth` command).

Runs the installed-app loopback OAuth flow in the browser, then stores the
resulting authorized-user JSON (the refresh token is the real secret) in the
macOS Keychain as item 'tamlil-google'. Re-runnable: re-consent overwrites it.
"""

from __future__ import annotations

import subprocess
import sys

from . import google_client


def creds_to_storage_json(creds) -> str:
    """The authorized-user JSON we persist. google.oauth2 Credentials.to_json
    already emits exactly the shape Credentials.from_authorized_user_info reads
    back, which is what util.load_google_creds_info returns."""
    return creds.to_json()


def _store_in_keychain(blob: str) -> None:
    subprocess.run(
        [
            "security",
            "add-generic-password",
            "-s",
            "tamlil-google",
            "-a",
            "google",
            "-w",
            blob,
            "-U",
        ],
        check=True,
    )


def authorize() -> None:
    """Open the browser, consent, persist the token. Raises on failure."""
    from google_auth_oauthlib.flow import InstalledAppFlow

    flow = InstalledAppFlow.from_client_config(
        google_client.client_config(),
        scopes=google_client.SCOPES,
    )
    # Loopback on a free port; access_type=offline + prompt=consent guarantees a
    # refresh token even on a re-auth.
    creds = flow.run_local_server(
        port=0,
        access_type="offline",
        prompt="consent",
        authorization_prompt_message="Tamlil: opening your browser to connect Google Calendar...",
        success_message="Connected. You can close this tab and return to Tamlil.",
    )
    _store_in_keychain(creds_to_storage_json(creds))


def main(argv: list[str] | None = None) -> int:
    if not google_client.configured():
        print(google_client.SETUP_HINT, file=sys.stderr)
        return 1
    try:
        authorize()
    except Exception as e:  # noqa: BLE001 - surface any flow/network failure cleanly
        print(f"Google Calendar connect failed: {e}", file=sys.stderr)
        return 1
    print("Google Calendar connected (Keychain item 'tamlil-google').")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
