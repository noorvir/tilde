import AppKit
import SwiftUI

/// Floating indicator while annotating: status, tools, the bars and cards under the pill, and
/// the list of annotations. It sits at the top centre of the screen with the pointer, unless the user
/// dragged the pill somewhere else on that screen; the position is kept per screen.
///
/// The panel keeps one size and the content sits at its top. Resizing an NSHostingView
/// while SwiftUI changes its content re-centers the content for a frame, which makes the
/// pill jump. Transparent parts of the panel let mouse events through to the overlay.
@MainActor
final class HUDPanel {
    static let motion = Animation.spring(duration: 0.3, bounce: 0)

    let window: NSPanel
    private let hosting: FirstMouseHostingView<HUDView>
    private unowned let controller: AnnotationController
    /// Where the HUD was before the window grid moved it home for its room.
    private var placeBeforeGrid: NSPoint?
    private var screenObserver: Any?
    private lazy var zoom = ZoomPresenter(panel: window) { [controller] isShown in
        controller.hud.isShown = isShown
    }
    /// Drags the pill, snapping it home, and remembers where it was dropped on each screen.
    private lazy var snapDrag = SnapDrag(window: window, outlineCornerRadius: PillMetrics.height / 2, positionsKey: "HUDPositions")
    /// The visible content (the pill and what shows under it) in the panel's SwiftUI coordinates, which
    /// have a top-left origin. The hosting view has no sizing options, so its fitting size
    /// is zero and cannot give this.
    private var contentFrame: CGRect = .zero
    private var clickMonitor: Any?

    /// Room for the widest content (the window grid) and its shadow.
    private static let width: CGFloat = HUDWindowGrid.sizes.max.width + 2 * 16

    init(controller: AnnotationController) {
        self.controller = controller
        hosting = FirstMouseHostingView(rootView: HUDView(controller: controller))
        hosting.sizingOptions = []
        // Not key: clicks on the HUD leave keyboard focus with the overlay for Esc and ⌘↩.
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        // A click on the HUD gives Tilde the keyboard, for Esc and ↩. It does so as the click
        // ends: activating Tilde on the press would close the source menu that the press opens.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak window, weak controller] event in
            if event.window === window {
                MainActor.assumeIsolated { controller?.takeKeyboard() }
            }
            return event
        }
        hosting.rootView = HUDView(controller: controller) { [weak self] in
            self?.dragPill()
        } onContentFrame: { [weak self] frame in
            self?.contentFrame = frame
        }
        // A drag can take the HUD to another screen; Record and the window grid follow it there.
        screenObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenChanged() }
        }
        snapDrag.moved = { [weak self] ended in
            self?.pillMoved(ended: ended)
        }
    }

    /// Shows the HUD on the screen that has the pointer, or with its top centre at `top`.
    func show(top: NSPoint? = nil) {
        place(top: top)
        // Lays the collapsed pill out at its place now. The first time, the hosting view has
        // never been laid out, and its first layout inside the zoom would animate the pill in
        // from the window's left edge.
        hosting.layoutSubtreeIfNeeded()
        zoom.show()
    }

    /// Collapses the pill into its centre, then hides the panel.
    func hide() {
        zoom.hide()
    }

    /// Tells the window grid how much room it has under the pill (or, in Tilde's browser,
    /// under the panel's top) on the panel's screen, so it never leaves the screen. A HUD
    /// too low for the grid goes up to its home while the grid is open, and back after.
    func fitWindowGrid() {
        guard let screen = screen ?? NSScreen.main else {
            return
        }
        if gridRoom(on: screen).height < HUDWindowGrid.sizes.min.height, !controller.hud.isInBrowser, placeBeforeGrid == nil {
            placeBeforeGrid = window.frame.origin
            let home = Self.homeTop(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
            window.setFrameOrigin(NSPoint(x: home.x - window.frame.width / 2, y: home.y - window.frame.height))
        }
        controller.sourcePicker.space = gridRoom(on: screen)
    }

    /// Back where the HUD was before the window grid moved it home.
    func endWindowGrid() {
        if let place = placeBeforeGrid {
            window.setFrameOrigin(place)
            placeBeforeGrid = nil
        }
    }

    /// The window grid's room under the pill where the panel is now.
    private func gridRoom(on screen: NSScreen) -> CGSize {
        let pill = controller.hud.isInBrowser ? 0 : PillMetrics.height + HUDAccessory.gap
        return room(under: window.frame, pill: pill, in: screen.visibleFrame)
    }

    /// While the window grid is open, its room follows a drag of the pill; a drop too low for
    /// it moves the HUD home until the grid closes, then back to the drop.
    private func pillMoved(ended: Bool) {
        screenChanged()
        guard controller.isWindowGridOpen, let screen else {
            return
        }
        if ended {
            fitWindowGrid()
        } else {
            controller.sourcePicker.space = gridRoom(on: screen)
        }
    }

    private func screenChanged() {
        if let display = screen?.displayID, display != controller.hud.display {
            controller.hud.display = display
        }
    }

    /// The screen with the pill. The clear panel is about a screen tall, so most of it can be
    /// on another screen, which `window.screen` would give.
    private var screen: NSScreen? {
        let screens = NSScreen.screens
        return Self.pillScreen(of: window.frame, among: screens.map(\.frame)).map { screens[$0] }
    }

    /// The index of the screen frame with the pill of a panel at `frame`.
    static func pillScreen(of frame: NSRect, among screens: [NSRect]) -> Int? {
        let pill = NSPoint(x: frame.midX, y: frame.maxY - 16 - PillMetrics.height / 2)
        return screens.firstIndex { $0.contains(pill) }
    }

    private func room(under frame: NSRect, pill: CGFloat, in visible: NSRect) -> CGSize {
        let top = frame.maxY - 16 - pill
        let halfWidth = min(frame.midX - visible.minX, visible.maxX - frame.midX) - 16
        return CGSize(width: 2 * halfWidth, height: top - visible.minY - 16)
    }

    /// Forgets the dragged positions and moves the HUD back to the top centre.
    func resetPosition() {
        snapDrag.forgetAll()
        if window.isVisible {
            place()
        }
    }

    /// Puts the panel on the screen with the pointer, at the saved position for that screen,
    /// or at `top`.
    private func place(top given: NSPoint? = nil) {
        placeBeforeGrid = nil
        let point = given ?? NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.screens.first else {
            return
        }

        let home = Self.homeTop(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        let top = given ?? Self.clamped(snapDrag.savedTop(on: screen) ?? home, in: screen.visibleFrame)
        let height = screen.visibleFrame.height + 4
        window.setFrame(NSRect(x: top.x - Self.width / 2, y: top.y - height, width: Self.width, height: height), display: true)
        screenChanged()
    }

    /// Moves the panel with the pointer while the pill is dragged; it snaps to home within
    /// 40 pt, where the outline of the pill shows (below the 16 pt content padding).
    private func dragPill() {
        // The user puts it somewhere else: choosing no longer moves it back.
        placeBeforeGrid = nil
        let height = window.frame.height
        snapDrag.begin { screen in
            let top = Self.homeTop(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
            return NSRect(x: top.x - Self.width / 2, y: top.y - height, width: Self.width, height: height)
        } outlineFrame: { home in
            NSRect(x: home.midX - HUDView.width / 2, y: home.maxY - 16 - PillMetrics.height, width: HUDView.width, height: PillMetrics.height)
        } clamped: { top, visible in
            Self.clamped(top, in: visible)
        }
    }

    /// Top centre of the panel at home: the top centre of the screen's visible area.
    static func homeTop(screenFrame: NSRect, visibleFrame: NSRect) -> NSPoint {
        NSPoint(x: screenFrame.midX, y: visibleFrame.maxY + 4)
    }

    /// Keeps the pill's top centre where the whole pill is inside the screen's visible area.
    static func clamped(_ top: NSPoint, in visible: NSRect) -> NSPoint {
        let halfWidth = HUDView.width / 2 + 16
        let x = min(max(top.x, visible.minX + halfWidth), visible.maxX - halfWidth)
        let y = min(max(top.y, visible.minY + PillMetrics.height + 32), visible.maxY + 4)
        return NSPoint(x: x, y: y)
    }

    /// Whether an AppKit screen point is over the visible HUD content.
    func contains(_ point: NSPoint) -> Bool {
        guard window.isVisible, controller.hud.isShown else {
            return false
        }
        return Self.screenRect(ofContent: contentFrame, inWindow: window.frame).contains(point)
    }

    /// Converts a frame in the panel's SwiftUI space (top-left origin) to AppKit screen
    /// coordinates.
    static func screenRect(ofContent content: CGRect, inWindow frame: NSRect) -> NSRect {
        NSRect(x: frame.minX + content.minX, y: frame.maxY - content.maxY, width: content.width, height: content.height)
    }
}
