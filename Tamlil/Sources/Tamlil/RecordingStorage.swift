// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLite3

struct RecordingID: Codable, Hashable, CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

struct RecordingPaths {
    let root: URL
    let id: RecordingID

    var directory: URL { root.appendingPathComponent(id.rawValue, isDirectory: true) }
    var rawDirectory: URL { directory.appendingPathComponent("raw", isDirectory: true) }
    var workDirectory: URL { directory.appendingPathComponent("work", isDirectory: true) }
    var finalDirectory: URL { directory.appendingPathComponent("final", isDirectory: true) }
    var logsDirectory: URL { directory.appendingPathComponent("logs", isDirectory: true) }

    var rawSystemAudio: URL { rawDirectory.appendingPathComponent("system.wav") }
    var rawMicAudio: URL { rawDirectory.appendingPathComponent("mic.wav") }
    var workMicDenoisedAudio: URL { workDirectory.appendingPathComponent("mic.denoised.wav") }
    var workMicASRJSON: URL { workDirectory.appendingPathComponent("mic.asr.json") }
    var workSystemASRJSON: URL { workDirectory.appendingPathComponent("system.asr.json") }
    var workMergedRawJSON: URL { workDirectory.appendingPathComponent("merged.raw.json") }
    var workMergedUncertainJSON: URL { workDirectory.appendingPathComponent("merged.uncertain.json") }
    var workEchoReportJSON: URL { workDirectory.appendingPathComponent("echo.report.json") }
    var workTermsLocal: URL { workDirectory.appendingPathComponent("terms.local.txt") }
    var finalTranscriptJSON: URL { finalDirectory.appendingPathComponent("transcript.json") }
    var finalTranscriptMarkdown: URL { finalDirectory.appendingPathComponent("transcript.md") }
    var pipelineLog: URL { logsDirectory.appendingPathComponent("pipeline.log") }

    func prepareDirectories() throws {
        for url in [rawDirectory, workDirectory, finalDirectory, logsDirectory] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

/// The playable file for a canonical wav artifact: the wav itself, or the
/// compacted .m4a the pipeline replaces it with once the transcript is final.
func existingAudio(for canonical: URL) -> URL? {
    let fm = FileManager.default
    if fm.fileExists(atPath: canonical.path) { return canonical }
    let compacted = canonical.deletingPathExtension().appendingPathExtension("m4a")
    return fm.fileExists(atPath: compacted.path) ? compacted : nil
}

/// Delete a recording's captured audio and intermediates — the raw/ and work/
/// directories — leaving the transcript (final/) and logs. Best-effort: a
/// missing directory is not an error.
func purgeRecordingAudio(_ paths: RecordingPaths) {
    let fm = FileManager.default
    for dir in [paths.rawDirectory, paths.workDirectory] {
        try? fm.removeItem(at: dir)
    }
}

protocol RecordingArtifactStore {
    var root: URL { get }
    func paths(for id: RecordingID) -> RecordingPaths
    func createDirectories(for id: RecordingID) throws -> RecordingPaths
}

struct FileRecordingArtifactStore: RecordingArtifactStore {
    let root: URL

    func paths(for id: RecordingID) -> RecordingPaths {
        RecordingPaths(root: root, id: id)
    }

    func createDirectories(for id: RecordingID) throws -> RecordingPaths {
        let paths = paths(for: id)
        try paths.prepareDirectories()
        return paths
    }
}

protocol RecordingRepository {
    func createRecording(app: String, bundleID: String, startedAt: Date) throws -> Meeting
    func loadRecordings() throws -> [Meeting]
    func updateRecording(_ id: RecordingID, mutate: (inout MeetingMeta) -> Void) throws
    func deleteRecording(_ id: RecordingID) throws
    func replaceSpeakerNames(_ names: [String: String], for id: RecordingID) throws
    func speakerNames(for id: RecordingID) throws -> [String: String]
    func saveClarifications(_ items: [Clarification], for id: RecordingID) throws
    func clarifications(for id: RecordingID) throws -> [Clarification]
}

final class SQLiteRecordingRepository: RecordingRepository {
    let databaseURL: URL
    let recordingsRoot: URL

    private let dateFormatter = ISO8601DateFormatter()

    init(databaseURL: URL, recordingsRoot: URL) throws {
        self.databaseURL = databaseURL
        self.recordingsRoot = recordingsRoot
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: recordingsRoot, withIntermediateDirectories: true)
        try withDB { db in
            try exec(db, """
            CREATE TABLE IF NOT EXISTS recordings (
              id TEXT PRIMARY KEY,
              directory TEXT NOT NULL UNIQUE,
              app TEXT NOT NULL,
              bundle_id TEXT NOT NULL,
              started_at TEXT NOT NULL,
              ended_at TEXT,
              state TEXT NOT NULL,
              stage TEXT,
              event_title TEXT,
              roster_json TEXT,
              rooms_json TEXT,
              transcription_engine TEXT
            );
            CREATE TABLE IF NOT EXISTS speaker_names (
              recording_id TEXT NOT NULL,
              voice TEXT NOT NULL,
              name TEXT NOT NULL,
              PRIMARY KEY (recording_id, voice)
            );
            CREATE TABLE IF NOT EXISTS clarifications (
              recording_id TEXT PRIMARY KEY,
              json TEXT NOT NULL
            );
            """)
            try? exec(db, "ALTER TABLE recordings ADD COLUMN transcription_engine TEXT")
        }
    }

    func createRecording(app: String, bundleID: String, startedAt: Date) throws -> Meeting {
        let id = try uniqueID(app: app, at: startedAt)
        let paths = RecordingPaths(root: recordingsRoot, id: id)
        try paths.prepareDirectories()
        let meta = MeetingMeta(app: app, bundleID: bundleID, startedAt: startedAt,
                               endedAt: nil, state: "recording")
        try withDB { db in
            try prepare(db, """
            INSERT INTO recordings
              (id, directory, app, bundle_id, started_at, ended_at, state, stage,
               event_title, roster_json, rooms_json, transcription_engine)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) { stmt in
                bind(stmt, 1, id.rawValue)
                bind(stmt, 2, paths.directory.path)
                bindMeta(stmt, from: 3, meta)
                try stepDone(stmt, db)
            }
        }
        return Meeting(id: id, directory: paths.directory, meta: meta)
    }

    func loadRecordings() throws -> [Meeting] {
        try withDB { db in
            var out: [Meeting] = []
            try prepare(db, """
            SELECT id, directory, app, bundle_id, started_at, ended_at, state, stage,
                   event_title, roster_json, rooms_json, transcription_engine
            FROM recordings
            ORDER BY started_at DESC
            """) { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = RecordingID(columnText(stmt, 0))
                    let meta = decodeMeta(stmt)
                    let dir = URL(fileURLWithPath: columnText(stmt, 1), isDirectory: true)
                    let clarifications = (try? clarifications(for: id)) ?? []
                    out.append(Meeting(id: id, directory: dir, meta: meta,
                                       pendingClarifications: clarifications.filter(\.isPending).count))
                }
            }
            return out
        }
    }

    /// Single-row meta fetch backing updateRecording: avoids reloading every
    /// recording (and each one's clarifications from disk) just to mutate one.
    private func loadMeta(_ id: RecordingID) throws -> MeetingMeta? {
        try withDB { db in
            var meta: MeetingMeta?
            try prepare(db, """
            SELECT id, directory, app, bundle_id, started_at, ended_at, state, stage,
                   event_title, roster_json, rooms_json, transcription_engine
            FROM recordings
            WHERE id = ?
            LIMIT 1
            """) { stmt in
                bind(stmt, 1, id.rawValue)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    meta = decodeMeta(stmt)
                }
            }
            return meta
        }
    }

    /// Decode a MeetingMeta from a row selected with the canonical column order
    /// (id, directory, app, bundle_id, started_at, ...). Shared by the list load
    /// and the single-row fetch so both stay in lockstep.
    private func decodeMeta(_ stmt: OpaquePointer) -> MeetingMeta {
        MeetingMeta(
            app: columnText(stmt, 2),
            bundleID: columnText(stmt, 3),
            startedAt: dateFormatter.date(from: columnText(stmt, 4)) ?? Date(),
            endedAt: columnOptionalText(stmt, 5).flatMap(dateFormatter.date(from:)),
            state: columnText(stmt, 6),
            stage: columnOptionalText(stmt, 7),
            eventTitle: columnOptionalText(stmt, 8),
            roster: decodeJSON(columnOptionalText(stmt, 9), as: [String].self),
            rooms: decodeJSON(columnOptionalText(stmt, 10), as: [String].self),
            transcriptionEngine: columnOptionalText(stmt, 11)
        )
    }

    func updateRecording(_ id: RecordingID, mutate: (inout MeetingMeta) -> Void) throws {
        guard var meta = try loadMeta(id) else { return }
        mutate(&meta)
        try withDB { db in
            try prepare(db, """
            UPDATE recordings
            SET app = ?, bundle_id = ?, started_at = ?, ended_at = ?, state = ?, stage = ?,
                event_title = ?, roster_json = ?, rooms_json = ?, transcription_engine = ?
            WHERE id = ?
            """) { stmt in
                bindMeta(stmt, from: 1, meta)
                bind(stmt, 11, id.rawValue)
                try stepDone(stmt, db)
            }
        }
    }

    /// Remove a recording's row and its dependent rows (speaker names,
    /// clarifications). Deleting an unknown id is a no-op, so trashing stays
    /// idempotent — a phantom row whose folder is already gone can always be
    /// cleared by deleting it again.
    func deleteRecording(_ id: RecordingID) throws {
        try withDB { db in
            for sql in [
                "DELETE FROM clarifications WHERE recording_id = ?",
                "DELETE FROM speaker_names WHERE recording_id = ?",
                "DELETE FROM recordings WHERE id = ?",
            ] {
                try prepare(db, sql) { stmt in
                    bind(stmt, 1, id.rawValue)
                    try stepDone(stmt, db)
                }
            }
        }
    }

    func replaceSpeakerNames(_ names: [String: String], for id: RecordingID) throws {
        try withDB { db in
            try prepare(db, "DELETE FROM speaker_names WHERE recording_id = ?") { stmt in
                bind(stmt, 1, id.rawValue)
                try stepDone(stmt, db)
            }
            for (voice, name) in names {
                try prepare(db, "INSERT INTO speaker_names (recording_id, voice, name) VALUES (?, ?, ?)") { stmt in
                    bind(stmt, 1, id.rawValue)
                    bind(stmt, 2, voice)
                    bind(stmt, 3, name)
                    try stepDone(stmt, db)
                }
            }
        }
    }

    func speakerNames(for id: RecordingID) throws -> [String: String] {
        try withDB { db in
            var out: [String: String] = [:]
            try prepare(db, "SELECT voice, name FROM speaker_names WHERE recording_id = ?") { stmt in
                bind(stmt, 1, id.rawValue)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    out[columnText(stmt, 0)] = columnText(stmt, 1)
                }
            }
            return out
        }
    }

    func saveClarifications(_ items: [Clarification], for id: RecordingID) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = String(data: try encoder.encode(items), encoding: .utf8) ?? "[]"
        try withDB { db in
            try prepare(db, """
            INSERT INTO clarifications (recording_id, json) VALUES (?, ?)
            ON CONFLICT(recording_id) DO UPDATE SET json = excluded.json
            """) { stmt in
                bind(stmt, 1, id.rawValue)
                bind(stmt, 2, json)
                try stepDone(stmt, db)
            }
        }
    }

    func clarifications(for id: RecordingID) throws -> [Clarification] {
        try withDB { db in
            var json: String?
            try prepare(db, "SELECT json FROM clarifications WHERE recording_id = ?") { stmt in
                bind(stmt, 1, id.rawValue)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    json = columnText(stmt, 0)
                }
            }
            guard let data = json?.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([Clarification].self, from: data)) ?? []
        }
    }


    func migrateLegacyRecordings(log: ((String) -> Void)? = nil) throws -> [RecordingID] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: recordingsRoot, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var migrated: [RecordingID] = []
        for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let id = RecordingID(dir.lastPathComponent)
            let paths = RecordingPaths(root: recordingsRoot, id: id)
            let metaURL = dir.appendingPathComponent("meta.json")
            let hasMeta = fm.fileExists(atPath: metaURL.path)
            let hasRaw = fm.fileExists(atPath: paths.rawDirectory.path)
            let hasFlatAudio = fm.fileExists(atPath: dir.appendingPathComponent("system.wav").path)
                || fm.fileExists(atPath: dir.appendingPathComponent("mic.wav").path)
            guard !hasRaw, (hasMeta || hasFlatAudio) else { continue }
            guard try !recordingExists(id) else { continue }

            let meta = loadLegacyMeta(from: metaURL, fallbackDirectory: dir)
            try insertLegacyRecording(id: id, directory: dir, meta: meta)
            let moved = try moveLegacyArtifacts(in: dir, paths: paths)
            try importLegacyStores(in: dir, id: id)
            migrated.append(id)
            let message = "migrated legacy recording \(id.rawValue): \(moved) artifact(s)"
            log?(message)
        }
        return migrated
    }

    private func recordingExists(_ id: RecordingID) throws -> Bool {
        try withDB { db in
            try prepare(db, "SELECT 1 FROM recordings WHERE id = ? LIMIT 1") { stmt in
                bind(stmt, 1, id.rawValue)
                return sqlite3_step(stmt) == SQLITE_ROW
            }
        }
    }

    private func insertLegacyRecording(id: RecordingID, directory: URL, meta: MeetingMeta) throws {
        try withDB { db in
            try prepare(db, """
            INSERT OR IGNORE INTO recordings
              (id, directory, app, bundle_id, started_at, ended_at, state, stage,
               event_title, roster_json, rooms_json, transcription_engine)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) { stmt in
                bind(stmt, 1, id.rawValue)
                bind(stmt, 2, directory.path)
                bindMeta(stmt, from: 3, meta)
                try stepDone(stmt, db)
            }
        }
    }

    private func loadLegacyMeta(from url: URL, fallbackDirectory dir: URL) -> MeetingMeta {
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode(MeetingMeta.self, from: data) {
                return decoded
            }
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: dir.path)
        let started = (attrs?[.creationDate] as? Date)
            ?? (attrs?[.modificationDate] as? Date)
            ?? Date()
        let parts = dir.lastPathComponent.split(separator: "-", maxSplits: 4).map(String.init)
        let app = parts.count == 5 ? parts[4] : dir.lastPathComponent
        return MeetingMeta(app: app, bundleID: "", startedAt: started, endedAt: nil,
                           state: "recorded")
    }

    private func moveLegacyArtifacts(in dir: URL, paths: RecordingPaths) throws -> Int {
        var moved = 0
        let pairs: [(String, URL)] = [
            ("system.wav", paths.rawSystemAudio),
            ("mic.wav", paths.rawMicAudio),
            ("terms.local.txt", paths.workTermsLocal),
            ("mic.denoised.wav", paths.workMicDenoisedAudio),
            ("mic.json", paths.workMicASRJSON),
            ("system.json", paths.workSystemASRJSON),
            ("merged.json", paths.workMergedRawJSON),
            ("echo.report.json", paths.workEchoReportJSON),
            ("merged.uncertain.json", paths.workMergedUncertainJSON),
            ("merged.corrected.json", paths.finalTranscriptJSON),
            ("transcript.md", paths.finalTranscriptMarkdown),
            ("pipeline.log", paths.pipelineLog),
        ]
        let fm = FileManager.default
        for (name, destination) in pairs {
            let source = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            try fm.moveItem(at: source, to: destination)
            moved += 1
        }
        return moved
    }

    private func importLegacyStores(in dir: URL, id: RecordingID) throws {
        let speakersURL = dir.appendingPathComponent("speakers.json")
        if let data = try? Data(contentsOf: speakersURL),
           let names = try? JSONDecoder().decode([String: String].self, from: data) {
            try replaceSpeakerNames(names, for: id)
        }
        let clarificationsURL = dir.appendingPathComponent("clarifications.json")
        if let data = try? Data(contentsOf: clarificationsURL),
           let items = try? JSONDecoder().decode([Clarification].self, from: data) {
            try saveClarifications(items, for: id)
        }
    }

    private func uniqueID(app: String, at date: Date) throws -> RecordingID {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let base = "\(fmt.string(from: date))-\(sanitize(app))"
        var id = RecordingID(base)
        var suffix = 2
        let fm = FileManager.default
        while fm.fileExists(atPath: RecordingPaths(root: recordingsRoot, id: id).directory.path) {
            id = RecordingID("\(base)-\(suffix)")
            suffix += 1
        }
        return id
    }

    private func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(scalars).replacingOccurrences(of: "--", with: "-")
    }

    private func withDB<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let db else {
            throw StorageError.sqlite("open \(databaseURL.path)")
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw StorageError.sqlite(message)
        }
    }

    private func prepare<T>(_ db: OpaquePointer, _ sql: String,
                            body: (OpaquePointer) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StorageError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        return try body(stmt)
    }

    private func stepDone(_ stmt: OpaquePointer, _ db: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StorageError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    /// Binds the ten recording columns (app .. transcription_engine, in schema
    /// order) starting at `start`. The INSERT and UPDATE statements all list
    /// those columns identically; binding them here keeps the order in one place.
    private func bindMeta(_ stmt: OpaquePointer, from start: Int32, _ meta: MeetingMeta) {
        bind(stmt, start, meta.app)
        bind(stmt, start + 1, meta.bundleID)
        bind(stmt, start + 2, dateFormatter.string(from: meta.startedAt))
        bind(stmt, start + 3, meta.endedAt.map(dateFormatter.string(from:)))
        bind(stmt, start + 4, meta.state)
        bind(stmt, start + 5, meta.stage)
        bind(stmt, start + 6, meta.eventTitle)
        bindJSON(stmt, start + 7, meta.roster)
        bindJSON(stmt, start + 8, meta.rooms)
        bind(stmt, start + 9, meta.transcriptionEngine)
    }

    private func bindJSON<T: Encodable>(_ stmt: OpaquePointer, _ index: Int32, _ value: T?) {
        guard let value,
              let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8)
        else {
            sqlite3_bind_null(stmt, index)
            return
        }
        bind(stmt, index, json)
    }

    private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
        // sqlite3_column_text returns NULL for a NULL column; String(cString:)
        // on a null pointer is undefined behavior. The app's NOT NULL columns
        // never hit this, but the DB is shared with the Python pipeline, so
        // degrade to "" rather than crash on an unexpected NULL.
        guard let text = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: text)
    }

    private func columnOptionalText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let text = sqlite3_column_text(stmt, index)
        else { return nil }
        return String(cString: text)
    }

    private func decodeJSON<T: Decodable>(_ value: String?, as type: T.Type) -> T? {
        guard let data = value?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

}

private enum StorageError: Error, CustomStringConvertible {
    case sqlite(String)

    var description: String {
        switch self {
        case .sqlite(let message): return "sqlite: \(message)"
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
