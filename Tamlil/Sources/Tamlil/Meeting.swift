// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import Foundation
import os
import SQLite3

struct TranscriptToken: Codable, Equatable {
    let text: String
    let start: Double
    let end: Double
    let confidence: Double?
    let speaker: String?
    let segmentStart: Double?
}


/// One recorded meeting = one SQLite row plus one artifact directory under
/// ~/Recordings/Tamlil/.
struct MeetingMeta: Codable, Equatable {
    var app: String
    var bundleID: String
    var startedAt: Date
    var endedAt: Date?
    var state: String
    // Pipeline sub-step ("transcribing"/"correcting"/"summarizing") written
    // while state == "processing"; absent otherwise.
    var stage: String?
    // Added by the pipeline's calendar lookup (roster.py); absent for huddles
    // and unmatched meetings. Optionals round-trip without polluting the file.
    var eventTitle: String?
    var roster: [String]?
    var rooms: [String]?
    var transcriptionEngine: String? = nil
    enum CodingKeys: String, CodingKey {
        case app
        case bundleID = "bundle_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case state
        case stage
        case eventTitle = "event_title"
        case roster
        case rooms
        case transcriptionEngine = "transcription_engine"
    }
}

struct Meeting: Identifiable, Equatable {
    let id: RecordingID
    let directory: URL
    var meta: MeetingMeta
    /// Snapshots taken at load time so list rendering never touches the disk.
    var pendingClarifications: Int = 0

    var paths: RecordingPaths { MeetingStore.artifacts.paths(for: id) }
    var transcriptURL: URL { paths.finalTranscriptMarkdown }

    var duration: TimeInterval? {
        guard let end = meta.endedAt else { return nil }
        return end.timeIntervalSince(meta.startedAt)
    }

    static let displayDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE d MMM · HH:mm"
        return fmt
    }()

    /// The title shown when no custom `eventTitle` is set: "<app> with <people>"
    /// or a plain "<app> huddle/meeting". This is what a rename field offers as
    /// its placeholder, and what clearing a custom title falls back to.
    var autoTitle: String {
        let people = (meta.roster ?? []).prefix(3).joined(separator: ", ")
        switch meta.app {
        case "Slack": return people.isEmpty ? "Slack huddle" : "Huddle with \(people)"
        case "Zoom": return people.isEmpty ? "Zoom meeting" : "Zoom with \(people)"
        default: return people.isEmpty ? "\(meta.app) call" : "\(meta.app) with \(people)"
        }
    }

    /// What the list shows: the user's custom title if set, else `autoTitle`.
    var displayTitle: String {
        if let title = meta.eventTitle, !title.isEmpty { return title }
        return autoTitle
    }
}

/// A renamed meeting's trimmed title, or nil to restore the automatic title.
func normalizedMeetingTitle(_ title: String) -> String? {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// True when a finished meeting's system track transcribed to nothing — the
/// "other side missing" signal surfaced in the completion notification. Only
/// meaningful for meetings long enough that real silence is implausible;
/// missing or malformed system.asr.json stays quiet.
func systemTrackCameUpEmpty(in directory: URL, duration: TimeInterval?) -> Bool {
    guard let duration, duration > 300 else { return false }
    let id = RecordingID(directory.lastPathComponent)
    let url = RecordingPaths(root: directory.deletingLastPathComponent(), id: id).workSystemASRJSON
    guard let data = try? Data(contentsOf: url),
          let doc = try? JSONDecoder().decode(TranscriptDoc.self, from: data)
    else { return false }
    return doc.segments.isEmpty
}

/// True when a finished meeting's *final* transcript has no segments at all —
/// nobody said anything transcribable. That's an unanswered call/huddle: Slack
/// holds the mic while it rings, so a ring longer than the too-short cutoff
/// still records and transcribes to nothing. Unlike `systemTrackCameUpEmpty`
/// this is deliberately not duration-gated — a completely empty final
/// transcript can't be a real meeting, since a real one carries at least the
/// user's own side. A missing or malformed transcript.json returns false, so
/// uncertainty never discards a recording.
func finalTranscriptIsEmpty(in directory: URL) -> Bool {
    let id = RecordingID(directory.lastPathComponent)
    let url = RecordingPaths(root: directory.deletingLastPathComponent(), id: id).finalTranscriptJSON
    guard let data = try? Data(contentsOf: url),
          let doc = try? JSONDecoder().decode(TranscriptDoc.self, from: data)
    else { return false }
    return doc.segments.isEmpty
}

enum MeetingStore {
    // TAMLIL_RECORDINGS_ROOT override lets screenshots/tests use staged data.
    static let root = ProcessInfo.processInfo.environment["TAMLIL_RECORDINGS_ROOT"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Recordings/Tamlil", isDirectory: true)

    static let artifacts = FileRecordingArtifactStore(root: root)

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static let databaseURL: URL = ProcessInfo.processInfo.environment["TAMLIL_DB_PATH"]
        .map { URL(fileURLWithPath: $0) }
        ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tamlil", isDirectory: true)
            .appendingPathComponent("tamlil.sqlite")

    private static let repo: SQLiteRecordingRepository = {
        do {
            return try SQLiteRecordingRepository(databaseURL: databaseURL, recordingsRoot: root)
        } catch {
            fatalError("SQLiteRecordingRepository init failed: \(error)")
        }
    }()

    static func createRecording(app: String, bundleID: String, startedAt: Date) throws -> Meeting {
        try repo.createRecording(app: app, bundleID: bundleID, startedAt: startedAt)
    }

    static func update(_ id: RecordingID, mutate: (inout MeetingMeta) -> Void) {
        do {
            try repo.updateRecording(id, mutate: mutate)
        } catch {
            Log.app.error("recording update failed: \(String(describing: error), privacy: .public)")
        }
    }

    static func delete(_ id: RecordingID) {
        do {
            try repo.deleteRecording(id)
        } catch {
            Log.app.error("recording delete failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Set a meeting's title; an empty/whitespace value restores the auto title.
    static func rename(_ id: RecordingID, to title: String) {
        update(id) { $0.eventTitle = normalizedMeetingTitle(title) }
    }


    static func migrateLegacyRecordings() {
        do {
            _ = try repo.migrateLegacyRecordings { message in
                Log.app.info("\(message, privacy: .public)")
            }
        } catch {
            Log.app.error("legacy recording migration failed: \(String(describing: error), privacy: .public)")
        }
    }

    static func load() -> [Meeting] {
        do {
            return try repo.loadRecordings()
        } catch {
            Log.app.error("recording load failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    static func speakerNames(for id: RecordingID) -> [String: String] {
        (try? repo.speakerNames(for: id)) ?? [:]
    }

    static func saveSpeakerNames(_ names: [String: String], for id: RecordingID) {
        try? repo.replaceSpeakerNames(names, for: id)
    }

    static func clarifications(for id: RecordingID) -> [Clarification] {
        (try? repo.clarifications(for: id)) ?? []
    }

    static func saveClarifications(_ items: [Clarification], for id: RecordingID) {
        try? repo.saveClarifications(items, for: id)
    }
}
