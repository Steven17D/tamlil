# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

"""Helpers shared by the Soniox transcription pipeline."""

from __future__ import annotations

import json
import os
import pwd
import shutil
import subprocess
from contextlib import suppress
from importlib import resources
from pathlib import Path


def account_full_name() -> str:
    """The local macOS account's full display name (the gecos field), or "" if
    unknown. Single source for the local user's identity: default_me_name derives
    the mic track's speaker label from it, and speaker_labels.sole_remote_attendee
    uses it to tell the local user apart from remote roster attendees."""
    try:
        return pwd.getpwuid(os.getuid()).pw_gecos.split(",")[0]
    except KeyError:
        return ""


def package_file(*parts: str) -> Path:
    """Filesystem path to a file bundled inside the package (the rnnoise model,
    terms.txt). Resolved through importlib.resources so it holds regardless of
    how the package was installed, instead of assuming the data sits next to a
    module's __file__."""
    # importlib.resources types this as Traversable; for an on-disk install it
    # is always a real path, so wrapping in Path is safe.
    return Path(resources.files(__package__).joinpath(*parts))  # type: ignore[arg-type]


_key_cache: dict[str, str] = {}


def _keychain_key(env_var: str, service: str, hint: str = "") -> str:
    """API key from the env var, else the macOS Keychain item.

    The Keychain result is memoized in-process so the `security` subprocess
    runs at most once. It is deliberately NOT written back into os.environ:
    that would push the secret into the environment of every child process the
    pipeline spawns (ffmpeg, uv, git, …), widening its exposure and letting it
    surface in crash dumps or process listings. In-process callers reach it
    through this function; a separate child process re-reads it from Keychain.
    """
    key = os.environ.get(env_var)
    if key:
        return key
    if env_var in _key_cache:
        return _key_cache[env_var]
    try:
        key = subprocess.run(
            ["security", "find-generic-password", "-s", service, "-w"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        key = ""
    if not key:
        raise RuntimeError(
            f"no API key: Keychain item '{service}' missing and {env_var} unset."
            + (f" {hint}" if hint else "")
        )
    _key_cache[env_var] = key
    return key


def soniox_auth() -> str:
    """Load the Soniox API key from SONIOX_API_KEY or Keychain item
    'tamlil-soniox' (add with `security add-generic-password -s tamlil-soniox
    -a soniox -w "$KEY" -U`)."""
    return _keychain_key("SONIOX_API_KEY", "tamlil-soniox")


def _keychain_raw(service: str) -> str:
    """Keychain item value, or '' if missing. Non-raising sibling of
    _keychain_key for optional secrets (the Google token is optional)."""
    try:
        return subprocess.run(
            ["security", "find-generic-password", "-s", service, "-w"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def load_google_creds_info() -> dict | None:
    """Authorized-user JSON for Google Calendar, from env TAMLIL_GOOGLE_CREDS
    (tests/staging) or Keychain item 'tamlil-google'. None when unset, so the
    pipeline degrades to an empty roster instead of failing."""
    raw = os.environ.get("TAMLIL_GOOGLE_CREDS") or _keychain_raw("tamlil-google")
    if not raw:
        return None
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        return None


def _static_ffmpeg_on_path() -> None:
    """Put the bundled static ffmpeg/ffprobe build on PATH (best effort)."""
    with suppress(Exception):
        import static_ffmpeg

        static_ffmpeg.add_paths()


def ffmpeg_path() -> str | None:
    """Put the bundled static ffmpeg on PATH; return the binary path if found."""
    _static_ffmpeg_on_path()
    return shutil.which("ffmpeg")


def ffprobe_path() -> str | None:
    """ffprobe from the same bundled static build as ffmpeg_path."""
    _static_ffmpeg_on_path()
    return shutil.which("ffprobe")


def load_terms(spec: str | None) -> list[str]:
    """Terms come from a file (one per line) or a comma-separated string."""
    if not spec:
        return []
    p = Path(spec)
    if p.exists():
        items = [line.strip() for line in p.read_text(encoding="utf-8").splitlines()]
    elif "," in spec:
        items = [t.strip() for t in spec.split(",")]
    else:
        raise FileNotFoundError(
            f"terms file not found: {spec} (pass an existing file or a comma-separated list)"
        )
    return [t for t in items if t and not t.startswith("#")]


def fmt_ts(seconds: float) -> str:
    h, rem = divmod(int(seconds), 3600)
    m, s = divmod(rem, 60)
    ms = int((seconds - int(seconds)) * 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def fmt_clock(seconds: float) -> str:
    """Compact H:MM:SS (or M:SS under an hour) for transcript display."""
    h, rem = divmod(int(seconds), 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


def write_srt(segments: list[dict], path: str | Path) -> None:
    blocks = [
        f"{i}\n{fmt_ts(s['start'])} --> {fmt_ts(s['end'])}\n{s['text']}\n"
        for i, s in enumerate(segments, 1)
    ]
    Path(path).write_text("\n".join(blocks), encoding="utf-8")


def write_outputs(result: dict, base: str | Path, fmt: str) -> None:
    """Write <base>.txt / <base>.json / <base>.srt per fmt (txt | srt | json | all)."""
    if fmt in ("txt", "all"):
        Path(f"{base}.txt").write_text(result["text"] + "\n", encoding="utf-8")
    if fmt in ("json", "all"):
        Path(f"{base}.json").write_text(
            json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
        )
    if fmt in ("srt", "all"):
        write_srt(result["segments"], f"{base}.srt")
