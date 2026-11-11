import TildeCore
import TildeInstaller
import AppKit
import Combine

/// The menu-bar item: annotation, the agent apps, the browser and Settings. A missing
/// permission shows as one warning at the top.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let browser: BrowserController
    private let controller: AnnotationController
    private let settings: SettingsWindow
    private let setup: AgentSetup
    private let version: String
    private let onResult: (InstallResult) -> Void
    private var subscription: AnyCancellable?

    init(
        browser: BrowserController, controller: AnnotationController, settings: SettingsWindow,
        setup: AgentSetup, version: String, onResult: @escaping (InstallResult) -> Void
    ) {
        self.browser = browser
        self.controller = controller
        self.settings = settings
        self.setup = setup
        self.version = version
        self.onResult = onResult
        super.init()

        item.button?.image = TildeMark.menuBarImage()
        item.button?.imageScaling = .scaleNone
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        subscription = controller.$flow.sink { [weak self] flow in
            self?.item.button?.contentTintColor = flow.session != nil ? .tildeBlue : nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let warning = permissionWarning() {
            menu.addItem(warning)
            menu.addItem(.separator())
        }

        if controller.session == nil {
            menu.addItem(action("Start Annotation", #selector(startAnnotation), shortcut: .startAnnotation))
        } else {
            // The same commands as the HUD's, named for the mode; a nil action disables an item.
            let pause = pauseItem
            menu.addItem(action(pause.title, pause.works ? #selector(togglePause) : nil, shortcut: .togglePause))
            // Notes keep their own window; only recording mode chooses what it records.
            if controller.isRecordMode {
                menu.addItem(action("Record a Specific Window", controller.accepts(.windowButton) && !controller.isPickingWindow ? #selector(chooseWindow) : nil))
            }
            menu.addItem(action("Cancel Annotation", controller.accepts(.requestCancel) ? #selector(cancelAnnotation) : nil))
        }
        menu.addItem(.separator())

        menu.addItem(agentsItem())
        menu.addItem(historyItem())
        let opensBrowser = controller.session == nil || controller.accepts(.openBrowser)
        menu.addItem(action("Open Browser", opensBrowser ? #selector(openBrowser) : nil))
        let settingsItem = action("Settings", #selector(openSettings))
        settingsItem.keyEquivalent = ","
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let versionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        versionItem.attributedTitle = NSAttributedString(
            string: "Tilde \(version)",
            attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(NSMenuItem(title: "Quit Tilde", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: - History

    /// The last five sessions, each restoring its notes (or showing History when it cannot be
    /// restored), then Show All.
    private func historyItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let records = controller.archive.all().prefix(5)
        if records.isEmpty {
            let none = NSMenuItem(title: "No sessions yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        }
        // Restoring into the session on screen follows the window button's rule.
        let takesRestore = controller.session == nil || controller.accepts(.restore)
        for record in records {
            let count = record.notes.count
            let title = "\(record.title) · \(count) \(count == 1 ? "note" : "notes") · \(record.updated.formatted(date: .abbreviated, time: .shortened))"
            let entry = action(title, #selector(openHistoryEntry(_:)))
            entry.representedObject = record.id
            entry.isEnabled = takesRestore || !restores(record)
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        submenu.addItem(action("Show All", #selector(showHistory)))

        let item = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func openHistoryEntry(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let record = controller.archive.record(id) else {
            return
        }
        if restores(record) {
            controller.restore(record)
        } else {
            showHistory()
        }
    }

    /// Whether an entry restores its notes; else it shows History.
    private func restores(_ record: SessionRecord) -> Bool {
        !record.notes.isEmpty && record.id != controller.session?.id
    }

    @objc private func showHistory() {
        settings.show(.history)
    }

    // MARK: - Agents

    /// One row per agent app on this Mac with its status and icon; each opens Install and
    /// Uninstall.
    private func agentsItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let rows = setup.foundRows
        if rows.isEmpty {
            let none = NSMenuItem(title: "No agent apps found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        }

        for row in rows {
            let status = setup.status(of: row)
            let entry = NSMenuItem(title: row.name, action: nil, keyEquivalent: "")
            entry.image = rowImage(icon: setup.icon(for: row), status: status)

            // The status leads the submenu; a tooltip on the row would cover the submenu.
            let choices = NSMenu()
            choices.autoenablesItems = false
            let line = NSMenuItem(title: status.label, action: nil, keyEquivalent: "")
            line.isEnabled = false
            choices.addItem(line)
            choices.addItem(.separator())
            let install = action(status == .installed ? "Reinstall" : "Install", #selector(install(_:)))
            install.representedObject = row.id
            choices.addItem(install)
            if status != .notInstalled {
                let uninstall = action("Uninstall", #selector(uninstall(_:)))
                uninstall.representedObject = row.id
                choices.addItem(uninstall)
            }
            entry.submenu = choices
            submenu.addItem(entry)
        }

        submenu.addItem(.separator())
        let everywhere = action("Install Everywhere", #selector(installEverywhere))
        everywhere.isEnabled = !rows.isEmpty
        submenu.addItem(everywhere)
        submenu.addItem(action("Manage in Settings", #selector(openAgentSettings)))

        let item = action("Agents", nil)
        item.submenu = submenu
        return item
    }

    /// A 6 pt status dot, then the 16 pt app icon, in one image so every row lines up.
    private func rowImage(icon: NSImage, status: InstallStatus) -> NSImage {
        let color: NSColor
        switch status {
        case .installed: color = .systemGreen
        case .failed: color = .systemRed
        case .notInstalled, .notFound: color = .tertiaryLabelColor
        }
        let image = NSImage(size: NSSize(width: 28, height: 16), flipped: false) { _ in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: 5, width: 6, height: 6)).fill()
            icon.draw(in: NSRect(x: 12, y: 0, width: 16, height: 16))
            return true
        }
        image.accessibilityDescription = status.label
        return image
    }

    private func row(_ sender: NSMenuItem) -> AgentSetup.Row? {
        AgentSetup.rows.first { $0.id == sender.representedObject as? String }
    }

    @objc private func install(_ sender: NSMenuItem) {
        if let row = row(sender) {
            onResult(setup.install([row]))
        }
    }

    @objc private func uninstall(_ sender: NSMenuItem) {
        if let row = row(sender) {
            onResult(setup.uninstall([row]))
        }
    }

    @objc private func installEverywhere() {
        onResult(setup.install(setup.foundRows))
    }

    @objc private func openAgentSettings() {
        settings.show(.home)
    }

    // MARK: - Permissions

    private func permissionWarning() -> NSMenuItem? {
        let missing = [
            ("Screen Recording", ScreenCapture.isAllowed, #selector(openScreenRecordingSettings)),
            ("Accessibility", AXIsProcessTrusted(), #selector(openAccessibilitySettings)),
        ].filter { !$0.1 }
        guard let first = missing.first else {
            return nil
        }
        let names = missing.map(\.0).joined(separator: " and ")
        return action("Allow \(names)", first.2)
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

    // MARK: - Actions

    @objc private func openSettings() {
        settings.show(.home)
    }

    @objc private func startAnnotation() {
        controller.startLocal()
    }

    @objc private func togglePause() {
        controller.dispatch(.togglePause)
    }

    /// The pause command in this mode, and whether it does anything now.
    private var pauseItem: (title: String, works: Bool) {
        let isOpen = if case .open = controller.mode { true } else { false }
        let works = isOpen && controller.accepts(.togglePause)
        guard controller.isRecordMode else {
            return (controller.pauses.contains(.user) ? "Resume Annotation" : "Pause Annotation", works)
        }
        return (controller.recording == .paused ? "Resume Recording" : "Pause Recording", works)
    }

    /// Asks in the HUD first, as × and Esc do, when there is something to lose.
    @objc private func cancelAnnotation() {
        controller.dispatch(.requestCancel)
    }

    /// Opens the browser and annotates only in it.
    @objc private func openBrowser() {
        controller.annotateInBrowser()
    }

    /// Chooses a window or screen, as the HUD's window button does.
    @objc private func chooseWindow() {
        controller.dispatch(.windowButton)
    }

    /// A `shortcut` shows that global shortcut.
    private func action(_ title: String, _ selector: Selector?, shortcut: ShortcutStore.Action? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        // A double tap cannot show as a key equivalent.
        if let shortcut, let keys = controller.shortcuts.shortcut(for: shortcut)?.combo {
            entry.keyEquivalent = keys.keyEquivalent
            entry.keyEquivalentModifierMask = keys.modifierFlags
        }
        return entry
    }
}
