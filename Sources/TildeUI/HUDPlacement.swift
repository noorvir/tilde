import AppKit

/// Where the session's HUD is: in its floating panel over the screen, or in the toolbar of
/// Tilde's browser while the session is limited to the browser.
@MainActor
final class HUDPlacement: ObservableObject {
    /// Whether the HUD pill is open. HUDPanel animates it, so the pill grows out of its centre
    /// when it appears and collapses into it before the panel hides.
    @Published var isShown = false
    /// The HUD is in the toolbar of Tilde's browser, and the floating HUD is hidden. It stays
    /// there through the Sent confirmation.
    @Published private(set) var isInBrowser = false
    /// The display the floating HUD is on, which its panel keeps up to date as it is placed
    /// and dragged.
    @Published var display: CGDirectDisplayID?
    /// The list of notes shows under the floating HUD.
    @Published var showsList = false

    private let browser: BrowserController
    private let makePanel: () -> HUDPanel
    private lazy var panel = makePanel()

    init(browser: BrowserController, makePanel: @escaping () -> HUDPanel) {
        self.browser = browser
        self.makePanel = makePanel
    }

    /// Puts the HUD where the session is. `inBrowser`: the session is limited to Tilde's
    /// browser, where the HUD stays in the toolbar and the floating panel shows only the
    /// source picker, under the toolbar, while choosing.
    func place(inBrowser: Bool, isPicking: Bool) {
        isInBrowser = inBrowser
        if inBrowser, isPicking, let frame = browser.window?.frame {
            panel.show(top: NSPoint(x: frame.midX, y: frame.maxY - BrowserMetrics.toolbarHeight + 10))
        } else if inBrowser {
            panel.hide()
        } else if !isShown {
            panel.show()
        }
        if isPicking {
            panel.fitPicker()
        } else {
            panel.endPicking()
        }
    }

    /// Brings the HUD forward where it is.
    func show() {
        if isInBrowser {
            browser.show()
        } else {
            panel.show()
        }
    }

    /// Shows the floating panel, also while the pill is in the browser's toolbar: for what
    /// shows under the pill, such as the drawing tools.
    func showPanel() {
        panel.show()
    }

    func hidePanel() {
        panel.hide()
    }

    /// Tilde's browser closes: the HUD floats again. `showing`: it has something to say now,
    /// such as the confirmation after Send.
    func leaveBrowser(showing: Bool) {
        guard isInBrowser else {
            return
        }
        isInBrowser = false
        if showing {
            panel.show()
        }
    }

    func hide() {
        isInBrowser = false
        panel.hide()
    }

    /// Forgets the dragged positions and moves the floating HUD back to the top centre.
    func resetPosition() {
        panel.resetPosition()
    }

    /// Whether an AppKit screen point is over the visible content of the floating HUD.
    func contains(_ point: NSPoint) -> Bool {
        panel.contains(point)
    }
}

#if DEBUG
extension HUDPlacement {
    /// Sets where the HUD is without showing its panel.
    func setStateForTesting(isInBrowser: Bool) {
        self.isInBrowser = isInBrowser
        isShown = true
    }
}
#endif
