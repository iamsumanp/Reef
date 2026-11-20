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
            itemCount: state.items.count
        )
    }
    private var panelContentWidth: CGFloat { layout.panelWidth }
    private var thumbnailTask: Task<Void, Never>?
    private var detailsTask: Task<Void, Never>?
    private static let releaseModifierMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    private var minPanelContentHeight: CGFloat {
        // Minimum height that still matches the layout for one row.
        CyclePanelLayout(style: layout.style, showsDetails: layout.showsDetails, showsPreviews: layout.showsPreviews, itemCount: 1).contentHeight
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
    func showSwitcher(for application: Application, startIndex: Int = 0) {
        currentApplication = application
        state.setApplication(application)
        
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

        loadThumbnails()
        loadDetails()
    }

    /// Looks up each window's website / folder / screen in the background; rows get
    /// their second line when it arrives.
    private func loadDetails() {
        detailsTask?.cancel()
        detailsTask = nil

        let windows = state.windows
        guard !windows.isEmpty else { return }

        let ids = windows.map(\.id)
        nonisolated(unsafe) let elements = windows.map(\.element)
        let bundleIdentifier = currentApplication?.bundleIdentifier

        detailsTask = Task { [weak self] in
            let facts = await Task.detached(priority: .userInitiated) {
                WindowDetails.facts(for: elements, bundleIdentifier: bundleIdentifier)
            }.value
            guard !Task.isCancelled, let self else { return }

            let details = WindowDetails.details(for: facts, bundleIdentifier: bundleIdentifier)
            self.state.setDetails(Dictionary(zip(ids, details), uniquingKeysWith: { first, _ in first }))
        }
    }

    /// Captures a fresh preview of every listed window. They appear as they arrive.
    private func loadThumbnails() {
        thumbnailTask?.cancel()
        thumbnailTask = nil

        guard state.showsPreviews else { return }

        let windowIDs = state.windows.map(\.id).filter { $0 != 0 }
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
    
    // Called when user releases a configured switcher modifier.
    func activateSelectedWindow() {
        guard let item = state.currentItem else {
            hideSwitcher()
            return
        }
        
        switch item {
        case .window(let window):
            window.focus()
            hideSwitcher()
        case .action:
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
        thumbnailTask?.cancel()
        thumbnailTask = nil
        detailsTask?.cancel()
        detailsTask = nil
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
        guard panel.isVisible else { return }

        let requiredModifiers = modifierManager.activateModifiers.intersection(Self.releaseModifierMask)
        guard !requiredModifiers.isEmpty else { return }

        let pressedModifiers = modifierFlags.intersection(Self.releaseModifierMask)
        if !requiredModifiers.isSubset(of: pressedModifiers) {
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
