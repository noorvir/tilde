import AppKit

/// The overlay windows of the session: one for each screen above everything, or one on the
/// window that the session is limited to, just above it.
/// Overlay panels are non-activating: the user's app stays frontmost while annotating.
@MainActor
final class OverlayStack {
    /// Whether the overlays take the pointer and the keyboard; without it, they only draw.
    var takesInput = false {
        didSet {
            for overlay in overlays {
                overlay.takesInput = takesInput
            }
        }
    }

    private var overlays: [OverlayWindow] = []
    /// The window the overlays are on; nil for one per screen.
    private var window: Int?
    private let browser: BrowserController
    /// Makes an overlay at a frame in AppKit screen coordinates.
    private let makeOverlay: (_ frame: CGRect, _ level: NSWindow.Level, _ isWindowSized: Bool) -> OverlayWindow

    init(browser: BrowserController, makeOverlay: @escaping (_ frame: CGRect, _ level: NSWindow.Level, _ isWindowSized: Bool) -> OverlayWindow) {
        self.browser = browser
        self.makeOverlay = makeOverlay
    }

    var isEmpty: Bool {
        overlays.isEmpty
    }

    var count: Int {
        overlays.count
    }

    /// Puts one overlay on each screen, or one on `scoped`, the window the session is limited
    /// to, unless the overlays are that already. Returns whether it made new ones.
    func layout(on scoped: ElementPicker.WindowInfo?) -> Bool {
        if !overlays.isEmpty, window == scoped?.number {
            return false
        }
        close()
        window = scoped?.number
        if let scoped {
            // The same level as the window, such as a floating one of Tilde's, so ordering above
            // it works; other apps' windows are normal ones.
            let level = NSApp.window(withWindowNumber: scoped.number)?.level ?? .normal
            overlays = [makeOverlay(frame(on: scoped), level, true)]
            orderAbove(scoped.number)
        } else {
            overlays = NSScreen.screens.map { makeOverlay($0.frame, OverlayWindow.overlayLevel, false) }
            for overlay in overlays {
                overlay.orderFrontRegardless()
            }
        }
        for overlay in overlays {
            overlay.takesInput = takesInput
        }
        return true
    }

    /// Where the overlay of a window goes, in AppKit screen coordinates: on Tilde's browser,
    /// its page only, so the toolbar (with the HUD) and the notes work as usual.
    private func frame(on window: ElementPicker.WindowInfo) -> CGRect {
        if window.number == browser.windowNumber, let page = browser.pageFrame {
            return page
        }
        return window.frame.flipped
    }

    func close() {
        for overlay in overlays {
            overlay.parent?.removeChildWindow(overlay)
            overlay.close()
        }
        overlays = []
    }

    /// Keeps a window's overlay directly above it, so other windows in front of it also cover
    /// the overlay. Tilde's own windows take it as a child window, which AppKit moves with
    /// them and keeps above them.
    func orderAbove(_ window: Int?) {
        guard let window, let overlay = overlays.first, overlay.isWindowSized else {
            return
        }
        if let own = NSApp.window(withWindowNumber: window) {
            if overlay.parent !== own {
                own.addChildWindow(overlay, ordered: .above)
            }
            return
        }
        overlay.order(.above, relativeTo: window)
    }

    /// The window of the overlay moved, or may have come forward over it, such as on a click
    /// in it: the overlay goes where the window is, above it.
    func follow(_ window: ElementPicker.WindowInfo) {
        let frame = frame(on: window)
        if let overlay = overlays.first, overlay.isWindowSized, overlay.frame != frame {
            overlay.setFrame(frame, display: true)
        }
        orderAbove(window.number)
    }

    /// Gives the keyboard to the overlay under the pointer. A window's overlay on a Space that
    /// does not show stays without it: a key window there brings that Space back.
    func makeKey() {
        moveToShownSpace()
        let pointer = NSEvent.mouseLocation
        guard let overlay = overlays.first(where: { $0.frame.contains(pointer) }) ?? overlays.first else {
            return
        }
        if overlay.isWindowSized, !overlay.isOnActiveSpace {
            return
        }
        overlay.makeKey()
    }

    /// A window's overlay made while another Space showed, as when the user chose a window in
    /// full screen from the desktop, is on that Space, and Tilde coming forward would bring that
    /// Space back. A new one takes its place on the Space that shows, when its window is there:
    /// macOS moves no window of `fullScreenAuxiliary` between Spaces.
    func moveToShownSpace() {
        guard let window, let overlay = overlays.first, overlay.isWindowSized, !overlay.isOnActiveSpace, ElementPicker.isOnScreen(window) else {
            return
        }
        let moved = makeOverlay(overlay.frame, overlay.level, true)
        close()
        overlays = [moved]
        moved.takesInput = takesInput
        orderAbove(window)
    }
}
