// SPDX-FileCopyrightText: Copyright 2026 Steven Dashevsky
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Combine
import SwiftUI

/// Owns the menu bar status item and the popover that hosts `MenuView`.
///
/// Uses AppKit `NSStatusItem` rather than SwiftUI `MenuBarExtra`: a long-lived
/// `MenuBarExtra` drops its status item after sleep/wake and display changes,
/// leaving the process running with no icon. An app-owned status item holds its
/// slot for the life of the process, and `autosaveName` keeps its position
/// stable (so a menu bar manager remembers where it goes).
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var iconObserver: AnyCancellable?
    private var currentKind: MenuBarIconKind?

    init(openSettings: @escaping () -> Void) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "dev.dashevsky.tamlil.status"
        statusItem.button?.image = MenuBarIcon.image(for: .idle)
        statusItem.button?.toolTip = "Tamlil"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        popover.behavior = .transient
        popover.contentSize = MenuView.panelSize
        popover.contentViewController = MenuView.hostingController(openSettings: openSettings)

        // The icon tracks coarse UI state (status, anyProcessing — both
        // @Published). objectWillChange fires before the change lands, so read
        // the new value on the next runloop tick.
        iconObserver = AppState.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.refreshIcon() }
        }
    }

    private func refreshIcon() {
        let kind = MenuBarIconKind(status: AppState.shared.status,
                                   anyProcessing: AppState.shared.anyProcessing)
        guard kind != currentKind else { return }
        currentKind = kind
        statusItem.button?.image = MenuBarIcon.image(for: kind)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
