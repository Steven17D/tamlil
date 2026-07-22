# SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
# SPDX-License-Identifier: Apache-2.0

"""Echo-suppression bookkeeping: the drop record and its stderr summary."""

from __future__ import annotations

import sys


def _empty_report() -> dict:
    return {"dropped": 0, "reasons": {}, "drops": []}


def _record_drop(report: dict, seg: dict, reason: str) -> None:
    report["dropped"] += 1
    report["reasons"][reason] = report["reasons"].get(reason, 0) + 1
    report["drops"].append(
        {
            "reason": reason,
            "start": seg.get("start"),
            "end": seg.get("end"),
            "speaker": seg.get("speaker"),
            "voice": seg.get("voice"),
            "text": seg.get("text", ""),
        }
    )


def report_has_alignment(report: dict) -> bool:
    return isinstance(report.get("system_mic_offset_s"), (int, float))


def _log_report(report: dict, detail: str = "") -> None:
    if report["dropped"]:
        print(
            f"== echo: dropped {report['dropped']} segment(s){detail}, "
            f"reasons {report['reasons']} ==",
            file=sys.stderr,
        )
