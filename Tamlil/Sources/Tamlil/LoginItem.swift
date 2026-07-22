// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import Foundation
import ServiceManagement

/// Auto-enables "start at login" the first time Tamlil runs, so a freshly
/// installed copy comes back after a reboot without the user opening Settings.
/// Acts only once: if the user later turns the toggle off in Settings, the
/// launch agent plist is absent, so we leave it alone.
enum LoginItem {
    static let launchAgentLabel = "dev.dashevsky.tamlil"
    private static let didAutoEnableKey = "didAutoEnableLoginItem"
    private static let appExecutable = URL(
        fileURLWithPath: "/Applications/Tamlil.app/Contents/MacOS/Tamlil"
    )

    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist")
    }

    private static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Tamlil", isDirectory: true)
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    /// True once Tamlil has completed a launch on any prior build (the
    /// auto-enable has run). Used as a "this isn't a brand-new install" signal,
    /// so an upgrade doesn't surprise existing users with first-run UI.
    static var hasLaunchedBefore: Bool {
        UserDefaults.standard.bool(forKey: didAutoEnableKey)
    }

    static func launchAgentPlist(appExecutable: URL,
                                 logDirectory: URL) -> [String: Any] {
        [
            "Label": launchAgentLabel,
            "ProgramArguments": [appExecutable.path],
            "RunAtLoad": true,
            "KeepAlive": ["Crashed": true],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "StandardOutPath": logDirectory.appendingPathComponent("launchd.out.log").path,
            "StandardErrorPath": logDirectory.appendingPathComponent("launchd.err.log").path,
        ]
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try install()
        } else {
            try uninstall()
        }
    }

    /// Keep this deferred (it's called from `AppState.start()`, i.e. a Task): it
    /// flips `didAutoEnableKey`, which `hasLaunchedBefore` reads to tell a fresh
    /// install from an upgrade. The main actor runs that Task only after
    /// `applicationDidFinishLaunching` — where the first-run window checks the
    /// flag — so the read precedes this write. Moving this to run synchronously
    /// at launch would flip the flag first and suppress the first-run window.
    static func enableOnFirstLaunch() {
        try? SMAppService.mainApp.unregister()
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didAutoEnableKey) else { return }
        defaults.set(true, forKey: didAutoEnableKey)
        try? install()
    }

    private static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: launchAgentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: launchAgentPlist(appExecutable: appExecutable,
                                               logDirectory: logDirectory),
            format: .xml,
            options: 0
        )
        try data.write(to: launchAgentURL, options: .atomic)
    }

    private static func uninstall() throws {
        try? SMAppService.mainApp.unregister()
        let fm = FileManager.default
        if fm.fileExists(atPath: launchAgentURL.path) {
            try fm.removeItem(at: launchAgentURL)
        }
    }
}
