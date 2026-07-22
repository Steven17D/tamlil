// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A meeting app we know how to watch. `bundlePrefix` matches the main app and
/// its helper processes (Zoom captures audio from a helper with the same prefix).
struct WatchedApp: Identifiable, Hashable {
    let id: String          // bundle id prefix
    let name: String

    static let known: [WatchedApp] = [
        WatchedApp(id: "us.zoom", name: "Zoom"),
        WatchedApp(id: "com.tinyspeck.slackmacgap", name: "Slack"),
        WatchedApp(id: "com.microsoft.teams", name: "Teams"),
        WatchedApp(id: "com.google.Chrome", name: "Chrome (Meet)"),
    ]
}

struct DetectedCall: Equatable {
    let app: WatchedApp
}

/// Detects "user is in a call" the way Granola/Notion do: a watched app's
/// process is actively capturing the microphone (Core Audio process objects,
/// macOS 14.4+). Polls every 2s; ends a call only after a grace period so a
/// brief mic re-open (mute toggling, device switch) doesn't split the meeting.
@MainActor
final class CallMonitor {
    var onCallStarted: ((DetectedCall) -> Void)?
    var onCallEnded: (() -> Void)?

    private(set) var current: DetectedCall?
    private var timer: Timer?
    private var lastSeenActive: Date?
    private let endGrace: TimeInterval = 8

    var enabledBundlePrefixes: Set<String> = []

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let active = activeCall()
        if let active {
            lastSeenActive = Date()
            // A different app capturing means the old call already ended —
            // don't let the grace period keep recording its dead tap.
            if let cur = current, cur != active {
                current = nil
                onCallEnded?()
            }
            if current == nil {
                current = active
                onCallStarted?(active)
            }
        } else if current != nil {
            if let last = lastSeenActive, Date().timeIntervalSince(last) > endGrace {
                current = nil
                lastSeenActive = nil
                onCallEnded?()
            }
        }
    }

    private func activeCall() -> DetectedCall? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // Prefer the app already being recorded: another watched app briefly
        // opening the mic mustn't hijack an ongoing call.
        var first: DetectedCall?
        for proc in AudioProcess.list() where proc.isRunningInput && proc.pid != ownPID {
            for app in WatchedApp.known
            where enabledBundlePrefixes.contains(app.id) && proc.bundleID.hasPrefix(app.id) {
                if app == current?.app { return DetectedCall(app: app) }
                if first == nil { first = DetectedCall(app: app) }
            }
        }
        return first
    }
}
