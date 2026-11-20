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
    /// A running app with no window on this desktop (other-apps switcher only).
    case app(Application)
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

    // MARK: Other-apps switcher (⌥ + `)

    enum Mode { case application, otherApps }

    @Published var mode: Mode = .application
    /// What has been typed to narrow the list down.
    @Published var filterText = ""
    /// Numbers with no app in the current profile, for the "give it a number" hint.
    @Published var freeNumbers: [Int] = []
    /// Short confirmation shown in the footer, e.g. "WhatsApp is now on ⌥ 4".
    @Published var footerMessage: String?
    /// The keys held to open the switcher, e.g. "⌥".
    @Published var modifierSymbols = ""
    /// Once the user types, letting go of the modifier no longer switches; Return does.
    @Published var isSticky = false
    /// Everything the other-apps switcher found, before filtering.
    private(set) var allItems: [CyclePanelItem] = []
    /// Windows on other desktops that stand in for apps with none here (by process id).
    @Published var otherDesktopWindows: [pid_t: OtherApps.RemoteWindow] = [:]

    func otherDesktopWindow(for app: Application) -> OtherApps.RemoteWindow? {
        app.pid.flatMap { otherDesktopWindows[$0] }
    }

    /// Every window whose picture the panel shows.
    var previewWindowIDs: [CGWindowID] {
        windows.map(\.id) + items.compactMap { item in
            if case let .app(app) = item { return otherDesktopWindow(for: app)?.id }
            return nil
        }
    }

    /// The panel is sized for every item found, so it doesn't jump while filtering.
    var layoutItemCount: Int {
        mode == .otherApps ? max(1, allItems.count) : items.count
    }

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
        // A prompt for another app (e.g. ⌥ 5 for a closed app, then ⌥ 1) must not carry over.
        launchPrompt = nil
        mode = .application
        filterText = ""
        isSticky = false
        footerMessage = nil
        freeNumbers = []
        allItems = []
        
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
        guard previewWindowIDs.contains(windowID) else { return }
        thumbnails[windowID] = image
    }
    
    /// Fills the panel with the windows of apps that have no number.
    func setOtherApps(_ result: OtherApps.Result) {
        mode = .otherApps
        applicationTitle = "Other apps"
        applicationIcon = nil
        launchPrompt = nil
        filterText = ""
        isSticky = false
        footerMessage = nil

        allItems = result.windows.map(CyclePanelItem.window) + result.windowlessApps.map(CyclePanelItem.app)
        items = allItems
        selectedIndex = 0
        otherDesktopWindows = result.otherDesktopWindows

        showsPreviews = (!result.windows.isEmpty || !result.otherDesktopWindows.isEmpty)
            && WindowThumbnailer.isEnabledInPreferences
            && WindowThumbnailer.hasPermission

        var thumbnails: [CGWindowID: NSImage] = [:]
        if showsPreviews {
            for id in previewWindowIDs {
                if let cached = WindowThumbnailer.shared.cachedThumbnail(for: id) {
                    thumbnails[id] = cached
                }
            }
        }
        self.thumbnails = thumbnails

        // Shared title starts are trimmed per app, not across apps.
        var titles: [CGWindowID: String] = [:]
        let byApp = Dictionary(grouping: result.windows) { $0.application.pid ?? 0 }
        for (_, appWindows) in byApp {
            let trimmed = Self.displayTitles(for: appWindows.map(\.title))
            for (window, title) in zip(appWindows, trimmed) { titles[window.id] = title }
        }
        displayTitles = titles
        details = [:]
    }

    /// Re-applies `filterText`, keeping the selection on the same item when it survives.
    func applyFilter() {
        let previous = currentItem.map(Self.identity)
        let query = filterText.lowercased().trimmingCharacters(in: .whitespaces)

        if query.isEmpty {
            items = allItems
        } else {
            let words = query.split(separator: " ").map(String.init)
            items = allItems.filter { item in
                let haystack = searchText(for: item).lowercased()
                return words.allSatisfy { haystack.contains($0) }
            }
        }

        if let previous, let index = items.firstIndex(where: { Self.identity($0) == previous }) {
            selectedIndex = index
        } else {
            selectedIndex = 0
        }
    }

    private func searchText(for item: CyclePanelItem) -> String {
        switch item {
        case .window(let window):
            let title = displayTitles[window.id] ?? window.title
            return [window.application.title, title, details[window.id]?.text ?? ""].joined(separator: " ")
        case .app(let app):
            let elsewhere = otherDesktopWindow(for: app).map { "\($0.title) another desktop" } ?? ""
            return "\(app.title) \(elsewhere)"
        case .action(let action):
            return action.title
        }
    }

    private static func identity(_ item: CyclePanelItem) -> String {
        switch item {
        case .window(let window): return "w\(window.id)"
        case .app(let app): return "a\(app.pid ?? 0)"
        case .action(let action): return "x\(action.title)"
        }
    }

    /// The app behind the selected card.
    var currentApplication: Application? {
        switch currentItem {
        case .window(let window): return window.application
        case .app(let app): return app
        default: return nil
        }
    }

    func movePrevious() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + items.count) % items.count
    }

    /// Moves by `step` items without wrapping (grid up/down by a row).
    func move(by step: Int) {
        guard !items.isEmpty else { return }
        let target = selectedIndex + step
        if items.indices.contains(target) { selectedIndex = target }
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
        mode = .application
        filterText = ""
        freeNumbers = []
        footerMessage = nil
        isSticky = false
        allItems = []
        otherDesktopWindows = [:]
    }
}
