//
//  PreferencesGeneralView.swift
//  Reef
//
//  Created by Xander Gouws on 26-01-2026.
//

import SwiftUI
import ServiceManagement
import ApplicationServices

struct PreferencesGeneralView: View {
    @AppStorage("launchOnLogin") private var launchOnLogin = true
//    @AppStorage("hideMenubarIcon") private var hideMenubarIcon = false
    @AppStorage("showActiveProfileInMenuBar") private var showActiveProfileInMenuBar = false
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("defaultNumberOrder") private var defaultNumberOrder = "rightHanded"
    @AppStorage("instantSwitch") private var instantSwitch = "never"
    @AppStorage("switcherPanelDelay") private var switcherPanelDelay = 0.2
    @AppStorage(WindowThumbnailer.preferenceKey) private var showWindowPreviews = true
    @AppStorage(SwitcherStyle.preferenceKey) private var switcherStyle = SwitcherStyle.grid.rawValue
    @AppStorage(CyclePanelState.confirmLaunchKey) private var confirmBeforeLaunch = true
    @AppStorage(OtherApps.preferenceKey) private var otherAppsSwitcher = true
    
    @State private var hasAccessibilityPermission = AXIsProcessTrusted()
    @State private var hasScreenRecordingPermission = WindowThumbnailer.hasPermission

    // Previews are switched on but macOS has not allowed Reef to capture windows yet.
    private var needsScreenRecordingPermission: Bool {
        showWindowPreviews && !hasScreenRecordingPermission
    }

    private var otherAppsLabel: String {
        let keys = AppDelegate.modifierManager?.activateModifierSymbols ?? ""
        return "Switch to apps without a number with \(keys.isEmpty ? "" : keys + " ")`"
    }

    private var formHeight: CGFloat {
        var height: CGFloat = showWindowPreviews ? 372 : 336
        if !hasAccessibilityPermission { height += 70 }
        if needsScreenRecordingPermission { height += 70 }
        return height
    }
    
    // Timer to poll for accessibility permission changes
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        Form {
            // Accessibility Permission Warning
            if !hasAccessibilityPermission {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                        .imageScale(.large)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Accessibility Permission Required")
                            .fontWeight(.medium)
                        Text("System Settings → Privacy & Security → Accessibility")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button("Open Settings") {
                        openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            
            // Screen Recording Permission Warning (only needed for window previews)
            if needsScreenRecordingPermission {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.dashed.badge.record")
                        .foregroundColor(.yellow)
                        .imageScale(.large)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Screen Recording Needed for Window Previews")
                            .fontWeight(.medium)
                        Text("Allow Reef under Screen & System Audio Recording, then relaunch it")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button("Open Settings") {
                        requestScreenRecordingPermission()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Section {
                Toggle("Launch Reef at login", isOn: $launchOnLogin)
                    .onChange(of: launchOnLogin) { _, newValue in
                        setLaunchAtLogin(enabled: newValue)
                    }
            }

            Section {
//                Toggle("Hide menubar icon", isOn: $hideMenubarIcon)
                Toggle("Show active profile in menu bar", isOn: $showActiveProfileInMenuBar)
                Toggle("Show window previews in switcher", isOn: $showWindowPreviews)

                if showWindowPreviews {
                    Picker("Switcher style:", selection: $switcherStyle) {
                        ForEach(SwitcherStyle.allCases) { style in
                            Text(style.title).tag(style.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Toggle("Ask before opening apps that aren't running", isOn: $confirmBeforeLaunch)

                Toggle(otherAppsLabel, isOn: $otherAppsSwitcher)
                    .onChange(of: otherAppsSwitcher) {
                        AppDelegate.modifierManager?.refreshShortcuts()
                    }

                Picker("Instant switch:", selection: $instantSwitch) {
                    Text("Never").tag("never")
                    Text("When only one window open").tag("whenOnlyOneWindowOpen")
                }
                .pickerStyle(.menu)

                Picker("Show the switcher:", selection: $switcherPanelDelay) {
                    Text("Right away").tag(0.0)
                    Text("After a short hold").tag(0.2)
                    Text("After a longer hold").tag(0.4)
                }
                .pickerStyle(.menu)
                .help("A quick tap goes straight to the window you were last on; keep holding the modifier, or press the number again, to see every window.")

                Picker("Default number order:", selection: $defaultNumberOrder) {
                    Text("Right handed (0, 9, ..., 1)").tag("rightHanded")
                    Text("Left handed (1, ..., 9, 0)").tag("leftHanded")
                }
                .pickerStyle(.menu)
            } footer: {
                Text("Number order sets the order in which numbers are displayed in the menubar")
            }
        }
        .formStyle(.grouped)
        .frame(height: formHeight)
        .onReceive(timer) { _ in
            // Poll for permission changes
            hasAccessibilityPermission = AXIsProcessTrusted()
            hasScreenRecordingPermission = WindowThumbnailer.hasPermission
        }
    }

    private func requestScreenRecordingPermission() {
        // The system prompt only ever appears once; after that the switch lives in System Settings.
        if !WindowThumbnailer.requestPermission() {
            WindowThumbnailer.openScreenRecordingSettings()
        }
    }
    
    private func openAccessibilitySettings() {
        // Open System Settings to the Privacy & Security > Accessibility pane
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
    
    private func setLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to \(enabled ? "enable" : "disable") launch at login: \(error)")
                // Revert the toggle if it failed
                DispatchQueue.main.async {
                    launchOnLogin = !enabled
                }
            }
        } else {
            // Legacy API for macOS 12 and earlier
            SMLoginItemSetEnabled(Bundle.main.bundleIdentifier! as CFString, enabled)
        }
    }
}

#Preview {
    PreferencesGeneralView()
}
