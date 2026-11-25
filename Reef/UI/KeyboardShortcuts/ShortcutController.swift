//
//  ShortcutController.swift
//  Reef
//
//  Created by Xander Gouws on 12-09-2025.
//

import KeyboardShortcuts
import Cocoa

let numberKeys: [KeyboardShortcuts.Key] = [
    .zero, .one, .two, .three, .four,
    .five, .six, .seven, .eight, .nine
]

// Numeric-keypad equivalents of `numberKeys`. Numpad keys have distinct virtual
// key codes from the main row (e.g. kVK_ANSI_Keypad0 != kVK_ANSI_0), so they
// must be registered as separate global hotkeys to also fire from the numpad.
let keypadKeys: [KeyboardShortcuts.Key] = [
    .keypad0, .keypad1, .keypad2, .keypad3, .keypad4,
    .keypad5, .keypad6, .keypad7, .keypad8, .keypad9
]

extension KeyboardShortcuts.Name {
    static let bindShortcuts: [KeyboardShortcuts.Name] = (0...9).map { number in
        Self("bind\(number)")
    }
    
    static let activateShortcuts: [KeyboardShortcuts.Name] = (0...9).map { number in
        Self("activate\(number)")
    }
    
    static let profileShortcuts: [KeyboardShortcuts.Name] = (0...9).map { number in
        Self("profile\(number)")
    }

    /// Switcher for apps without a number: the activate modifiers + `.
    static let activateOtherApps = Self("activateOtherApps")

    // Numeric-keypad counterparts registered alongside the main-row shortcuts.
    static let bindKeypadShortcuts: [KeyboardShortcuts.Name] = (0...9).map { number in
        Self("bindKeypad\(number)")
    }

    static let activateKeypadShortcuts: [KeyboardShortcuts.Name] = (0...9).map { number in
        Self("activateKeypad\(number)")
    }

    static let profileKeypadShortcuts: [KeyboardShortcuts.Name] = (0...9).map { number in
        Self("profileKeypad\(number)")
    }
}

@MainActor
final class ShortcutController {
    private let cycleController: CyclePanelController
    private let profileManager: ProfileManager
    
    init(_ cycleController: CyclePanelController, _ profileManager: ProfileManager) {
        self.cycleController = cycleController
        self.profileManager = profileManager
        cycleController.profileManager = profileManager
        
        setupShortcuts()
        #if REEF_DEBUG
        NotificationCenter.default.addObserver(forName: .reefDebugPress, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                switch note.object {
                case let number as Int: self?.handleActivate(number: number)
                case "otherapps" as String: self?.handleOtherApps()
                case "release" as String: self?.cycleController.activateSelectedWindow()
                default: break
                }
            }
        }
        #endif
    }
    
    private func setupShortcuts() {
        KeyboardShortcuts.onKeyDown(for: .activateOtherApps) {
            self.handleOtherApps()
        }

        for number in 0...9 {
            // Register both the main-row and numeric-keypad shortcut for each
            // number so either physical key triggers the same action.
            for name in [KeyboardShortcuts.Name.bindShortcuts[number], .bindKeypadShortcuts[number]] {
                KeyboardShortcuts.onKeyUp(for: name) {
                    self.handleBind(number: number)
                }
            }

            for name in [KeyboardShortcuts.Name.activateShortcuts[number], .activateKeypadShortcuts[number]] {
                KeyboardShortcuts.onKeyDown(for: name) {
                    self.handleActivate(number: number)
                }
            }

            for name in [KeyboardShortcuts.Name.profileShortcuts[number], .profileKeypadShortcuts[number]] {
                KeyboardShortcuts.onKeyDown(for: name) {
                    self.handleProfile(number: number)
                }
            }
        }
    }
    
    private func handleOtherApps() {
        ActivityLog.log("key ` pressed (panel \(cycleController.panel.isVisible ? "up" : "down"), front: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))")
        if cycleController.isActive, cycleController.isShowingOtherApps {
            cycleController.cycleNext()
        } else {
            cycleController.showOtherApps()
        }
    }

    private func handleBind(number: Int) {
        // In the other-apps switcher the bind shortcut binds the selected app (replacing any).
        if cycleController.panel.isVisible, cycleController.isShowingOtherApps {
            cycleController.bindSelectedApp(to: number, replacing: true)
            return
        }

        guard let application = Application.getFrontApplication() else {
            NSSound.beep()
            return
        }

        guard let bundleIdentifier = application.bundleIdentifier else {
            NSSound.beep()
            return
        }

        profileManager.bind(bundleIdentifier: bundleIdentifier, to: number)

        print("Bound \(application.title) to \(number)")
    }
    
    private func handleActivate(number: Int) {
        ActivityLog.log("key \(number) pressed (panel \(cycleController.panel.isVisible ? "up" : "down"), front: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))")
        // In the other-apps switcher, a free number gives the selected app that number.
        if cycleController.panel.isVisible, cycleController.isShowingOtherApps,
           cycleController.bindSelectedApp(to: number, replacing: false) {
            return
        }

        guard let binding = profileManager.application(for: number) else {
            NSSound.beep()
            return
        }
        
        // If panel is already visible (or about to be), cycle if same app; otherwise switch to the newly requested app.
        if cycleController.isActive {
            if cycleController.isShowingSwitcher(for: binding) {
                cycleController.cycleNext()
            } else {
                cycleController.showSwitcher(for: binding, number: number)
            }
            
            return
        }

        // Already in this app: the switcher opens at once, still on the window you're in
        // (the original Reef started on its second window).
        let alreadyInApp = Application.getFrontApplication()?.title == binding.title
        cycleController.showSwitcher(for: binding, number: number, alreadyInApp: alreadyInApp)
    }
    
    func handleProfile(number: Int) {
        guard let profileID = profileManager.profileID(forNumber: number) else {
            NSSound.beep()
            return
        }
        
        profileManager.switchProfile(id: profileID)
    }
}
