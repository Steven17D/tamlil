# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

import datetime as dt

from tamlil import roster


def _item(start_iso, summary, attendees):
    return {"start": {"dateTime": start_iso}, "summary": summary, "attendees": attendees}


def test_select_picks_nearest_within_window_and_extracts():
    start = dt.datetime(2026, 6, 14, 15, 0, tzinfo=dt.UTC)
    items = [
        _item("2026-06-14T13:00:00Z", "Far", [{"email": "x@e.com", "displayName": "X"}]),
        _item(
            "2026-06-14T15:05:00Z",
            "Standup",
            [
                {"email": "jane.roe@e.com", "displayName": "Jane Roe"},
                {"email": "john.doe@e.com"},
                {"email": "self@e.com", "self": True},
                {"email": "no@e.com", "responseStatus": "declined"},
                {"displayName": "Big Room", "resource": True},
            ],
        ),
    ]
    got = roster._select(items, start, window_min=20)
    assert got["title"] == "Standup"
    assert got["attendees"] == ["Jane Roe", "John Doe"]
    assert got["rooms"] == ["Big Room"]


def test_select_rejects_when_nothing_within_window():
    start = dt.datetime(2026, 6, 14, 15, 0, tzinfo=dt.UTC)
    items = [_item("2026-06-14T13:00:00Z", "Far", [])]
    assert roster._select(items, start, window_min=20) == {}


def test_lookup_empty_without_creds(monkeypatch):
    monkeypatch.setattr(roster.util, "load_google_creds_info", lambda: None)
    assert roster.lookup("2026-06-14T15:00:00Z") == {}
