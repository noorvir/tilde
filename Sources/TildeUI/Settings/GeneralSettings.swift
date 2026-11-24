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

    var body: some View {
        let permissions = model.permissions()

        VStack(alignment: .leading, spacing: 28) {
            SettingsSection("Application") {
                SettingsRow(title: "Launch at login", subtitle: launchError, subtitleIsError: launchError != nil) {
                    SettingsToggle("Launch at login", isOn: $launchesAtLogin)
                        .onChange(of: launchesAtLogin) { _, isOn in
                            setLaunchAtLogin(isOn)
                        }
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

            BrowserSettings(browser: model.browser, browsers: model.cookieBrowsers)

            SettingsSection("HUD") {
                SettingsRow(title: "Position", subtitle: "Back to the top centre of each screen") {
                    Button("Reset", action: model.onResetHUD)
                }
            }

            UpdateSettings(updates: model.updates, version: model.version)

            BetaSettings(nodes: model.setup.nodes, wireframes: model.wireframes)
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

/// Features that are off until the user turns them on; each shows at once.
private struct BetaSettings: View {
    @ObservedObject var nodes: NodeSetup
    @ObservedObject var wireframes: WireframeSwitch

    var body: some View {
        SettingsSection("Beta features") {
            SettingsRow(title: "Remote machines", subtitle: "Agents on a linked machine can open Tilde on this screen") {
                SettingsToggle("Remote machines", isOn: Binding { nodes.isEnabled } set: { nodes.setEnabled($0) })
            }
            SettingsDivider()
            SettingsRow(title: "Wireframes", subtitle: "Sketch components over the screen and send them as one note") {
                SettingsToggle("Wireframes", isOn: Binding { wireframes.isOn } set: { wireframes.set($0) })
            }
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

/// Tilde's browser: import a browser profile's cookies, offer the browser for pages of other
/// browsers, or clear its data.
private struct BrowserSettings: View {
    @ObservedObject var browser: BrowserController
    let browsers: () -> [CookieBrowser]
    @State private var choice: [CookieBrowser]?
    @State private var asksToClear = false
    @AppStorage("BrowserImport.summary") private var lastImport = ""
    @AppStorage(BrowserOffer.enabledKey) private var offersBrowser = true
    @AppStorage(LoginImportBar.enabledKey) private var offersImport = true

    var body: some View {
        SettingsSection("Browser") {
            SettingsRow(title: "Import logins", subtitle: lastImport.isEmpty ? "Cookies from a browser on this Mac, so pages open signed in" : lastImport) {
                Button("Import") {
                    choice = browsers()
                }
            }
            SettingsDivider()
            SettingsRow(title: "Offer to import logins", subtitle: "A bar in Tilde's browser until logins are imported") {
                SettingsToggle("Offer to import logins", isOn: $offersImport)
            }
            // Not while the page is in Tilde's browser already.
            if browser.pageURL == nil {
                SettingsDivider()
                SettingsRow(title: "Offer Tilde's browser", subtitle: "For a note on a page in another browser") {
                    SettingsToggle("Offer Tilde's browser", isOn: $offersBrowser)
                }
            }
            SettingsDivider()
            SettingsRow(title: "Browser data", subtitle: "Cookies, logins and cache of Tilde's browser") {
                Button("Clear") {
                    asksToClear = true
                }
            }
        }
        .sheet(item: Binding(get: { choice.map(BrowserChoice.init) }, set: { choice = $0?.browsers })) { item in
            ImportSheet(browsers: item.browsers, browser: browser) { summary in
                if let summary {
                    lastImport = summary
                }
                choice = nil
            }
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
}

struct BrowserChoice: Identifiable {
    let browsers: [CookieBrowser]
    var id: [String] { browsers.map(\.id) }
}

/// The import: a browser on this Mac, then one of its profiles. Safari asks for Full Disk
/// Access first.
struct ImportSheet: View {
    let browsers: [CookieBrowser]
    let browser: BrowserController
    /// The result line, or nil when cancelled.
    let onDone: (String?) -> Void
    @State private var selected: CookieBrowser?
    @State private var profile: CookieProfile?
    /// The import under way; Cancel stops it before the cookies go to the browser.
    @State private var importing: Task<Void, Never>?
    @State private var error: String?

    private var isImporting: Bool {
        importing != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Import logins").font(.headline)
            Text("Tilde's browser gets this profile's cookies. Your browser stays as it is.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if browsers.isEmpty {
                Text("No browser with logins found on this Mac.").foregroundStyle(.secondary).padding(.vertical, 12)
            }
            ForEach(browsers) { item in
                row(item)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    importing?.cancel()
                    onDone(nil)
                }
                    .keyboardShortcut(.cancelAction)
                Button(action: importLogins) {
                    // While importing, a spinner takes the label's place at the same width.
                    ZStack {
                        Text("Import").opacity(isImporting ? 0 : 1)
                        if isImporting {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(profile == nil || selected?.needsFullDiskAccess != false || isImporting)
                .accessibilityLabel("Import")
            }
            .padding(.top, 10)
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            choose(browsers.first { !$0.needsFullDiskAccess } ?? browsers.first)
        }
    }

    private func row(_ item: CookieBrowser) -> some View {
        let isSelected = selected == item
        return HStack(spacing: 12) {
            Image(nsImage: icon(item)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                Text(detail(item)).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if item.needsFullDiskAccess {
                Button("Grant") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
            } else if isSelected, item.profiles.count > 1 {
                Picker("Profile", selection: $profile) {
                    ForEach(item.profiles, id: \.self) { profile in
                        Text(profile.name).tag(Optional(profile))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.accentColor.opacity(0.08) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25)))
        .contentShape(Rectangle())
        .onTapGesture { choose(item) }
    }

    private func detail(_ item: CookieBrowser) -> String {
        if item.needsFullDiskAccess {
            return "Needs Full Disk Access for Tilde"
        }
        return item.profiles.count == 1 ? item.profiles[0].name : "\(item.profiles.count) profiles"
    }

    private func icon(_ item: CookieBrowser) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleID) else {
            return NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func choose(_ item: CookieBrowser?) {
        selected = item
        profile = item?.profiles.first
        error = nil
    }

    /// Reads the profile's cookies off the main thread (macOS may ask for the Keychain
    /// password), then adds them to the browser. Only counts are kept. The spinner shows for
    /// at least a second.
    private func importLogins() {
        guard let profile else {
            return
        }
        error = nil
        importing = Task {
            let spinner = SpinnerTime()
            defer { importing = nil }
            do {
                let result = try await Task.detached { try BrowserCookies.cookies(of: profile) }.value
                try Task.checkCancellation()
                await browser.add(result.cookies)
                await spinner.waitForMinimum()
                let time = Date().formatted(date: .abbreviated, time: .shortened)
                onDone("✓ \(result.cookies.count) cookies from \(profile.title), \(time)")
            } catch is CancellationError {
                return
            } catch {
                self.error = "Could not import: \(error)"
            }
        }
    }
}
