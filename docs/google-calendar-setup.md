# Google Calendar setup (bring your own OAuth client)

The calendar feature — meeting titles and attendee names, also fed to the
recognizer as context — is **optional**. Tamlil ships **no OAuth client of its
own**: until you register one and point Tamlil at it, calendar lookup is simply
off and meetings record and transcribe with an empty roster.

It's a five-minute, one-time setup in the
[Google Cloud Console](https://console.cloud.google.com/):

1. **Project + API.** Create or pick a project, then enable the **Google Calendar
   API** (APIs & Services → Library → search "Google Calendar API" → Enable).
2. **Consent screen** (APIs & Services → OAuth consent screen). Pick a user type
   and add the scope `https://www.googleapis.com/auth/calendar.events.readonly`:
   - **Internal** — only if everyone who will connect is in your Google Workspace
     org. Simplest: no verification, no warnings.
   - **External** — the usual case for a personal or public fork. Leave the app
     in **Testing** and add every Google account that will connect under **Test
     users**. A Testing app needs no Google verification for this read-only
     scope; each test user just clicks through a one-time "Google hasn't verified
     this app" screen — it's *your* app, limited to the users you listed.
3. **Credentials** (APIs & Services → Credentials → Create credentials → OAuth
   client ID → Application type **Desktop app**). Copy the **client ID** and
   **client secret**.
4. **Give them to Tamlil** — pick one; both are read at run time and neither is
   written into a tracked file:
   - **In the app (easiest):** Settings → Google Calendar → paste the client ID
     and secret → **Save client**.
   - **Environment:** `export TAMLIL_GOOGLE_CLIENT_ID=…` and
     `TAMLIL_GOOGLE_CLIENT_SECRET=…`.
   - **Local file:** `src/tamlil/google_client.local.json` (gitignored),
     `{"client_id": "…", "client_secret": "…"}`.
5. **Connect.** Click **Sign in with Google** in Settings (or run
   `uv run tamlil-auth`) and complete the browser consent. The per-user refresh
   token is stored in the macOS Keychain (item `tamlil-google`); the client
   id/secret never touch the repo.

Under Google's installed-app model the client secret is not confidential, so
keeping it out of the tree is publish hygiene, not secrecy.
