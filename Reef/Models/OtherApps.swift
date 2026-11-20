//
//  OtherApps.swift
//  Reef
//
//  Finds the windows of running apps that have no number in the current profile,
//  for the "other apps" switcher (⌥ + `).
//

import AppKit
import ApplicationServices


@MainActor
enum OtherApps {
    struct Result {
        /// Windows of unbound apps in every space, frontmost first.
        var windows: [Window]

        var isEmpty: Bool { windows.isEmpty }
    }

    /// UserDefaults key for turning the ⌥ + ` switcher on or off (default on).
    static let preferenceKey = "otherAppsSwitcherEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true
    }

    static func collect(excludingBundleIdentifiers bound: Set<String>) -> Result {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let stacking = stackingOrder()

        var windows: [Window] = []

        let candidates = NSWorkspace.shared.runningApplications.filter { running in
            running.activationPolicy == .regular
                && running.processIdentifier != ownPID
                && !running.isTerminated
                && !(running.bundleIdentifier.map(bound.contains) ?? false)
        }

        for running in candidates {
            let app = Application(running)
            // Keep one stuck app from stalling the switcher.
            if let element = app.element {
                AXUIElementSetMessagingTimeout(element, 0.3)
            }
            // Apps with no window anywhere (running in the background after their last
            // window closed) are left out, as in Mission Control.
            windows.append(contentsOf: app.getWindows().filter(isSwitchable))
        }

        // Frontmost first, like ⌘-Tab; windows not on screen (minimized, other desktops,
        // other full-screen apps) go after, grouped by app.
        windows.sort { a, b in
            let orderA = stacking[a.id] ?? Int.max
            let orderB = stacking[b.id] ?? Int.max
            if orderA != orderB { return orderA < orderB }
            return a.application.title.localizedCaseInsensitiveCompare(b.application.title) == .orderedAscending
        }

        return Result(windows: windows)
    }

    /// Real windows only: no palettes, tooltips or zero-sized helpers.
    private static func isSwitchable(_ window: Window) -> Bool {
        guard window.id != 0 else { return false }
        // Already filtered (titled, real-sized) by the window server lookup.
        if window.isOffscreen { return true }
        let subrole = window.element.value(kAXSubroleAttribute) as? String
        if let subrole, subrole != kAXStandardWindowSubrole, subrole != kAXDialogSubrole {
            return false
        }
        if let frame = window.element.frame, frame.width < 40 || frame.height < 40 {
            return false
        }
        return true
    }

    /// Window id → position in the on-screen stack (0 = frontmost).
    private static func stackingOrder() -> [CGWindowID: Int] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [:] }

        var order: [CGWindowID: Int] = [:]
        for (index, entry) in info.enumerated() {
            if let id = entry[kCGWindowNumber as String] as? CGWindowID, order[id] == nil {
                order[id] = index
            }
        }
        return order
    }
}
