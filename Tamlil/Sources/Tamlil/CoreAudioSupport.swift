// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Thin typed wrappers over the Core Audio property API (macOS 14.4+ process
/// objects / taps). Errors carry the OSStatus for debugging.
enum CoreAudioError: Error, CustomStringConvertible {
    case status(OSStatus, String)
    var description: String {
        if case let .status(code, what) = self { return "\(what) failed (OSStatus \(code))" }
        return "unknown"
    }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    func read<T>(_ selector: AudioObjectPropertySelector, into value: inout T) throws {
        var address = Self.address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let err = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0)
        }
        guard err == noErr else { throw CoreAudioError.status(err, "read \(selector)") }
    }

    func readUInt32(_ selector: AudioObjectPropertySelector) throws -> UInt32 {
        var v: UInt32 = 0
        try read(selector, into: &v)
        return v
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var cf: CFString = "" as CFString
        try read(selector, into: &cf)
        return cf as String
    }

    func readObjectList(_ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var address = Self.address(selector)
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard err == noErr else { throw CoreAudioError.status(err, "size \(selector)") }
        var list = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &list)
        guard err == noErr else { throw CoreAudioError.status(err, "read \(selector)") }
        return list
    }
}

/// A process currently known to Core Audio (i.e. doing, or set up for, audio I/O).
struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isRunningInput: Bool   // capturing the microphone right now

    static func list() -> [AudioProcess] {
        guard let objects = try? AudioObjectID.system.readObjectList(kAudioHardwarePropertyProcessObjectList)
        else { return [] }
        return objects.compactMap { obj in
            var pid: pid_t = -1
            try? obj.read(kAudioProcessPropertyPID, into: &pid)
            guard pid > 0 else { return nil }
            let bundleID = (try? obj.readString(kAudioProcessPropertyBundleID)) ?? ""
            let input = ((try? obj.readUInt32(kAudioProcessPropertyIsRunningInput)) ?? 0) != 0
            return AudioProcess(
                objectID: obj, pid: pid, bundleID: bundleID, isRunningInput: input
            )
        }
    }
}

/// The default output device — where meeting apps render, as opposed to the
/// system (alerts) output device. Anchors the aggregate device.
func defaultOutputDeviceID() throws -> AudioObjectID {
    var deviceID = kAudioObjectUnknown
    try AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, into: &deviceID)
    return deviceID
}

/// The default input device — the microphone capture follows.
func defaultInputDeviceID() throws -> AudioObjectID {
    var deviceID = kAudioObjectUnknown
    try AudioObjectID.system.read(kAudioHardwarePropertyDefaultInputDevice, into: &deviceID)
    return deviceID
}

/// Warn (returning a user-facing message) when the input device's Core Audio
/// transport type is Bluetooth. A BT headset that also carries the mic drops to
/// the HFP profile — 16 kHz mono, right at Soniox's usable floor — so the built
/// in mic gives markedly better transcription. Warn only; the capture path is
/// left following the system default. Pure for unit testing (see SelfCheck).
func bluetoothMicWarning(transportType: UInt32) -> String? {
    guard transportType == kAudioDeviceTransportTypeBluetooth else { return nil }
    return "Recording from a Bluetooth mic gives phone-quality (16 kHz) audio "
        + "and weaker transcription — prefer the built-in microphone."
}

/// Trailing-edge debounce for a default-output-device change, driven by polling
/// instead of a CoreAudio listener — the listener burst is the storm surface
/// that wedged coreaudiod. Each poll compares the current default output UID to
/// the anchored one and to the previous poll's observation: a device still in
/// flight (differs from the last poll) restarts the debounce, and only a device
/// that has read the same non-anchor UID for `requiredStablePolls` consecutive
/// polls asks for a rebuild. The caller stores the returned `stablePolls` and
/// the current UID as the next `lastObservedUID`. Pure for unit testing.
func anchorChangeDebounce(
    currentDefaultUID: String,
    anchoredUID: String,
    lastObservedUID: String,
    stablePolls: Int,
    requiredStablePolls: Int
) -> (stablePolls: Int, shouldRebuild: Bool) {
    if currentDefaultUID == anchoredUID {
        return (0, false)                        // no pending change
    }
    if currentDefaultUID != lastObservedUID {
        return (1, false)                        // still moving; restart the debounce
    }
    let next = stablePolls + 1
    return (next, next >= requiredStablePolls)   // settled on a new device
}

/// The on-disk format for captured audio: the hardware rate capped at 48 kHz,
/// 16-bit integer samples, same channel count. Capture devices often run at
/// 96 kHz Float32 — 8x the data speech transcription or playback can use.
func recordingFileFormat(capturing input: AVAudioFormat) -> AVAudioFormat {
    let sampleRate = min(input.sampleRate, 48_000)
    return AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                         channels: input.channelCount, interleaved: true) ?? input
}

/// The on-disk format for the system-audio track: always the 48 kHz / 16-bit
/// ceiling, independent of the first output device's rate. The tap file is
/// created once and later-format audio is resampled into it, so pinning it to
/// the first device (e.g. AirPods at 24 kHz) would permanently cap the whole
/// recording — a later switch to a 48 kHz device would be needlessly
/// downsampled. Falls back to the capture format only if 48 kHz is unbuildable.
func systemAudioFileFormat(capturing input: AVAudioFormat) -> AVAudioFormat {
    AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                  channels: input.channelCount, interleaved: true)
        ?? recordingFileFormat(capturing: input)
}

/// Resamples live capture buffers back into a recording file's original format
/// after a device change altered the capture rate. The converter is stateful
/// (rate conversion carries filter history) and the output buffer is reused, so
/// the realtime callback allocates nothing once the converter is built — reuse
/// one instance per capture incarnation.
final class CaptureConverter {
    private let converter: AVAudioConverter
    private var output: AVAudioPCMBuffer?

    init?(from input: AVAudioFormat, to outputFormat: AVAudioFormat) {
        guard let c = AVAudioConverter(from: input, to: outputFormat) else { return nil }
        // Capture devices routinely run well above the file rate (96 kHz), so
        // this converter is almost always downsampling. Best quality is near
        // free at these rates and keeps the antialiasing clean for ASR.
        c.sampleRateConverterQuality = .max
        if outputFormat.sampleRate < input.sampleRate {
            c.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        }
        converter = c
    }

    /// The returned buffer is reused on the next call — the caller must consume
    /// it (write it out) before converting again, which the single-threaded
    /// audio callback does.
    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let needed = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        if output == nil || output!.frameCapacity < needed {
            output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: needed)
        }
        guard let converted = output else {
            throw CoreAudioError.status(-1, "allocate conversion buffer")
        }
        converted.frameLength = 0
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            throw conversionError ?? CoreAudioError.status(-1, "convert capture buffer")
        }
        return converted
    }
}

/// What the system-audio tap watchdog should do this tick. Kept pure so the
/// policy is unit-tested without an audio device.
enum TapWatchdogAction: Equatable {
    case none      // healthy, or nothing actionable this tick
    case rebuild   // re-anchor + rebuild the tap/aggregate against the current default
    case giveUp    // recovery has failed too many times: stop and release the device
}

/// Decide the tap watchdog's action. A rebuild is warranted when a default
/// output change has settled (`shouldRebuildForChange`, from
/// `anchorChangeDebounce`), when the anchor device died, or when the IOProc
/// stopped delivering buffers *while the anchor device is actively running IO*
/// (`anchorRunning`). The running gate matters: when nothing plays, macOS idles
/// the output device and the tap's clock stops, so a buffer stall is legitimate
/// silence, not a dead tap — rebuilding then just churns; the tap comes back when
/// audio (and the device) do. Once `consecutiveFailedRebuilds` reaches
/// `maxRebuilds`, give up rather than loop forever. Pure for unit testing.
func tapWatchdogAction(
    shouldRebuildForChange: Bool,
    anchorAlive: Bool,
    anchorRunning: Bool,
    secondsSinceLastBuffer: TimeInterval,
    stallThreshold: TimeInterval,
    consecutiveFailedRebuilds: Int,
    maxRebuilds: Int
) -> TapWatchdogAction {
    if consecutiveFailedRebuilds >= maxRebuilds { return .giveUp }
    let bufferStalled = secondsSinceLastBuffer >= stallThreshold && anchorRunning
    if shouldRebuildForChange || !anchorAlive || bufferStalled { return .rebuild }
    return .none
}

/// Whether the microphone engine has been failing to re-establish capture for
/// long enough that the recorder must stop and release the input device rather
/// than hold it captive. Time-based, not a count, so the fast retry cadence
/// while a device settles never trips it early. Pure for unit testing.
func micRestartExhausted(secondsSinceFirstFailure: TimeInterval, abandonAfter: TimeInterval) -> Bool {
    secondsSinceFirstFailure >= abandonAfter
}
