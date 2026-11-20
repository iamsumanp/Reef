//
//  CyclePanelState.swift
//  Reef
//
//  Created by Xander Gouws on 23-01-2026.
//

import Foundation
import AppKit

enum CyclePanelAction {
    case launchApp
    case openWindow
    
    var title: String {
        switch self {
        case .launchApp:
            return "Launch app"
        case .openWindow:
            return "Focus app"
        }
    }
}

enum CyclePanelItem {
    case window(Window)
    case action(CyclePanelAction)
}

@MainActor
final class CyclePanelState: ObservableObject {
    @Published var applicationTitle: String = ""
    @Published var items: [CyclePanelItem] = []
    @Published var selectedIndex: Int = 0

    /// True when rows should make room for a window preview.
    @Published var showsPreviews: Bool = false
    /// Window previews captured so far, keyed by window id.
    @Published var thumbnails: [CGWindowID: NSImage] = [:]
    /// Shown in place of a preview until (or unless) one arrives.
    @Published var applicationIcon: NSImage?
    /// Titles as shown: the part every window shares (e.g. "Jane Doe: ") is left out.
    @Published var displayTitles: [CGWindowID: String] = [:]
    /// Second line per window: website, folder, file location or screen.
    @Published var details: [CGWindowID: WindowDetail] = [:]
    /// Set while asking "press 3 again to open" for an app that is not running.
    @Published var launchPrompt: LaunchPrompt?

    struct LaunchPrompt: Equatable {
        /// The number key that opened the switcher, e.g. "3".
        let key: String
        /// The keys held with it, e.g. "⌥".
        let modifiers: String
    }

    /// UserDefaults key: ask before launching an app that is not running (default on).
    static let confirmLaunchKey = "confirmBeforeLaunch"

    static var confirmsLaunch: Bool {
        UserDefaults.standard.object(forKey: confirmLaunchKey) as? Bool ?? true
    }
    
    var windows: [Window] {
        items.compactMap { item in
            if case let .window(window) = item {
                return window
            }
            
            return nil
        }
    }
    
    var currentItem: CyclePanelItem? {
        guard !items.isEmpty, selectedIndex < items.count else { return nil }
        return items[selectedIndex]
    }
    
    var currentWindow: Window? {
        guard let currentItem else { return nil }
        
        if case let .window(window) = currentItem {
            return window
        }
        
        return nil
    }
    
    var currentAction: CyclePanelAction? {
        guard let currentItem else { return nil }
        
        if case let .action(action) = currentItem {
            return action
        }
        
        return nil
    }
    
    func setApplication(_ application: Application) {
        self.applicationTitle = application.title
        
        let windows = application.getWindows()
        if windows.isEmpty {
            let action: CyclePanelAction = application.isRunning ? .openWindow : .launchApp
            self.items = [.action(action)]
        } else {
            self.items = windows.map(CyclePanelItem.window)
        }
        
        self.selectedIndex = 0
        self.applicationIcon = application.runningApplication?.icon
            ?? application.bundleUrl.map { NSWorkspace.shared.icon(forFile: $0.path) }

        // Previews need the preference on, Screen Recording allowed, and real windows to show.
        self.showsPreviews = !windows.isEmpty
            && WindowThumbnailer.isEnabledInPreferences
            && WindowThumbnailer.hasPermission

        // Start from the last known previews so the panel is not empty while fresh ones load.
        var thumbnails: [CGWindowID: NSImage] = [:]
        if showsPreviews {
            for window in windows {
                if let cached = WindowThumbnailer.shared.cachedThumbnail(for: window.id) {
                    thumbnails[window.id] = cached
                }
            }
        }
        self.thumbnails = thumbnails

        let titles = Self.displayTitles(for: windows.map(\.title))
        self.displayTitles = Dictionary(zip(windows.map(\.id), titles), uniquingKeysWith: { first, _ in first })
        self.details = [:]
    }

    /// Stores the second lines once they have been looked up.
    func setDetails(_ details: [CGWindowID: WindowDetail]) {
        let details = details.filter { id, _ in windows.contains(where: { $0.id == id }) }
        self.details = details

        // A fuller title from elsewhere (Dia shows "claude.ai / Claude Code" in its address
        // bar while its window title is cut to "Jane Doe: Claude C…") wins.
        for (id, detail) in details {
            if let pageTitle = detail.pageTitle, !pageTitle.isEmpty {
                displayTitles[id] = pageTitle
            }
        }
    }

    /// Separators that split an app's own label from the part that names the window.
    nonisolated private static let titleSeparators = [": ", " - ", " — ", " – ", " | ", " · "]

    /// Drops the start (or end) every title shares, like "Jane Doe: " in Dia or
    /// " - Google Chrome", but only at a separator and only when every title keeps some text.
    nonisolated static func displayTitles(for titles: [String]) -> [String] {
        guard titles.count > 1 else { return titles }

        var result = titles

        let prefix = titles.dropFirst().reduce(titles[0]) { $0.commonPrefix(with: $1) }
        if let cut = titleSeparators.compactMap({ prefix.range(of: $0, options: .backwards)?.upperBound }).max() {
            let count = prefix.distance(from: prefix.startIndex, to: cut)
            let trimmed = result.map { String($0.dropFirst(count)).trimmingCharacters(in: .whitespaces) }
            if trimmed.allSatisfy({ !$0.isEmpty }) { result = trimmed }
        }

        let reversed = result.map { String($0.reversed()) }
        let suffix = String(reversed.dropFirst().reduce(reversed[0]) { $0.commonPrefix(with: $1) }.reversed())
        if let cut = titleSeparators.compactMap({ suffix.range(of: $0)?.lowerBound }).min() {
            let count = suffix.distance(from: cut, to: suffix.endIndex)
            let trimmed = result.map { String($0.dropLast(count)).trimmingCharacters(in: .whitespaces) }
            if trimmed.allSatisfy({ !$0.isEmpty }) { result = trimmed }
        }

        return result
    }

    /// Stores a freshly captured preview, ignoring windows that are no longer listed.
    func setThumbnail(_ image: NSImage, for windowID: CGWindowID) {
        guard windows.contains(where: { $0.id == windowID }) else { return }
        thumbnails[windowID] = image
    }
    
    func cycleNext() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % items.count
    }
    
    func reset() {
        items = []
        selectedIndex = 0
        applicationTitle = ""
        showsPreviews = false
        thumbnails = [:]
        applicationIcon = nil
        displayTitles = [:]
        details = [:]
        launchPrompt = nil
    }
}
