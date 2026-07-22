// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Records what the system plays during a call (= everyone else on it)
/// without touching the call itself: a global Core Audio tap (macOS 14.4+)
/// excluding our own process and known music apps, mixed down to stereo and
/// written to a wav file. Global rather than per-app (the Granola/Notion
/// route): fixed process-list taps miss helpers that spawn after creation
/// and record silence when the call migrates apps mid-meeting.
///
/// First use triggers the one-time "System Audio Recording" permission prompt.
final class ProcessTapRecorder {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "tamlil.tap")
    // Detached + concurrent: the CoreAudio teardown (AudioDeviceStop + destroys)
    // can block indefinitely when the anchor device vanished mid-switch, so it
    // runs here instead of on `queue` — a stuck teardown holds only its own pool
    // thread, never the tap queue, the watchdog, or a `stop()` waiting on it.
    private static let teardownQueue = DispatchQueue(label: "tamlil.tap.teardown",
                                                     attributes: .concurrent)

    // Watchdog + rebuild state (all touched only on `queue`, so the serial
    // queue is the single-flight guard — no rebuild can overlap another).
    private var watchdog: DispatchSourceTimer?
    private var anchorDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var anchorUID = ""
    private var lastObservedDefaultUID = ""
    private var changeStablePolls = 0
    private var consecutiveFailedRebuilds = 0
    private var lastRebuildAt: TimeInterval?
    private var stopped = false
    // Bumped on every teardown; a still-firing IOProc from a torn-down
    // incarnation checks it and no-ops instead of writing the current file.
    private var captureToken = 0

    // Poll faster than we declare a stall; require a settled device for a few
    // polls before re-anchoring (trailing-edge debounce); give a rebuilt tap a
    // warm-up grace before the watchdog may touch it again; cap consecutive
    // failed rebuilds so a wedged HAL can never spin forever.
    static let watchdogInterval = 1.0
    static let stallThreshold = 2.0
    static let requiredStablePolls = 3
    static let recoverGrace = 4.0
    static let maxRebuilds = 6

    private let sink = AudioCaptureSink(logTag: "ProcessTapRecorder", noun: "system audio",
                                        detectLevels: false)

    /// Invoked at most once per recording session, on the main queue, for a
    /// transient stall/write problem the recorder is still trying to recover.
    var onFailure: ((String) -> Void)? {
        get { sink.onFailure }
        set { sink.onFailure = newValue }
    }

    /// Invoked once, on the main queue, when the recorder has permanently given
    /// up and released its device. The supervisor drops this track.
    var onTerminalFailure: ((String) -> Void)?

    /// Bundle ids whose audio never belongs in a meeting transcript.
    private static let excludedBundleIDs: Set<String> = [
        "com.spotify.client",
        "com.apple.Music",
    ]

    func start(outputURL: URL) throws {
        try queue.sync {
            do {
                try buildCapturePath(outputURL: outputURL)
                startWatchdog()
            } catch {
                stopLocked()
                throw error
            }
        }
    }

    /// Built fresh on every capture (re)build: exclusions reference live
    /// process objects, so a music app relaunched since the last build is
    /// re-excluded instead of leaking back into the recording.
    private func makeTapDescription() -> CATapDescription {
        // Best-effort exclusions: our own playback plus music apps. A failed
        // PID translation skips that exclusion — it must never fail capture.
        var excluded = AudioProcess.list()
            .filter { Self.excludedBundleIDs.contains($0.bundleID) }
            .map(\.objectID)
        if let own = try? processObject(for: ProcessInfo.processInfo.processIdentifier) {
            excluded.append(own)
        }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        return description
    }

    func stop() {
        queue.sync { stopLocked() }
    }

    /// Full teardown, assumed to run ON `queue` (the serial single-flight guard).
    /// `stop()` wraps it in `queue.sync`; `giveUp()` and `start()`'s failure path
    /// are already on `queue`, so they call it directly — a reentrant `queue.sync`
    /// would deadlock.
    private func stopLocked() {
        stopped = true
        watchdog?.cancel()
        watchdog = nil
        teardownCapturePath()
        sink.setFile(nil)
    }

    /// Creates the tap, the aggregate anchored to the current default output
    /// device, and the IOProc. Pass an output URL on first build; on rebuild
    /// (nil) the existing file is kept and new-format audio is converted into
    /// its original format.
    private func buildCapturePath(outputURL: URL?) throws {
        let description = makeTapDescription()
        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &newTapID)
        guard err == noErr else { throw CoreAudioError.status(err, "create process tap") }
        tapID = newTapID

        var asbd = AudioStreamBasicDescription()
        try tapID.read(kAudioTapPropertyFormat, into: &asbd)

        let outputDevice = try defaultOutputDeviceID()
        let outputUID = try outputDevice.readString(kAudioDevicePropertyDeviceUID)
        let aggDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tamlil Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &newAggregateID)
        guard err == noErr else { throw CoreAudioError.status(err, "create aggregate device") }
        aggregateID = newAggregateID

        // The IOProc delivers frames at the aggregate device's actual rate,
        // which follows the physical output device (e.g. AirPods at 24 kHz) —
        // NOT necessarily the tap format's claimed rate. Stamping the file
        // with the wrong rate makes recordings play sped up / slowed down.
        var deviceRate: Float64 = 0
        try? aggregateID.read(kAudioDevicePropertyNominalSampleRate, into: &deviceRate)
        if deviceRate > 0, deviceRate != asbd.mSampleRate {
            NSLog("tap rate \(asbd.mSampleRate) != device rate \(deviceRate); using device rate")
            asbd.mSampleRate = deviceRate
        }
        guard let captureFormat = AVAudioFormat(streamDescription: &asbd) else {
            throw CoreAudioError.status(-1, "tap format")
        }

        if let outputURL {
            // Pin the file to the 48 kHz cap, not the first output device's
            // rate: the file outlives device switches (rebuilds resample into
            // it), so anchoring it to e.g. AirPods at 24 kHz would cap the whole
            // recording and downsample later 48 kHz audio.
            let recordFormat = systemAudioFileFormat(capturing: captureFormat)
            var settings = recordFormat.settings
            settings[AVFormatIDKey] = kAudioFormatLinearPCM   // wav container
            let audioFile = try AVAudioFile(forWriting: outputURL, settings: settings,
                                            commonFormat: recordFormat.commonFormat,
                                            interleaved: recordFormat.isInterleaved)
            sink.setFile(audioFile)
        }
        sink.resetErrorCount()
        guard let fileFormat = sink.fileFormat else {
            throw CoreAudioError.status(-1, "recording file gone")
        }
        var converter: CaptureConverter?
        if captureFormat != fileFormat {
            guard let resampler = CaptureConverter(from: captureFormat, to: fileFormat) else {
                throw CoreAudioError.status(-1, "convert tap format for recording")
            }
            converter = resampler
        }

        let token = captureToken
        err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) {
            [weak self] _, inInputData, _, _, _ in
            // Ignore callbacks from an incarnation we've already torn down — its
            // detached stop may still be in flight (or hung on a dead device).
            guard let self, self.captureToken == token,
                  let buffer = AVAudioPCMBuffer(
                      pcmFormat: captureFormat,
                      bufferListNoCopy: inInputData,
                      deallocator: nil
                  )
            else { return }
            self.sink.write(buffer, converter: converter)
        }
        guard err == noErr else { throw CoreAudioError.status(err, "create IO proc") }

        err = AudioDeviceStart(aggregateID, ioProcID)
        guard err == noErr else { throw CoreAudioError.status(err, "start aggregate device") }

        anchorDeviceID = outputDevice
        anchorUID = outputUID
        lastObservedDefaultUID = outputUID
        changeStablePolls = 0
        lastRebuildAt = ProcessInfo.processInfo.systemUptime
        sink.markCaptureStarted()
    }

    /// Release the current tap/aggregate. The IOProc-stop and destroys can block
    /// *indefinitely* inside CoreAudio when the anchor device vanished mid-switch
    /// (observed: `AudioDeviceStop` never returns), so they run detached on
    /// `teardownQueue` — a stuck teardown can never freeze the tap queue, the
    /// watchdog, or a `stop()` waiting on it. Bumping `captureToken` first makes
    /// the outgoing IOProc a no-op so it can't write the recording after we move
    /// on, even if its stop hangs. Leaks that one incarnation on a hang (reaped
    /// when the process exits); the alternative — blocking — froze everything.
    /// Must be called on `queue`.
    private func teardownCapturePath() {
        captureToken &+= 1
        let agg = aggregateID
        let proc = ioProcID
        let tap = tapID
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        ioProcID = nil
        tapID = AudioObjectID(kAudioObjectUnknown)
        guard agg != kAudioObjectUnknown || tap != kAudioObjectUnknown else { return }
        Self.teardownQueue.async {
            if agg != kAudioObjectUnknown, let proc {
                AudioDeviceStop(agg, proc)
                AudioDeviceDestroyIOProcID(agg, proc)
            }
            if agg != kAudioObjectUnknown {
                AudioHardwareDestroyAggregateDevice(agg)
            }
            if tap != kAudioObjectUnknown {
                AudioHardwareDestroyProcessTap(tap)
            }
        }
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.watchdogInterval,
                       repeating: Self.watchdogInterval)
        timer.setEventHandler { [weak self] in self?.checkTap() }
        watchdog = timer
        timer.resume()
    }

    /// Polled on `queue` every `watchdogInterval`. Re-anchors on a settled
    /// default-output change, a dead anchor, or a stalled IOProc — but a stall
    /// only counts as a dead tap while the anchor device is actively running IO.
    /// When nothing plays the output device idles and the tap's clock stops; that
    /// silence is legitimate and the tap resumes when audio returns, so we must
    /// not rebuild-storm through it.
    private func checkTap() {
        guard !stopped else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let sinceRebuild = lastRebuildAt.map { now - $0 }
        // Don't disturb a tap still warming up from the last (re)build.
        if recoveryWithinGrace(secondsSinceLastRestart: sinceRebuild,
                               hasDeliveredSinceRestart: sink.hasDeliveredSinceStart,
                               grace: Self.recoverGrace) { return }

        let currentUID = (try? defaultOutputDeviceID()
            .readString(kAudioDevicePropertyDeviceUID)) ?? anchorUID
        let alive = ((try? anchorDeviceID
            .readUInt32(kAudioDevicePropertyDeviceIsAlive)) ?? 1) != 0
        let running = ((try? anchorDeviceID
            .readUInt32(kAudioDevicePropertyDeviceIsRunningSomewhere)) ?? 1) != 0

        let debounce = anchorChangeDebounce(
            currentDefaultUID: currentUID, anchoredUID: anchorUID,
            lastObservedUID: lastObservedDefaultUID, stablePolls: changeStablePolls,
            requiredStablePolls: Self.requiredStablePolls)
        changeStablePolls = debounce.stablePolls
        lastObservedDefaultUID = currentUID

        let gap = sink.secondsSinceLastBuffer()
        switch tapWatchdogAction(
            shouldRebuildForChange: debounce.shouldRebuild, anchorAlive: alive,
            anchorRunning: running,
            secondsSinceLastBuffer: gap, stallThreshold: Self.stallThreshold,
            consecutiveFailedRebuilds: consecutiveFailedRebuilds,
            maxRebuilds: Self.maxRebuilds
        ) {
        case .none:
            return
        case .rebuild:
            let reason = debounce.shouldRebuild ? "default output changed"
                : (alive ? "capture stalled" : "anchor device died")
            rebuild(reason: reason)
        case .giveUp:
            giveUp()
        }
    }

    /// Re-anchor to the current default output and rebuild the tap+aggregate.
    /// `lastRebuildAt` is stamped up front so both success and a bad-object
    /// failure are spaced by the warm-up grace — a device still mid-transition
    /// simply fails, and the next tick retries once it has settled.
    private func rebuild(reason: String) {
        guard !stopped else { return }
        lastRebuildAt = ProcessInfo.processInfo.systemUptime
        NSLog("ProcessTapRecorder: rebuilding capture (\(reason))")
        teardownCapturePath()
        do {
            try buildCapturePath(outputURL: nil)
            consecutiveFailedRebuilds = 0
        } catch {
            teardownCapturePath()
            consecutiveFailedRebuilds += 1
            NSLog("ProcessTapRecorder: rebuild failed (\(error)); "
                  + "attempt \(consecutiveFailedRebuilds)/\(Self.maxRebuilds)")
        }
    }

    private func giveUp() {
        guard !stopped else { return }
        stopLocked()
        let message = "system audio capture could not recover after "
            + "\(Self.maxRebuilds) attempts"
        NSLog("ProcessTapRecorder: \(message)")
        DispatchQueue.main.async { [weak self] in self?.onTerminalFailure?(message) }
    }

    private func processObject(for pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectID.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafeMutablePointer(to: &qualifier) { qptr in
            AudioObjectGetPropertyData(
                .system, &address,
                UInt32(MemoryLayout<pid_t>.size), qptr,
                &size, &object
            )
        }
        guard err == noErr, object != kAudioObjectUnknown else {
            throw CoreAudioError.status(err, "translate pid \(pid) to process object")
        }
        return object
    }
}
