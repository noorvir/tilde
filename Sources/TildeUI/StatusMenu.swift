import TildeCore
import AppKit
import Combine

/// The menu-bar item: server status, setup commands for agents, permissions.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let server: ServerState
    private let browser: BrowserController
    private let controller: AnnotationController
    private var subscription: AnyCancellable?

    init(server: ServerState, browser: BrowserController, controller: AnnotationController) {
        self.server = server
        self.browser = browser
        self.controller = controller
        super.init()

        item.button?.image = NSImage(systemSymbolName: "pencil.and.scribble", accessibilityDescription: "Tilde")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        subscription = controller.$phase.sink { [weak self] phase in
            self?.item.button?.contentTintColor = phase == .annotating ? .tildeBlue : nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(disabled(statusTitle))
        menu.addItem(.separator())

        if controller.session == nil {
            menu.addItem(action("Start Annotation", #selector(startAnnotation), key: "a"))
        } else {
            let title = controller.isPaused ? "Resume Annotation" : "Pause Annotation"
            menu.addItem(action(title, #selector(togglePause), key: "p"))
            menu.addItem(action("Cancel Annotation", #selector(cancelAnnotation)))
        }
        menu.addItem(.separator())

        menu.addItem(action("Reset HUD Position", #selector(resetHUDPosition)))
        menu.addItem(action("Open Browser", #selector(openBrowser)))
        menu.addItem(action("Open Inbox Folder", #selector(openInbox)))

        let connect = NSMenuItem(title: "Connect an Agent", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (index, setup) in setups.enumerated() {
            let entry = action(setup.title, #selector(copySetup(_:)))
            entry.tag = index
            entry.toolTip = setup.text
            submenu.addItem(entry)
        }
        connect.submenu = submenu
        menu.addItem(connect)

        menu.addItem(.separator())
        menu.addItem(permission("Screen Recording", allowed: ScreenCapture.isAllowed, #selector(openScreenRecordingSettings)))
        menu.addItem(permission("Accessibility", allowed: AXIsProcessTrusted(), #selector(openAccessibilitySettings)))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Tilde", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private var statusTitle: String {
        if let session = controller.session {
            return "Annotating for \(session.client)"
        }
        switch server.status {
        case .starting:
            return "Starting on port \(server.port)"
        case .ready(let port):
            return "Ready · http://127.0.0.1:\(port)/mcp"
        case .failed(let message):
            return "Port \(server.port) unavailable: \(message)"
        }
    }

    // MARK: - Setup commands

    private struct Setup {
        let title: String
        let text: String
    }

    private var setups: [Setup] {
        let url = "http://127.0.0.1:\(server.port)/mcp"
        let shim = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/tilde-mcp").path
        return [
            Setup(title: "Copy Claude Code Command", text: "claude mcp add --scope user --transport http tilde \(url)"),
            Setup(title: "Copy Codex Config (config.toml)", text: "[mcp_servers.tilde]\nurl = \"\(url)\"\ndefault_tools_approval_mode = \"approve\"\n"),
            Setup(title: "Copy JSON Config (HTTP)", text: #"{ "mcpServers": { "tilde": { "url": "\#(url)" } } }"#),
            Setup(title: "Copy JSON Config (stdio)", text: #"{ "mcpServers": { "tilde": { "command": "\#(shim)" } } }"#),
            Setup(title: "Copy SSH Tunnel for Remote Agents", text: "ssh -R \(server.port):127.0.0.1:\(server.port) <host>"),
        ]
    }

    @objc private func copySetup(_ sender: NSMenuItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(setups[sender.tag].text, forType: .string)
    }

    // MARK: - Actions

    @objc private func startAnnotation() {
        controller.startLocal()
    }

    @objc private func togglePause() {
        controller.togglePause()
    }

    @objc private func cancelAnnotation() {
        controller.cancel()
    }

    @objc private func resetHUDPosition() {
        controller.resetHUDPosition()
    }

    @objc private func openBrowser() {
        browser.show()
    }

    @objc private func openInbox() {
        try? FileManager.default.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(inboxRoot)
    }

    @objc private func openScreenRecordingSettings() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: - Items

    /// A `key` shows the matching ⌃⌥ global shortcut from `HotKeys`.
    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        entry.keyEquivalentModifierMask = [.control, .option]
        entry.target = self
        return entry
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func permission(_ name: String, allowed: Bool, _ selector: Selector) -> NSMenuItem {
        if allowed {
            let entry = disabled("\(name): allowed")
            entry.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            return entry
        }
        let entry = action("\(name): not allowed. Open Settings", selector)
        entry.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        return entry
    }
}
