# Contributing

Thanks for your interest in Tamlil. Outside contributions are welcome — bug
reports, feature requests, and pull requests.

By participating you agree to abide by our
[Code of Conduct](CODE_OF_CONDUCT.md).

## Reporting issues

Open a [bug report or feature request](.github/ISSUE_TEMPLATE) using the
templates. For anything that looks like a security vulnerability, please report
it privately rather than in a public issue (see the "Security vulnerability"
link on the new-issue page).

## Dev setup

```bash
git clone https://github.com/Steven17D/tamlil.git && cd tamlil
uv sync
make hooks        # one-time: pre-push runs lint + tests
```

`make check` runs the SPDX-header gate, `ruff check`, `ruff format --check`,
`mypy`, `pytest`, and the Swift self-check. The pre-push hook runs a faster
subset — `ruff check` and `pytest`, plus the Swift self-check only when the
pushed commits touch `Tamlil/` (it costs a Swift build).

## Repository layout

The Python package lives under `src/tamlil/` rather than a top-level `tamlil/`:
the macOS filesystem is case-insensitive, so a top-level `tamlil/` would collide
with the Swift menu-bar app's `Tamlil/`. Keep the package under `src/`.

## Testing

- Python: `make test-python` (pytest, `tests/`).
- Swift: `make test-swift`. There is no Xcode on dev machines, so XCTest is
  unavailable — the app embeds its own assertion harness, invoked as
  `swift run Tamlil --self-check`. Do not use `swift test`.
- Tests never touch real user state: `tests/conftest.py` scrubs every ambient
  `TAMLIL_*` override and points `TAMLIL_LEXICON_ROOT` at a tmp dir for the
  whole run. A test that needs an override sets it itself with `monkeypatch`.
- MCP end-to-end (optional): `test/container/run.sh` simulates a from-scratch
  connector install in a Linux container (Apple `container` or Docker).
  `test-assets/` holds seed text for synthesized bilingual audio fixtures.

## Submitting a pull request

1. Fork the repository and create a topic branch from `main`.
2. Make your change. Keep it focused — one logical change per pull request.
3. Run `make check` and make sure it is green. Add or update tests where it
   makes sense.
4. Commit with a sign-off (see [Sign your work](#sign-your-work-dco) below).
5. Push to your fork and open a pull request against `main`, filling in the
   pull-request template.

### How merges work

Development happens in a separate working repository, and this public repository
receives periodic release snapshots. Because of that, an accepted pull request
is **merged out of band**: a maintainer reviews it here, applies it upstream
with your authorship and sign-off preserved, and it ships in a later release
snapshot. Your pull request will then be closed with a note (rather than showing
GitHub's green "Merged" badge), even though your change was accepted. This is
expected — it does not mean your contribution was rejected.

## Commit conventions

- Short imperative subject; body only when the why isn't obvious.
- No emoji, no AI-attribution trailers.
- Never commit `dictionary.json`, `learned.jsonl`, or anything under
  `recordings/` — these are grown from real meetings.

## Sign your work (DCO)

Tamlil uses the [Developer Certificate of Origin](https://developercertificate.org/)
(DCO) instead of a contributor licence agreement. Signing off certifies that you
wrote the change or otherwise have the right to submit it under the project's
licence. **Every commit must be signed off.**

Add the sign-off automatically with the `-s` flag:

```bash
git commit -s -m "Fix the roster fallback message"
```

That appends a trailer with the name and email from your Git config:

```
Signed-off-by: Your Name <you@example.com>
```

Use your real name and a reachable email. If you forget on the last commit,
`git commit --amend -s` fixes it; for an earlier commit, rebase and re-sign.

The full text you are certifying:

```
Developer Certificate of Origin
Version 1.1

Copyright (C) 2004, 2006 The Linux Foundation and its contributors.

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.


Developer's Certificate of Origin 1.1

By making a contribution to this project, I certify that:

(a) The contribution was created in whole or in part by me and I
    have the right to submit it under the open source license
    indicated in the file; or

(b) The contribution is based upon previous work that, to the best
    of my knowledge, is covered under an appropriate open source
    license and I have the right under that license to submit that
    work with modifications, whether created in whole or in part
    by me, under the same open source license (unless I am
    permitted to submit under a different license), as indicated
    in the file; or

(c) The contribution was provided directly to me by some other
    person who certified (a), (b) or (c) and I have not modified
    it.

(d) I understand and agree that this project and the contribution
    are public and that a record of the contribution (including all
    personal information I submit with it, including my sign-off) is
    maintained indefinitely and may be redistributed consistent with
    this project or the open source license(s) involved.
```

---

Thanks for helping make Tamlil better.
