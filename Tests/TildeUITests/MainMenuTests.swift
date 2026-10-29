@testable import TildeUI
import AppKit
import Testing

/// The main menu gives Tilde's browser the usual shortcuts.
@MainActor
struct MainMenuTests {
    @Test func browserAndEditingShortcutsAreInTheMenu() throws {
        let browser = BrowserController()
        let menu = MainMenu.make(browser: browser, settings: SettingsWindow(model: try Fixtures.settingsModel(page: .general)))
        let items = menu.items.flatMap { $0.submenu?.items ?? [] }
        func item(_ key: String) -> NSMenuItem? {
            items.first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == .command }
        }

        #expect(item("a")?.action == #selector(NSText.selectAll(_:)))
        #expect(item("c")?.action == #selector(NSText.copy(_:)))
        #expect(item("[")?.action == #selector(BrowserController.goBack(_:)))
        #expect(item("]")?.action == #selector(BrowserController.goForward(_:)))
        #expect(item("l")?.action == #selector(BrowserController.openLocation(_:)))
        #expect(item("r")?.target === browser)
        #expect(item("w")?.action == #selector(NSWindow.performClose(_:)))

        // Without the browser in front, its commands are off.
        #expect(browser.validateMenuItem(try #require(item("r"))) == false)
    }
}
