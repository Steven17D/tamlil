// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Classifies each notification the app posts. Routine lifecycle events are
/// gated by the "Meeting notifications" setting; actionable failures are not —
/// you should never be able to silence "can't record" by accident.
enum NotificationKind {
    case meetingEvent
    case problem
}

func shouldPost(_ kind: NotificationKind, notifyMeetingEvents: Bool) -> Bool {
    switch kind {
    case .problem: return true
    case .meetingEvent: return notifyMeetingEvents
    }
}

/// Body of the "recording started" notification. When the participant-reminder
/// setting is on, appends a nudge to tell the other side they're being recorded.
func recordingStartedBody(dirName: String, remind: Bool) -> String {
    remind ? "\(dirName) — let participants know they're being recorded" : dirName
}
