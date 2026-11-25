//
//  LastUsedWindows.swift
//  Reef
//
//  The window each app had focused when the user last left it.
//

import AppKit
import ApplicationServices

/// Accessibility only lists an app's windows in the spaces on screen, so a window the
/// user was working in on another display's other desktop came last, and a tap on the
/// app's number went to whichever of its windows happened to be on screen instead.
/// Reef notes the focused window of every app the user leaves and puts it first.
enum LastUsedWindows {
    private static let lock = NSLock()
    private static var byPID: [pid_t: CGWindowID] = [:]
    private static let queue = DispatchQueue(label: "reef.last-used-windows", qos: .userInitiated)
    private static var observers: [NSObjectProtocol] = []

    static func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification,
                                            object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            record(pid: app.processIdentifier)
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                            object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            lock.lock(); byPID[app.processIdentifier] = nil; lock.unlock()
        })
    }

    /// Reads the app's focused window off the main thread: a busy app must not hold up
    /// the switch the user just made.
    static func record(pid: pid_t) {
        queue.async {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.3)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID()
            else { return }
            let window = value as! AXUIElement
            guard let id = window.getWindowID(), id != 0 else { return }
            lock.lock(); byPID[pid] = id; lock.unlock()
            ActivityLog.log("left pid \(pid) in window \(id)")
        }
    }

    static func window(for pid: pid_t) -> CGWindowID? {
        lock.lock(); defer { lock.unlock() }
        return byPID[pid]
    }

    /// The window the user left the app in first, when the app isn't the one in front.
    static func ordered(_ windows: [Window], pid: pid_t, appIsActive: Bool) -> [Window] {
        guard !appIsActive, let last = window(for: pid),
              let index = windows.firstIndex(where: { $0.id == last }), index > 0
        else { return windows }
        var windows = windows
        windows.insert(windows.remove(at: index), at: 0)
        return windows
    }
}
