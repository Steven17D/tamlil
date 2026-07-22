// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation

/// The largest absolute sample in a capture buffer, normalized to [0, 1] where
/// 1.0 is digital full scale. A single linear scan — cheap enough for the
/// realtime callback. Returns 0 for an empty or unrecognized buffer so the
/// silence check treats "no data" as quiet rather than crashing.
func bufferPeak(_ buffer: AVAudioPCMBuffer) -> Float {
    let frames = Int(buffer.frameLength)
    guard frames > 0 else { return 0 }
    let channels = Int(buffer.format.channelCount)
    // Interleaved buffers pack all channels into one allocation with the
    // channel pointers spaced by `stride`; deinterleaved buffers use stride 1.
    let stride = buffer.format.isInterleaved ? channels : 1
    var peak: Float = 0
    if let data = buffer.floatChannelData {
        for ch in 0..<channels {
            let samples = data[ch]
            for i in 0..<frames { peak = max(peak, abs(samples[i * stride])) }
        }
    } else if let data = buffer.int16ChannelData {
        for ch in 0..<channels {
            let samples = data[ch]
            for i in 0..<frames { peak = max(peak, abs(Float(samples[i * stride]))) }
        }
        peak /= 32_768
    } else if let data = buffer.int32ChannelData {
        for ch in 0..<channels {
            let samples = data[ch]
            for i in 0..<frames { peak = max(peak, abs(Float(samples[i * stride]))) }
        }
        peak /= 2_147_483_648
    }
    return peak
}

/// What a silent/overdriven input warrants. The stall watchdog only sees
/// silence as *missing* buffers; a muted mic or a wrong input device still
/// delivers buffers, just empty ones, and a pinned input delivers full-scale
/// ones — neither of which the stall clock notices.
enum AudioSignalAlert: Equatable {
    case none
    case silent    // no sample above the silence floor for a sustained span
    case clipping  // pinned at full scale for a sustained span
}

/// Decide whether sustained silence or clipping deserves the one-shot alert.
/// `secondsSinceSignal` is time since the last buffer whose peak rose above the
/// silence floor; `secondsClipping` is how long the input has sat pinned at full
/// scale (0 when the latest buffer isn't clipping). Pure for unit testing.
func audioSignalAlert(secondsSinceSignal: TimeInterval,
                      secondsClipping: TimeInterval,
                      silenceThreshold: TimeInterval,
                      clippingThreshold: TimeInterval) -> AudioSignalAlert {
    if secondsSinceSignal >= silenceThreshold { return .silent }
    if secondsClipping >= clippingThreshold { return .clipping }
    return .none
}

/// Thread-safe wav sink shared by the mic and system-audio recorders. Owns the
/// output file, optionally resamples capture buffers into the file's format,
/// caps runaway write failures, and reports the first failure exactly once on
/// the main queue. Both recorders run their realtime callbacks through `write`,
/// so the locking and one-shot failure logic live in one place.
final class AudioCaptureSink {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var consecutiveWriteErrors = 0
    private var failureReported = false
    private var lastBufferUptime = ProcessInfo.processInfo.systemUptime
    // False from markCaptureStarted until the first real buffer arrives — lets
    // recovery tell "still warming up" from "was delivering, now stalled".
    private var deliveredSinceStart = false
    // Silence/clipping tracking. `lastSignalUptime` is the last time a buffer
    // rose above the silence floor; `clippingStartUptime` is when the current
    // run of full-scale buffers began (nil when the last buffer wasn't pinned).
    private var lastSignalUptime = ProcessInfo.processInfo.systemUptime
    private var clippingStartUptime: TimeInterval?
    private static let maxConsecutiveWriteErrors = 10

    /// Peak below this (normalized) counts as a silent buffer — well under room
    /// tone, so only a muted mic or a dead/wrong input device stays under it.
    static let silenceFloor: Float = 0.0008
    /// Peak at or above this counts as clipping (pinned at digital full scale).
    static let clippingFloor: Float = 0.999
    /// A meeting recorder tolerates long quiet stretches (you listen more than
    /// you talk), so only flag after a genuinely sustained silence. One-shot per
    /// session via `reportFailure`, so this can afford to be generous.
    static let silenceThreshold: TimeInterval = 90
    /// Continuous full-scale for this long means the input is overdriven.
    static let clippingThreshold: TimeInterval = 5

    /// NSLog tag, e.g. "MicRecorder", and the noun in write-failure messages,
    /// e.g. "mic" -> "mic write failed: ...".
    private let logTag: String
    private let noun: String
    /// Whether to raise the silence/clipping alert. Only meaningful for a live
    /// microphone, whose noise floor stays above `silenceFloor` whenever it
    /// works. The system-audio tap is a digital output mix that legitimately
    /// renders exact-zero samples during remote quiet (waiting room, everyone
    /// muted), so running the check there would fire a false "silent" alert and
    /// burn the one-shot failure slot.
    private let detectLevels: Bool

    /// Invoked at most once per recording session, on the main queue, when
    /// capture stalls or writes fail mid-recording.
    var onFailure: ((String) -> Void)?

    init(logTag: String, noun: String, detectLevels: Bool = true) {
        self.logTag = logTag
        self.noun = noun
        self.detectLevels = detectLevels
    }

    /// The format buffers must be converted to before writing, or nil if no
    /// file is set.
    var fileFormat: AVAudioFormat? {
        lock.lock()
        defer { lock.unlock() }
        return file?.processingFormat
    }

    func setFile(_ newFile: AVAudioFile?) {
        lock.lock()
        file = newFile
        consecutiveWriteErrors = 0
        lock.unlock()
    }

    func resetErrorCount(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        consecutiveWriteErrors = 0
        // A recovered device restarts the silence clock: the gap while it was
        // dead was already handled by the stall watchdog, so don't double-count
        // it here as sustained silence.
        lastSignalUptime = now
        clippingStartUptime = nil
        lock.unlock()
    }

    /// Seconds since the last capture buffer arrived. An input tap fires
    /// continuously even through silence, so a large gap here means the tap has
    /// gone dead (a device change that stopped delivery), not a quiet room.
    /// A watchdog polls this to detect and recover from a stalled tap.
    func secondsSinceLastBuffer(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return now - lastBufferUptime
    }

    /// Reset the liveness clock without a real buffer — used when (re)starting
    /// capture so the watchdog gives the fresh tap time to deliver.
    func markCaptureStarted(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        lastBufferUptime = now
        lastSignalUptime = now
        clippingStartUptime = nil
        deliveredSinceStart = false
        lock.unlock()
    }

    /// True once a real buffer has arrived since the last `markCaptureStarted`
    /// (the (re)started device has finished warming up). Recovery uses this so
    /// the warm-up grace protects only a not-yet-delivering device, not one that
    /// was delivering and then stalled on a fresh switch.
    var hasDeliveredSinceStart: Bool {
        lock.lock()
        defer { lock.unlock() }
        return deliveredSinceStart
    }

    func write(_ buffer: AVAudioPCMBuffer, converter: CaptureConverter?) {
        var failureMessage: String?
        var levelMessage: String?
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        lastBufferUptime = now
        deliveredSinceStart = true
        // Track signal level so a muted mic or an overdriven input is caught
        // even while buffers keep flowing (the stall watchdog only sees a dead
        // tap as missing buffers, never as empty or clipped ones). Mic only:
        // the system-audio tap goes legitimately silent during remote quiet.
        if detectLevels {
            let peak = bufferPeak(buffer)
            if peak >= Self.silenceFloor { lastSignalUptime = now }
            if peak >= Self.clippingFloor {
                if clippingStartUptime == nil { clippingStartUptime = now }
            } else {
                clippingStartUptime = nil
            }
            switch audioSignalAlert(
                secondsSinceSignal: now - lastSignalUptime,
                secondsClipping: clippingStartUptime.map { now - $0 } ?? 0,
                silenceThreshold: Self.silenceThreshold,
                clippingThreshold: Self.clippingThreshold
            ) {
            case .none: break
            case .silent:
                levelMessage = "\(noun) is silent — check that it isn't muted and the right input device is selected"
            case .clipping:
                levelMessage = "\(noun) is clipping — the input level is too high; lower the input gain"
            }
        }
        if let file, consecutiveWriteErrors < Self.maxConsecutiveWriteErrors {
            do {
                if let converter {
                    let converted = try converter.convert(buffer)
                    if converted.frameLength > 0 { try file.write(from: converted) }
                } else {
                    try file.write(from: buffer)
                }
                consecutiveWriteErrors = 0
            } catch {
                consecutiveWriteErrors += 1
                if consecutiveWriteErrors == 1 { failureMessage = "\(noun) write failed: \(error)" }
            }
        }
        lock.unlock()
        // A write failure is the more urgent signal, and reportFailure is
        // one-shot, so prefer it when both surface on the same buffer.
        if let message = failureMessage ?? levelMessage { reportFailure(message) }
    }

    func reportFailure(_ message: String) {
        lock.lock()
        let first = !failureReported
        failureReported = true
        lock.unlock()
        guard first else { return }
        NSLog("\(logTag): \(message)")
        DispatchQueue.main.async { [weak self] in self?.onFailure?(message) }
    }
}
