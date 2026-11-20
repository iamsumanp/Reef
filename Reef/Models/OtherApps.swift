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
        /// Windows of unbound apps, frontmost first.
        var windows: [Window]
        /// Unbound apps that are running but show no window on this desktop.
        var windowlessApps: [Application]

        var isEmpty: Bool { windows.isEmpty && windowlessApps.isEmpty }
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
        var windowlessApps: [Application] = []

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

            let appWindows = app.getWindows().filter(isSwitchable)
            if appWindows.isEmpty {
                windowlessApps.append(app)
            } else {
                windows.append(contentsOf: appWindows)
            }
        }

        // Frontmost first, like ⌘-Tab; windows the window server doesn't list
        // (minimized, other desktops) go after, grouped by app.
        windows.sort { a, b in
            let orderA = stacking[a.id] ?? Int.max
            let orderB = stacking[b.id] ?? Int.max
            if orderA != orderB { return orderA < orderB }
            return a.application.title.localizedCaseInsensitiveCompare(b.application.title) == .orderedAscending
        }
        windowlessApps.sort {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        return Result(windows: windows, windowlessApps: windowlessApps)
    }

    /// Real windows only: no palettes, tooltips or zero-sized helpers.
    private static func isSwitchable(_ window: Window) -> Bool {
        guard window.id != 0 else { return false }
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
