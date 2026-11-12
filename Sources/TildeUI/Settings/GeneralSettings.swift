import TildeCore
import ServiceManagement
import SwiftUI

struct GeneralSettings: View {
    @ObservedObject var model: SettingsModel
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    private var address: String {
        "http://127.0.0.1:\(model.server.port)/mcp"
    }

    @AppStorage("drawingSnaps") private var snapsDrawings = true

    var body: some View {
        let permissions = model.permissions()

        VStack(alignment: .leading, spacing: 28) {
            SettingsSection("Application") {
                SettingsRow(title: "Launch at login", subtitle: launchError, subtitleIsError: launchError != nil) {
                    Toggle("Launch at login", isOn: $launchesAtLogin)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .tint(Color.tildeBlue)
                        .labelsHidden()
                        .onChange(of: launchesAtLogin) { _, isOn in
                            setLaunchAtLogin(isOn)
                        }
                }
                SettingsDivider()
                SettingsRow(title: "Snap drawings to elements", subtitle: "Hold ⌘ while drawing to draw freely") {
                    Toggle("Snap drawings to elements", isOn: $snapsDrawings)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .tint(Color.tildeBlue)
                        .labelsHidden()
                }
                SettingsDivider()
                PermissionRow(title: "Screen Recording", subtitle: "Screenshots of any app", isAllowed: permissions.screenRecording) {
                    CGRequestScreenCaptureAccess()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                SettingsDivider()
                PermissionRow(title: "Accessibility", subtitle: "Element details in native apps", isAllowed: permissions.accessibility) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }

            SettingsSection("Connection") {
                SettingsRow(title: "MCP server", subtitle: statusText, subtitleCode: address) {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(address, forType: .string)
                    }
                }
                SettingsDivider()
                SettingsRow(title: "Feedback inbox", subtitleCode: tildePath(inboxRoot)) {
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(inboxRoot)
                    }
                }
            }

            BrowserSettings(browser: model.browser, profiles: model.browserProfiles())

            SettingsSection("HUD") {
                SettingsRow(title: "Position", subtitle: "Back to the top centre of each screen") {
                    Button("Reset", action: model.onResetHUD)
                }
            }
        }
    }

    private var statusText: String {
        switch model.server.status {
        case .starting: "Starting"
        case .ready: "Running"
        case .failed: "Port in use"
        }
    }

    private func setLaunchAtLogin(_ isOn: Bool) {
        do {
            if isOn {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = "Could not change: \(error.localizedDescription)"
        }
    }
}

/// A permission with a check when macOS allows it, and a button while it does not.
private struct PermissionRow: View {
    let title: String
    let subtitle: String
    let isAllowed: Bool
    let openSettings: () -> Void

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            SetupStatus(state: isAllowed ? .ok : .action("Grant"), action: openSettings)
        }
    }
}

/// Logins for Tilde's browser: import a Chromium profile's cookies, or clear the browser.
private struct BrowserSettings: View {
    let browser: BrowserController
    let profiles: [ChromiumProfile]
    @State private var profile: ChromiumProfile?
    @State private var isImporting = false
    @State private var error: String?
    @State private var asksToClear = false
    @AppStorage("BrowserImport.summary") private var lastImport = ""

    var body: some View {
        SettingsSection("Browser") {
            SettingsRow(title: "Import logins", subtitle: subtitle, subtitleIsError: error != nil) {
                HStack(spacing: 10) {
                    if profiles.count > 1 {
                        Picker("Profile", selection: $profile) {
                            ForEach(profiles, id: \.self) { profile in
                                Text(profile.title).tag(Optional(profile))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Button(action: importLogins) {
                        // While importing, a spinner takes the label's place at the same width.
                        ZStack {
                            Text("Import").opacity(isImporting ? 0 : 1)
                            if isImporting {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(profiles.isEmpty || isImporting)
                    .accessibilityLabel("Import")
                }
            }
            SettingsDivider()
            SettingsRow(title: "Browser data", subtitle: "Cookies, logins and cache of Tilde's browser") {
                Button("Clear") {
                    asksToClear = true
                }
            }
        }
        .onAppear {
            profile = profile ?? profiles.first
        }
        .confirmationDialog("Clear Tilde's browser data?", isPresented: $asksToClear) {
            Button("Clear", role: .destructive) {
                Task {
                    await browser.clearData()
                    lastImport = ""
                }
            }
        } message: {
            Text("You will be logged out of every site in Tilde's browser.")
        }
    }

    private var subtitle: String {
        if let error {
            return error
        }
        if profiles.isEmpty {
            return "No Chrome, Arc, Brave or Edge profile found"
        }
        if !lastImport.isEmpty {
            return lastImport
        }
        return "From \(profile?.browser.name ?? "Chrome") into Tilde's browser. Stays on this Mac."
    }

    /// Reads the profile's cookies off the main thread (macOS may ask for the Keychain
    /// password), then adds them to the browser. Only counts are kept.
    private func importLogins() {
        guard let profile else {
            return
        }
        isImporting = true
        error = nil
        Task {
            defer { isImporting = false }
            do {
                let result = try await Task.detached { try BrowserCookies.cookies(of: profile) }.value
                await browser.add(result.cookies)
                let time = Date().formatted(date: .abbreviated, time: .shortened)
                lastImport = "\(result.cookies.count) cookies from \(profile.title), \(time)"
            } catch {
                self.error = "Could not import: \(error)"
            }
        }
    }
}
