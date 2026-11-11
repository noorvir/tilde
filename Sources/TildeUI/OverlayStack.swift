import AppKit

/// The overlay windows of the session: one for each screen above everything, or one on the
/// window that the session is limited to, just above it.
/// Overlay panels are non-activating: the user's app stays frontmost while annotating.
@MainActor
final class OverlayStack {
    private var overlays: [OverlayWindow] = []
    /// The window the overlays are on; nil for one per screen.
    private var window: Int?
    /// Makes an overlay at a frame in AppKit screen coordinates.
    private let makeOverlay: (_ frame: CGRect, _ level: NSWindow.Level, _ isWindowSized: Bool) -> OverlayWindow

    init(makeOverlay: @escaping (_ frame: CGRect, _ level: NSWindow.Level, _ isWindowSized: Bool) -> OverlayWindow) {
        self.makeOverlay = makeOverlay
    }

    var isEmpty: Bool {
        overlays.isEmpty
    }

    var count: Int {
        overlays.count
    }

    /// Puts one overlay on each screen, or one at `frame` (AppKit screen coordinates) on the
    /// window `scoped` names, unless the overlays are that already. Returns whether it made
    /// new ones.
    func layout(on scoped: (window: Int, frame: CGRect)?) -> Bool {
        if !overlays.isEmpty, window == scoped?.window {
            return false
        }
        close()
        window = scoped?.window
        if let scoped {
            // The same level as the window, such as a floating one of Tilde's, so ordering above
            // it works; other apps' windows are normal ones.
            let level = NSApp.window(withWindowNumber: scoped.window)?.level ?? .normal
            overlays = [makeOverlay(scoped.frame, level, true)]
            orderAbove(scoped.window)
        } else {
            overlays = NSScreen.screens.map { makeOverlay($0.frame, OverlayWindow.overlayLevel, false) }
            for overlay in overlays {
                overlay.orderFrontRegardless()
            }
        }
        return true
    }

    func close() {
        for overlay in overlays {
            overlay.parent?.removeChildWindow(overlay)
            overlay.close()
        }
        overlays = []
    }

    /// Whether the overlays take the pointer; without it, they only draw.
    func setTakesInput(_ takesInput: Bool) {
        for overlay in overlays {
            overlay.takesInput = takesInput
        }
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

    /// Moves a window's overlay with its window.
    func setFrame(_ frame: CGRect) {
        if let overlay = overlays.first, overlay.isWindowSized, overlay.frame != frame {
            overlay.setFrame(frame, display: true)
        }
    }

    /// Gives the keyboard to the overlay under the pointer.
    func makeKey() {
        let pointer = NSEvent.mouseLocation
        let overlay = overlays.first { $0.frame.contains(pointer) } ?? overlays.first
        overlay?.makeKey()
    }
}
