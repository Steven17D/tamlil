# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] - 2026-07-22

First public release, licensed under Apache-2.0.

### Added

- Menu bar app that detects call apps, records system audio + microphone as
  separate tracks, and runs the transcription pipeline on hangup.
- Soniox-only transcription pipeline: concurrent per-track async jobs,
  timestamp merge with per-track speaker labels and diarized voice ids, mic
  echo suppression, low-confidence clarification cards.
- Google Calendar integration: meeting titles and attendee names are pulled
  from your Google Calendar via per-user OAuth ("Sign in with Google" in
  Settings); attendee names also seed the Soniox context terms.
- Learned lexicon: Clarify confirmations become deterministic rewrites and
  Soniox context terms on future transcripts.
- Read-only MCP server (`tamlil-mcp`) so agents can list, fetch, and search
  meeting transcripts.
- One-command installer (`scripts/install.sh`) with a Soniox key wizard and
  Google sign-in, plus in-app self-update.

[1.0.0]: https://github.com/Steven17D/tamlil/releases/tag/v1.0.0
