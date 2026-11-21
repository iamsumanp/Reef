//
//  WindowDetails.swift
//  Reef
//
//  Works out a short second line for a window in the switcher: the website a
//  browser window shows, the folder a Finder window shows, the file a document
//  window has open, or where the window is.
//

import AppKit
import ApplicationServices


/// What the switcher shows under a window's title.
struct WindowDetail: Equatable {
    /// "claude.ai", "~/Desktop/desk", "~/Documents" — or nil when the app reports nothing.
    var location: String?
    /// "Built-in Display", "Minimized" — only filled in when it helps tell windows apart.
    var placement: String?
    /// A fuller title than the window's own, when the app shows one elsewhere (Dia's address bar).
    var pageTitle: String?

    var text: String? {
        let parts = [location, placement].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}


/// Reads window details through the Accessibility API. Every call is cheap except
/// the browser lookup, which walks a small part of the window's element tree.
enum WindowDetails {
    /// Apps whose windows show web pages. Their detail is the website.
    static let browserBundleIDs: Set<String> = [
        "company.thebrowser.dia",
        "company.thebrowser.Browser",       // Arc
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "org.chromium.Chromium",
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "org.mozilla.firefox",
        "app.zen-browser.zen",
    ]

    /// Raw facts about one window, gathered off the main thread.
    struct Facts: Sendable {
        var url: URL?
        /// The full page title, when the browser shows one beside the address (Dia does).
        var pageTitle: String?
        var documentURL: URL?
        var frame: CGRect?
        var isMinimized = false
    }

    /// Collects the facts for each window element. Safe to call off the main thread.
    nonisolated static func facts(for elements: [AXUIElement], bundleIdentifier: String?) -> [Facts] {
        let isBrowser = bundleIdentifier.map(browserBundleIDs.contains) ?? false
        let isFinder = bundleIdentifier == "com.apple.finder"

        return elements.map { element in
            // Keep a stuck app from stalling the switcher.
            AXUIElementSetMessagingTimeout(element, 0.25)

            var facts = Facts()
            facts.isMinimized = (element.value(kAXMinimizedAttribute) as? Bool) ?? false
            facts.frame = element.frame

            if let document = element.value(kAXDocumentAttribute) as? String,
               let url = URL(string: document) {
                facts.documentURL = url
            }

            if isBrowser {
                if let page = webPage(in: element) {
                    facts.url = page.url
                    facts.pageTitle = page.title
                }
            } else if isFinder, facts.documentURL == nil {
                facts.documentURL = finderFolder(of: element)
            }

            return facts
        }
    }

    /// Turns the facts for all of an app's windows into one detail line per window.
    @MainActor
    static func details(for facts: [Facts], bundleIdentifier: String?) -> [WindowDetail] {
        let isFinder = bundleIdentifier == "com.apple.finder"
        let screens = NSScreen.screens

        // Only name the screen when this app's windows are spread over more than one.
        let screenNames = facts.map { screenName(for: $0.frame, among: screens) }
        let distinctScreens = Set(facts.indices.filter { !facts[$0].isMinimized }.compactMap { screenNames[$0] })
        let namesScreens = distinctScreens.count > 1

        return facts.indices.map { index in
            let facts = facts[index]
            var detail = WindowDetail()

            detail.pageTitle = facts.pageTitle

            if let url = facts.url {
                detail.location = shortWebAddress(url)
            } else if let documentURL = facts.documentURL {
                if documentURL.isFileURL {
                    // Finder: the folder itself. Documents: the folder the file is in.
                    let path = isFinder ? documentURL.path : documentURL.deletingLastPathComponent().path
                    detail.location = abbreviated(path)
                } else {
                    detail.location = shortWebAddress(documentURL)
                }
            }

            if facts.isMinimized {
                detail.placement = "Minimized"
            } else if namesScreens {
                detail.placement = screenNames[index]
            }

            return detail
        }
    }

    // MARK: - Browsers

    /// The address (and, if shown, the title) of the page a browser window shows.
    nonisolated static func webPage(in window: AXUIElement) -> (url: URL, title: String?)? {
        // Some browsers put it on the window itself.
        if let url = urlValue(window.value(kAXURLAttribute)) {
            return (url, nil)
        }

        // Otherwise the first web area's URL, or the address bar's text. Dia's address
        // bar is a text area reading "claude.ai / Claude Code": the site, then the page title.
        var addressBar: (url: URL, title: String?)?
        let webArea = firstElement(in: window, maxVisited: 600) { element in
            let role = element.value(kAXRoleAttribute) as? String
            if role == "AXWebArea" {
                return urlValue(element.value(kAXURLAttribute)) != nil
            }
            if addressBar == nil,
               role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole,
               let value = element.value(kAXValueAttribute) as? String {
                addressBar = parseAddressBar(value)
            }
            return false
        }

        if let webArea, let url = urlValue(webArea.value(kAXURLAttribute)) {
            let title = (webArea.value(kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
            return (url, title ?? addressBar?.title)
        }

        return addressBar
    }

    /// "claude.ai / Claude Code", "github.com/x/y" or "https://…" → address and optional title.
    nonisolated static func parseAddressBar(_ text: String) -> (url: URL, title: String?)? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var address = text
        var title: String?
        if let separator = text.range(of: " / ") {
            address = String(text[..<separator.lowerBound])
            let rest = text[separator.upperBound...].trimmingCharacters(in: .whitespaces)
            title = rest.isEmpty ? nil : rest
        }
        guard looksLikeWebAddress(address),
              let url = URL(string: address.contains("://") ? address : "https://" + address)
        else { return nil }
        return (url, title)
    }

    private nonisolated static func looksLikeWebAddress(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains(" ") else { return false }
        if text.hasPrefix("http://") || text.hasPrefix("https://") { return true }
        // "github.com/…": a dot in the part before the first slash.
        let host = text.split(separator: "/").first ?? ""
        return host.contains(".") && !host.hasSuffix(".")
    }

    static func shortWebAddress(_ url: URL) -> String {
        if url.isFileURL { return abbreviated(url.path) }
        guard var host = url.host(percentEncoded: false), !host.isEmpty else {
            return url.absoluteString
        }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    // MARK: - Finder

    /// The folder a Finder window shows. Finder does not report it on the window, but
    /// the path bar (when shown) and every file in the window carry file URLs.
    nonisolated static func finderFolder(of window: AXUIElement) -> URL? {
        let title = window.value(kAXTitleAttribute) as? String

        // 1. The path bar: "Macintosh HD › Users › … › desk" (plus the selected file, if any).
        if let pathBar = firstElement(in: window, maxVisited: 400, where: { element in
            (element.value(kAXRoleAttribute) as? String) == kAXListRole
                && (element.value(kAXDescriptionAttribute) as? String) == "path"
        }) {
            let urls = ((pathBar.value(kAXChildrenAttribute) as? [AXUIElement]) ?? [])
                .compactMap { fileURL($0.value(kAXURLAttribute)) }
            // The deepest folder named like the window; else the last folder in the bar.
            if let match = urls.last(where: { $0.lastPathComponent == title && $0.hasDirectoryPath }) {
                return match
            }
            if let lastFolder = urls.last(where: { $0.hasDirectoryPath }) {
                return lastFolder
            }
        }

        // 2. Any file in the window: its folder is the window's folder.
        var folder: URL?
        _ = firstElement(in: window, maxVisited: 400) { element in
            guard let url = fileURL(element.value(kAXURLAttribute)) else { return false }
            let parent = url.deletingLastPathComponent()
            if title == nil || parent.lastPathComponent == title {
                folder = parent
                return true
            }
            return false
        }
        return folder
    }

    /// Resolves Finder's file reference URLs (file:///.file/id=…) to normal paths.
    private nonisolated static func fileURL(_ value: AnyObject?) -> URL? {
        guard let url = urlValue(value), url.isFileURL else { return nil }
        return (url as NSURL).filePathURL ?? url
    }

    // MARK: - Placement

    @MainActor
    static func screenName(for frame: CGRect?, among screens: [NSScreen]) -> String? {
        guard let frame, let primary = screens.first else { return nil }
        // AX frames are top-left based; NSScreen frames are bottom-left based.
        let flipped = CGRect(
            x: frame.minX,
            y: primary.frame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        let best = screens.max { a, b in
            a.frame.intersection(flipped).area < b.frame.intersection(flipped).area
        }
        guard let best, best.frame.intersection(flipped).area > 0 else { return nil }
        return best.localizedName
    }

    // MARK: - Helpers

    static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private nonisolated static func urlValue(_ value: AnyObject?) -> URL? {
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    /// Breadth-first search, visiting at most `maxVisited` elements.
    nonisolated static func firstElement(
        in root: AXUIElement,
        maxVisited: Int,
        where matches: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        var queue: [AXUIElement] = [root]
        var head = 0
        while head < queue.count, head < maxVisited {
            let element = queue[head]
            head += 1
            if element != root, matches(element) { return element }
            if let children = element.value(kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return nil
    }
}


extension AXUIElement {
    /// Raw attribute value, or nil.
    nonisolated func value(_ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    /// The element's frame in screen coordinates (top-left origin), if it reports one.
    nonisolated var frame: CGRect? {
        guard let positionValue = value(kAXPositionAttribute),
              let sizeValue = value(kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }
}


private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}


#if REEF_DEBUG
/// Debug only: `reefctl dump` writes what each app reports about its windows to
/// ~/Library/Logs/Reef/windows.txt, so the details can be checked without the UI.
extension Notification.Name {
    static let reefDebugPress = Notification.Name("reefDebugPress")
}

enum WindowDetailsDebug {
    static let notificationName = Notification.Name("io.github.iamsumanp.reef.debug")

    @MainActor
    static func install() {
        DistributedNotificationCenter.default().addObserver(
            forName: notificationName,
            object: nil,
            queue: .main
        ) { notification in
            let command = notification.object as? String ?? ""
            Task { @MainActor in run(command) }
        }
    }

    @MainActor
    private static func run(_ command: String) {
        if command == "others" {
            let bound = Set((AppDelegate.profileManager.currentProfile?.bindings ?? []).compactMap { $0 })
            let started = CFAbsoluteTimeGetCurrent()
            let result = OtherApps.collect(excludingBundleIdentifiers: bound)
            let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            var out = "bound: \(bound.sorted())\ncollect took \(ms) ms\n\nwindows (front first):\n"
            for window in result.windows {
                out += "  [\(window.id)] \(window.application.title): \(window.title)\(window.offscreenPlacement.map { "  (\($0.label ?? "this desktop, AX silent"))" } ?? "")\n"
            }
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Reef")
            try? out.write(to: dir.appendingPathComponent("others.txt"), atomically: true, encoding: .utf8)
            return
        }
        if command.hasPrefix("probe ") {
            // One app by bundle id, bound or not.
            let bundleID = String(command.dropFirst(6))
            guard let app = Application(bundleIdentifier: bundleID), app.pid != nil else { return }
            let started = CFAbsoluteTimeGetCurrent()
            let windows = app.getWindows()
            ActivityLog.log("probe \(app.title): \(windows.count) windows, \(ActivityLog.ms(since: started)) ms total")
            for window in windows {
                ActivityLog.log("    [\(window.id)] \(window.title)  \(window.offscreenPlacement.map { "\($0)" } ?? "via AX")")
            }
            return
        }
        if command.hasPrefix("press ") {
            // As if the activate shortcut for this number were pressed (and let go at once).
            NotificationCenter.default.post(name: .reefDebugPress, object: Int(command.dropFirst(6)))
            return
        }
        if command == "probe" {
            // Time the window lookup of every bound app, as a key press would.
            ActivityLog.log("probe")
            for bundleID in (AppDelegate.profileManager.currentProfile?.bindings ?? []).compactMap({ $0 }) {
                guard let app = Application(bundleIdentifier: bundleID), app.pid != nil else { continue }
                let started = CFAbsoluteTimeGetCurrent()
                let count = app.getWindows().count
                ActivityLog.log("  \(app.title): \(count) windows, \(ActivityLog.ms(since: started)) ms total")
            }
            return
        }
        if command.hasPrefix("tree ") {
            tree(bundleIdentifier: String(command.dropFirst(5)))
            return
        }
        guard command == "dump" else { return }

        var out = "AX trusted: \(AXIsProcessTrusted())  screen capture: \(CGPreflightScreenCaptureAccess())\n"
        out += "screens: \(NSScreen.screens.map(\.localizedName))\n\n"

        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        for running in apps {
            let app = Application(running)
            let windows = app.getWindows()
            guard !windows.isEmpty else { continue }

            let started = CFAbsoluteTimeGetCurrent()
            let facts = WindowDetails.facts(for: windows.map(\.element), bundleIdentifier: app.bundleIdentifier)
            let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            let details = WindowDetails.details(for: facts, bundleIdentifier: app.bundleIdentifier)
            let titles = CyclePanelState.displayTitles(for: windows.map(\.title))

            out += "== \(app.title) (\(app.bundleIdentifier ?? "?")) — \(windows.count) windows, \(ms) ms\n"
            for (index, window) in windows.enumerated() {
                let f = facts[index]
                out += "  [\(window.id)] \"\(window.title)\"\(window.offscreenPlacement.map { "  (\($0.label ?? "this desktop, AX silent"))" } ?? "")\n"
                out += "      shown as: \"\(titles[index])\" / \(details[index].text ?? "—")\n"
                out += "      page=\(f.pageTitle ?? "-") url=\(f.url?.absoluteString ?? "-") document=\(f.documentURL?.absoluteString ?? "-") min=\(f.isMinimized) frame=\(f.frame.map { "\($0)" } ?? "-")\n"
                let names = (window.element.attributeNames ?? []).joined(separator: ",")
                out += "      attributes: \(names)\n"
            }
            out += "\n"
        }

        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Reef")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? out.write(to: dir.appendingPathComponent("windows.txt"), atomically: true, encoding: .utf8)
    }
}

extension WindowDetailsDebug {
    /// Writes the element tree of the app's first two windows to ~/Library/Logs/Reef/tree.txt.
    @MainActor
    static func tree(bundleIdentifier: String) {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return }
        let app = Application(running)
        var out = ""
        var visited = 0
        func walk(_ element: AXUIElement, _ depth: Int) {
            guard visited < 2500, depth < 40 else { return }
            visited += 1
            let role = element.value(kAXRoleAttribute) as? String ?? "?"
            let subrole = element.value(kAXSubroleAttribute) as? String
            let title = element.value(kAXTitleAttribute) as? String
            let desc = element.value(kAXDescriptionAttribute) as? String
            let value = element.value(kAXValueAttribute)
            let url = element.value(kAXURLAttribute)
            let doc = element.value(kAXDocumentAttribute)
            var line = String(repeating: "  ", count: depth) + role
            if let subrole { line += "/\(subrole)" }
            if let title, !title.isEmpty { line += " title=\"\(title.prefix(60))\"" }
            if let desc, !desc.isEmpty { line += " desc=\"\(desc.prefix(60))\"" }
            if let value = value as? String, !value.isEmpty { line += " value=\"\(value.prefix(80))\"" }
            if let url { line += " URL=\(url)" }
            if let doc { line += " DOC=\(doc)" }
            if let help = element.value(kAXHelpAttribute) as? String, !help.isEmpty { line += " HELP=\"\(help.prefix(80))\"" }
            if let ident = element.value(kAXIdentifierAttribute) as? String, !ident.isEmpty { line += " ID=\(ident.prefix(40))" }
            if let rd = element.value(kAXRoleDescriptionAttribute) as? String { line += " RD=\(rd)" }
            if let placeholder = element.value(kAXPlaceholderValueAttribute) as? String, !placeholder.isEmpty { line += " PH=\"\(placeholder.prefix(60))\"" }
            if let sel = element.value(kAXSelectedAttribute) as? Bool, sel { line += " SELECTED" }
            out += line + "\n"
            for child in (element.value(kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, depth + 1) }
        }
        for window in app.getWindows().prefix(2) {
            out += "### window \(window.id) \(window.title)\n"
            visited = 0
            walk(window.element, 0)
            out += "(visited \(visited))\n\n"
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Reef")
        try? out.write(to: dir.appendingPathComponent("tree.txt"), atomically: true, encoding: .utf8)
    }
}

private extension AXUIElement {
    var attributeNames: [String]? {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(self, &names) == .success else { return nil }
        return names as? [String]
    }
}
#endif
