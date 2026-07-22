// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// The Settings window, hosted in a plain NSWindow rather than the SwiftUI
/// `Settings` scene. Tamlil is a menu-bar (accessory) app with no app menu, so
/// the scene's `showSettingsWindow:` action has no responder to reach and
/// silently no-ops — clicking the gear did nothing. A window we own opens
/// deterministically. A single window is reused and re-centered when reopened.
///
/// While the window is open the app becomes `.regular` so it appears in the
/// Cmd-Tab switcher (and Dock); on close it reverts to the configured policy
/// (Dock-on stays regular, otherwise back to accessory).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        if !window.isVisible { window.center() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(
            rootView: SettingsView().environmentObject(AppState.shared))
        // Don't let the hosting controller resize the window to the (tall)
        // content — the window is fixed-width with a screen-capped height and the
        // form scrolls inside it.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Tamlil Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 800
        window.setContentSize(NSSize(width: 420, height: min(600, visibleHeight - 120)))
        window.contentMinSize = NSSize(width: 420, height: 320)
        window.contentMaxSize = NSSize(width: 420, height: visibleHeight)
        return window
    }

    func windowWillClose(_ notification: Notification) {
        DockPresence.apply(DockPresence.isEnabled)
    }
}
