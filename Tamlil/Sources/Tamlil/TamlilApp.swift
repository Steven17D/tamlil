// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

@main
struct TamlilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        SelfCheck.runIfRequested()               // exits if --self-check
        NotifyCLI.runIfRequested()               // exits if --notify "<message>"
        ScreenshotRenderer.renderIfRequested()   // blocks if --preview-windows
        Task { @MainActor in AppState.shared.start() }
    }

    // The menu bar surface is an AppKit `NSStatusItem` owned by the app
    // delegate, not a SwiftUI `MenuBarExtra`: a long-lived `MenuBarExtra` on an
    // LSUIElement app loses its status item after sleep/wake and display
    // reconfiguration, leaving the process running with no visible icon. Only
    // the `Settings` scene lives here; the status item holds the app alive.
    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(AppState.shared)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var mainWindow: MainWindowController?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        settingsWindow = SettingsWindowController()
        let openSettings: () -> Void = { [weak self] in self?.showSettings() }
        menuBar = MenuBarController(openSettings: openSettings)
        mainWindow = MainWindowController(openSettings: openSettings)
        AppState.shared.showMainWindow = { [weak self] in self?.mainWindow?.show() }
        DockPresence.apply(DockPresence.isEnabled)
        showWindowOnFirstLaunch()
    }

    /// First ever launch of a brand-new install: surface the window once so a
    /// new user sees Tamlil and learns it runs in the menu bar. A background
    /// agent whose icon may be hidden behind a crowded notch is otherwise
    /// invisible on day one.
    ///
    /// Gated on `hasLaunchedBefore` so upgrading an existing install never pops
    /// an unexpected, focus-stealing window — including at a login-item launch,
    /// since a fresh install's first launch is always user-initiated.
    private func showWindowOnFirstLaunch() {
        let key = "didShowFirstRunWindow"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        guard !LoginItem.hasLaunchedBefore else { return }
        showFirstRunPanel()
    }

    private var firstRunWindow: NSWindow?

    /// First-launch panel: the privacy summary plus one-tap permission priming.
    /// Replaces the bare window pop so a new user learns what leaves their machine
    /// and grants mic + notifications before the first recording.
    private func showFirstRunPanel() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to Tamlil"
        window.isReleasedWhenClosed = false
        window.center()
        let view = FirstRunView(openSettings: { [weak self] in self?.showSettings() }) { [weak self] in
            self?.firstRunWindow?.close()
            self?.firstRunWindow = nil
        }
        window.contentView = NSHostingView(rootView: view)
        firstRunWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Reopening the app — clicking the Dock icon, or relaunching from Spotlight
    /// or Finder while it's already running — brings the window up. This is the
    /// universal recovery when the menu bar icon is hidden by an overflowing bar.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        mainWindow?.show()
        return true
    }

    /// Closing the window must not quit the background recorder.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Open the Settings window. Hosted in our own NSWindow
    /// (SettingsWindowController) rather than the SwiftUI `Settings` scene: this
    /// is a menu-bar app with no app menu, so the scene's `showSettingsWindow:`
    /// action has no responder to reach and silently no-ops.
    func showSettings() {
        settingsWindow?.show()
    }

    /// Quitting mid-call must finalize the wav headers, write meta, and hand
    /// the recording to the pipeline (which outlives this process) — otherwise
    /// the meeting is stuck at "recording" forever.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if case .recording = AppState.shared.status {
            AppState.shared.endRecording()
        }
        return .terminateNow
    }
}
