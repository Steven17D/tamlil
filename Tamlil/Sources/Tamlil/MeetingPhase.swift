// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Single source of truth for interpreting the recording state string (the
/// Swift<->Python contract). Every user-facing label, color, and icon derives
/// from the parsed phase — no string matching anywhere else.
enum MeetingPhase: Equatable {
    case recording
    case queued
    case processing
    case needsClarification(Int)
    case ready
    case discarded(reason: String)
    case error(String)
    case unknown(String)
}

/// The parenthetical in a "discarded (...)" state string, e.g. "too short" or
/// "call not answered"; empty when the state carries no reason.
private func discardReason(from state: String) -> String {
    guard let open = state.firstIndex(of: "("),
          let close = state.lastIndex(of: ")"), open < close else { return "" }
    return String(state[state.index(after: open)..<close])
}

extension Meeting {
    var phase: MeetingPhase {
        switch meta.state {
        case "recording": return .recording
        case "recorded": return .queued
        case "processing": return .processing
        case "done":
            return pendingClarifications > 0
                ? .needsClarification(pendingClarifications) : .ready
        case let s where s.hasPrefix("error"):
            return .error(
                String(s.dropFirst("error:".count)).trimmingCharacters(in: .whitespaces)
            )
        case let s where s.hasPrefix("discarded"):
            return .discarded(reason: discardReason(from: s))
        case let s: return .unknown(s)
        }
    }

    var isProcessing: Bool {
        phase == .queued || phase == .processing
    }

    /// Pipeline sub-step for display; only meaningful mid-run.
    var stageText: String? {
        isProcessing ? meta.stage : nil
    }

    var displayState: String {
        switch phase {
        case .recording: return "Recording"
        case .queued: return "Queued"
        case .processing: return "Processing"
        case .needsClarification(let n): return "Needs clarification (\(n))"
        case .ready: return "Ready"
        case .discarded(let reason):
            return reason.isEmpty ? "Discarded" : "Discarded (\(reason))"
        case .error: return "Error"
        case .unknown(let s): return s
        }
    }

    var stateColor: Color {
        switch phase {
        case .recording, .error: return .red
        case .queued, .processing, .needsClarification: return .orange
        case .ready: return .green
        case .discarded, .unknown: return .secondary
        }
    }

    var durationText: String? {
        guard let d = duration else { return nil }
        return Tamlil.durationText(seconds: d)
    }
}

/// Coarse human duration: hours+minutes past an hour, whole minutes past a
/// minute, else seconds. Pure so `--self-check` can cover the boundaries.
func durationText(seconds: TimeInterval) -> String {
    let minutes = Int(seconds) / 60
    if minutes >= 60 { return "\(minutes / 60) h \(minutes % 60) min" }
    return minutes > 0 ? "\(minutes) min" : "\(Int(seconds)) s"
}
