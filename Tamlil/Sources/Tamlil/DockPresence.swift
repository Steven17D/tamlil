// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// Whether Tamlil shows a Dock icon. Off by default — it's a menu-bar agent.
///
/// macOS hides a status item behind the notch when the menu bar overflows, and
/// no app can override that. Turning this on flips the activation policy to
/// `.regular`, giving users a Dock icon that is always visible and clickable
/// regardless of how crowded the menu bar is. The standalone window and the
/// "reopen the app to show it" recovery cover everyone who leaves it off.
enum DockPresence {
    static let key = "showInDock"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: key) }

    @MainActor
    static func apply(_ enabled: Bool) {
        NSApp.setActivationPolicy(enabled ? .regular : .accessory)
    }
}
