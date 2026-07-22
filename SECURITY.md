# Security Policy

## Reporting a vulnerability

If you believe you have found a security vulnerability in Tamlil, please report
it privately. Do not open a public issue, pull request, or discussion for it.

Either private channel is fine:

- **GitHub private advisory (preferred).** On the repository, open the
  **Security** tab and choose **Report a vulnerability** to file a private
  advisory. This is the same "Report a security vulnerability" link that appears
  on the new-issue page.
- **Email.** Write to dashevskysteven@gmail.com. If you can encrypt, please
  do; if not, send a short note and we will arrange a secure channel.

Please include enough detail to reproduce the issue: the affected version or
commit, which component is involved (the Swift menu-bar app, the Python
pipeline, or the MCP server), the steps to reproduce, and the impact you
observed. If a report involves a real recording, redact the meeting audio and
transcript content — a description of the problem is enough.

## What to expect

- We aim to acknowledge your report within **3 business days**.
- We will tell you whether we can reproduce it and keep you updated as we work
  on a fix, typically within **10 business days** of that acknowledgement.
- We will credit you when the fix ships, unless you would rather stay anonymous.
- Please give us a reasonable chance to release a fix before any public
  disclosure.

## Scope

Tamlil is source-first: you build and run it from this repository on your own
Mac. Reports about Tamlil's own code and configuration are in scope — for
example the recording pipeline, credential handling (the Soniox and Google
tokens live in the macOS Keychain, never in a file), the ad-hoc-signed app
bundle, the pull-and-rebuild updater, or the read-only MCP server. How Tamlil
handles meeting audio and transcripts is described in the "Privacy and data
handling" section of the [README](README.md). Vulnerabilities in the
third-party services Tamlil talks to (Soniox, Google) should be reported to
those vendors directly, though we are glad to help coordinate.

## Supported versions

Tamlil ships as periodic source snapshots and has no long-term support
branches. Security fixes land on `main` and go out in the next snapshot; please
test against the latest `main` before reporting.
