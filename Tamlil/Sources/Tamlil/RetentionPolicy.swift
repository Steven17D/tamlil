// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How long a recording's captured audio (raw/ + work/ wavs and the compacted
/// .m4a) is kept. The transcript, logs, and DB row are never touched by this —
/// only the audio, which the pipeline no longer needs once the transcript is final.
enum RetentionPolicy: String {
    case keep             // never delete audio (default)
    case deleteAfterDays  // delete audio N days after the transcript is final
    case deleteWhenFinal  // delete audio as soon as the transcript is final
}

/// The metadata `recordingsToPurge` needs about one recording. Decoupled from
/// `Meeting` so the selection logic stays pure and self-checkable without a DB.
struct RetentionCandidate {
    let id: String
    let isFinal: Bool     // transcript is final (ready or needs-clarification)
    let endedAt: Date?
}

/// Ids whose captured audio should be deleted under `policy`. Pure: it decides
/// from the policy, whether the transcript is final, and age only. The caller
/// checks the filesystem and deletes just the audio that actually still exists.
func recordingsToPurge(_ candidates: [RetentionCandidate], policy: RetentionPolicy,
                       days: Int, now: Date) -> [String] {
    switch policy {
    case .keep:
        return []
    case .deleteWhenFinal:
        return candidates.filter(\.isFinal).map(\.id)
    case .deleteAfterDays:
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return candidates.filter { $0.isFinal && ($0.endedAt ?? now) < cutoff }.map(\.id)
    }
}
