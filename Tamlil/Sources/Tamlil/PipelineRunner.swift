// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Runs meeting_pipeline.py on a finished recording. The pipeline owns SQLite
/// state reporting ("processing" -> "done"/"error"); we just launch it,
/// capture its log, and signal completion so the UI can refresh.
@MainActor
final class PipelineRunner {
    /// The repo the pipeline runs from: the user's stored path, but only when it
    /// actually holds the tamlil package. There is no baked-in fallback — an
    /// earlier build hardcoded the author's `~/Projects/tamlil`, so on every
    /// other machine the app silently resolved a checkout that wasn't there.
    /// `nil` means "not configured yet"; callers surface a clear "set your
    /// Tamlil repo in Settings" state instead of running against nothing. Shared
    /// with ClarificationStore (learned.jsonl) and SettingsView (the repo
    /// warning) so all three agree on where the pipeline reads and writes.
    static func resolvedRepo() -> URL? {
        guard let stored = UserDefaults.standard.string(forKey: "repoPath"),
              !stored.isEmpty else { return nil }
        let url = URL(fileURLWithPath: stored)
        let hasPackage = FileManager.default.fileExists(
            atPath: url.appendingPathComponent("src/tamlil/meeting_pipeline.py").path)
        return hasPackage ? url : nil
    }

    /// A previous run's work/merged.raw.json is reusable only if it decodes and has
    /// segments — a partial/corrupt one must trigger a fresh transcribe, not a
    /// skip that loops on the same decode error forever.
    private static func hasUsableMergedJSON(in dir: URL) -> Bool {
        let paths = MeetingStore.artifacts.paths(for: RecordingID(dir.lastPathComponent))
        guard let data = try? Data(contentsOf: paths.workMergedRawJSON),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = obj["segments"] as? [Any]
        else { return false }
        return !segments.isEmpty
    }

    var onFinished: ((URL, Bool) -> Void)?
    var onRunningChanged: ((Set<String>) -> Void)?

    private var running: Set<String> = [] {
        didSet { onRunningChanged?(running) }
    }

    func isRunning(meetingDir: URL) -> Bool {
        running.contains(meetingDir.path)
    }

    func process(meetingDir: URL) {
        guard !running.contains(meetingDir.path) else { return }

        // No configured repo: don't silently launch against nothing — record a
        // clear error pointing at Settings and stop.
        guard let repo = Self.resolvedRepo() else {
            MeetingStore.update(RecordingID(meetingDir.lastPathComponent)) {
                $0.state = "error: set your Tamlil repo in Settings"
                $0.stage = nil
            }
            onFinished?(meetingDir, false)
            return
        }

        running.insert(meetingDir.path)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // The pipeline derives the mic-track speaker label from the macOS
        // account's full name itself.
        var command = "exec uv run tamlil-pipeline \"$MEETING_DIR\""
        // A previous run already transcribed; reuse its merged transcript.
        // Only skip when work/merged.raw.json is actually reusable, so a corrupt one is
        // re-transcribed instead of failing every retry on the same bad file.
        if Self.hasUsableMergedJSON(in: meetingDir) {
            command += " --skip-transcribe"
        }
        // login shell so uv/aws from the user's environment resolve
        task.arguments = ["-lc", command]
        task.currentDirectoryURL = repo
        var env = ProcessInfo.processInfo.environment
        env["MEETING_DIR"] = meetingDir.path
        env["TAMLIL_DB_PATH"] = MeetingStore.databaseURL.path
        env["TAMLIL_RECORDING_ID"] = meetingDir.lastPathComponent
        if let started = MeetingStore.load()
            .first(where: { $0.id == RecordingID(meetingDir.lastPathComponent) })?
            .meta.startedAt {
            env["TAMLIL_STARTED_AT"] = ISO8601DateFormatter().string(from: started)
        }
        task.environment = env

        // Append, never truncate: an orphaned run from a previous app launch
        // may still hold the log, and earlier runs' output stays diagnosable.
        let logURL = MeetingStore.artifacts
            .paths(for: RecordingID(meetingDir.lastPathComponent))
            .pipelineLog
        try? MeetingStore.artifacts
            .paths(for: RecordingID(meetingDir.lastPathComponent))
            .prepareDirectories()
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let log = try? FileHandle(forWritingTo: logURL) {
            _ = try? log.seekToEnd()
            let stamp = ISO8601DateFormatter().string(from: Date())
            try? log.write(contentsOf: Data("\n--- pipeline run \(stamp) ---\n".utf8))
            task.standardOutput = log
            task.standardError = log
        }

        task.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                if status != 0 {
                    Self.recordExitFailure(status: status, meetingDir: meetingDir)
                }
                self?.running.remove(meetingDir.path)
                self?.onFinished?(meetingDir, status == 0)
            }
        }

        do {
            try task.run()
        } catch {
            running.remove(meetingDir.path)
            MeetingStore.update(RecordingID(meetingDir.lastPathComponent)) {
                $0.state = "error: \(error.localizedDescription)"
                $0.stage = nil
            }
            onFinished?(meetingDir, false)
        }
    }

    /// The pipeline reports its own terminal state, but a crash or kill can
    /// leave meta stuck mid-run; record the failure so the UI shows it.
    private static func recordExitFailure(status: Int32, meetingDir: URL) {
        let id = RecordingID(meetingDir.lastPathComponent)
        let meeting = MeetingStore.load().first { $0.id == id }
        guard let meeting, meeting.isProcessing else { return }
        MeetingStore.update(id) {
            $0.state = "error: pipeline exited \(status) — see pipeline.log"
            $0.stage = nil
        }
    }

}
