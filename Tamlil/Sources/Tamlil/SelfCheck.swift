// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import CoreAudio
import Foundation
import ObjCSupport

/// `Tamlil --self-check` runs these pure-logic assertions and exits — the
/// stand-in for `swift test` on this machine: Command Line Tools ship
/// neither XCTest nor Swift Testing, so a test target can't compile.
/// Each check prints PASS or FAIL; any failure exits 1.
enum SelfCheck {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--self-check") else { return }
        var failures = 0
        for (name, body) in checks {
            do {
                try body()
                print("PASS \(name)")
            } catch {
                failures += 1
                print("FAIL \(name): \(error)")
            }
        }
        print(failures == 0 ? "All \(checks.count) checks passed"
              : "\(failures) of \(checks.count) checks FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    private static let checks: [(String, () throws -> Void)] =
        storageChecks + lexiconChecks + flagRangeChecks + wordAudioChecks + engineChecks
        + systemTrackChecks + speakerNameChecks + durationChecks + clarificationEditChecks
        + reconcileChecks + waveformPlaybackChecks + menuBarIconChecks + loginItemChecks
        + captureStallChecks + captureQualityChecks + deleteRenameChecks + anchorDebounceChecks
        + tapWatchdogChecks + micRestartChecks + watchdogConstantChecks
        + exceptionCatcherChecks + notAnsweredChecks + credentialChecks
        + retentionChecks + notificationChecks + exportChecks + permissionChecks

    private static let permissionChecks: [(String, () throws -> Void)] = [
        ("permissions-needing-attention lists only the denied ones", {
            try expectEqual(permissionsNeedingAttention(micDenied: false, notificationsDenied: false),
                            [], "all granted lists nothing")
            try expectEqual(permissionsNeedingAttention(micDenied: true, notificationsDenied: false),
                            ["Microphone"], "mic denied only")
            try expectEqual(permissionsNeedingAttention(micDenied: true, notificationsDenied: true),
                            ["Microphone", "Notifications"], "both denied, mic first")
        }),
    ]

    private static let notificationChecks: [(String, () throws -> Void)] = [
        ("notification gating keeps problems unconditional and gates meeting events", {
            try expectEqual(shouldPost(.problem, notifyMeetingEvents: false), true,
                            "problems always post")
            try expectEqual(shouldPost(.meetingEvent, notifyMeetingEvents: false), false,
                            "meeting events off when the toggle is off")
            try expectEqual(shouldPost(.meetingEvent, notifyMeetingEvents: true), true,
                            "meeting events on when the toggle is on")
        }),
        ("recording-started body appends the participant reminder only when asked", {
            try expectEqual(recordingStartedBody(dirName: "2026-07-21-Zoom", remind: false),
                            "2026-07-21-Zoom", "no reminder by default")
            try expectEqual(recordingStartedBody(dirName: "2026-07-21-Zoom", remind: true),
                            "2026-07-21-Zoom — let participants know they're being recorded",
                            "reminder appended when enabled")
        }),
    ]

    private static let exportChecks: [(String, () throws -> Void)] = [
        ("plain-text export renders one speaker-labeled line per entry", {
            let lines = [(speaker: "Steven", text: "Let's start."),
                         (speaker: "Them", text: "Sounds good.")]
            try expectEqual(transcriptPlainText(lines: lines),
                            "Steven: Let's start.\nThem: Sounds good.", "two lines joined")
            try expectEqual(transcriptPlainText(lines: []), "", "empty transcript is empty")
        }),
    ]

    private static let retentionChecks: [(String, () throws -> Void)] = [
        ("retention policy selects the right recordings to purge", {
            let now = Date(timeIntervalSince1970: 1_000_000)
            let old = now.addingTimeInterval(-40 * 86_400)     // 40 days ago
            let recent = now.addingTimeInterval(-2 * 86_400)   // 2 days ago
            let cands = [
                RetentionCandidate(id: "final-old", isFinal: true, endedAt: old),
                RetentionCandidate(id: "final-recent", isFinal: true, endedAt: recent),
                RetentionCandidate(id: "not-final", isFinal: false, endedAt: old),
            ]
            try expectEqual(recordingsToPurge(cands, policy: .keep, days: 30, now: now),
                            [], "keep purges nothing")
            try expectEqual(recordingsToPurge(cands, policy: .deleteWhenFinal, days: 30, now: now).sorted(),
                            ["final-old", "final-recent"], "delete-when-final purges all finalized")
            try expectEqual(recordingsToPurge(cands, policy: .deleteAfterDays, days: 30, now: now),
                            ["final-old"], "delete-after-days purges only finalized older than N days")
            try expectEqual(recordingsToPurge([], policy: .deleteWhenFinal, days: 30, now: now),
                            [], "no candidates purges nothing")
        }),
    ]

    private static let captureStallChecks: [(String, () throws -> Void)] = [
        ("capture watchdog leaves a live tap alone", {
            try expectEqual(
                captureStallAction(secondsSinceLastBuffer: 0.1,
                                   stallThreshold: 2.0, failureThreshold: 20.0),
                .none, "buffers still flowing")
            try expectEqual(
                captureStallAction(secondsSinceLastBuffer: 1.99,
                                   stallThreshold: 2.0, failureThreshold: 20.0),
                .none, "just under stall threshold")
        }),
        ("capture watchdog recovers a silent tap", {
            // The AirPods-mid-call bug: the tap goes silent and never comes
            // back on its own. A gap past the stall threshold must re-tap.
            try expectEqual(
                captureStallAction(secondsSinceLastBuffer: 2.0,
                                   stallThreshold: 2.0, failureThreshold: 20.0),
                .recover, "at stall threshold")
            try expectEqual(
                captureStallAction(secondsSinceLastBuffer: 5.0,
                                   stallThreshold: 2.0, failureThreshold: 20.0),
                .recover, "well past stall, still recovering silently")
        }),
        ("capture watchdog alerts once recovery keeps failing", {
            try expectEqual(
                captureStallAction(secondsSinceLastBuffer: 19.99,
                                   stallThreshold: 2.0, failureThreshold: 20.0),
                .recover, "just under failure threshold still only recovers")
            try expectEqual(
                captureStallAction(secondsSinceLastBuffer: 20.0,
                                   stallThreshold: 2.0, failureThreshold: 20.0),
                .reportAndRecover, "at failure threshold")
            try expectEqual(
                captureStallAction(secondsSinceLastBuffer: 45.0,
                                   stallThreshold: 2.0, failureThreshold: 20.0),
                .reportAndRecover, "long dead")
        }),
        ("grace protects a warming device but not one that delivered then stalled", {
            try expectEqual(
                recoveryWithinGrace(secondsSinceLastRestart: nil,
                                    hasDeliveredSinceRestart: false, grace: 4.0),
                false, "no prior restart: nothing to protect")
            try expectEqual(
                recoveryWithinGrace(secondsSinceLastRestart: 0.5,
                                    hasDeliveredSinceRestart: false, grace: 4.0),
                true, "just restarted, no buffer yet: protect the warm-up")
            try expectEqual(
                recoveryWithinGrace(secondsSinceLastRestart: 3.99,
                                    hasDeliveredSinceRestart: false, grace: 4.0),
                true, "still warming up")
            try expectEqual(
                recoveryWithinGrace(secondsSinceLastRestart: 4.0,
                                    hasDeliveredSinceRestart: false, grace: 4.0),
                false, "warm-up window elapsed")
            try expectEqual(
                recoveryWithinGrace(secondsSinceLastRestart: 0.5,
                                    hasDeliveredSinceRestart: true, grace: 4.0),
                false, "buffers flowed then stalled: recover now, don't wait out the grace")
        }),
        ("mic recovery rebuilds the engine instead of reusing a stale tap graph", {
            try expectEqual(
                micRecoveryAction(stopped: false, hasFileFormat: true,
                                  hardwareSampleRate: 48_000, hardwareChannels: 1,
                                  secondsSinceLastRestart: 4.0,
                                  hasDeliveredSinceRestart: false, grace: 4.0),
                .rebuildEngine, "ready recovery uses a fresh AVAudioEngine")
            try expectEqual(
                micRecoveryAction(stopped: false, hasFileFormat: true,
                                  hardwareSampleRate: 0, hardwareChannels: 1,
                                  secondsSinceLastRestart: 4.0,
                                  hasDeliveredSinceRestart: false, grace: 4.0),
                .waitForValidDevice, "dead input format waits for the device")
            try expectEqual(
                micRecoveryAction(stopped: false, hasFileFormat: true,
                                  hardwareSampleRate: 48_000, hardwareChannels: 1,
                                  secondsSinceLastRestart: 3.9,
                                  hasDeliveredSinceRestart: false, grace: 4.0),
                .waitForWarmup, "warming device (no buffer yet) is not torn down again")
            try expectEqual(
                micRecoveryAction(stopped: false, hasFileFormat: true,
                                  hardwareSampleRate: 48_000, hardwareChannels: 1,
                                  secondsSinceLastRestart: 3.9,
                                  hasDeliveredSinceRestart: true, grace: 4.0),
                .rebuildEngine, "delivered then stalled inside grace: recover now")
            try expectEqual(
                micRecoveryAction(stopped: true, hasFileFormat: true,
                                  hardwareSampleRate: 48_000, hardwareChannels: 1,
                                  secondsSinceLastRestart: 4.0,
                                  hasDeliveredSinceRestart: false, grace: 4.0),
                .skip, "stopped recorder never recovers")
        }),
        ("capture watchdog constants keep a safe margin", {
            // Ties the shipped constants to reality: poll faster than we decide
            // a stall; the stall threshold must sit above the worst-case buffer
            // cadence (4096 frames at 8 kHz HFP ~= 0.51 s) or a healthy tap
            // reads as dead; warm-up grace outlasts stall detection; the alert
            // waits for several retry cycles.
            let worstCadence = 4096.0 / 8000.0
            try expectEqual(MicRecorder.watchdogInterval < MicRecorder.stallThreshold,
                            true, "poll faster than stall declaration")
            try expectEqual(MicRecorder.stallThreshold > worstCadence * 2,
                            true, "stall threshold clears buffer cadence with margin")
            try expectEqual(MicRecorder.recoverGrace > MicRecorder.stallThreshold,
                            true, "warm-up grace outlasts stall detection")
            try expectEqual(MicRecorder.failureThreshold > MicRecorder.recoverGrace,
                            true, "alert only after several retry cycles")
        }),
        ("capture liveness clock advances on every buffer and resets on start", {
            let sink = AudioCaptureSink(logTag: "selfcheck", noun: "mic")
            sink.markCaptureStarted(now: 100)
            try expectEqual(sink.secondsSinceLastBuffer(now: 105), 5, "gap since start")
            // A real buffer must bump the clock, else a healthy recording would
            // read as a dead tap and be re-torn every second.
            let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                    channels: 1, interleaved: true)!
            let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 512)!
            buffer.frameLength = 512
            sink.markCaptureStarted(now: 0)   // pin the clock far in the past
            sink.write(buffer, converter: nil)
            try expectEqual(sink.secondsSinceLastBuffer() < 1.0, true,
                            "write() bumped the clock to now")
        }),
    ]

    private static let captureQualityChecks: [(String, () throws -> Void)] = [
        ("bluetooth input warns, wired input stays quiet", {
            try expectEqual(bluetoothMicWarning(transportType: kAudioDeviceTransportTypeBluetooth) != nil,
                            true, "bluetooth mic warns")
            try expectEqual(bluetoothMicWarning(transportType: kAudioDeviceTransportTypeBuiltIn),
                            nil, "built-in mic stays quiet")
            try expectEqual(bluetoothMicWarning(transportType: kAudioDeviceTransportTypeUSB),
                            nil, "usb mic stays quiet")
        }),
        ("signal alert flags sustained silence and clipping, not brief dips", {
            try expectEqual(
                audioSignalAlert(secondsSinceSignal: 89, secondsClipping: 0,
                                 silenceThreshold: 90, clippingThreshold: 5),
                .none, "quiet stretch under threshold is tolerated")
            try expectEqual(
                audioSignalAlert(secondsSinceSignal: 90, secondsClipping: 0,
                                 silenceThreshold: 90, clippingThreshold: 5),
                .silent, "sustained silence flagged")
            try expectEqual(
                audioSignalAlert(secondsSinceSignal: 0, secondsClipping: 4.99,
                                 silenceThreshold: 90, clippingThreshold: 5),
                .none, "brief clipping tolerated")
            try expectEqual(
                audioSignalAlert(secondsSinceSignal: 0, secondsClipping: 5,
                                 silenceThreshold: 90, clippingThreshold: 5),
                .clipping, "sustained clipping flagged")
            try expectEqual(
                audioSignalAlert(secondsSinceSignal: 120, secondsClipping: 30,
                                 silenceThreshold: 90, clippingThreshold: 5),
                .silent, "a dead input reads as silent, not clipping")
        }),
        ("capture level constants keep silence generous and clipping strict", {
            try expectEqual(AudioCaptureSink.silenceFloor < AudioCaptureSink.clippingFloor,
                            true, "silence floor below the clipping ceiling")
            try expectEqual(AudioCaptureSink.silenceThreshold > AudioCaptureSink.clippingThreshold,
                            true, "tolerate quiet far longer than overdrive")
        }),
        ("buffer peak reads silence, full scale, and float levels", {
            let intFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                       channels: 1, interleaved: true)!
            let silent = AVAudioPCMBuffer(pcmFormat: intFmt, frameCapacity: 128)!
            silent.frameLength = 128
            try expectEqual(bufferPeak(silent), Float(0), "all-zero buffer is silent")

            let hot = AVAudioPCMBuffer(pcmFormat: intFmt, frameCapacity: 128)!
            hot.frameLength = 128
            let hotPtr = hot.int16ChannelData![0]
            for i in 0..<128 { hotPtr[i] = 32767 }
            try expectEqual(bufferPeak(hot) >= AudioCaptureSink.clippingFloor,
                            true, "full-scale int buffer reads as clipping")

            let floatFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                         channels: 1, interleaved: false)!
            let half = AVAudioPCMBuffer(pcmFormat: floatFmt, frameCapacity: 64)!
            half.frameLength = 64
            let halfPtr = half.floatChannelData![0]
            for i in 0..<64 { halfPtr[i] = 0.5 }
            try expectEqual(bufferPeak(half), Float(0.5), "float peak normalized to full scale")

            let empty = AVAudioPCMBuffer(pcmFormat: intFmt, frameCapacity: 128)!
            empty.frameLength = 0
            try expectEqual(bufferPeak(empty), Float(0), "empty buffer never crashes")
        }),
        ("system audio file is pinned to the 48 kHz cap regardless of device rate", {
            let low = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                    channels: 2, interleaved: true)!
            let format = systemAudioFileFormat(capturing: low)
            try expectEqual(format.sampleRate, 48_000, "pinned up to the cap")
            try expectEqual(format.channelCount, 2, "channels kept")
            try expectEqual(format.commonFormat, .pcmFormatInt16, "16-bit on disk")
        }),
        ("capture converter downsamples a high-rate buffer without erroring", {
            let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 96_000,
                                       channels: 2, interleaved: true)!
            let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                       channels: 2, interleaved: true)!
            guard let converter = CaptureConverter(from: source, to: target) else {
                throw Failure(description: "converter build failed")
            }
            let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 960)!
            input.frameLength = 960
            let output = try converter.convert(input)
            try expectEqual(output.frameLength > 0, true, "produced samples")
            try expectEqual(output.frameLength < input.frameLength, true, "downsampled")
        }),
    ]

    private static let anchorDebounceChecks: [(String, () throws -> Void)] = [
        ("anchor debounce ignores a stable, matching default output", {
            let r = anchorChangeDebounce(currentDefaultUID: "A", anchoredUID: "A",
                                         lastObservedUID: "A", stablePolls: 0,
                                         requiredStablePolls: 3)
            try expectEqual(r.stablePolls, 0, "no pending change")
            try expectEqual(r.shouldRebuild, false, "matching default never rebuilds")
        }),
        ("anchor debounce restarts the counter while the device is still moving", {
            // First poll after a switch: current (B) differs from both the
            // anchor (A) and the last observation (A) — device still in flight.
            let r = anchorChangeDebounce(currentDefaultUID: "B", anchoredUID: "A",
                                         lastObservedUID: "A", stablePolls: 0,
                                         requiredStablePolls: 3)
            try expectEqual(r.stablePolls, 1, "counter restarts at 1")
            try expectEqual(r.shouldRebuild, false, "one sighting is not settled")
            // A flap to a third device mid-debounce also restarts.
            let flap = anchorChangeDebounce(currentDefaultUID: "C", anchoredUID: "A",
                                            lastObservedUID: "B", stablePolls: 2,
                                            requiredStablePolls: 3)
            try expectEqual(flap.stablePolls, 1, "flap resets the debounce")
            try expectEqual(flap.shouldRebuild, false, "not settled after a flap")
        }),
        ("anchor debounce fires once a new device is stable for the required polls", {
            let two = anchorChangeDebounce(currentDefaultUID: "B", anchoredUID: "A",
                                           lastObservedUID: "B", stablePolls: 1,
                                           requiredStablePolls: 3)
            try expectEqual(two.stablePolls, 2, "second sighting")
            try expectEqual(two.shouldRebuild, false, "still under the threshold")
            let three = anchorChangeDebounce(currentDefaultUID: "B", anchoredUID: "A",
                                             lastObservedUID: "B", stablePolls: 2,
                                             requiredStablePolls: 3)
            try expectEqual(three.stablePolls, 3, "third sighting")
            try expectEqual(three.shouldRebuild, true, "settled: rebuild")
        }),
    ]

    private static let tapWatchdogChecks: [(String, () throws -> Void)] = [
        ("tap watchdog leaves a healthy, current tap alone", {
            try expectEqual(
                tapWatchdogAction(shouldRebuildForChange: false, anchorAlive: true,
                                  anchorRunning: true,
                                  secondsSinceLastBuffer: 0.2, stallThreshold: 2.0,
                                  consecutiveFailedRebuilds: 0, maxRebuilds: 6),
                .none, "buffers flowing, anchor current and alive")
        }),
        ("tap watchdog rebuilds on a settled device change, a dead anchor, or a running stall", {
            try expectEqual(
                tapWatchdogAction(shouldRebuildForChange: true, anchorAlive: true,
                                  anchorRunning: true,
                                  secondsSinceLastBuffer: 0.2, stallThreshold: 2.0,
                                  consecutiveFailedRebuilds: 0, maxRebuilds: 6),
                .rebuild, "settled default-output change")
            try expectEqual(
                tapWatchdogAction(shouldRebuildForChange: false, anchorAlive: false,
                                  anchorRunning: true,
                                  secondsSinceLastBuffer: 0.2, stallThreshold: 2.0,
                                  consecutiveFailedRebuilds: 0, maxRebuilds: 6),
                .rebuild, "anchor device died")
            try expectEqual(
                tapWatchdogAction(shouldRebuildForChange: false, anchorAlive: true,
                                  anchorRunning: true,
                                  secondsSinceLastBuffer: 2.0, stallThreshold: 2.0,
                                  consecutiveFailedRebuilds: 0, maxRebuilds: 6),
                .rebuild, "IOProc stalled while the device is running: dead tap")
        }),
        ("tap watchdog ignores a stall while the output device is idle (silence)", {
            try expectEqual(
                tapWatchdogAction(shouldRebuildForChange: false, anchorAlive: true,
                                  anchorRunning: false,
                                  secondsSinceLastBuffer: 30, stallThreshold: 2.0,
                                  consecutiveFailedRebuilds: 0, maxRebuilds: 6),
                .none, "device idle, nothing playing: legitimate silence, don't churn")
        }),
        ("tap watchdog gives up after the rebuild budget is spent", {
            try expectEqual(
                tapWatchdogAction(shouldRebuildForChange: true, anchorAlive: false,
                                  anchorRunning: true,
                                  secondsSinceLastBuffer: 30, stallThreshold: 2.0,
                                  consecutiveFailedRebuilds: 6, maxRebuilds: 6),
                .giveUp, "budget spent: stop and release, never loop")
        }),
    ]

    private static let micRestartChecks: [(String, () throws -> Void)] = [
        ("mic restart is time-bounded so a wedged input is released, not held", {
            try expectEqual(micRestartExhausted(secondsSinceFirstFailure: 0, abandonAfter: 15),
                            false, "just started failing: keep retrying")
            try expectEqual(micRestartExhausted(secondsSinceFirstFailure: 14.9, abandonAfter: 15),
                            false, "still under the abandon window")
            try expectEqual(micRestartExhausted(secondsSinceFirstFailure: 15, abandonAfter: 15),
                            true, "sustained failure: release the device")
        }),
    ]

    private static let watchdogConstantChecks: [(String, () throws -> Void)] = [
        ("tap watchdog constants keep safe margins", {
            try expectEqual(ProcessTapRecorder.watchdogInterval < ProcessTapRecorder.stallThreshold,
                            true, "poll faster than a stall is declared")
            try expectEqual(ProcessTapRecorder.recoverGrace > ProcessTapRecorder.stallThreshold,
                            true, "warm-up grace outlasts stall detection")
            try expectEqual(ProcessTapRecorder.requiredStablePolls >= 2,
                            true, "a settled change needs more than one sighting")
            try expectEqual(ProcessTapRecorder.maxRebuilds >= 1,
                            true, "at least one rebuild attempt before giving up")
            try expectEqual(MicRecorder.retryInterval < MicRecorder.watchdogInterval,
                            true, "settle re-poll is faster than a watchdog tick")
            try expectEqual(MicRecorder.restartAbandonAfter > MicRecorder.recoverGrace,
                            true, "give a settling device far longer than one warm-up before release")
        }),
    ]

    private static let menuBarIconChecks: [(String, () throws -> Void)] = [
        ("menu bar icon prefers recording, then processing, then idle", {
            try expectEqual(MenuBarIconKind(
                status: .recording(app: "Zoom", since: Date(timeIntervalSince1970: 0)),
                anyProcessing: true), .recording, "recording wins")
            try expectEqual(MenuBarIconKind(status: .idle, anyProcessing: true),
                            .processing, "processing when idle")
            try expectEqual(MenuBarIconKind(status: .idle, anyProcessing: false),
                            .idle, "idle")
        }),
    ]

    private static let loginItemChecks: [(String, () throws -> Void)] = [
        ("launch agent restarts Tamlil only after a crash", {
            let plist = LoginItem.launchAgentPlist(
                appExecutable: URL(fileURLWithPath: "/Applications/Tamlil.app/Contents/MacOS/Tamlil"),
                logDirectory: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Logs/Tamlil", isDirectory: true)
            )
            try expectEqual(plist["Label"] as? String, LoginItem.launchAgentLabel, "label")
            try expectEqual(plist["ProgramArguments"] as? [String],
                            ["/Applications/Tamlil.app/Contents/MacOS/Tamlil"], "program")
            try expectEqual(plist["RunAtLoad"] as? Bool, true, "login launch")
            let keepAlive = plist["KeepAlive"] as? [String: Bool]
            try expectEqual(keepAlive?["Crashed"], true, "crash relaunch")
            try expectEqual(plist["LimitLoadToSessionType"] as? String, "Aqua", "gui session")
        }),
    ]

    private static let exceptionCatcherChecks: [(String, () throws -> Void)] = [
        ("objc exception catcher turns a raised NSException into a Swift error", {
            // Guards the fix for the installTap "format mismatch" crash: an
            // Objective-C NSException must surface as a catchable Swift error.
            var threw = false
            do {
                try ExceptionCatcher.catching {
                    NSException(name: .genericException, reason: "boom", userInfo: nil).raise()
                }
            } catch {
                threw = true
            }
            try expectEqual(threw, true, "a raised NSException surfaces as a Swift error")
            var ran = false
            try ExceptionCatcher.catching { ran = true }
            try expectEqual(ran, true, "a clean block runs without throwing")
        }),
    ]

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expectEqual<T: Equatable>(
        _ got: T, _ want: T, _ label: String
    ) throws {
        if got != want { throw Failure(description: "\(label): got \(got), want \(want)") }
    }

    private static func tempJSON(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("selfcheck-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func tempDir(_ name: String = "selfcheck-\(UUID().uuidString)") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: storage

    private static let storageChecks: [(String, () throws -> Void)] = [
        ("recording paths use GA layout", {
            let root = try tempDir()
            let id = RecordingID("2026-06-12-120000-Zoom")
            let paths = RecordingPaths(root: root, id: id)
            try expectEqual(paths.rawSystemAudio.path,
                            root.appendingPathComponent("\(id.rawValue)/raw/system.wav").path,
                            "system path")
            try expectEqual(paths.workMergedRawJSON.path,
                            root.appendingPathComponent("\(id.rawValue)/work/merged.raw.json").path,
                            "merged path")
            try expectEqual(paths.pipelineLog.path,
                            root.appendingPathComponent("\(id.rawValue)/logs/pipeline.log").path,
                            "log path")
        }),
        ("sqlite repository creates and updates recording state", {
            let dir = try tempDir()
            let db = dir.appendingPathComponent("tamlil.sqlite")
            let root = dir.appendingPathComponent("recordings", isDirectory: true)
            let repo = try SQLiteRecordingRepository(databaseURL: db, recordingsRoot: root)
            let started = Date(timeIntervalSince1970: 1_800_000_000)
            let meeting = try repo.createRecording(app: "Zoom", bundleID: "us.zoom.xos",
                                                   startedAt: started)
            try repo.updateRecording(meeting.id) { meta in
                meta.state = "processing"
                meta.stage = "transcribing"
                meta.endedAt = started.addingTimeInterval(3600)
            }
            let loaded = try repo.loadRecordings()
            try expectEqual(loaded.count, 1, "recording count")
            try expectEqual(loaded[0].id, meeting.id, "id")
            try expectEqual(loaded[0].meta.app, "Zoom", "app")
            try expectEqual(loaded[0].meta.state, "processing", "state")
            try expectEqual(loaded[0].meta.stage, "transcribing", "stage")
            try expectEqual(loaded[0].directory.path,
                            root.appendingPathComponent(meeting.id.rawValue).path,
                            "directory")
        }),
        ("update targets one row and missing id is a no-op", {
            let dir = try tempDir()
            let db = dir.appendingPathComponent("tamlil.sqlite")
            let root = dir.appendingPathComponent("recordings", isDirectory: true)
            let repo = try SQLiteRecordingRepository(databaseURL: db, recordingsRoot: root)
            let a = try repo.createRecording(app: "Zoom", bundleID: "us.zoom.xos",
                                             startedAt: Date(timeIntervalSince1970: 1_000))
            let b = try repo.createRecording(app: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                                             startedAt: Date(timeIntervalSince1970: 2_000))
            try repo.updateRecording(b.id) { meta in
                meta.state = "processing"
                meta.stage = "transcribing"
            }
            try repo.updateRecording(RecordingID("does-not-exist")) { $0.state = "wrecked" }
            let byID = Dictionary(uniqueKeysWithValues:
                try repo.loadRecordings().map { ($0.id, $0.meta) })
            try expectEqual(byID.count, 2, "no row created for missing id")
            try expectEqual(byID[a.id]?.state, "recording", "untouched row state")
            try expectEqual(byID[a.id]?.stage, nil, "untouched row stage")
            try expectEqual(byID[b.id]?.state, "processing", "updated row state")
            try expectEqual(byID[b.id]?.stage, "transcribing", "updated row stage")
        }),
        ("recording paths create logs only when requested", {
            let root = try tempDir()
            let paths = RecordingPaths(root: root, id: RecordingID("order-check"))
            try expectEqual(FileManager.default.fileExists(atPath: paths.directory.path),
                            false, "paths are pure")
            try paths.prepareDirectories()
            try expectEqual(FileManager.default.fileExists(atPath: paths.rawDirectory.path),
                            true, "raw exists")
            try expectEqual(FileManager.default.fileExists(atPath: paths.workDirectory.path),
                            true, "work exists")
            try expectEqual(FileManager.default.fileExists(atPath: paths.finalDirectory.path),
                            true, "final exists")
            try expectEqual(FileManager.default.fileExists(atPath: paths.logsDirectory.path),
                            true, "logs exists")
        }),

        ("legacy flat recording migrates to sqlite and GA layout", {
            let dir = try tempDir()
            let db = dir.appendingPathComponent("tamlil.sqlite")
            let root = dir.appendingPathComponent("recordings", isDirectory: true)
            let legacy = root.appendingPathComponent("2026-06-12-120000-Zoom", isDirectory: true)
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            let meta = """
            {"app":"Zoom","bundle_id":"us.zoom.xos","started_at":"2026-06-12T12:00:00Z","ended_at":"2026-06-12T12:30:00Z","state":"recorded","stage":"transcribing","event_title":"Standup","roster":["Roy"],"rooms":["Room A"]}
            """
            try meta.write(to: legacy.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
            try Data("sys".utf8).write(to: legacy.appendingPathComponent("system.wav"))
            try Data("mic".utf8).write(to: legacy.appendingPathComponent("mic.wav"))
            try Data("{}".utf8).write(to: legacy.appendingPathComponent("mic.json"))
            try Data("{}".utf8).write(to: legacy.appendingPathComponent("system.json"))
            try Data("{}".utf8).write(to: legacy.appendingPathComponent("merged.json"))
            try Data(#"{"system_mic_offset_s":5.14}"#.utf8)
                .write(to: legacy.appendingPathComponent("echo.report.json"))
            try Data("[]".utf8).write(to: legacy.appendingPathComponent("merged.uncertain.json"))
            try Data("{}".utf8).write(to: legacy.appendingPathComponent("merged.corrected.json"))
            try Data("transcript".utf8).write(to: legacy.appendingPathComponent("transcript.md"))
            try Data("log".utf8).write(to: legacy.appendingPathComponent("pipeline.log"))
            let repo = try SQLiteRecordingRepository(databaseURL: db, recordingsRoot: root)
            let migrated = try repo.migrateLegacyRecordings()
            try expectEqual(migrated.count, 1, "migrated count")
            let id = RecordingID("2026-06-12-120000-Zoom")
            let paths = RecordingPaths(root: root, id: id)
            try expectEqual(FileManager.default.fileExists(atPath: paths.rawSystemAudio.path), true, "system raw")
            try expectEqual(FileManager.default.fileExists(atPath: paths.rawMicAudio.path), true, "mic raw")
            try expectEqual(FileManager.default.fileExists(atPath: paths.workMicASRJSON.path), true, "mic asr")
            try expectEqual(FileManager.default.fileExists(atPath: paths.workSystemASRJSON.path), true, "system asr")
            try expectEqual(FileManager.default.fileExists(atPath: paths.workMergedRawJSON.path), true, "merged raw")
            try expectEqual(FileManager.default.fileExists(atPath: paths.workEchoReportJSON.path), true, "echo report")
            try expectEqual(FileManager.default.fileExists(atPath: paths.workMergedUncertainJSON.path), true, "uncertain")
            try expectEqual(FileManager.default.fileExists(atPath: paths.finalTranscriptJSON.path), true, "final json")
            try expectEqual(FileManager.default.fileExists(atPath: paths.finalTranscriptMarkdown.path), true, "final md")
            try expectEqual(FileManager.default.fileExists(atPath: paths.pipelineLog.path), true, "log")
            let loaded = try repo.loadRecordings()
            try expectEqual(loaded.count, 1, "recording count")
            try expectEqual(loaded[0].id, id, "id")
            try expectEqual(loaded[0].meta.state, "recorded", "state")
            try expectEqual(loaded[0].meta.stage, "transcribing", "stage")
            try expectEqual(loaded[0].meta.eventTitle, "Standup", "event title")
        }),

        ("legacy audio without meta migrates into raw", {
            let dir = try tempDir()
            let db = dir.appendingPathComponent("tamlil.sqlite")
            let root = dir.appendingPathComponent("recordings", isDirectory: true)
            let legacy = root.appendingPathComponent("2026-06-12-140000-Unknown", isDirectory: true)
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            try Data("sys".utf8).write(to: legacy.appendingPathComponent("system.wav"))
            let repo = try SQLiteRecordingRepository(databaseURL: db, recordingsRoot: root)
            try expectEqual(try repo.migrateLegacyRecordings().count, 1, "migration count")
            let paths = RecordingPaths(root: root, id: RecordingID("2026-06-12-140000-Unknown"))
            try expectEqual(FileManager.default.fileExists(atPath: paths.rawSystemAudio.path), true, "raw system")
            let loaded = try repo.loadRecordings()
            try expectEqual(loaded.count, 1, "recording count")
            try expectEqual(loaded[0].meta.state, "recorded", "state")
        }),
        ("legacy migration is idempotent and preserves stores", {
            let dir = try tempDir()
            let db = dir.appendingPathComponent("tamlil.sqlite")
            let root = dir.appendingPathComponent("recordings", isDirectory: true)
            let legacy = root.appendingPathComponent("2026-06-12-130000-Slack", isDirectory: true)
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            try #"{"app":"Slack","bundle_id":"com.tinyspeck.slackmacgap","started_at":"2026-06-12T13:00:00Z","state":"recorded"}"#.write(to: legacy.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
            try Data("sys".utf8).write(to: legacy.appendingPathComponent("system.wav"))
            try #"{"1":"Roy"}"#.write(to: legacy.appendingPathComponent("speakers.json"), atomically: true, encoding: .utf8)
            let cards = """
            [{"original":"EB two","guess":"EB-2","context":"Discuss EB two","status":"pending","severity":"wrong","answer":null,"edits":null,"start":1.0,"end":1.5,"speaker":"Them"}]
            """
            try cards.write(to: legacy.appendingPathComponent("clarifications.json"), atomically: true, encoding: .utf8)
            let repo = try SQLiteRecordingRepository(databaseURL: db, recordingsRoot: root)
            try expectEqual(try repo.migrateLegacyRecordings().count, 1, "first migration")
            try expectEqual(try repo.migrateLegacyRecordings().count, 0, "second migration")
            let id = RecordingID("2026-06-12-130000-Slack")
            try expectEqual(try repo.speakerNames(for: id), ["1": "Roy"], "speaker names")
            let loadedCards = try repo.clarifications(for: id)
            try expectEqual(loadedCards.count, 1, "clarification count")
            try expectEqual(loadedCards[0].original, "EB two", "clarification original")
        }),
    ]

    // MARK: delete and rename

    private static let deleteRenameChecks: [(String, () throws -> Void)] = [
        ("delete removes a recording and its dependent rows", {
            let dir = try tempDir()
            let db = dir.appendingPathComponent("tamlil.sqlite")
            let root = dir.appendingPathComponent("recordings", isDirectory: true)
            let repo = try SQLiteRecordingRepository(databaseURL: db, recordingsRoot: root)
            let a = try repo.createRecording(app: "Zoom", bundleID: "us.zoom.xos",
                                             startedAt: Date(timeIntervalSince1970: 1_000))
            let b = try repo.createRecording(app: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                                             startedAt: Date(timeIntervalSince1970: 2_000))
            try repo.replaceSpeakerNames(["2": "Roy"], for: a.id)
            try repo.saveClarifications([pendingFlag("EB two")], for: a.id)
            try repo.deleteRecording(a.id)
            let loaded = try repo.loadRecordings()
            try expectEqual(loaded.count, 1, "only one row remains")
            try expectEqual(loaded.first?.id, b.id, "the other recording survives")
            try expectEqual(try repo.speakerNames(for: a.id), [String: String](),
                            "speaker names cleared")
            try expectEqual(try repo.clarifications(for: a.id).count, 0,
                            "clarifications cleared")
        }),
        ("delete of an unknown or already-gone id is a no-op", {
            let dir = try tempDir()
            let db = dir.appendingPathComponent("tamlil.sqlite")
            let root = dir.appendingPathComponent("recordings", isDirectory: true)
            let repo = try SQLiteRecordingRepository(databaseURL: db, recordingsRoot: root)
            let a = try repo.createRecording(app: "Zoom", bundleID: "us.zoom.xos",
                                             startedAt: Date(timeIntervalSince1970: 1_000))
            try repo.deleteRecording(RecordingID("never-existed"))
            try repo.deleteRecording(a.id)
            try repo.deleteRecording(a.id)   // idempotent: second delete must not throw
            try expectEqual(try repo.loadRecordings().count, 0, "all rows gone")
        }),
        ("rename sets and clears the event title", {
            let dir = try tempDir()
            let db = dir.appendingPathComponent("tamlil.sqlite")
            let root = dir.appendingPathComponent("recordings", isDirectory: true)
            let repo = try SQLiteRecordingRepository(databaseURL: db, recordingsRoot: root)
            let a = try repo.createRecording(app: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                                             startedAt: Date(timeIntervalSince1970: 1_000))
            try repo.updateRecording(a.id) { $0.eventTitle = normalizedMeetingTitle("  Design sync ") }
            try expectEqual(try repo.loadRecordings().first?.meta.eventTitle, "Design sync",
                            "trimmed title set")
            try repo.updateRecording(a.id) { $0.eventTitle = normalizedMeetingTitle("   ") }
            try expectEqual(try repo.loadRecordings().first?.meta.eventTitle, nil,
                            "whitespace clears back to auto title")
        }),
        ("meeting display title prefers a custom title over the auto one", {
            let slack = Meeting(id: RecordingID("s"), directory: URL(fileURLWithPath: "/tmp/s"),
                                meta: MeetingMeta(app: "Slack", bundleID: "", startedAt: Date(),
                                                  endedAt: nil, state: "ready"))
            try expectEqual(slack.autoTitle, "Slack huddle", "auto huddle title")
            try expectEqual(slack.displayTitle, "Slack huddle", "display falls back to auto")
            var named = slack
            named.meta.eventTitle = "Weekly sync"
            try expectEqual(named.displayTitle, "Weekly sync", "custom title wins")
        }),
    ]

    // MARK: lexicon dictionary

    private static let lexiconChecks: [(String, () throws -> Void)] = [
        ("lexicon matches variants case-insensitively", {
            let url = try tempJSON("""
            {"version": 2, "ingested": 0, "terms": [
              {"canonical": "EB-2", "variants": ["EB two", "יבי טו"], "count": 3, "last_seen": ""}
            ]}
            """)
            let dict = LexiconDictionary.load(from: url)
            try expectEqual(dict.canonical(for: "eb TWO"), "EB-2", "latin variant")
            try expectEqual(dict.canonical(for: "יבי טו"), "EB-2", "hebrew variant")
            try expectEqual(dict.canonical(for: "PERM"), nil, "unknown term")
        }),
        ("lexicon missing file is empty", {
            let dict = LexiconDictionary.load(
                from: URL(fileURLWithPath: "/nonexistent/dict.json"))
            try expectEqual(dict.canonical(for: "anything"), nil, "missing file")
        }),
        ("lexicon malformed json is empty", {
            let url = try tempJSON("{not json")
            try expectEqual(LexiconDictionary.load(from: url).canonical(for: "x"),
                            nil, "malformed file")
        }),
        ("lexicon canonical never suggests itself", {
            let url = try tempJSON("""
            {"version": 2, "ingested": 0, "terms": [
              {"canonical": "eval", "variants": ["eval", "gibel"], "count": 1, "last_seen": ""}
            ]}
            """)
            let dict = LexiconDictionary.load(from: url)
            try expectEqual(dict.canonical(for: "eval"), nil, "self echo")
            try expectEqual(dict.canonical(for: "gibel"), "eval", "real variant")
        }),
        ("suggestions order and dedup", {
            let dict = LexiconDictionary(variantToCanonical: ["requirments": "requirements"])
            try expectEqual(dict.suggestions(for: "requirments", guess: "requirement's"),
                            ["requirement's", "requirements"], "guess first")
            try expectEqual(dict.suggestions(for: "requirments", guess: "Requirements"),
                            ["Requirements"], "case-insensitive dedup")
            try expectEqual(dict.suggestions(for: "requirments", guess: "requirments"),
                            ["requirements"], "guess echoing heard dropped")
            try expectEqual(LexiconDictionary.empty.suggestions(for: "word", guess: nil),
                            [], "no sources")
        }),
        ("lexicon match key ignores edge punctuation and spacing", {
            let url = try tempJSON("""
            {"version": 2, "ingested": 0, "terms": [
              {"canonical": "EB-2", "variants": ["EB two"], "count": 3, "last_seen": ""}
            ]}
            """)
            let dict = LexiconDictionary.load(from: url)
            try expectEqual(dict.canonical(for: "EB two,"), "EB-2", "trailing comma")
            try expectEqual(dict.canonical(for: "  eb   two…"), "EB-2", "spacing and ellipsis")
            try expectEqual(dict.suggestions(for: "(EB two)", guess: nil),
                            ["EB-2"], "parenthesized selection")
            try expectEqual(dict.suggestions(for: "EB-2.", guess: "EB-2"),
                            [], "echo modulo punctuation")
        }),
    ]

    // MARK: flag display ranges

    private static func pendingFlag(_ original: String) -> Clarification {
        Clarification(original: original, guess: "fix", context: "ctx", status: "pending",
                      severity: "wrong", answer: nil, edits: nil,
                      start: nil, end: nil, speaker: nil)
    }

    private static let flagRangeChecks: [(String, () throws -> Void)] = [
        ("clarification decodes source without guess", {
            let data = Data("""
            [{"original":"gamma","context":"ship gamma","status":"pending","severity":"unsure","source":"asr_confidence","start":1.0,"end":2.0,"speaker":"Me","confidence":0.42}]
            """.utf8)
            let cards = try JSONDecoder().decode([Clarification].self, from: data)
            try expectEqual(cards.count, 1, "count")
            try expectEqual(cards[0].guess, nil, "guess")
            try expectEqual(cards[0].source, "asr_confidence", "source")
            try expectEqual(cards[0].confidence, 0.42, "confidence")
        }),
        ("flag range found on token boundaries", {
            let text = "What are the requiremesnts for this?"
            let ranges = flagDisplayRanges([pendingFlag("requiremesnts")], in: text)
            try expectEqual(ranges.count, 1, "count")
            try expectEqual(String(text[ranges[0].range]), "requiremesnts", "range text")
        }),
        ("short term never matches inside longer word", {
            let ranges = flagDisplayRanges([pendingFlag("term")], in: "determine the result")
            try expectEqual(ranges.count, 0, "count")
        }),
        ("already applied flag drops out", {
            let ranges = flagDisplayRanges([pendingFlag("requiremesnts")],
                                           in: "the requirements are set")
            try expectEqual(ranges.count, 0, "count")
        }),
        ("multi-word phrase found", {
            let text = "Let's dive into EB two PERM with Globex."
            let ranges = flagDisplayRanges([pendingFlag("EB two")], in: text)
            try expectEqual(ranges.count, 1, "count")
            try expectEqual(String(text[ranges[0].range]), "EB two", "range text")
        }),
        ("hebrew term found", {
            let text = "צריך לבדוק את האיבל מחר"
            let ranges = flagDisplayRanges([pendingFlag("האיבל")], in: text)
            try expectEqual(ranges.count, 1, "count")
            try expectEqual(String(text[ranges[0].range]), "האיבל", "range text")
        }),
        ("flag swallowed when replacement destroys its term", {
            let flags = [pendingFlag("EB two")]
            let ids = swallowedFlagIDs(replacing: "into EB two PERM", with: "into EB-2 PERM",
                                       in: "Let's dive into EB two PERM with Globex.",
                                       among: flags)
            try expectEqual(ids, flags.map(\.id), "swallowed ids")
        }),
        ("flag survives replacement elsewhere in line", {
            let ids = swallowedFlagIDs(replacing: "Globex", with: "Globex Corp",
                                       in: "Let's dive into EB two PERM with Globex.",
                                       among: [pendingFlag("EB two")])
            try expectEqual(ids, [], "untouched flag")
        }),
        ("flag absent from text never reported swallowed", {
            let ids = swallowedFlagIDs(replacing: "requirements", with: "rules",
                                       in: "What are the requirements for this?",
                                       among: [pendingFlag("EB two")])
            try expectEqual(ids, [], "absent flag")
        }),
    ]

    // MARK: word audio ranges

    private static let wordAudioWords = [
        TranscriptWord(text: "Ship", start: 10.0, end: 10.4),
        TranscriptWord(text: "the", start: 10.5, end: 10.7),
        TranscriptWord(text: "Gamma", start: 10.8, end: 11.2),
        TranscriptWord(text: "rollout", start: 11.3, end: 11.8),
    ]

    private static let wordAudioChecks: [(String, () throws -> Void)] = [
        ("word audio matches multi-word sequence", {
            let range = wordAudioRange(for: "Gamma rollout", in: wordAudioWords,
                                       segmentStart: 10.0, segmentEnd: 12.0)
            try expectEqual(range?.start, 10.5, "start")
            try expectEqual(range?.end, 12.0, "end")
        }),
        ("word audio matches single word", {
            let range = wordAudioRange(for: "the", in: wordAudioWords,
                                       segmentStart: 10.0, segmentEnd: 12.0)
            try expectEqual(range?.start, 10.2, "start")
            try expectEqual(range?.end, 11.0, "end")
        }),
        ("word audio match is case-insensitive", {
            let range = wordAudioRange(for: "ship", in: wordAudioWords,
                                       segmentStart: 10.0, segmentEnd: 12.0)
            try expectEqual(range?.start, 10.0, "start")
            try expectEqual(range?.end, 10.7, "end")
        }),
        ("word audio no-match returns nil", {
            let range = wordAudioRange(for: "missing", in: wordAudioWords,
                                       segmentStart: 10.0, segmentEnd: 12.0)
            try expectEqual(range == nil, true, "nil")
        }),
    ]

    // MARK: waveform playback

    private static let waveformPlaybackChecks: [(String, () throws -> Void)] = [
        ("waveform downsampling normalizes peak buckets", {
            let samples: [Float] = [0, 0.5, -1, 0.25, 0.75, -0.25]
            let buckets = waveformBuckets(samples: samples, bucketCount: 3)
            try expectEqual(buckets, [0.5, 1.0, 0.75], "buckets")
        }),
        ("waveform bucket starts honor source offset", {
            let starts = waveformBucketStartFrames(
                totalFrames: 100,
                sampleRate: 10,
                sourceOffset: 2,
                bucketCount: 4
            )
            try expectEqual(starts, [20, 40, 60, 80], "starts")
        }),
        ("active segment uses playback time not display time", {
            let segments = [
                TranscriptSegment(start: 100, end: 105, text: "retimed",
                                  speaker: "Them", words: nil, voice: nil,
                                  audioStart: 10, audioEnd: 15),
            ]
            try expectEqual(activeTranscriptSegment(at: 12, in: segments), 0, "active")
            try expectEqual(activeTranscriptSegment(at: 102, in: segments), nil,
                            "display time ignored")
        }),
        ("overlapping active segments prefer latest playback start", {
            let segments = [
                TranscriptSegment(start: 0, end: 5, text: "a", speaker: "Me",
                                  words: nil, voice: nil, audioStart: 0, audioEnd: 5),
                TranscriptSegment(start: 1, end: 4, text: "b", speaker: "Them",
                                  words: nil, voice: nil, audioStart: 2, audioEnd: 4),
            ]
            try expectEqual(activeTranscriptSegment(at: 2.5, in: segments), 1, "tie break")
        }),
        ("playback sources prefer denoised mic and keep system", {
            let root = try tempDir()
            let paths = RecordingPaths(root: root, id: RecordingID("waveform"))
            try paths.prepareDirectories()
            try Data("mic".utf8).write(to: paths.rawMicAudio)
            try Data("denoised".utf8).write(to: paths.workMicDenoisedAudio)
            try Data("system".utf8).write(to: paths.rawSystemAudio)
            let sources = meetingPlaybackSources(in: paths.directory)
            try expectEqual(sources?.mic, paths.workMicDenoisedAudio, "mic")
            try expectEqual(sources?.system, paths.rawSystemAudio, "system")
        }),
        ("playback sources fall back to compacted m4a tracks", {
            let root = try tempDir()
            let paths = RecordingPaths(root: root, id: RecordingID("compacted"))
            try paths.prepareDirectories()
            let micM4a = paths.workDirectory.appendingPathComponent("mic.denoised.m4a")
            let systemM4a = paths.rawDirectory.appendingPathComponent("system.m4a")
            try Data("mic".utf8).write(to: micM4a)
            try Data("system".utf8).write(to: systemM4a)
            let sources = meetingPlaybackSources(in: paths.directory)
            try expectEqual(sources?.mic, micM4a, "mic m4a")
            try expectEqual(sources?.system, systemM4a, "system m4a")
            try expectEqual(meetingAudioURL(speaker: "Them", in: paths.directory),
                            systemM4a, "slice system m4a")
            try expectEqual(meetingAudioURL(speaker: "Alice", in: paths.directory),
                            micM4a, "slice mic m4a")
        }),
        ("recording file format caps rate at 48 kHz and 16-bit", {
            let hires = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 96_000,
                                      channels: 2, interleaved: true)!
            let capped = recordingFileFormat(capturing: hires)
            try expectEqual(capped.sampleRate, 48_000, "capped rate")
            try expectEqual(capped.commonFormat, .pcmFormatInt16, "sample format")
            try expectEqual(capped.channelCount, 2, "channels kept")
            let low = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                    channels: 1, interleaved: false)!
            try expectEqual(recordingFileFormat(capturing: low).sampleRate, 44_100,
                            "lower rate kept")
        }),
        ("playback sources read system mic offset from echo report", {
            let root = try tempDir()
            let paths = RecordingPaths(root: root, id: RecordingID("waveform-offset"))
            try paths.prepareDirectories()
            try Data("system".utf8).write(to: paths.rawSystemAudio)
            try #"{"system_mic_offset_s":5.14,"system_mic_offset_source":"broad_envelope"}"#
                .write(to: paths.workEchoReportJSON, atomically: true, encoding: .utf8)
            let sources = meetingPlaybackSources(in: paths.directory)
            try expectEqual(sources?.systemOffset, 5.14, "offset")
        }),
        ("source time adds system offset but keeps mic time unchanged", {
            let sync = PlaybackSync(systemOffset: 5.14)
            try expectEqual(sync.sourceTime(for: .mic, displayTime: 12.0, duration: 30.0),
                            12.0, "mic source")
            try expectEqual(sync.sourceTime(for: .system, displayTime: 12.0, duration: 30.0),
                            17.14, "system source")
            try expectEqual(sync.sourceTime(for: .system, displayTime: 29.0, duration: 30.0),
                            30.0, "system clamped")
        }),
        ("playback mix uses one owned track at a time", {
            let sync = PlaybackSync(systemOffset: 5.14)
            let segments = [
                TranscriptSegment(start: 94.14, end: 95.14, text: "remote",
                                  speaker: "Them", words: nil, voice: nil,
                                  audioStart: nil, audioEnd: nil),
                TranscriptSegment(start: 20, end: 21, text: "local",
                                  speaker: "Alice", words: nil, voice: nil,
                                  audioStart: nil, audioEnd: nil),
            ]
            try expectEqual(playbackMix(at: 89.2, in: segments, sync: sync),
                            PlaybackMix(micVolume: 0, systemVolume: 1),
                            "remote mix")
            try expectEqual(playbackMix(at: 20.2, in: segments, sync: sync),
                            PlaybackMix(micVolume: 1, systemVolume: 0),
                            "local mix")
        }),
        ("mic channel opens a lead-in before the user's segment", {
            let sync = PlaybackSync(systemOffset: 0)
            let segments = [
                TranscriptSegment(start: 18, end: 20, text: "remote",
                                  speaker: "Them", words: nil, voice: nil,
                                  audioStart: nil, audioEnd: nil),
                TranscriptSegment(start: 20, end: 21, text: "local",
                                  speaker: "Alice", words: nil, voice: nil,
                                  audioStart: nil, audioEnd: nil),
            ]
            try expectEqual(playbackMix(at: 20 - playbackMicLeadIn - 0.1, in: segments, sync: sync),
                            PlaybackMix(micVolume: 0, systemVolume: 1),
                            "before the lead-in the remote still owns the mix")
            try expectEqual(playbackMix(at: 19.8, in: segments, sync: sync),
                            PlaybackMix(micVolume: 1, systemVolume: 0),
                            "upcoming user segment preempts the remote tail")
            try expectEqual(playbackMix(at: 21.2, in: segments, sync: sync),
                            PlaybackMix(micVolume: 0, systemVolume: 1),
                            "no lead-out after the segment")
        }),
        ("slice playback requests other playback to stop only when starting", {
            var stops = 0
            var state = AudioSlicePlaybackState(playingID: nil)
            let started = prepareAudioSliceToggle(
                state: &state,
                id: "slice-1",
                stopOtherPlayback: { stops += 1 }
            )
            try expectEqual(started, true, "first toggle starts")
            try expectEqual(stops, 1, "start stops other playback")
            try expectEqual(state.playingID, "slice-1", "playing id")

            let stopped = prepareAudioSliceToggle(
                state: &state,
                id: "slice-1",
                stopOtherPlayback: { stops += 1 }
            )
            try expectEqual(stopped, false, "second toggle stops")
            try expectEqual(stops, 1, "stop does not stop other playback again")
            try expectEqual(state.playingID, nil, "cleared id")
        }),
        ("active system segment subtracts offset from transcript time", {
            let sync = PlaybackSync(systemOffset: 5.14)
            let segments = [
                TranscriptSegment(start: 94.14, end: 95.14, text: "remote",
                                  speaker: "Them", words: nil, voice: nil,
                                  audioStart: nil, audioEnd: nil),
            ]
            try expectEqual(activeTranscriptSegment(at: 89.2, in: segments, sync: sync),
                            0, "corrected active")
            try expectEqual(activeTranscriptSegment(at: 94.2, in: segments, sync: sync),
                            nil, "raw time ignored")
        }),
        ("segment seek uses corrected system timeline", {
            let sync = PlaybackSync(systemOffset: 5.14)
            let remote = TranscriptSegment(start: 94.14, end: 95.14, text: "remote",
                                           speaker: "Them", words: nil, voice: nil,
                                           audioStart: nil, audioEnd: nil)
            let local = TranscriptSegment(start: 12, end: 13, text: "local",
                                          speaker: "Alice", words: nil, voice: nil,
                                          audioStart: nil, audioEnd: nil)
            try expectEqual(sync.displayStart(for: remote), 89.0, "remote display")
            try expectEqual(sync.displayStart(for: local), 12.0, "local display")
        }),
        ("transcript display order uses corrected timeline", {
            let sync = PlaybackSync(systemOffset: 5.14)
            let local = TranscriptSegment(start: 1308.84, end: 1309.68, text: "one sec",
                                          speaker: "Alice", words: nil, voice: nil,
                                          audioStart: nil, audioEnd: nil)
            let remote = TranscriptSegment(start: 1313.0, end: 1315.452, text: "כן.",
                                           speaker: "Them", words: nil, voice: nil,
                                           audioStart: nil, audioEnd: nil)
            try expectEqual(transcriptDisplayOrder(for: [local, remote], sync: sync),
                            [1, 0], "order")
            try expectEqual(transcriptTimestamp(for: remote, sync: sync), "21:47",
                            "remote timestamp")
        }),
    ]

    // MARK: speaker display names

    private static func displayName(
        _ speaker: String?, voice: String? = nil, names: [String: String] = [:],
        voiceCounts: [String: Int] = [:], roster: [String] = []
    ) -> String? {
        speakerDisplayName(speaker: speaker, voice: voice, names: names,
                           voiceCounts: voiceCounts, roster: roster,
                           meFullName: "Alice Smith")
    }

    private static let speakerNameChecks: [(String, () throws -> Void)] = [
        ("solo mic voice stays the local user", {
            try expectEqual(displayName("Alice", voice: "1",
                                        voiceCounts: ["Alice": 1, "Them": 3],
                                        roster: ["Roy"]),
                            "Alice", "mic track")
        }),
        ("shared-room mic voices show Speaker N", {
            try expectEqual(displayName("Alice", voice: "1",
                                        voiceCounts: ["Alice": 3]),
                            "Speaker 1", "mic multi-voice")
        }),
        ("assigned name wins for a mic voice too", {
            try expectEqual(displayName("Alice", voice: "2", names: ["2": "Danield"],
                                        voiceCounts: ["Alice": 3]),
                            "Danield", "named mic voice")
        }),
        ("roster shortcut never applies to mic voices", {
            try expectEqual(displayName("Alice", voice: "1",
                                        voiceCounts: ["Alice": 2],
                                        roster: ["Roy", "Alice Smith"]),
                            "Speaker 1", "mic ignores roster")
        }),
        ("assigned name wins for a diarized voice", {
            try expectEqual(displayName("Them", voice: "2", names: ["2": "Roy"],
                                        voiceCounts: ["Them": 3]),
                            "Roy", "named voice")
        }),
        ("unnamed voice among several shows Speaker N", {
            try expectEqual(displayName("Them", voice: "2", voiceCounts: ["Them": 3],
                                        roster: ["Roy", "Niv"]),
                            "Speaker 2", "multi-voice")
        }),
        ("fragmented voices fall back to sole roster attendee", {
            try expectEqual(displayName("Them", voice: "3", voiceCounts: ["Them": 6],
                                        roster: ["Roy", "Alice"]),
                            "Roy", "one other attendee")
        }),
        ("ambiguous roster stays Them", {
            try expectEqual(displayName("Them", roster: ["Roy", "Niv"]),
                            "Them", "ambiguous")
        }),
        ("nil speaker yields nil", {
            try expectEqual(displayName(nil, voice: "1", voiceCounts: ["Them": 2]),
                            nil, "no speaker")
        }),
        ("mic voice renamable only in a shared room", {
            try expectEqual(renamableVoice(speaker: "Alice", voice: "1",
                                           voiceCounts: ["Alice": 1]),
                            nil, "solo mic not renamable")
            try expectEqual(renamableVoice(speaker: "Alice", voice: "1",
                                           voiceCounts: ["Alice": 3]),
                            "1", "shared-room mic renamable")
            try expectEqual(renamableVoice(speaker: "Them", voice: "2",
                                           voiceCounts: ["Them": 1]),
                            "2", "system voice always renamable")
        }),
        ("copy markdown resolves speakers like the view, not raw Them", {
            let mic = TranscriptSegment(start: 1.0, end: 2.0, text: "hi",
                                        speaker: "Alice", words: nil, voice: nil,
                                        audioStart: nil, audioEnd: nil)
            let them = TranscriptSegment(start: 3.0, end: 4.0, text: "shalom",
                                         speaker: "Them", words: nil, voice: "2",
                                         audioStart: nil, audioEnd: nil)
            let md = transcriptMarkdown(segments: [them, mic], speakerNames: ["2": "Roy"],
                                        roster: ["Roy"], meFullName: "Alice Smith")
            try expectEqual(md,
                            "# Transcript\n\n**[0:01] Alice:** hi\n\n**[0:03] Roy:** shalom\n",
                            "resolved + start-ordered")
        }),
    ]

    // MARK: duration text

    private static let durationChecks: [(String, () throws -> Void)] = [
        ("duration text switches units at boundaries", {
            try expectEqual(durationText(seconds: 0), "0 s", "zero")
            try expectEqual(durationText(seconds: 45), "45 s", "sub-minute")
            try expectEqual(durationText(seconds: 59), "59 s", "just under a minute")
            try expectEqual(durationText(seconds: 60), "1 min", "one minute")
            try expectEqual(durationText(seconds: 90), "1 min", "rounds down to whole minutes")
            try expectEqual(durationText(seconds: 3599), "59 min", "just under an hour")
            try expectEqual(durationText(seconds: 3600), "1 h 0 min", "one hour")
            try expectEqual(durationText(seconds: 5400), "1 h 30 min", "ninety minutes")
        }),
    ]

    // MARK: clarification edits

    private static func resolvedCard(
        original: String = "EB two", context: String = "ctx",
        answer: String? = nil, edits: [[String]]? = nil
    ) -> Clarification {
        Clarification(original: original, guess: nil, context: context,
                      status: "resolved", severity: nil, answer: answer, edits: edits,
                      start: nil, end: nil, speaker: nil)
    }

    private static func expectEditList(
        _ got: [(String, String)], _ want: [(String, String)], _ label: String
    ) throws {
        try expectEqual(got.map { [$0.0, $0.1] }, want.map { [$0.0, $0.1] }, label)
    }

    private static let clarificationEditChecks: [(String, () throws -> Void)] = [
        ("resolved edits prefer the structured edits field", {
            let card = resolvedCard(answer: "ignored → stale",
                                    edits: [["EB two", "EB-2"], ["PERM", "perm"]])
            try expectEditList(card.resolvedEdits,
                               [("EB two", "EB-2"), ("PERM", "perm")], "edits used")
        }),
        ("resolved edits drop malformed pairs but keep valid ones", {
            let card = resolvedCard(edits: [["EB two", "EB-2"], ["lonely"]])
            try expectEditList(card.resolvedEdits, [("EB two", "EB-2")], "valid kept")
        }),
        ("resolved edits backfill from answer when edits yield nothing", {
            // A present-but-unusable edits array still falls back to the summary.
            let card = resolvedCard(answer: "EB two → EB-2", edits: [["lonely"]])
            try expectEditList(card.resolvedEdits, [("EB two", "EB-2")], "answer fallback")
        }),
        ("resolved edits parse a multi-edit answer summary", {
            let card = resolvedCard(answer: "EB two → EB-2, perm → PERM")
            try expectEditList(card.resolvedEdits,
                               [("EB two", "EB-2"), ("perm", "PERM")], "parsed pairs")
        }),
        ("resolved edits treat a bare answer as a fix for the original", {
            let card = resolvedCard(original: "EB two", answer: "EB-2")
            try expectEditList(card.resolvedEdits, [("EB two", "EB-2")], "bare answer")
        }),
        ("resolved edits empty without answer or edits", {
            try expectEditList(resolvedCard().resolvedEdits, [], "no sources")
        }),
        ("corrected sentence applies whole-token edits to the context", {
            let card = resolvedCard(context: "Discuss EB two PERM today",
                                    edits: [["EB two", "EB-2"]])
            try expectEqual(card.correctedSentence, "Discuss EB-2 PERM today", "rewritten")
        }),
        ("corrected sentence leaves the line intact when the term is absent", {
            let card = resolvedCard(context: "Discuss the roadmap",
                                    edits: [["EB two", "EB-2"]])
            try expectEqual(card.correctedSentence, "Discuss the roadmap", "unchanged")
        }),
    ]

    // MARK: transcription engine

    private static let engineChecks: [(String, () throws -> Void)] = [
        ("sqlite repository round-trips transcription engine", {
            let dir = try tempDir()
            let db = dir.appendingPathComponent("tamlil.sqlite")
            let root = dir.appendingPathComponent("recordings", isDirectory: true)
            let repo = try SQLiteRecordingRepository(databaseURL: db, recordingsRoot: root)
            let meeting = try repo.createRecording(app: "Zoom", bundleID: "us.zoom.xos",
                                                   startedAt: Date(timeIntervalSince1970: 1))
            try repo.updateRecording(meeting.id) { $0.transcriptionEngine = "soniox" }
            let loaded = try repo.loadRecordings()
            try expectEqual(loaded.first?.meta.transcriptionEngine, "soniox", "engine")
        }),
        ("engine annotation hidden for soniox and old recordings", {
            try expectEqual(engineAnnotation(nil), nil, "nil hidden")
            try expectEqual(engineAnnotation("soniox"), nil, "soniox hidden")
        }),
        ("engine annotation hidden for removed engines", {
            try expectEqual(engineAnnotation("local"), nil, "local")
            try expectEqual(engineAnnotation("mixed"), nil, "mixed")
        }),
        ("keychain check reports absent service as missing", {
            try expectEqual(SettingsView.keychainPresent(service: "tamlil-does-not-exist"),
                            false, "keychain check for absent service")
        }),
    ]

    // MARK: stale recording recovery

    private static let reconcileChecks: [(String, () throws -> Void)] = [
        ("fresh in-progress recording is left alone", {
            try expectEqual(
                staleRecordingResolution(phase: .recording, audioBytes: 5_000_000, audioAge: 5),
                .leaveAlone, "fresh recording")
        }),
        ("stale recording with audio is reprocessed", {
            try expectEqual(
                staleRecordingResolution(phase: .recording, audioBytes: 5_000_000, audioAge: 120),
                .process, "stale with audio")
        }),
        ("stale recording with negligible audio is marked interrupted", {
            try expectEqual(
                staleRecordingResolution(phase: .recording, audioBytes: 1_000, audioAge: 120),
                .markInterrupted, "stale without audio")
        }),
        ("interrupted pipeline run is flagged for retry", {
            try expectEqual(
                staleRecordingResolution(phase: .processing, audioBytes: 0, audioAge: 0),
                .markPipelineInterrupted, "processing")
        }),
        ("queued recording is reprocessed", {
            try expectEqual(
                staleRecordingResolution(phase: .queued, audioBytes: 0, audioAge: 0),
                .reprocess, "queued")
        }),
        ("finished meeting is never disturbed", {
            try expectEqual(
                staleRecordingResolution(phase: .ready, audioBytes: 0, audioAge: 9_999),
                .leaveAlone, "ready")
            try expectEqual(
                staleRecordingResolution(phase: .error("boom"), audioBytes: 9_000_000, audioAge: 9_999),
                .leaveAlone, "error")
        }),
    ]

    // MARK: empty system track

    private static func meetingDir(systemJSON: String?) throws -> URL {
        let root = try tempDir()
        let id = RecordingID("selfcheck-meeting-\(UUID().uuidString)")
        let paths = RecordingPaths(root: root, id: id)
        try paths.prepareDirectories()
        if let systemJSON {
            try systemJSON.write(to: paths.workSystemASRJSON,
                                 atomically: true, encoding: .utf8)
        }
        return paths.directory
    }

    private static let systemTrackChecks: [(String, () throws -> Void)] = [
        ("empty system track flagged on long meeting", {
            let dir = try meetingDir(systemJSON: #"{"segments": [], "text": ""}"#)
            try expectEqual(systemTrackCameUpEmpty(in: dir, duration: 1999), true, "flag")
        }),
        ("populated system track not flagged", {
            let dir = try meetingDir(
                systemJSON: #"{"segments": [{"start": 1.0, "end": 2.0, "text": "hi"}]}"#)
            try expectEqual(systemTrackCameUpEmpty(in: dir, duration: 1999), false, "flag")
        }),
        ("short meeting never flagged", {
            let dir = try meetingDir(systemJSON: #"{"segments": []}"#)
            try expectEqual(systemTrackCameUpEmpty(in: dir, duration: 60), false, "flag")
        }),
        ("missing system.asr.json stays quiet", {
            let dir = try meetingDir(systemJSON: nil)
            try expectEqual(systemTrackCameUpEmpty(in: dir, duration: 1999), false, "flag")
        }),
    ]

    // MARK: unanswered call (empty final transcript)

    private static func meetingDir(finalTranscriptJSON: String?) throws -> URL {
        let root = try tempDir()
        let id = RecordingID("selfcheck-meeting-\(UUID().uuidString)")
        let paths = RecordingPaths(root: root, id: id)
        try paths.prepareDirectories()
        if let finalTranscriptJSON {
            try finalTranscriptJSON.write(to: paths.finalTranscriptJSON,
                                          atomically: true, encoding: .utf8)
        }
        return paths.directory
    }

    private static func discardMeeting(state: String) -> Meeting {
        Meeting(id: RecordingID("s"), directory: URL(fileURLWithPath: "/tmp/s"),
                meta: MeetingMeta(app: "Slack", bundleID: "", startedAt: Date(),
                                  endedAt: nil, state: state))
    }

    private static let notAnsweredChecks: [(String, () throws -> Void)] = [
        ("empty final transcript reads as an unanswered call", {
            let dir = try meetingDir(finalTranscriptJSON: #"{"segments": []}"#)
            try expectEqual(finalTranscriptIsEmpty(in: dir), true, "empty")
        }),
        ("populated final transcript is not discarded", {
            let dir = try meetingDir(
                finalTranscriptJSON: #"{"segments": [{"start": 1.0, "end": 2.0, "text": "hi"}]}"#)
            try expectEqual(finalTranscriptIsEmpty(in: dir), false, "populated")
        }),
        ("missing final transcript never discards", {
            let dir = try meetingDir(finalTranscriptJSON: nil)
            try expectEqual(finalTranscriptIsEmpty(in: dir), false, "missing")
        }),
        ("discard reason surfaces in the state label", {
            try expectEqual(discardMeeting(state: "discarded (call not answered)").displayState,
                            "Discarded (call not answered)", "not answered label")
            try expectEqual(discardMeeting(state: "discarded (too short)").displayState,
                            "Discarded (too short)", "too short label")
            try expectEqual(discardMeeting(state: "discarded (call not answered)").phase,
                            .discarded(reason: "call not answered"), "phase reason")
        }),
    ]

    // MARK: settings credentials

    private static let credentialChecks: [(String, () throws -> Void)] = [
        ("google client config round-trips through its json", {
            let cfg = GoogleClientConfig(clientId: "12345.apps.googleusercontent.com",
                                         clientSecret: #"we\ird "secret""#)
            try expectEqual(GoogleClientConfig.parse(cfg.json()), cfg, "round trip")
        }),
        ("google client json is exactly the two keys python reads", {
            let cfg = GoogleClientConfig(clientId: "id", clientSecret: "secret")
            let parsed = try JSONSerialization.jsonObject(with: Data(cfg.json().utf8))
            guard let dict = parsed as? [String: Any] else {
                throw Failure(description: "json() did not produce an object")
            }
            try expectEqual(dict.count, 2, "key count")
            try expectEqual(dict["client_id"] as? String, "id", "client_id")
            try expectEqual(dict["client_secret"] as? String, "secret", "client_secret")
        }),
        ("google client parse rejects malformed or incomplete json", {
            try expectEqual(GoogleClientConfig.parse("{not json"), nil, "malformed")
            try expectEqual(GoogleClientConfig.parse(#"{"client_id": "x"}"#), nil,
                            "missing secret")
            try expectEqual(GoogleClientConfig.parse(#"["client_id"]"#), nil, "non-object")
        }),
        ("soniox keychain add is an upsert on the documented service and account", {
            let args = SonioxKeychain.addArgs(key: "the-key")
            try expectEqual(args.first, "add-generic-password", "subcommand")
            try expectEqual(args.contains("-U"), true, "upsert flag")
            guard let s = args.firstIndex(of: "-s"), let a = args.firstIndex(of: "-a") else {
                throw Failure(description: "missing -s or -a flag")
            }
            try expectEqual(args[s + 1], "tamlil-soniox", "service")
            try expectEqual(args[a + 1], "soniox", "account")
            try expectEqual(Array(args.suffix(2)), ["-w", "the-key"], "key trails -w")
        }),
    ]
}
