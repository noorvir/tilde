import AppKit
import TildeCore
import SwiftUI

/// Tilde's settings: a sidebar of pages beside cards of rows, in the system's light or dark
/// look. The traffic lights sit over the sidebar; there is no title text.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    enum Page: String, CaseIterable, Identifiable {
        case general
        case agents
        case shortcuts
        case history

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .agents: "Agents"
            case .shortcuts: "Shortcuts"
            case .history: "History"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .agents: "point.3.connected.trianglepath.dotted"
            case .shortcuts: "keyboard.fill"
            case .history: "clock.fill"
            }
        }

        var tint: Color {
            switch self {
            case .general: Color(white: 0.55)
            case .agents: .tildeBlue
            case .shortcuts: Color(white: 0.3)
            case .history: .orange
            }
        }
    }

    private let model: SettingsModel
    private(set) var window: NSWindow?

    init(model: SettingsModel) {
        self.model = model
    }

    @objc func showGeneral(_ sender: Any?) {
        show(.general)
    }

    func show(_ page: Page) {
        model.page = page
        let window = self.window ?? makeWindow()
        self.window = window

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        model.recordingShortcut = nil
        let others = NSApp.windows.contains { $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) }
        if !others {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 805),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Tilde Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentMinSize = NSSize(width: 700, height: 460)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center()
        // The user's own size and place from last time; on a smaller screen, what fits.
        window.setFrameAutosaveName("TildeSettings")
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame, !visible.contains(window.frame) {
            window.setFrame(window.frame.intersection(visible), display: false)
        }
        return window
    }
}

/// What the settings pages show and change.
@MainActor
final class SettingsModel: ObservableObject {
    /// Leaving a page stops a shortcut recording.
    @Published var page: SettingsWindow.Page = .general {
        didSet {
            recordingShortcut = nil
            machinePath = []
        }
    }
    /// The machine whose page is open, on the Agents page.
    @Published var machinePath: [String] = []
    /// The agent rows that show their files.
    @Published var expandedAgents: Set<String> = []
    /// The shortcut that waits for a key press.
    @Published var recordingShortcut: ShortcutStore.Action?
    let setup: AgentSetup
    let shortcuts: ShortcutStore
    let browser: BrowserController
    let history: HistoryModel
    let server: ServerState
    let version: String
    let onResult: (InstallResult) -> Void
    let onResetHUD: () -> Void
    /// The Chromium profiles whose logins Tilde's browser can import.
    let browserProfiles: () -> [ChromiumProfile]
    /// Whether macOS allows Tilde to record the screen and to use Accessibility.
    let permissions: () -> (screenRecording: Bool, accessibility: Bool)

    init(
        setup: AgentSetup, shortcuts: ShortcutStore, browser: BrowserController, history: HistoryModel, server: ServerState, version: String,
        onResult: @escaping (InstallResult) -> Void = { _ in }, onResetHUD: @escaping () -> Void = {},
        browserProfiles: @escaping () -> [ChromiumProfile] = { BrowserCookies.profiles() },
        permissions: @escaping () -> (screenRecording: Bool, accessibility: Bool) = { (ScreenCapture.isAllowed, AXIsProcessTrusted()) }
    ) {
        self.setup = setup
        self.shortcuts = shortcuts
        self.browser = browser
        self.history = history
        self.server = server
        self.version = version
        self.onResult = onResult
        self.onResetHUD = onResetHUD
        self.permissions = permissions
        self.browserProfiles = browserProfiles
    }

    /// "0.1.0 (12)" from the app bundle.
    static var bundleVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        guard let build = info["CFBundleVersion"] as? String else {
            return version
        }
        return "\(version) (\(build))"
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(model: model)
                .frame(width: 185)
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(width: 1)
            ScrollView {
                page
                    .padding(.horizontal, 32)
                    .padding(.top, 24)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(SettingsColors.content)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var page: some View {
        switch model.page {
        case .general:
            GeneralSettings(model: model)
        case .agents:
            if let host = model.machinePath.last {
                MachineSettings(nodes: model.setup.nodes, host: host, expanded: $model.expandedAgents) {
                    model.machinePath.removeLast()
                }
            } else {
                AgentSettings(setup: model.setup, expanded: $model.expandedAgents, onResult: model.onResult) { host in
                    model.machinePath.append(host)
                }
            }
        case .shortcuts:
            ShortcutSettings(shortcuts: model.shortcuts, recording: $model.recordingShortcut)
        case .history:
            HistorySettings(history: model.history)
        }
    }
}

private struct SettingsSidebar: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsWindow.Page.allCases) { page in
                SidebarItem(page: page, isSelected: model.page == page) {
                    model.page = page
                }
            }
            Spacer()
            Text("Tilde \(model.version)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 52)
        .padding(.horizontal, 6)
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity)
        .background(SettingsColors.sidebar)
    }
}

/// A coloured tile with a white symbol, and the page name; the selected row sits on a card.
private struct SidebarItem: View {
    let page: SettingsWindow.Page
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(page.tint.gradient))
                Text(page.title)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 35)
            .background(RoundedRectangle(cornerRadius: 10).fill(background))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var background: Color {
        if isSelected {
            return SettingsColors.selection
        }
        return isHovered ? Color.primary.opacity(0.05) : .clear
    }
}

