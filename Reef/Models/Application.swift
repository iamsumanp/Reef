//
//  Application.swift
//  Reef
//
//  Created by Xander Gouws on 16-09-2025.
//

import Foundation
import Cocoa


class Application {
    var title: String
    var element: AXUIElement?

    var runningApplication: NSRunningApplication?
    var pid: pid_t?
    var bundleIdentifier: String?
    var bundleUrl: URL?
    
    init(_ runningApplication: NSRunningApplication) {
        self.runningApplication = runningApplication

        self.pid = runningApplication.processIdentifier

        self.element = AXUIElementCreateApplication(self.pid!)

        self.title = runningApplication.localizedName ?? "Unknown Application"
        self.bundleIdentifier = runningApplication.bundleIdentifier
        self.bundleUrl = runningApplication.bundleURL
    }
    
    // Initialize from URL (for loading from persistence)
    init?(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        self.bundleUrl = url
        self.bundleIdentifier = Bundle(url: url)?.bundleIdentifier
        self.title = url.deletingPathExtension().lastPathComponent
        
        // Try to find running instance
        if let bundle = Bundle(url: url),
           let bundleIdentifier = bundle.bundleIdentifier,
           let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            self.runningApplication = runningApp
            self.pid = runningApp.processIdentifier
            self.element = AXUIElementCreateApplication(self.pid!)
            self.title = runningApp.localizedName ?? self.title
        } else {
            self.runningApplication = nil
            self.pid = nil
            self.element = nil
        }
    }

    convenience init?(bundleIdentifier: String) {
        if let runningApp = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first
        {
            self.init(runningApp)
            return
        }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            self.init(url: url)
            return
        }

        return nil
    }
    
//    // Ensure application is running and refresh internal state
//    func ensureRunning() -> Bool {
//        guard let bundleUrl = self.bundleUrl else {
//            return false
//        }
//        
//        // Check if already running
//        if let runningApp = self.runningApplication,
//           runningApp.isTerminated == false {
//            return true
//        }
//        
//        // Try to find if it's running but we lost the reference
//        if let bundle = Bundle(url: bundleUrl),
//           let bundleIdentifier = bundle.bundleIdentifier,
//           let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
//            self.runningApplication = runningApp
//            self.pid = runningApp.processIdentifier
//            self.element = AXUIElementCreateApplication(self.pid!)
//            return true
//        }
//        
//        return false
//    }
    
    func focus() {
        self.activate()
    }
    
    var isRunning: Bool {
        refreshRunningApplication() != nil
    }

    func activate(options: NSApplication.ActivationOptions = []) {
        if let runningApplication = refreshRunningApplication() {
            // App is running, just activate it
            runningApplication.activate(options: options)
        } else {
            // App not running, launch it
            try? reopen()
        }
    }
    
    func getFocusedWindow() -> Window? {
        guard let element = element,
              let windowElement: AXUIElement = element.getAttributeValue(.focusedWindow) else {
            return nil
        }
        
        return Window(windowElement, self)
    }
    
    func getFirstWindow() -> Window? {
        guard let element = element,
              let windowElements: [AXUIElement] = element.getAttributeValue(.windows) else {
            return nil
        }
        
        if let firstWindowElement = windowElements.first {
            return Window(firstWindowElement, self)
        }
        
        return nil
    }
    
    func reopen(
        configuration: NSWorkspace.OpenConfiguration = Application.defaultOpenConfiguration(),
        completion: @escaping (Result<NSRunningApplication, Error>) -> Void
    ) throws {
        guard let bundleUrl = self.bundleUrl else {
            throw ApplicationError.noBundleURL
        }
        
        NSWorkspace.shared.openApplication(
            at: bundleUrl,
            configuration: configuration,
            completionHandler: { runningApplication, error in
                if let runningApplication {
                    self.setRunningApplication(runningApplication)
                    completion(.success(runningApplication))
                    return
                }
                
                completion(.failure(error ?? ApplicationError.openFailed))
            }
        )
    }
    
    func reopen(
        configuration: NSWorkspace.OpenConfiguration = Application.defaultOpenConfiguration()
    ) async throws -> NSRunningApplication {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try reopen(configuration: configuration) { result in
                    continuation.resume(with: result)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    func reopen() throws {
        try reopen(configuration: Self.defaultOpenConfiguration()) { _ in }
    }
    
    func performNoWindowAction() async -> Bool {
        if let existingWindow = getWindows().first {
            existingWindow.focus()
            return true
        }
        
        do {
            _ = try await reopen(configuration: Self.defaultOpenConfiguration(activates: true))
            return true
        } catch {
            return false
        }
    }
    
    static func getFrontApplication() -> Application? {
        guard let runningApplication = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        
        return Application(runningApplication)
    }
    
    static func activateOrLaunch(
        bundleIdentifier: String,
        bundleURL: URL,
        options: NSApplication.ActivationOptions = []
    ) {
        if let runningApplication = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first
        {
            runningApplication.activate(options: options)
            return
        }
        
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in }
    }

    func getAXWindows() -> [AXUIElement] {
        axWindows() ?? []
    }

    /// nil when the app didn't answer (asleep, busy, or past the messaging timeout).
    private func axWindows() -> [AXUIElement]? {
        guard let element = element else {
            return []
        }
        
        // NOTE: Only returns windows in current Desktop (but multiple monitors does work)
        let started = CFAbsoluteTimeGetCurrent()
        // An app that just failed to answer is asked briefly, so every press of its
        // number doesn't stall a whole second; its windows come from the window server.
        AXUIElementSetMessagingTimeout(element, isUnresponsive ? 0.15 : 0)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
        let windows = value as? [AXUIElement] ?? []
        ActivityLog.log("  \(title): AX windows → \(result == .success ? "\(windows.count)" : "error \(result.rawValue)") in \(ActivityLog.ms(since: started)) ms")
        if let pid {
            if result == .cannotComplete {
                Self.unresponsiveSince[pid] = Self.unresponsiveSince[pid] ?? CFAbsoluteTimeGetCurrent()
            } else {
                Self.unresponsiveSince[pid] = nil
            }
        }
        // .noValue: a running app with no windows at all, which is an answer.
        guard result == .success || result == .noValue else { return nil }
        return windows
    }
    
    /// Apps whose last Accessibility request timed out (hung, or busy), by pid.
    private static var unresponsiveSince: [pid_t: CFAbsoluteTime] = [:]

    /// The app didn't answer the last time it was asked for its windows.
    var isUnresponsive: Bool {
        guard let pid else { return false }
        return Self.unresponsiveSince[pid] != nil
    }

    func getWindows() -> [Window] {
        let axWindows = self.axWindows()
        var windows = (axWindows ?? []).map { axWindow in
            Window(axWindow, self)
        }
        windows = Self.droppingFloatingWindows(windows)
        
        // Finder can expose a trailing generic "Finder" window that is not useful for switching.
        if bundleIdentifier == "com.apple.finder",
           let lastWindow = windows.last,
           lastWindow.title == "Finder" {
            windows.removeLast()
        }

        // Accessibility only lists windows in the spaces on screen. Add the rest
        // (full-screen apps, other desktops) from the window server.
        if let pid {
            let started = CFAbsoluteTimeGetCurrent()
            let known = Set(windows.map(\.id))
            // If Accessibility didn't answer, the window server still knows every window,
            // and can focus them by id.
            let offscreen = Spaces.offscreenWindows(
                pid: pid, excluding: known, includingOnScreen: axWindows == nil)
            windows += offscreen.map { Window(offscreen: $0, self) }
            ActivityLog.log("  \(title): \(offscreen.count) windows in other spaces, in \(ActivityLog.ms(since: started)) ms")
            // The window the user was last working in comes first, wherever it is.
            windows = LastUsedWindows.ordered(windows, pid: pid,
                                              appIsActive: runningApplication?.isActive ?? false)
        }

        // A window that draws nothing (an app's transparent overlay) leads nowhere.
        InvisibleWindows.check(windows.map(\.id))
        windows.removeAll { InvisibleWindows.isInvisible($0.id) }
        return windows
    }
    
    /// Picture-in-picture videos (Dia's YouTube popup), palettes and other windows that
    /// float above normal ones aren't something to switch to; real windows sit on
    /// the normal level, 0.
    private static func droppingFloatingWindows(_ windows: [Window]) -> [Window] {
        let ids = Set(windows.compactMap(\.cgWindowID))
        guard !ids.isEmpty,
              let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
        else { return windows }

        var floating: Set<CGWindowID> = []
        for entry in info {
            if let id = entry[kCGWindowNumber as String] as? CGWindowID, ids.contains(id),
               let layer = entry[kCGWindowLayer as String] as? Int, layer != 0 {
                floating.insert(id)
            }
        }
        guard !floating.isEmpty else { return windows }
        ActivityLog.log("  left out floating windows \(floating.sorted())")
        return windows.filter { !floating.contains($0.id) }
    }

    func listAvailableAttributes() -> [String] {
        guard let element = element else {
            return []
        }
        
        var attributesRef: CFArray?
        let result = AXUIElementCopyAttributeNames(element, &attributesRef)
        
        guard result == .success, let attributes = attributesRef as? [String] else {
            return []
        }
        
        return attributes
    }
    
    @discardableResult
    private func refreshRunningApplication() -> NSRunningApplication? {
        if let runningApplication,
           runningApplication.isTerminated == false {
            return runningApplication
        }
        
        guard let bundleIdentifier else {
            setRunningApplication(nil)
            return nil
        }
        
        guard let detectedRunningApp = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first
        else {
            setRunningApplication(nil)
            return nil
        }
        
        setRunningApplication(detectedRunningApp)
        return detectedRunningApp
    }
    
    private func setRunningApplication(_ runningApplication: NSRunningApplication?) {
        self.runningApplication = runningApplication
        
        if let runningApplication {
            self.pid = runningApplication.processIdentifier
            self.element = AXUIElementCreateApplication(runningApplication.processIdentifier)
            self.title = runningApplication.localizedName ?? self.title
            return
        }
        
        self.pid = nil
        self.element = nil
    }
    
    private static func defaultOpenConfiguration(activates: Bool = true) -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        return configuration
    }
    
}


enum ApplicationError: Error {
    case noBundleURL
    case openFailed
}
