//
//  WindowThumbnailer.swift
//  Reef
//
//  Captures small previews of windows for the switcher panel.
//

import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit


/// Takes small screenshots of individual windows so the switcher can show what
/// each one looks like. This is what tells two windows with the same title apart.
///
/// Needs the Screen Recording permission. Without it nothing is captured and
/// the switcher keeps its text-only layout.
@MainActor
final class WindowThumbnailer {
    static let shared = WindowThumbnailer()

    /// UserDefaults key for the "Show window previews" preference (default on).
    static let preferenceKey = "showWindowPreviews"
    private static let didRequestAccessKey = "didRequestScreenCaptureAccess"

    /// Last known preview per window, so reopening the switcher shows something
    /// at once while fresh captures are on their way.
    private let cache: NSCache<NSNumber, NSImage> = {
        let cache = NSCache<NSNumber, NSImage>()
        cache.countLimit = 24   // previews are ~1.3 MB each at 2x
        return cache
    }()

    static var isEnabledInPreferences: Bool {
        UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true
    }

    static var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system Screen Recording prompt. macOS only shows it once per
    /// app; after that the user has to flip the switch in System Settings.
    @discardableResult
    static func requestPermission() -> Bool {
        UserDefaults.standard.set(true, forKey: didRequestAccessKey)
        return CGRequestScreenCaptureAccess()
    }

    /// Asks for Screen Recording the first time Reef runs with previews turned on.
    static func requestPermissionOnFirstLaunchIfNeeded() {
        guard isEnabledInPreferences,
              !hasPermission,
              !UserDefaults.standard.bool(forKey: didRequestAccessKey)
        else { return }

        requestPermission()
    }

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    func cachedThumbnail(for windowID: CGWindowID) -> NSImage? {
        cache.object(forKey: NSNumber(value: windowID))
    }

    /// Captures a preview of each window and hands them back one by one, as each
    /// capture finishes.
    ///
    /// - Parameters:
    ///   - windowIDs: The windows to capture.
    ///   - pointSize: The box (in points) each preview must fit inside.
    ///   - scale: Backing scale of the screen the previews are drawn on.
    func captureThumbnails(
        for windowIDs: [CGWindowID],
        fitting pointSize: CGSize,
        scale: CGFloat,
        onThumbnail: @escaping @MainActor (CGWindowID, NSImage) -> Void
    ) async {
        guard Self.hasPermission, !windowIDs.isEmpty else { return }

        let pixelSize = CGSize(width: pointSize.width * scale, height: pointSize.height * scale)

        await Self.capture(windowIDs: Set(windowIDs), fitting: pixelSize) { windowID, cgImage in
            await MainActor.run {
                let image = NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
                )
                self.cache.setObject(image, forKey: NSNumber(value: windowID))
                onThumbnail(windowID, image)
            }
        }
    }

    private nonisolated static func capture(
        windowIDs: Set<CGWindowID>,
        fitting pixelSize: CGSize,
        deliver: @escaping @Sendable (CGWindowID, CGImage) async -> Void
    ) async {
        let started = CFAbsoluteTimeGetCurrent()
        // Off-screen windows are included so minimized ones can still be matched.
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else {
            ActivityLog.log("  pictures: window list failed after \(ActivityLog.ms(since: started)) ms")
            return
        }
        ActivityLog.log("  pictures: window list in \(ActivityLog.ms(since: started)) ms")

        let windows = content.windows.filter { windowIDs.contains($0.windowID) }

        await withTaskGroup(of: Void.self) { group in
            for window in windows {
                group.addTask {
                    guard let image = await captureImage(of: window, fitting: pixelSize) else { return }
                    await deliver(window.windowID, image)
                }
            }
        }
        ActivityLog.log("  pictures: \(windows.count) captured, all done in \(ActivityLog.ms(since: started)) ms")
    }

    private nonisolated static func captureImage(of window: SCWindow, fitting pixelSize: CGSize) async -> CGImage? {
        let frame = window.frame
        guard frame.width > 1, frame.height > 1 else { return nil }

        // Scale the window down so it fits the box, keeping its proportions.
        let ratio = min(pixelSize.width / frame.width, pixelSize.height / frame.height)

        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((frame.width * ratio).rounded()))
        configuration.height = max(1, Int((frame.height * ratio).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true

        // Captures the window by itself, even when other windows cover it.
        let filter = SCContentFilter(desktopIndependentWindow: window)

        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
