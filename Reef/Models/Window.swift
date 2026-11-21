//
//  Window.swift
//  Reef
//
//  Created by Xander Gouws on 12-09-2025.
//

import Foundation
import Cocoa


class Window: Identifiable {
    var id: CGWindowID { cgWindowID ?? 0 }
    var element: AXUIElement
    var cgWindowID: CGWindowID?
    var application: Application
    /// Set for a window outside the spaces on screen (a full-screen app, another
    /// desktop): Accessibility can't reach it, so `element` is only the app's element.
    private(set) var offscreen: Spaces.OffscreenWindow?

    init(_ element: AXUIElement, _ application: Application) {
        self.element = element
        self.cgWindowID = element.getWindowID()
        self.application = application
    }

    init(offscreen window: Spaces.OffscreenWindow, _ application: Application) {
        self.element = application.element ?? AXUIElementCreateApplication(application.pid ?? 0)
        self.cgWindowID = window.id
        self.application = application
        self.offscreen = window
    }

    var isOffscreen: Bool { offscreen != nil }
    /// "Full screen", "Other desktop" or "Minimized" for windows outside the spaces on screen.
    var offscreenPlacement: Spaces.Placement? { offscreen?.placement }
    
    var title: String {
        if let offscreen { return offscreen.title }

        if let title: String = self.element.getAttributeValue(.title) {
            return title
        }
        
        return application.title
    }
    
    func focus() {
        let started = CFAbsoluteTimeGetCurrent()
        // Outside the spaces on screen: ask the window server to bring this exact
        // window forward, which also switches to its space.
        if offscreen != nil {
            if let pid = application.pid, let id = cgWindowID,
               Spaces.focus(windowID: id, pid: pid) {
                ActivityLog.log("  focused \(application.title) [\(id)] by window server in \(ActivityLog.ms(since: started)) ms")
                return
            }
            application.activate()
            ActivityLog.log("  window server refused; activated \(application.title)")
            return
        }

        do {
            try self.element.performAction(.raise)
            self.application.activate()
            ActivityLog.log("  raised \(application.title) [\(id)] in \(ActivityLog.ms(since: started)) ms")
        } catch {
            ActivityLog.log("  raise failed (AX error \(error.rawValue)) after \(ActivityLog.ms(since: started)) ms; reopening \(application.title)")
            try? self.application.reopen()
        }
    }
    
    static func getFrontWindow() -> Window? {
        guard let frontApplication = Application.getFrontApplication() else {
            return nil
        }
        
        if let focusedWindow = frontApplication.getFocusedWindow() {
            return focusedWindow
        }
        
        if let firstWindow = frontApplication.getFirstWindow() {
            return firstWindow
        }
        
        return nil
    }
}
