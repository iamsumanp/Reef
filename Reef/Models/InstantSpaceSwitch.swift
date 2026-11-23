//
//  InstantSpaceSwitch.swift
//  Reef
//
//  Shows another space without the sliding animation, before a window there is
//  focused. macOS has no setting for this (Reduce motion only swaps the slide for a
//  fade), so Reef posts the Dock the same swipe a trackpad would, with a fling so fast
//  that there is nothing left to animate.
//
//  The gesture layout, including the raw IOHID payload macOS 27 requires, comes from
//  InstantSpaceSwitcher by jurplel (MIT): github.com/jurplel/InstantSpaceSwitcher
//

import AppKit
import CoreGraphics

enum InstantSpaceSwitch {
    /// Turned off with `defaults write io.github.iamsumanp.reef instantSpaceSwitch -bool false`.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "instantSpaceSwitch") as? Bool ?? true
    }

    /// Shows the space `windowID` is in, if it is in a space that is not on screen on the
    /// display under the pointer. Returns once the space is shown (or after a short wait);
    /// false when nothing was switched, so the caller's own focus does the moving.
    @discardableResult
    static func reveal(windowID: CGWindowID) -> Bool {
        guard isEnabled else { return false }
        let started = CFAbsoluteTimeGetCurrent()
        let connection = CGSMainConnectionID()
        let windowSpaces = (CGSCopySpacesForWindows(connection, 7, [windowID] as CFArray) as? [Int]) ?? []
        guard !windowSpaces.isEmpty else {
            ActivityLog.log("  instant switch: [\(windowID)] is in no space")
            return false
        }

        let displays = (CGSCopyManagedDisplaySpaces(connection) as? [[String: Any]]) ?? []
        guard let display = displays.first(where: { spaceIDs(of: $0).contains(where: windowSpaces.contains) })
        else { return false }

        let spaces = spaceIDs(of: display)
        guard let current = currentSpace(of: display),
              let from = spaces.firstIndex(of: current),
              let to = spaces.firstIndex(where: windowSpaces.contains)
        else {
            ActivityLog.log("  instant switch: no space index for [\(windowID)] in \(windowSpaces)")
            return false
        }
        if from == to {
            ActivityLog.log("  instant switch: [\(windowID)] already in the current space \(current)")
            return false
        }

        // The Dock moves the display under the pointer; another display's spaces are
        // left to the window server.
        if displays.count > 1, display["Display Identifier"] as? String != pointerDisplayIdentifier() {
            ActivityLog.log("  instant switch skipped: [\(windowID)] is on another display")
            return false
        }

        let right = to > from
        for _ in 0..<abs(to - from) {
            postSwipe(right: right, velocity: 2000 * Double(abs(to - from)))
        }

        // Wait for the Dock, so the window is focused in its own space rather than
        // asking the window server to slide there again.
        let target = spaces[to]
        let identifier = display["Display Identifier"] as? String
        while CFAbsoluteTimeGetCurrent() - started < 0.5 {
            if currentSpace(onDisplay: identifier, connection: connection) == target {
                ActivityLog.log("  instant switch \(from) → \(to) in \(ActivityLog.ms(since: started)) ms")
                return true
            }
            usleep(5_000)
        }
        ActivityLog.log("  instant switch \(from) → \(to) not seen after \(ActivityLog.ms(since: started)) ms")
        return true
    }

    // MARK: - Spaces

    private static func spaceIDs(of display: [String: Any]) -> [Int] {
        ((display["Spaces"] as? [[String: Any]]) ?? []).compactMap { $0["ManagedSpaceID"] as? Int }
    }

    private static func currentSpace(of display: [String: Any]) -> Int? {
        (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
    }

    private static func currentSpace(onDisplay identifier: String?, connection: Int32) -> Int? {
        let displays = (CGSCopyManagedDisplaySpaces(connection) as? [[String: Any]]) ?? []
        let display = displays.first { $0["Display Identifier"] as? String == identifier } ?? displays.first
        return display.flatMap(currentSpace(of:))
    }

    private static func pointerDisplayIdentifier() -> String? {
        guard let location = CGEvent(source: nil)?.location else { return nil }
        var display = CGDirectDisplayID(0)
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(location, 1, &display, &count) == .success, count > 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    // MARK: - Synthetic Dock swipe

    private static func field(_ raw: UInt32) -> CGEventField { CGEventField(rawValue: raw)! }

    private static let eventType = field(55)
    private static let hidType = field(110)
    private static let swipeMotion = field(123)
    private static let swipeProgress = field(124)
    private static let swipePositionX = field(125)
    private static let swipeVelocityX = field(129)
    private static let swipeVelocityY = field(130)
    private static let gesturePhase = field(132)
    private static let gesturePhaseAlias = field(134)
    private static let zoomDeltaY = field(138)
    private static let sourceProcessIDAlias = field(169)

    private static let gestureEvent: Int64 = 29
    private static let dockControlEvent: Int64 = 30
    private static let dockSwipe: Int64 = 23
    private static let horizontal: Int64 = 1
    private enum Phase: Int64 { case began = 1, changed = 2, ended = 4 }

    private static let needsPayload = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27

    /// Began, changed, ended: one space over. With only two, Mission Control breaks.
    private static func postSwipe(right: Bool, velocity: Double) {
        for phase in [Phase.began, .changed, .ended] {
            if needsPayload {
                postModernSwipe(phase: phase, right: right)
            } else {
                postLegacySwipe(phase: phase, right: right, velocity: velocity)
            }
        }
    }

    private static func postLegacySwipe(phase: Phase, right: Bool, velocity: Double) {
        guard let event = CGEvent(source: nil) else { return }
        event.setIntegerValueField(eventType, value: dockControlEvent)
        event.setIntegerValueField(hidType, value: dockSwipe)
        event.setIntegerValueField(gesturePhase, value: phase.rawValue)
        event.setDoubleValueField(swipeProgress, value: right ? 0.000016 : -0.000016)
        event.setIntegerValueField(swipeMotion, value: horizontal)
        event.setDoubleValueField(swipeVelocityX, value: right ? velocity : -velocity)
        event.setDoubleValueField(swipeVelocityY, value: right ? velocity : -velocity)
        event.post(tap: .cgSessionEventTap)
    }

    /// macOS 27 only honours a swipe that carries the trackpad's raw IOHID event, and
    /// reads its direction through the natural scrolling setting.
    private static func postModernSwipe(phase: Phase, right: Bool) {
        let natural = CFPreferencesGetAppBooleanValue("com.apple.swipescrolldirection" as CFString,
                                                      kCFPreferencesAnyApplication, nil)
        let defined = CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString,
                                                kCFPreferencesAnyApplication) != nil
        var sign: Double = right ? -1 : 1
        if defined && !natural { sign = -sign }

        guard let event = CGEvent(source: nil) else { return }
        event.setIntegerValueField(eventType, value: dockControlEvent)
        event.setIntegerValueField(hidType, value: dockSwipe)
        event.setIntegerValueField(gesturePhase, value: phase.rawValue)
        event.setIntegerValueField(swipeMotion, value: horizontal)
        // The smallest non-zero progress leaves nothing to animate; the fling commits it.
        event.setDoubleValueField(swipeProgress, value: sign * 0.000016)
        event.setIntegerValueField(gesturePhaseAlias, value: phase.rawValue)
        event.setDoubleValueField(zoomDeltaY, value: 3)
        event.setDoubleValueField(sourceProcessIDAlias, value: Double(mach_absolute_time()))
        event.setDoubleValueField(swipePositionX, value: 0.1)
        if phase == .ended {
            // 16.16 fixed point in the payload, so it stays under 32767.
            event.setDoubleValueField(swipeVelocityX, value: sign * 9999)
        }
        guard let augmented = withIOHIDPayload(event), let companion = CGEvent(source: nil) else { return }
        // The Dock ignores a Dock-control event without a gesture event after it.
        companion.setIntegerValueField(eventType, value: gestureEvent)
        augmented.post(tap: .cgSessionEventTap)
        companion.post(tap: .cgSessionEventTap)
    }

    /// The event's serialized form plus a tagged IOHID queue element: a fluid-touch
    /// gesture (type 23, dock flavour) and, when moving, a velocity event (type 9).
    private static func withIOHIDPayload(_ event: CGEvent) -> CGEvent? {
        guard let data = event.data as Data?, data.prefix(4) == Data([0, 0, 0, 2]) else { return nil }

        let phase = event.getIntegerValueField(gesturePhase)
        let velocityX = event.getDoubleValueField(swipeVelocityX)
        let velocityY = event.getDoubleValueField(swipeVelocityY)
        let withVelocity = velocityX != 0 || velocityY != 0 || phase == Phase.ended.rawValue

        var payload = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { payload.append(contentsOf: $0) } }
        func fixed(_ value: Double) -> Int32 {
            let result = Int32(clamping: Int64(value * 65536))
            return result == 0 && value != 0 ? (value > 0 ? 1 : -1) : result
        }

        // Queue element header (28 bytes).
        let timestamp = event.timestamp == 0 ? mach_absolute_time() : event.timestamp
        append(UInt64(timestamp)); append(UInt64(0)); append(UInt32(0)); append(UInt32(0))
        append(UInt32(withVelocity ? 2 : 1))
        // Fluid touch gesture (40 bytes).
        append(UInt32(40)); append(UInt32(23)); append(UInt32(UInt32(phase & 0xff) << 24))
        append(UInt32(0))   // depth + reserved
        append(fixed(event.getDoubleValueField(swipePositionX)))
        append(fixed(event.getDoubleValueField(field(126))))
        append(Int32(0))
        append(UInt32(truncatingIfNeeded: event.getIntegerValueField(field(115))))
        append(UInt16(truncatingIfNeeded: event.getIntegerValueField(swipeMotion)))
        append(UInt16(3))   // dock primary
        append(fixed(event.getDoubleValueField(swipeProgress)))
        // Velocity (28 bytes).
        if withVelocity {
            append(UInt32(28)); append(UInt32(9)); append(UInt32(0))
            append(UInt32(1))   // depth 1
            append(fixed(velocityX)); append(fixed(velocityY)); append(Int32(0))
        }

        var result = data
        // Tag: payload size, then field id 4205, both big-endian 16-bit.
        result.append(contentsOf: [UInt8(payload.count >> 8 & 0xff), UInt8(payload.count & 0xff),
                                   UInt8(4205 >> 8), UInt8(4205 & 0xff)])
        result.append(payload)
        return CGEvent(withDataAllocator: nil, data: result as CFData)
    }
}

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> CFArray

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ connection: Int32, _ mask: Int32, _ windowIDs: CFArray) -> CFArray
