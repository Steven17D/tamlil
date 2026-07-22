# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

"""Look up the calendar event around a meeting and return its participants.

Reads the user's primary Google Calendar via the Calendar API, authenticated by
the per-user OAuth token from `tamlil-auth` (Keychain item 'tamlil-google'). The
names feed Soniox context terms. Best-effort: any failure (not connected,
offline, no event) returns an empty roster and the pipeline proceeds.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json

from . import google_client, util


def _name(att: dict) -> str | None:
    if att.get("resource") or att.get("responseStatus") == "declined":
        return None
    if att.get("displayName"):
        return att["displayName"]
    email = att.get("email", "")
    local = email.split("@")[0]
    if not local:
        return None
    # nirku -> Nirku, john.doe -> John Doe
    return " ".join(p.capitalize() for p in local.replace(".", " ").replace("_", " ").split())


def _utc(t: dt.datetime) -> dt.datetime:
    # astimezone() interprets a naive datetime as local time.
    return t.astimezone(dt.UTC)


def _select(items: list[dict], start: dt.datetime, window_min: int) -> dict:
    """Pick the event whose start is nearest `start` within window_min, and
    pull {title, attendees, rooms} from it. Pure: no API, no creds."""
    window = dt.timedelta(minutes=window_min)
    best, best_gap = None, None
    for ev in items:
        s = ev.get("start", {}).get("dateTime")
        if not s:
            continue  # all-day event, no time
        try:
            ev_start = _utc(dt.datetime.fromisoformat(s.replace("Z", "+00:00")))
        except ValueError:
            continue
        gap = abs((ev_start - start).total_seconds())
        if gap <= window.total_seconds() and (best_gap is None or gap < best_gap):
            best, best_gap = ev, gap

    if best is None:
        return {}
    attendees, rooms = [], []
    for att in best.get("attendees", []):
        if att.get("self"):
            continue  # the local user; their side is labeled separately
        if att.get("resource"):
            if att.get("displayName"):
                rooms.append(att["displayName"])
            continue
        n = _name(att)
        if n:
            attendees.append(n)
    seen: set[str] = set()
    # Order-preserving dedup; set.add returns None (falsy) so unseen names pass.
    attendees = [a for a in attendees if not (a in seen or seen.add(a))]  # type: ignore[func-returns-value]
    return {"title": best.get("summary", ""), "attendees": attendees, "rooms": rooms}


def _fetch_events(start: dt.datetime) -> list[dict]:
    """Events on the primary calendar within +/-2h of start. [] on any failure."""
    info = util.load_google_creds_info()
    if not info:
        return []
    try:
        from google.auth.transport.requests import Request
        from google.oauth2.credentials import Credentials
        from googleapiclient.discovery import build

        creds = Credentials.from_authorized_user_info(info, scopes=google_client.SCOPES)
        if not creds.valid:
            creds.refresh(Request())
        lo = (start - dt.timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
        hi = (start + dt.timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
        service = build("calendar", "v3", credentials=creds, cache_discovery=False)
        doc = (
            service.events()
            .list(
                calendarId="primary",
                timeMin=lo,
                timeMax=hi,
                singleEvents=True,
                orderBy="startTime",
                maxResults=20,
            )
            .execute()
        )
        return doc.get("items", [])
    except Exception:  # noqa: BLE001 - best-effort; never break the pipeline
        return []


def lookup(started_at: str, window_min: int = 20) -> dict:
    """Return {title, attendees:[names], rooms:[names]} for the event at this time."""
    try:
        start = _utc(dt.datetime.fromisoformat(started_at.replace("Z", "+00:00")))
    except ValueError:
        return {}
    return _select(_fetch_events(start), start, window_min)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("started_at", help="ISO timestamp of the meeting start")
    args = ap.parse_args(argv)
    print(json.dumps(lookup(args.started_at), ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
