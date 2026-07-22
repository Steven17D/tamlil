// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import CoreAudio
import Foundation
import ObjCSupport

/// What a capture watchdog should do given how long the tap has been silent.
enum CaptureStallAction: Equatable {
    case none              // audio still flowing
    case recover           // silent long enough to re-establish the tap
    case reportAndRecover  // silent so long the user should be told (once)
}

/// Decide the watchdog's action from the gap since the last capture buffer.
/// An input tap fires continuously even through silence, so a gap past
/// `stallThreshold` means the tap died (typically a device change that stopped
/// delivery). Past `failureThreshold` recovery has been failing long enough
/// that the user deserves an alert. Kept pure so the policy is unit-testable
/// without an audio device (see SelfCheck).
func captureStallAction(secondsSinceLastBuffer: TimeInterval,
                        stallThreshold: TimeInterval,
                        failureThreshold: TimeInterval) -> CaptureStallAction {
    if secondsSinceLastBuffer >= failureThreshold { return .reportAndRecover }
    if secondsSinceLastBuffer >= stallThreshold { return .recover }
    return .none
}

/// Whether a just-restarted engine is still within its warm-up grace and must
/// not be torn down again yet. A slow input (Bluetooth HFP renegotiation) can
/// take over a second to deliver its first buffer after `engine.start()`;
/// retrying faster than that repeatedly kills the device before it warms up and
/// starves the very recovery the watchdog exists to perform. This backoff is
/// deliberately separate from the stall clock, which keeps climbing during the
/// outage so the failure alert still escalates. `nil` means nothing has been
/// restarted yet, so there is nothing to protect. Once the device has delivered
/// a buffer the warm-up is over and a fresh stall recovers immediately rather
/// than waiting out the grace. Pure for unit testing.
func recoveryWithinGrace(secondsSinceLastRestart: TimeInterval?,
                         hasDeliveredSinceRestart: Bool,
                         grace: TimeInterval) -> Bool {
    guard let elapsed = secondsSinceLastRestart, !hasDeliveredSinceRestart else { return false }
    return elapsed < grace
}

enum MicRecoveryAction: Equatable {
    case skip
    case waitForWarmup
    case waitForValidDevice
    case rebuildEngine
}

func micRecoveryAction(stopped: Bool,
                       hasFileFormat: Bool,
                       hardwareSampleRate: Double,
                       hardwareChannels: AVAudioChannelCount,
                       secondsSinceLastRestart: TimeInterval?,
                       hasDeliveredSinceRestart: Bool,
                       grace: TimeInterval) -> MicRecoveryAction {
    guard !stopped, hasFileFormat else { return .skip }
    guard !recoveryWithinGrace(secondsSinceLastRestart: secondsSinceLastRestart,
                               hasDeliveredSinceRestart: hasDeliveredSinceRestart,
                               grace: grace) else { return .waitForWarmup }
    guard hardwareSampleRate > 0, hardwareChannels > 0 else { return .waitForValidDevice }
    return .rebuildEngine
}

/// Records the local user's microphone to a wav file (the "Me" track).
/// Triggers the standard microphone permission prompt on first use.
final class MicRecorder {
    private var engine = AVAudioEngine()
    private var fileFormat: AVAudioFormat?
    private var configChangeObserver: NSObjectProtocol?
    private var watchdog: DispatchSourceTimer?
    private var recoveryPending = false
    private var lastRestartAt: TimeInterval?
    private var stopped = false
    // Start of the current run of failed recoveries (nil once capture is
    // re-established); drives the time-based give-up.
    private var firstFailureAt: TimeInterval?

    private let sink = AudioCaptureSink(logTag: "MicRecorder", noun: "mic")

    // A device switch (e.g. AirPods connecting) makes AVAudioEngine stop itself
    // and reject a tap re-installed too soon ("config change pending"), a
    // failure it does not surface as an error. So re-tapping is coalesced
    // behind a settle delay and, because the first attempt can still land mid
    // switch, retried by a watchdog until buffers flow again.
    static let settleDelay = 0.3
    static let watchdogInterval = 1.0
    static let stallThreshold = 2.0
    // A re-tapped device gets this long to deliver its first buffer before the
    // watchdog may tear it down again — longer than a Bluetooth HFP warm-up,
    // and longer than stallThreshold so a successful restart isn't re-torn.
    static let recoverGrace = 4.0
    static let failureThreshold = 20.0
    // While the new input device is still settling after a switch, re-poll this
    // fast (rather than waiting a full ~1 s watchdog tick) so capture resumes the
    // instant the device is ready — the dominant source of audio lost per switch.
    static let retryInterval = 0.2
    // Give up and release the input device only after this long of continuous
    // failure to re-establish capture — time-based, so the fast retry cadence
    // never abandons a device that is merely slow to settle. Never held captive.
    static let restartAbandonAfter = 15.0

    /// Invoked at most once per recording session, on the main queue, when
    /// capture stalls or writes fail mid-recording.
    var onFailure: ((String) -> Void)? {
        get { sink.onFailure }
        set { sink.onFailure = newValue }
    }

    /// Invoked once, on the main queue, when the recorder has permanently given
    /// up restarting and released the input device. The supervisor drops the
    /// mic track.
    var onTerminalFailure: ((String) -> Void)?

    static var permissionDenied: Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted: return true
        default: return false
        }
    }

    func start(outputURL: URL) throws {
        do {
            try begin(outputURL: outputURL)
        } catch {
            stop()
            throw error
        }
    }

    private func begin(outputURL: URL) throws {
        let format = engine.inputNode.outputFormat(forBus: 0)
        // installTap raises an uncatchable NSException on a dead format
        // (no input device, or capture denied).
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CoreAudioError.status(-1, "read microphone input format")
        }
        let recordFormat = recordingFileFormat(capturing: format)
        var settings = recordFormat.settings
        settings[AVFormatIDKey] = kAudioFormatLinearPCM   // wav container
        let audioFile = try AVAudioFile(forWriting: outputURL, settings: settings,
                                        commonFormat: recordFormat.commonFormat,
                                        interleaved: recordFormat.isInterleaved)
        sink.setFile(audioFile)
        fileFormat = audioFile.processingFormat
        try reinstallTap(on: engine, hardwareFormat: format)
        observeConfigurationChanges()
        startWatchdog()
        do {
            try engine.start()
            lastRestartAt = ProcessInfo.processInfo.systemUptime
            sink.markCaptureStarted()
        } catch {
            // A transient start failure (e.g. the input device momentarily busy,
            // another app grabbing it) must not lose the mic for the whole
            // meeting: keep the recorder and let the watchdog re-establish it.
            NSLog("MicRecorder: initial start failed (\(error)); recovering")
            sink.markCaptureStarted()
            scheduleFastRetry(reason: "initial start failed")
        }
        warnIfBluetoothInput()
    }

    /// Best-effort: a Bluetooth mic negotiates down to 16 kHz HFP, right at
    /// Soniox's floor. We follow the system default input regardless (warn
    /// only), but tell the user the built-in mic transcribes better.
    private func warnIfBluetoothInput() {
        guard let transport = try? defaultInputDeviceID()
                .readUInt32(kAudioDevicePropertyTransportType),
              let message = bluetoothMicWarning(transportType: transport) else { return }
        NSLog("MicRecorder: \(message)")
        Task { @MainActor in
            Notifier.notify(title: "Bluetooth microphone", body: message)
        }
    }

    func stop() {
        stopped = true
        watchdog?.cancel()
        watchdog = nil
        removeConfigurationObserver()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        sink.setFile(nil)
    }

    private func observeConfigurationChanges() {
        removeConfigurationObserver()
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.scheduleRecovery(reason: "engine configuration change")
        }
    }

    private func removeConfigurationObserver() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }

    private func installTap(on engine: AVAudioEngine,
                            format: AVAudioFormat,
                            converter: CaptureConverter?) throws {
        // installTap raises an *uncatchable* NSException when the input device is
        // mid-transition ("Failed to create tap due to format mismatch"). The
        // ExceptionCatcher shim turns that into a Swift error so recovery retries
        // within its budget instead of terminating the app.
        try ExceptionCatcher.catching {
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) {
                [weak self] buffer, _ in
                self?.sink.write(buffer, converter: converter)
            }
        }
    }

    /// (Re)build the converter for the current hardware format and install the
    /// tap. Throws if the recording file is gone, a converter can't be built, or
    /// `installTap` raises a format mismatch mid-transition. Recovery calls this
    /// on a fresh engine and treats a throw as a failed restart (retry, then
    /// release) rather than letting an uncatchable AVAudioEngine exception crash.
    private func reinstallTap(on engine: AVAudioEngine, hardwareFormat format: AVAudioFormat) throws {
        guard let fileFormat else {
            throw CoreAudioError.status(-1, "recording file gone")
        }
        engine.inputNode.removeTap(onBus: 0)
        var converter: CaptureConverter?
        if format != fileFormat {
            guard let resampler = CaptureConverter(from: format, to: fileFormat) else {
                throw CoreAudioError.status(-1, "convert microphone format \(format)")
            }
            converter = resampler
        }
        try installTap(on: engine, format: format, converter: converter)
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.watchdogInterval,
                       repeating: Self.watchdogInterval)
        timer.setEventHandler { [weak self] in self?.checkForStall() }
        watchdog = timer
        timer.resume()
    }

    private func checkForStall() {
        guard !stopped else { return }
        switch captureStallAction(
            secondsSinceLastBuffer: sink.secondsSinceLastBuffer(),
            stallThreshold: Self.stallThreshold,
            failureThreshold: Self.failureThreshold
        ) {
        case .none:
            return
        case .recover:
            scheduleRecovery(reason: "capture stalled")
        case .reportAndRecover:
            reportFailure("microphone stopped delivering audio; still retrying")
            scheduleRecovery(reason: "capture stalled")
        }
    }

    /// Coalesce the burst of triggers a device switch fires (config-change
    /// notification plus repeated watchdog ticks) into one settle-delayed
    /// attempt, matching ProcessTapRecorder's rebuild.
    private func scheduleRecovery(reason: String) {
        guard !stopped, !recoveryPending else { return }
        // Don't tear the engine down again while a just-restarted device is
        // still warming up — otherwise the ~1 Hz watchdog re-fires every tick
        // (the stall clock stays high until the first buffer) and starves a
        // slow input that needs longer than a tick to deliver, the exact
        // AirPods case this recorder is meant to survive. The stall clock keeps
        // climbing regardless, so the failure alert still escalates.
        let sinceRestart = lastRestartAt.map { ProcessInfo.processInfo.systemUptime - $0 }
        guard !recoveryWithinGrace(secondsSinceLastRestart: sinceRestart,
                                   hasDeliveredSinceRestart: sink.hasDeliveredSinceStart,
                                   grace: Self.recoverGrace) else { return }
        recoveryPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            self?.recover(reason: reason)
        }
    }

    /// Re-attempt recovery on a short cadence while the new input device is still
    /// settling. Unlike `scheduleRecovery` it skips the settle delay and the
    /// warm-up grace — there is no started device to disturb yet, so polling fast
    /// grabs the device the moment it is ready, cutting the audio gap per switch.
    private func scheduleFastRetry(reason: String) {
        guard !stopped, !recoveryPending else { return }
        recoveryPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryInterval) { [weak self] in
            self?.recover(reason: reason)
        }
    }

    /// A recovery attempt that didn't establish capture — the input device is
    /// still settling, or the tap/start threw mid-switch. Poll again fast so
    /// capture resumes the moment the device is ready; give up and release the
    /// device only after a sustained outage, never holding it captive.
    private func failedAttempt(reason: String, note: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if firstFailureAt == nil {
            firstFailureAt = now
            NSLog("MicRecorder: recovery after \(reason) in progress: \(note)")
        }
        if micRestartExhausted(secondsSinceFirstFailure: now - (firstFailureAt ?? now),
                               abandonAfter: Self.restartAbandonAfter) {
            abandon("microphone could not be re-established for "
                    + "\(Int(Self.restartAbandonAfter))s")
        } else {
            scheduleFastRetry(reason: reason)
        }
    }

    /// Re-tap the (possibly new) input device and restart the engine. If the
    /// device isn't ready yet, or the tap silently failed because the switch is
    /// still in flight, no buffers arrive and the watchdog fires this again.
    private func recover(reason: String) {
        recoveryPending = false
        let freshEngine = AVAudioEngine()
        let format = freshEngine.inputNode.outputFormat(forBus: 0)
        let sinceRestart = lastRestartAt.map { ProcessInfo.processInfo.systemUptime - $0 }
        let action = micRecoveryAction(stopped: stopped, hasFileFormat: fileFormat != nil,
                                       hardwareSampleRate: format.sampleRate,
                                       hardwareChannels: format.channelCount,
                                       secondsSinceLastRestart: sinceRestart,
                                       hasDeliveredSinceRestart: sink.hasDeliveredSinceStart,
                                       grace: Self.recoverGrace)
        switch action {
        case .skip, .waitForWarmup:
            return
        case .waitForValidDevice:
            // Device still settling; poll fast, don't wait a full watchdog tick.
            failedAttempt(reason: reason, note: "input device not ready")
            return
        case .rebuildEngine:
            break
        }

        removeConfigurationObserver()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()

        do {
            try reinstallTap(on: freshEngine, hardwareFormat: format)
            try freshEngine.start()
            engine = freshEngine
            observeConfigurationChanges()
            lastRestartAt = ProcessInfo.processInfo.systemUptime
            sink.resetErrorCount()
            // Reset the liveness clock and the delivered flag so the warm-up
            // grace protects this fresh engine until it delivers its first
            // buffer — without this a slow input (Bluetooth HFP) is re-torn
            // before it can warm up. Mirrors the tap's buildCapturePath.
            sink.markCaptureStarted()
            firstFailureAt = nil
        } catch {
            freshEngine.inputNode.removeTap(onBus: 0)
            freshEngine.stop()
            failedAttempt(reason: reason, note: "\(error)")
        }
    }

    /// Stop for good and release the input device. Unlike `stop()` (a clean
    /// user/end-of-meeting stop) this fires `onTerminalFailure` so the
    /// supervisor drops the mic track. Idempotent via `stopped`.
    private func abandon(_ message: String) {
        guard !stopped else { return }
        stop()
        NSLog("MicRecorder: \(message)")
        DispatchQueue.main.async { [weak self] in self?.onTerminalFailure?(message) }
    }

    private func reportFailure(_ message: String) {
        sink.reportFailure(message)
    }
}
