//
//  CyclePanelController.swift
//  Reef
//
//  Created by Xander Gouws on 23-01-2026.
//

import AppKit
import SwiftUI


@MainActor
final class CyclePanelController: NSObject {
    private(set) var panel: CyclePanel!
    private let state = CyclePanelState()
    private let modifierManager: ModifierManager
    private var localFlagsMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var keyDownMonitor: Any?
    private var currentApplication: Application?
    private var panelAnchorCenter: CGPoint?
    private var targetScreen: NSScreen?
    /// Set by ShortcutController; used to find apps without a number and to bind them.
    var profileManager: ProfileManager?
    private var footerMessageTask: Task<Void, Never>?
    /// Waiting to show the panel: a quick tap switches without it ever appearing.
    private var pendingPanel: DispatchWorkItem?

    /// Up, or about to be: a press of the same number cycles instead of starting over.
    var isActive: Bool { panel.isVisible || pendingPanel != nil }

    /// How long the modifier has to stay down before the panel appears, from Preferences.
    /// 0 shows it right away, as the original Reef did.
    private static var panelDelay: TimeInterval {
        UserDefaults.standard.object(forKey: "switcherPanelDelay") as? Double ?? 0.2
    }

    var isShowingOtherApps: Bool { state.mode == .otherApps }

    /// 1…9 then 0, as on the keyboard.
    private static let keyboardNumberOrder = Array(1...9) + [0]

    private static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private let maxPanelFrameHeightCap: CGFloat = 620

    // Shared with CyclePanelView through CyclePanelLayout.
    private var layout: CyclePanelLayout {
        CyclePanelLayout(
            style: SwitcherStyle.current,
            showsDetails: !state.windows.isEmpty,
            showsPreviews: state.showsPreviews,
            itemCount: state.layoutItemCount,
            showsLaunchPrompt: state.launchPrompt != nil,
            showsFooter: state.mode == .otherApps
        )
    }
    private var panelContentWidth: CGFloat { layout.panelWidth }
    private var thumbnailTask: Task<Void, Never>?
    private var detailsTask: Task<Void, Never>?
    private static let releaseModifierMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    private var minPanelContentHeight: CGFloat {
        // Minimum height that still matches the layout for one row.
        CyclePanelLayout(style: layout.style, showsDetails: layout.showsDetails, showsPreviews: layout.showsPreviews, itemCount: 1, showsLaunchPrompt: layout.showsLaunchPrompt, showsFooter: layout.showsFooter).contentHeight
    }
    
    init(modifierManager: ModifierManager) {
        self.modifierManager = modifierManager
        super.init()
        createPanel()
    }
    
    private func createPanel() {
        let contentRect = NSRect(x: 0, y: 0, width: 400, height: 300)
        panel = CyclePanel(contentRect: contentRect)
        
        let contentView = CyclePanelView(state: state)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        
        guard let containerView = panel.contentView else { return }
        containerView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
    }
    
    // Called when user presses the configured window-switching shortcut.
    func showSwitcher(for application: Application, startIndex: Int = 0, number: Int? = nil) {
        currentApplication = application
        let started = CFAbsoluteTimeGetCurrent()
        state.setApplication(application)
        ActivityLog.log("  switcher for \(application.title): \(state.items.count) items, built in \(ActivityLog.ms(since: started)) ms")

        // An app that is not running is only launched after its number is pressed again.
        if CyclePanelState.confirmsLaunch, let number,
           case .action(.launchApp) = state.currentItem {
            state.launchPrompt = .init(key: "\(number)", modifiers: modifierManager.activateModifierSymbols)
        }
        
        // Instant switch if the user opted in and there is one actual window
        if UserDefaults.standard.string(forKey: "instantSwitch") == "whenOnlyOneWindowOpen",
           state.items.count == 1,
           case .window = state.currentItem {
            activateSelectedWindow()
            return
        }
        
        // If starting index is provided (e.g., already on that app), use it
        if startIndex > 0 && startIndex < state.items.count {
            state.selectedIndex = startIndex
        }

        // A launch prompt waits for a second press, so it shows even after letting go.
        if state.launchPrompt == nil, switchIfModifierAlreadyReleased() { return }

        showPanel(delayed: state.launchPrompt == nil)
    }

    /// Shows the panel, or after a short hold: letting go of the modifier before then
    /// switches to the selected window with no panel at all.
    private func showPanel(delayed: Bool) {
        pendingPanel?.cancel()
        pendingPanel = nil
        let delay = Self.panelDelay
        guard delayed, delay > 0, !panel.isVisible else {
            presentPanel()
            loadThumbnails()
            loadDetails()
            return
        }

        installFlagsMonitor()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pendingPanel != nil else { return }
            self.pendingPanel = nil
            ActivityLog.log("  held; showing the panel")
            self.presentPanel()
            self.loadThumbnails()
            self.loadDetails()
        }
        pendingPanel = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// A slow window lookup (an app that sat idle for hours and has to wake up) can
    /// take longer than the key press. The modifier was then let go before the panel
    /// and its release monitor existed, so the panel would sit there waiting for a
    /// release that already happened. Check the keys as they are now instead.
    private func switchIfModifierAlreadyReleased() -> Bool {
        guard !panel.isVisible else { return false }
        let required = modifierManager.activateModifiers.intersection(Self.releaseModifierMask)
        guard !required.isEmpty,
              !required.isSubset(of: NSEvent.modifierFlags.intersection(Self.releaseModifierMask))
        else { return false }

        ActivityLog.log("  modifier already released before the panel appeared; switching")
        activateSelectedWindow()
        return true
    }

    /// Shows the panel (or resizes it if it is already up) in the middle of the screen.
    private func presentPanel() {
        if !panel.isVisible {
            // The exact middle of the screen the mouse is on. (NSWindow.center() sits
            // the window in the upper third, and always on the main screen.)
            let screen = Self.screenUnderMouse()
            targetScreen = screen
            if let visibleFrame = screen?.visibleFrame {
                panelAnchorCenter = CGPoint(x: visibleFrame.midX, y: visibleFrame.midY)
            } else {
                panel.center()
                panelAnchorCenter = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
            }
            updatePanelSize()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            installFlagsMonitor()
            installKeyDownMonitor()
        } else {
            if panelAnchorCenter == nil {
                panelAnchorCenter = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
            }
            updatePanelSize()
        }
    }

    // MARK: - Other apps (⌥ + `)

    /// Shows the windows of every running app that has no number in the current profile.
    func showOtherApps() {
        let profile = profileManager?.currentProfile
        let bound = Set((profile?.bindings ?? []).compactMap { $0 })
        // Read before Reef comes to the front: the window the user is in right now.
        let frontWindowID = Window.getFrontWindow()?.id

        let started = CFAbsoluteTimeGetCurrent()
        let result = OtherApps.collect(excludingBundleIdentifiers: bound)
        ActivityLog.log("  other apps: \(result.windows.count) windows listed in \(ActivityLog.ms(since: started)) ms")
        guard !result.isEmpty else {
            NSSound.beep()
            return
        }

        currentApplication = nil
        state.setOtherApps(result)
        state.modifierSymbols = modifierManager.activateModifierSymbols
        state.freeNumbers = Self.keyboardNumberOrder.filter { profile?.bundleIdentifier(for: $0) == nil }

        // Like ⌘-Tab: the first press goes to the window before the current one.
        if state.items.count > 1, case let .window(first) = state.items[0], first.id == frontWindowID {
            state.selectedIndex = 1
        }

        if switchIfModifierAlreadyReleased() { return }

        showPanel(delayed: true)
    }

    /// Gives the selected card's app a number. Without `replacing`, only free numbers are
    /// used, so a slip of the finger never moves another app off its number.
    @discardableResult
    func bindSelectedApp(to number: Int, replacing: Bool) -> Bool {
        guard isShowingOtherApps,
              let profileManager,
              let app = state.currentApplication,
              let bundleIdentifier = app.bundleIdentifier
        else { return false }

        if !replacing, profileManager.bundleIdentifier(for: number) != nil {
            return false
        }

        profileManager.bind(bundleIdentifier: bundleIdentifier, to: number)
        state.freeNumbers = Self.keyboardNumberOrder.filter { profileManager.bundleIdentifier(for: $0) == nil }
        showFooterMessage("\(app.title) is now on \(state.modifierSymbols) \(number)")
        return true
    }

    private func showFooterMessage(_ message: String) {
        footerMessageTask?.cancel()
        state.footerMessage = message
        footerMessageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.state.footerMessage = nil
        }
    }

    /// Typing, arrows, Return and Backspace in the other-apps switcher. Returns true when used.
    private func handleOtherAppsKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36, 76: // Return, Enter
            activateSelectedWindow(force: true)
            return true
        case 123: // ←
            state.movePrevious()
            return true
        case 124: // →
            state.cycleNext()
            return true
        case 126: // ↑ one row up in the grid, else one item
            state.move(by: -(layout.effectiveStyle == .grid ? layout.gridColumns : 1))
            return true
        case 125: // ↓
            state.move(by: layout.effectiveStyle == .grid ? layout.gridColumns : 1)
            return true
        case 48: // Tab / ⇧Tab
            event.modifierFlags.contains(.shift) ? state.movePrevious() : state.cycleNext()
            return true
        case 51: // Backspace
            guard !state.filterText.isEmpty else { return true }
            state.filterText.removeLast()
            state.applyFilter()
            return true
        default:
            break
        }

        // ⌥ changes what letters type (⌥w = ∑), so read the key itself.
        guard let characters = event.charactersIgnoringModifiers?.lowercased(),
              let character = characters.first,
              characters.count == 1
        else { return false }

        // Once Reef is sticky (the user let go of ⌥), plain digits give a number.
        if state.isSticky, let digit = character.wholeNumberValue {
            if !bindSelectedApp(to: digit, replacing: false) { NSSound.beep() }
            return true
        }

        guard character.isLetter || character.isNumber || character == " " || character == "." || character == "-" else {
            return false
        }

        state.filterText.append(character)
        state.isSticky = true
        state.applyFilter()
        return true
    }

    /// Looks up each window's website / folder / screen in the background; rows get
    /// their second line when it arrives.
    private func loadDetails() {
        detailsTask?.cancel()
        detailsTask = nil

        let allWindows = state.windows
        guard !allWindows.isEmpty else { return }

        // Windows outside the spaces on screen can't be asked; their line says where they are.
        let offscreenDetails = Dictionary(uniqueKeysWithValues: allWindows.compactMap { window in
            window.offscreenPlacement.map { (window.id, WindowDetail(location: nil, placement: $0.label)) }
        })
        let windows = allWindows.filter { !$0.isOffscreen }
        guard !windows.isEmpty else {
            state.setDetails(offscreenDetails)
            return
        }

        // One lookup per app: the rules differ (browser, Finder, documents).
        let groups = Dictionary(grouping: windows) { $0.application.bundleIdentifier ?? "pid\($0.application.pid ?? 0)" }
            .map { _, appWindows in
                (bundleIdentifier: appWindows[0].application.bundleIdentifier,
                 ids: appWindows.map(\.id),
                 elements: appWindows.map(\.element))
            }
        nonisolated(unsafe) let work = groups

        detailsTask = Task { [weak self] in
            let facts = await Task.detached(priority: .userInitiated) {
                work.map { WindowDetails.facts(for: $0.elements, bundleIdentifier: $0.bundleIdentifier) }
            }.value
            guard !Task.isCancelled, let self else { return }

            var all = offscreenDetails
            for (group, groupFacts) in zip(work, facts) {
                let details = WindowDetails.details(for: groupFacts, bundleIdentifier: group.bundleIdentifier)
                for (id, detail) in zip(group.ids, details) { all[id] = detail }
            }
            self.state.setDetails(all)
            if self.state.mode == .otherApps, !self.state.filterText.isEmpty {
                self.state.applyFilter()   // websites and folders are searchable too
            }
        }
    }

    /// Captures a fresh preview of every listed window. They appear as they arrive.
    private func loadThumbnails() {
        thumbnailTask?.cancel()
        thumbnailTask = nil

        guard state.showsPreviews else { return }

        let windowIDs = state.previewWindowIDs.filter { $0 != 0 }
        let scale = (targetScreen ?? panel.screen ?? NSScreen.main)?.backingScaleFactor ?? 2

        thumbnailTask = Task { [weak self] in
            await WindowThumbnailer.shared.captureThumbnails(
                for: windowIDs,
                fitting: CyclePanelLayout.captureSize,
                scale: scale
            ) { windowID, image in
                guard !Task.isCancelled else { return }
                self?.state.setThumbnail(image, for: windowID)
            }
        }
    }

    private func updatePanelSize() {
        let desiredContentHeight = layout.contentHeight

        let maxContentHeightByScreen: CGFloat = {
            let visibleFrameHeight = (targetScreen ?? panel.screen ?? NSScreen.main)?.visibleFrame.height ?? maxPanelFrameHeightCap
            let maxFrameHeight = min(maxPanelFrameHeightCap, visibleFrameHeight * 0.6)
            let maxFrameRect = NSRect(x: 0, y: 0, width: panelContentWidth, height: maxFrameHeight)
            return panel.contentRect(forFrameRect: maxFrameRect).height
        }()

        let clampedContentHeight = max(minPanelContentHeight, min(desiredContentHeight, maxContentHeightByScreen))
        let targetContentRect = NSRect(x: 0, y: 0, width: panelContentWidth, height: clampedContentHeight)
        let targetFrameSize = panel.frameRect(forContentRect: targetContentRect).size

        // Keep the panel pinned to the same center while the switcher shortcut is held.
        let center = panelAnchorCenter ?? CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let newOrigin = CGPoint(
            x: center.x - targetFrameSize.width / 2,
            y: center.y - targetFrameSize.height / 2
        )
        let newFrame = NSRect(origin: newOrigin, size: targetFrameSize)

        panel.setFrame(newFrame, display: true, animate: false)
    }
    
    // Called when user presses the switcher shortcut again while panel is visible.
    func cycleNext() {
        // Pressing the number again is the "yes, open it".
        if state.launchPrompt != nil {
            state.launchPrompt = nil
            activateSelectedWindow()
            return
        }
        // A second press before the panel appeared only brings it up, still on the window
        // last used: pressing twice to open the switcher is a habit, not a step forward.
        if pendingPanel != nil {
            showPanel(delayed: false)
            return
        }
        state.cycleNext()
    }
    
    func isShowingSwitcher(for application: Application) -> Bool {
        guard let currentApplication else { return false }
        
        if let currentBundleID = currentApplication.bundleIdentifier,
           let targetBundleID = application.bundleIdentifier {
            return currentBundleID == targetBundleID
        }
        
        if let currentURL = currentApplication.bundleUrl,
           let targetURL = application.bundleUrl {
            return currentURL == targetURL
        }
        
        return currentApplication.title == application.title
    }
    
    // Called when user releases a configured switcher modifier (or presses Return).
    func activateSelectedWindow(force: Bool = false) {
        // After typing a filter, letting go of the modifier doesn't switch; Return does.
        if state.isSticky, !force { return }

        guard let item = state.currentItem else {
            hideSwitcher()
            return
        }
        
        switch item {
        case .window(let window):
            window.focus()
            hideSwitcher()

        case .action:
            // Letting go without confirming cancels the launch.
            if state.launchPrompt != nil {
                hideSwitcher()
                return
            }

            let application = currentApplication
            hideSwitcher()
            
            Task { @MainActor in
                guard let application else {
                    NSSound.beep()
                    return
                }
                
                let success = await application.performNoWindowAction()
                if !success {
                    NSSound.beep()
                }
            }
        }
    }
    
    private func hideSwitcher() {
        pendingPanel?.cancel()
        pendingPanel = nil
        thumbnailTask?.cancel()
        thumbnailTask = nil
        detailsTask?.cancel()
        detailsTask = nil
        footerMessageTask?.cancel()
        footerMessageTask = nil
        removeFlagsMonitor()
        removeKeyDownMonitor()
        panel.orderOut(nil)
        state.reset()
        currentApplication = nil
        panelAnchorCenter = nil
        targetScreen = nil
    }
    
    private func installFlagsMonitor() {
        guard localFlagsMonitor == nil, globalFlagsMonitor == nil else { return }
        
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self else { return event }
            
            self.activateIfSwitcherModifierWasReleased(event.modifierFlags)
            
            return event
        }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.activateIfSwitcherModifierWasReleased(event.modifierFlags)
            }
        }
    }

    private func activateIfSwitcherModifierWasReleased(_ modifierFlags: NSEvent.ModifierFlags) {
        guard isActive else { return }

        let requiredModifiers = modifierManager.activateModifiers.intersection(Self.releaseModifierMask)
        guard !requiredModifiers.isEmpty else { return }

        let pressedModifiers = modifierFlags.intersection(Self.releaseModifierMask)
        if !requiredModifiers.isSubset(of: pressedModifiers) {
            ActivityLog.log(panel.isVisible ? "  modifier released" : "  modifier released before the panel; switching")
            activateSelectedWindow()
        }
    }
    
    private func removeFlagsMonitor() {
        if let monitor = localFlagsMonitor {
            NSEvent.removeMonitor(monitor)
            localFlagsMonitor = nil
        }

        if let monitor = globalFlagsMonitor {
            NSEvent.removeMonitor(monitor)
            globalFlagsMonitor = nil
        }
    }

    private func installKeyDownMonitor() {
        guard keyDownMonitor == nil else { return }

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // Escape closes the switcher.
            if self.panel.isVisible, event.keyCode == 53 {
                Task { @MainActor in
                    self.hideSwitcher()
                }
                return nil
            }

            if self.panel.isVisible, self.isShowingOtherApps {
                let handled = MainActor.assumeIsolated { self.handleOtherAppsKey(event) }
                if handled {
                    MainActor.assumeIsolated { self.updatePanelSize() }
                    return nil
                }
            }

            return event
        }
    }

    private func removeKeyDownMonitor() {
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
            keyDownMonitor = nil
        }
    }
    
    deinit {
        // Capture the monitor in a local variable before deinit (while still on main actor)
        let localMonitor = localFlagsMonitor
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }

        let globalMonitor = globalFlagsMonitor
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }

        let keyMonitor = keyDownMonitor
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }
}
