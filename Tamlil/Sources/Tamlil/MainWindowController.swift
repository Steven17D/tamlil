// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// The standalone "Tamlil" window — the surface macOS never hides.
///
/// The menu bar icon can be pushed behind the notch when the bar overflows, so
/// this window is the guaranteed way in: reachable from the Dock when that's
/// enabled, and for every user by reopening the app (Spotlight, Finder, or
/// Launchpad relaunch lands on the running instance, which shows it). A single
/// window is reused and re-centered each time it is brought back from closed.
@MainActor
final class MainWindowController {
    private let openSettings: () -> Void
    private var window: NSWindow?

    init(openSettings: @escaping () -> Void) {
        self.openSettings = openSettings
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentViewController: MenuView.hostingController(
                openSettings: openSettings, respondsToOpenRequests: true))
        window.title = "Tamlil"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(MenuView.panelSize)
        return window
    }
}
