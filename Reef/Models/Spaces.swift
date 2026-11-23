//
//  Spaces.swift
//  Reef
//
//  Windows outside the current desktop: full-screen apps, other desktops, other
//  displays' spaces. Accessibility only lists windows in the spaces on screen right
//  now, so these come from the window server instead, and are focused by window id.
//
//  Uses private SkyLight calls, the same ones AltTab and yabai rely on.
//

import AppKit
import ApplicationServices


enum Spaces {
    /// Where a window lives, for the switcher's second line.
    enum Placement: Equatable {
        case fullScreen
        case otherDesktop
        case minimized
        /// On screen now, found here only because Accessibility didn't answer.
        case thisDesktop

        var label: String? {
            switch self {
            case .fullScreen: return "Full screen"
            case .otherDesktop: return "Other desktop"
            case .minimized: return "Minimized"
            case .thisDesktop: return nil
            }
        }
    }

    /// A window the window server knows about but Accessibility didn't list.
    struct OffscreenWindow {
        let id: CGWindowID
        let title: String
        let placement: Placement
    }

    /// The app's titled, real-sized windows that are not in a space on screen now.
    /// `known` are the window ids Accessibility already returned. With `includingOnScreen`
    /// (Accessibility didn't answer: the app is asleep or busy), on-screen windows too.
    static func offscreenWindows(
        pid: pid_t,
        excluding known: Set<CGWindowID>,
        includingOnScreen: Bool = false
    ) -> [OffscreenWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }

        let connection = CGSMainConnectionID()
        let visible = visibleSpaces(connection)
        let fullScreen = fullScreenSpaces(connection)

        var result: [OffscreenWindow] = []
        for entry in info {
            guard (entry[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (entry[kCGWindowLayer as String] as? Int) == 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID, !known.contains(id),
                  let title = entry[kCGWindowName as String] as? String, !title.isEmpty,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) >= 120, (bounds["Height"] ?? 0) >= 120,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0
            else { continue }

            let spaces = Set(spacesFor(window: id, connection: connection))

            let placement: Placement
            if !spaces.isDisjoint(with: visible) {
                // In a space on screen: Accessibility left it out on purpose (tool windows
                // etc.), unless it didn't answer at all.
                guard includingOnScreen else { continue }
                placement = .thisDesktop
            } else if spaces.isEmpty {
                placement = .minimized
            } else if !spaces.isDisjoint(with: fullScreen) {
                placement = .fullScreen
            } else {
                placement = .otherDesktop
            }
            result.append(OffscreenWindow(id: id, title: title, placement: placement))
        }
        return result
    }

    /// Brings one specific window to the front, switching to its space if needed.
    /// Returns false if the window server refused, so the caller can fall back.
    @discardableResult
    static func focus(windowID: CGWindowID, pid: pid_t) -> Bool {
        var psn = ProcessSerialNumber()
        guard GetProcessForPID(pid, &psn) == noErr else { return false }

        // Show the window's space first without the slide, so the window server has
        // nothing left to animate.
        InstantSpaceSwitch.reveal(windowID: windowID)

        // kCPSUserGenerated: as if the user clicked the window.
        guard _SLPSSetFrontProcessWithOptions(&psn, windowID, 0x200) == .success else { return false }
        makeKey(windowID: windowID, psn: &psn)
        // Chromium apps act on the event above, but AppKit apps (Passwords, Notes,
        // Activity Monitor) only move to the window's space when it is raised.
        if let element = accessibilityElement(windowID: windowID, pid: pid) {
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        return true
    }

    /// The Accessibility element of a window in another space. The app's window list
    /// leaves those out, but every element can be addressed by a remote token
    /// (pid + "coco" + element id), so walk the ids until one is this window. AltTab
    /// does the same.
    static func accessibilityElement(windowID: CGWindowID, pid: pid_t) -> AXUIElement? {
        let started = CFAbsoluteTimeGetCurrent()
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f_636f)) { Data($0) })

        for elementID: UInt64 in 0..<1000 {
            // An app that doesn't answer would make each try wait; give up instead.
            if CFAbsoluteTimeGetCurrent() - started > 0.3 { break }
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })
            guard let element = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(element, 0.1)
            var id = CGWindowID(0)
            if _AXUIElementGetWindow(element, &id) == .success, id == windowID {
                ActivityLog.log("  found AX element for [\(windowID)] at id \(elementID) in \(ActivityLog.ms(since: started)) ms")
                return element
            }
        }
        ActivityLog.log("  no AX element for [\(windowID)] after \(ActivityLog.ms(since: started)) ms")
        return nil
    }

    /// Two synthetic "make this window key" event records (the layout yabai uses).
    private static func makeKey(windowID: CGWindowID, psn: inout ProcessSerialNumber) {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        var id = windowID
        withUnsafeBytes(of: &id) { raw in
            for (offset, byte) in raw.enumerated() { bytes[0x3c + offset] = byte }
        }
        for offset in 0x20..<0x30 { bytes[offset] = 0xff }

        bytes[0x08] = 0x01
        _ = SLPSPostEventRecordTo(&psn, &bytes)
        bytes[0x08] = 0x02
        _ = SLPSPostEventRecordTo(&psn, &bytes)
    }

    // MARK: - Space lookups

    private static func spacesFor(window id: CGWindowID, connection: Int32) -> [Int] {
        // 7 = all spaces the window belongs to (current, other, user + fullscreen).
        (CGSCopySpacesForWindows(connection, 7, [id] as CFArray) as? [Int]) ?? []
    }

    /// The space currently shown on each display.
    private static func visibleSpaces(_ connection: Int32) -> Set<Int> {
        var result: Set<Int> = []
        for display in managedDisplaySpaces(connection) {
            if let current = display["Current Space"] as? [String: Any],
               let id = current["ManagedSpaceID"] as? Int {
                result.insert(id)
            }
        }
        return result
    }

    private static func fullScreenSpaces(_ connection: Int32) -> Set<Int> {
        var result: Set<Int> = []
        for display in managedDisplaySpaces(connection) {
            for space in (display["Spaces"] as? [[String: Any]]) ?? [] {
                // type 4 = a full-screen app's space.
                if (space["type"] as? Int) == 4, let id = space["ManagedSpaceID"] as? Int {
                    result.insert(id)
                }
            }
        }
        return result
    }

    private static func managedDisplaySpaces(_ connection: Int32) -> [[String: Any]] {
        (CGSCopyManagedDisplaySpaces(connection) as? [[String: Any]]) ?? []
    }
}


// MARK: - Private window server API

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> CFArray

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ connection: Int32, _ mask: Int32, _ windowIDs: CFArray) -> CFArray

// The SkyLight calls are looked up at run time, so neither the Xcode project nor
// Package.swift has to link the private framework.
private let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

private typealias SetFrontProcessFunction = @convention(c) (
    UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32
) -> CGError
private typealias PostEventRecordFunction = @convention(c) (
    UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>
) -> CGError

private let setFrontProcess: SetFrontProcessFunction? = skyLight
    .flatMap { dlsym($0, "_SLPSSetFrontProcessWithOptions") }
    .map { unsafeBitCast($0, to: SetFrontProcessFunction.self) }

private let postEventRecord: PostEventRecordFunction? = skyLight
    .flatMap { dlsym($0, "SLPSPostEventRecordTo") }
    .map { unsafeBitCast($0, to: PostEventRecordFunction.self) }

private func _SLPSSetFrontProcessWithOptions(
    _ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ windowID: CGWindowID, _ mode: UInt32
) -> CGError {
    setFrontProcess?(psn, windowID, mode) ?? .failure
}

private func SLPSPostEventRecordTo(
    _ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ bytes: UnsafeMutablePointer<UInt8>
) -> CGError {
    postEventRecord?(psn, bytes) ?? .failure
}

@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

@_silgen_name("GetProcessForPID")
private func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
