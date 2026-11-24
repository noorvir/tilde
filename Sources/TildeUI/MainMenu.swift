import AppKit

/// The app's main menu. Tilde lives in the menu bar, so this shows only while Tilde's
/// browser or Settings is open; its key equivalents make the usual shortcuts work there:
/// editing in text fields (⌘A, ⌘C, ⌘V, ⌘Z), browsing (⌘[, ⌘], ⌘R, ⌘L, zoom) and ⌘W.
@MainActor
enum MainMenu {
    static func make(browser: BrowserController, settings: SettingsWindow) -> NSMenu {
        let menu = NSMenu()

        let app = submenu("Tilde", in: menu)
        app.addItem(withTitle: "About Tilde", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let settingsItem = app.addItem(withTitle: "Settings", action: #selector(SettingsWindow.showGeneral(_:)), keyEquivalent: ",")
        settingsItem.target = settings
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Tilde", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Tilde", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = submenu("Edit", in: menu)
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let view = submenu("View", in: menu)
        for (title, action, key) in [
            ("Back", #selector(BrowserController.goBack(_:)), "["),
            ("Forward", #selector(BrowserController.goForward(_:)), "]"),
            ("Reload Page", #selector(BrowserController.reload(_:)), "r"),
            ("Open Location", #selector(BrowserController.openLocation(_:)), "l"),
            ("Zoom In", #selector(BrowserController.zoomIn(_:)), "+"),
            ("Zoom Out", #selector(BrowserController.zoomOut(_:)), "-"),
            ("Actual Size", #selector(BrowserController.actualSize(_:)), "0"),
        ] {
            view.addItem(withTitle: title, action: action, keyEquivalent: key).target = browser
        }
        let notes = view.addItem(withTitle: "Hide Notes", action: #selector(BrowserController.toggleNotes(_:)), keyEquivalent: "n")
        notes.keyEquivalentModifierMask = [.command, .option]
        notes.target = browser

        let window = submenu("Window", in: menu)
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return menu
    }

    private static func submenu(_ title: String, in menu: NSMenu) -> NSMenu {
        let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        item.submenu = submenu
        return submenu
    }
}
