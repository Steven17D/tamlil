// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftUI

/// What to do with a recording a previous app instance left mid-lifecycle.
/// Split out of `reconcileStaleMeetings` so the recovery rules are covered by
/// `--self-check` without touching SQLite or the pipeline.
enum StaleResolution: Equatable {
    case leaveAlone
    case process                 // enough audio captured: mark recorded, run pipeline
    case markInterrupted         // negligible audio: mark errored
    case markPipelineInterrupted // pipeline died mid-run: flag for retry
    case reprocess               // was queued: just run the pipeline
}

/// A recording another live instance is still writing keeps a fresh mtime, so
/// only a file untouched for `staleAfter` is reconciled — never hijack an
/// in-progress capture.
func staleRecordingResolution(
    phase: MeetingPhase,
    audioBytes: Int,
    audioAge: TimeInterval,
    minAudioBytes: Int = 100 * 1024,
    staleAfter: TimeInterval = 60
) -> StaleResolution {
    switch phase {
    case .recording:
        guard audioAge > staleAfter else { return .leaveAlone }
        return audioBytes > minAudioBytes ? .process : .markInterrupted
    case .processing:
        return .markPipelineInterrupted
    case .queued:
        return .reprocess
    default:
        return .leaveAlone
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Status: Equatable {
        case idle
        case recording(app: String, since: Date)
    }

    @Published var status: Status = .idle
    @Published var meetings: [Meeting] = []
    @Published var lastError: String?
    @Published private(set) var runningPipelineDirs: Set<String> = []

    @AppStorage("autoRecord") var autoRecord = true
    @AppStorage("enabledApps") private var enabledAppsRaw = "us.zoom,com.tinyspeck.slackmacgap"
    @AppStorage("notifyMeetingEvents") var notifyMeetingEvents = true
    @AppStorage("remindInformParticipants") var remindInformParticipants = true
    @AppStorage("audioRetention") var audioRetentionRaw = RetentionPolicy.keep.rawValue
    @AppStorage("audioRetentionDays") var audioRetentionDays = 30

    /// Parsed form of `audioRetentionRaw`, read by the retention sweep.
    var retentionPolicy: RetentionPolicy {
        RetentionPolicy(rawValue: audioRetentionRaw) ?? .keep
    }

    /// A meeting the main window should navigate to — set by a notification's
    /// "Show transcript" action and consumed (then cleared) by the main-window
    /// MenuView. Set before `showMainWindow` so a freshly created window picks it
    /// up on appear.
    @Published var meetingToOpen: RecordingID?

    /// Brings the main window forward; wired by the app delegate that owns it.
    var showMainWindow: (() -> Void)?

    /// Open a meeting's transcript in the main window (a notification action).
    func openMeeting(_ id: RecordingID) {
        meetingToOpen = id
        showMainWindow?()
    }

    private let monitor = CallMonitor()
    private let pipeline = PipelineRunner()

    private var tapRecorder: ProcessTapRecorder?
    private var micRecorder: MicRecorder?
    private var currentDir: URL?
    private var currentID: RecordingID?
    private var currentMeta: MeetingMeta?

    /// The meeting currently being recorded by this instance, if any — so the
    /// UI can refuse to delete a live recording.
    var recordingDir: URL? { currentDir }

    var enabledApps: Set<String> {
        get { Set(enabledAppsRaw.split(separator: ",").map(String.init)) }
        set {
            enabledAppsRaw = newValue.sorted().joined(separator: ",")
            monitor.enabledBundlePrefixes = newValue
        }
    }

    func start() {
        Notifier.requestPermission()
        Notifier.configure()
        LoginItem.enableOnFirstLaunch()
        monitor.enabledBundlePrefixes = enabledApps
        monitor.onCallStarted = { [weak self] call in
            guard let self, self.autoRecord else { return }
            self.beginRecording(call)
        }
        monitor.onCallEnded = { [weak self] in
            self?.endRecording()
        }
        pipeline.onRunningChanged = { [weak self] dirs in
            self?.runningPipelineDirs = dirs
        }
        pipeline.onFinished = { [weak self] dir, ok in
            guard let self else { return }
            self.refreshMeetings()
            let name = dir.lastPathComponent
            // Nothing transcribable in the whole recording means the call was
            // never answered — Slack held the mic through the ring. Discard it
            // rather than park a one-sided non-meeting in the list.
            if ok, finalTranscriptIsEmpty(in: dir),
               let meeting = self.meetings.first(where: { $0.directory == dir }) {
                MeetingStore.update(meeting.id) { $0.state = "discarded (call not answered)" }
                self.refreshMeetings()
                if shouldPost(.meetingEvent, notifyMeetingEvents: self.notifyMeetingEvents) {
                    Notifier.notify(title: "Call not answered",
                                    body: "\(name) — discarded, no audio",
                                    threadIdentifier: name, folderPath: dir.path)
                }
                return
            }
            var body = name
            if ok, let meeting = self.meetings.first(where: { $0.directory == dir }) {
                let pending = meeting.pendingClarifications
                if pending > 0 { body += " — \(pending) terms need clarification" }
                if systemTrackCameUpEmpty(in: dir, duration: meeting.duration) {
                    body += " — system audio was silent, other side missing"
                }
                if let suffix = engineNotificationSuffix(meeting.meta.transcriptionEngine) {
                    body += " — \(suffix)"
                }
            }
            if ok {
                if shouldPost(.meetingEvent, notifyMeetingEvents: self.notifyMeetingEvents) {
                    Notifier.notify(title: "Transcript ready", body: body,
                                    threadIdentifier: name, folderPath: dir.path)
                }
            } else {
                Notifier.notify(title: "Pipeline failed", body: "\(name) — see pipeline.log",
                                threadIdentifier: name, folderPath: dir.path, sound: true)
            }
            self.sweepRetention()
        }
        MeetingStore.migrateLegacyRecordings()
        monitor.start()
        reconcileStaleMeetings()
        refreshMeetings()
        sweepRetention()
    }

    /// Recordings a previous app instance left behind (crash, force quit)
    /// would otherwise sit at "recording"/"processing" forever.
    private func reconcileStaleMeetings() {
        let fm = FileManager.default
        for meeting in MeetingStore.load() {
            guard meeting.directory != currentDir,
                  !pipeline.isRunning(meetingDir: meeting.directory) else { continue }
            let attrs = try? fm.attributesOfItem(atPath: meeting.paths.rawSystemAudio.path)
            let size = (attrs?[.size] as? Int) ?? 0
            let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
            let age = Date().timeIntervalSince(mtime)
            switch staleRecordingResolution(phase: meeting.phase, audioBytes: size, audioAge: age) {
            case .leaveAlone:
                continue
            case .process:
                MeetingStore.update(meeting.id) {
                    if $0.endedAt == nil { $0.endedAt = mtime }
                    $0.state = "recorded"
                }
                pipeline.process(meetingDir: meeting.directory)
            case .markInterrupted:
                MeetingStore.update(meeting.id) { $0.state = "error: recording interrupted" }
            case .markPipelineInterrupted:
                MeetingStore.update(meeting.id) {
                    $0.state = "error: pipeline interrupted — retry to reprocess"
                    $0.stage = nil
                }
            case .reprocess:
                pipeline.process(meetingDir: meeting.directory)
            }
        }
    }

    func refreshMeetings() {
        // Meetings is Equatable — skip the assignment (and the SwiftUI
        // re-render of every row) when nothing actually changed.
        let updated = MeetingStore.load()
        if updated != meetings { meetings = updated }
    }

    /// The 2s UI timer only needs to poll while something can change on disk.
    var shouldAutoRefresh: Bool {
        if case .recording = status { return true }
        return anyProcessing
    }

    /// Delete captured audio for finalized recordings per the retention policy.
    /// Best-effort; never touches the live recording, the transcript, or logs.
    func sweepRetention() {
        let policy = retentionPolicy
        guard policy != .keep else { return }
        let candidates = meetings.map { m in
            RetentionCandidate(id: m.id.rawValue, isFinal: isTranscriptFinal(m),
                               endedAt: m.meta.endedAt)
        }
        let ids = Set(recordingsToPurge(candidates, policy: policy,
                                        days: audioRetentionDays, now: Date()))
        guard !ids.isEmpty else { return }
        for m in meetings where ids.contains(m.id.rawValue) && m.directory != currentDir {
            purgeRecordingAudio(m.paths)
        }
    }

    private func isTranscriptFinal(_ m: Meeting) -> Bool {
        switch m.phase {
        case .ready, .needsClarification: return true
        default: return false
        }
    }

    private func beginRecording(_ call: DetectedCall) {
        guard currentDir == nil else { return }
        let meeting: Meeting
        do {
            meeting = try MeetingStore.createRecording(
                app: call.app.name, bundleID: call.app.id, startedAt: Date())
        } catch {
            lastError = "recording failed: \(error)"
            Notifier.notify(title: "Tamlil can't record", body: "\(error)")
            return
        }
        let dir = meeting.directory
        var meta = meeting.meta

        let tap = ProcessTapRecorder()
        let mic = MicRecorder()
        tap.onFailure = { [weak self] message in
            Task { @MainActor in
                self?.lastError = "system audio capture failed: \(message)"
                Notifier.notify(title: "System audio track failed", body: message)
                NSLog("system audio capture failed: \(message)")
            }
        }
        mic.onFailure = { [weak self] message in
            Task { @MainActor in
                self?.lastError = "mic capture failed: \(message)"
                Notifier.notify(title: "Mic track failed", body: message)
                NSLog("mic capture failed: \(message)")
            }
        }
        tap.onTerminalFailure = { [weak self] message in
            Task { @MainActor in self?.handleTerminalFailure(track: .system, message: message) }
        }
        mic.onTerminalFailure = { [weak self] message in
            Task { @MainActor in self?.handleTerminalFailure(track: .mic, message: message) }
        }

        do {
            try tap.start(outputURL: meeting.paths.rawSystemAudio)
        } catch {
            tap.stop()
            mic.stop()
            meta.endedAt = Date()
            meta.state = "error: \(error)"
            MeetingStore.update(meeting.id) { $0 = meta }
            lastError = "recording failed: \(error)"
            Notifier.notify(title: "Tamlil can't record", body: "\(error)")
            refreshMeetings()
            return
        }
        lastError = nil

        var micStarted = true
        do {
            try mic.start(outputURL: meeting.paths.rawMicAudio)
        } catch {
            // system track alone is still a valid meeting recording
            micStarted = false
            let detail = MicRecorder.permissionDenied
                ? "Recording without your mic — check Microphone permission in System Settings"
                : "Recording without your mic — \(error.localizedDescription)"
            lastError = detail
            Notifier.notify(title: "Mic unavailable", body: detail)
            NSLog("mic recording failed: \(error)")
        }

        tapRecorder = tap
        micRecorder = micStarted ? mic : nil
        currentDir = dir
        currentID = meeting.id
        currentMeta = meta
        status = .recording(app: call.app.name, since: meta.startedAt)
        if shouldPost(.meetingEvent, notifyMeetingEvents: notifyMeetingEvents) {
            Notifier.notify(title: "Recording \(call.app.name) call",
                            body: recordingStartedBody(dirName: dir.lastPathComponent,
                                                       remind: remindInformParticipants),
                            threadIdentifier: dir.lastPathComponent, folderPath: dir.path)
        }
        refreshMeetings()
    }

    /// Also callable from the UI ("Stop" button).
    func endRecording() {
        guard let dir = currentDir, let id = currentID, var meta = currentMeta else { return }
        tapRecorder?.stop()
        micRecorder?.stop()
        tapRecorder = nil
        micRecorder = nil
        currentDir = nil
        currentID = nil
        currentMeta = nil
        status = .idle

        let ended = Date()
        meta.endedAt = ended
        // Skip accidental blips (<20s of call audio).
        let tooShort = ended.timeIntervalSince(meta.startedAt) < 20
        meta.state = tooShort ? "discarded (too short)" : "recorded"
        MeetingStore.update(id) { $0 = meta }
        refreshMeetings()
        if !tooShort {
            pipeline.process(meetingDir: dir)
        }
    }

    private enum FailedTrack { case mic, system }

    /// A recorder permanently gave up and released its device. Drop that track.
    /// The surviving track keeps recording; the meeting is finalized only when
    /// both tracks are gone.
    private func handleTerminalFailure(track: FailedTrack, message: String) {
        guard currentDir != nil else { return }
        switch track {
        case .system: tapRecorder = nil
        case .mic: micRecorder = nil
        }
        lastError = message
        Notifier.notify(
            title: track == .mic ? "Mic track stopped" : "System audio track stopped",
            body: message)
        NSLog("terminal capture failure (\(track == .mic ? "mic" : "system")): \(message)")
        if tapRecorder == nil && micRecorder == nil {
            endRecording()   // finalize and run the pipeline on whatever was captured
        }
    }

    var anyProcessing: Bool {
        meetings.contains(where: \.isProcessing)
    }

    /// Live truth, unlike persisted state, which an orphaned or crashed
    /// pipeline can leave stale.
    func isPipelineRunning(_ meeting: Meeting) -> Bool {
        runningPipelineDirs.contains(meeting.directory.path)
    }

    func reprocess(_ meeting: Meeting) {
        // Immediate feedback: flip the state before the pipeline (which takes
        // seconds to boot) writes "processing" itself.
        var meta = meeting.meta
        meta.state = "processing"
        MeetingStore.update(meeting.id) { $0 = meta }
        refreshMeetings()
        pipeline.process(meetingDir: meeting.directory)
    }
}
