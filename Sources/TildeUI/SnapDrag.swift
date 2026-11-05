import AppKit

/// Moves a panel with the pointer, as the HUD and the preview do. While it moves, a dotted
/// outline shows its home frame; when the panel's centre is within 40 pt of home's centre, it
/// snaps there, at any size. Dropped at home, its place on that screen is forgotten; dropped
/// elsewhere, it stays on the screen and its place is remembered for that screen.
@MainActor
final class SnapDrag {
    static let snapDistance: CGFloat = 40

    private let window: NSWindow
    private let outline: HomeOutline
    /// Where the places are saved: offsets of the top centre from each screen's top-left
    /// corner, keyed by display ID.
    private let positionsKey: String
    /// The drag under way: where the pointer and the panel started, and the panel's home and
    /// limits, from the caller.
    private struct Drag {
        let pointer: NSPoint
        let origin: NSPoint
        let home: (NSScreen) -> NSRect
        let outlineFrame: (NSRect) -> NSRect
        let clamped: (NSPoint, NSRect) -> NSPoint
    }
    private var current: Drag?
    /// Where the button went down on the panel, and the panel's origin then.
    private var pressed: (pointer: NSPoint, origin: NSPoint)?
    /// Sees the button's presses, moves and release, each where it happened. Events can reach
    /// Tilde late, so the pointer's and the button's state now can be ahead of them.
    private var monitor: Any?
    private var isSnapped = false
    /// Called after each move of a drag, and with `true` once it is dropped.
    var moved: (_ ended: Bool) -> Void = { _ in }

    init(window: NSWindow, outlineCornerRadius: CGFloat, positionsKey: String) {
        self.window = window
        self.positionsKey = positionsKey
        outline = HomeOutline(cornerRadius: outlineCornerRadius)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
            return event
        }
    }

    /// Makes the press a drag of the panel, when its SwiftUI drag gesture reports the first
    /// move. `home` is the panel's frame at home on a screen, `outlineFrame` the outline's
    /// frame for that home frame, and `clamped` keeps a top centre inside a screen's visible
    /// area.
    func begin(home: @escaping (NSScreen) -> NSRect, outlineFrame: @escaping (NSRect) -> NSRect, clamped: @escaping (NSPoint, NSRect) -> NSPoint) {
        guard current == nil, let pressed else {
            return
        }
        current = Drag(pointer: pressed.pointer, origin: pressed.origin, home: home, outlineFrame: outlineFrame, clamped: clamped)
        // The move that SwiftUI reports now went past the monitor before the drag began.
        if let event = NSApp.currentEvent, event.type == .leftMouseDragged {
            move(to: Self.screenLocation(of: event), ended: false)
        }
    }

    private func handle(_ event: NSEvent) {
        let pointer = Self.screenLocation(of: event)
        switch event.type {
        case .leftMouseDown:
            pressed = event.window === window ? (pointer, window.frame.origin) : nil
        case .leftMouseDragged:
            if current != nil {
                move(to: pointer, ended: false)
            }
        case .leftMouseUp:
            if current != nil {
                move(to: pointer, ended: true)
            }
            pressed = nil
        default:
            break
        }
    }

    /// Where an event happened, in AppKit screen coordinates.
    private static func screenLocation(of event: NSEvent) -> NSPoint {
        guard let location = event.cgEvent?.location, let main = NSScreen.screens.first else {
            return NSEvent.mouseLocation
        }
        return NSPoint(x: location.x, y: main.frame.maxY - location.y)
    }

    private func move(to pointer: NSPoint, ended: Bool) {
        guard let current else {
            return
        }
        let size = window.frame.size
        var top = NSPoint(x: current.origin.x + pointer.x - current.pointer.x + size.width / 2, y: current.origin.y + pointer.y - current.pointer.y + size.height)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(top) }) ?? NSScreen.screens.first(where: { $0.frame.contains(pointer) }) else {
            return
        }

        let homeFrame = current.home(screen)
        let centre = NSPoint(x: top.x, y: top.y - size.height / 2)
        let isNearHome = Self.snapsHome(centre, home: NSPoint(x: homeFrame.midX, y: homeFrame.midY))
        if isNearHome {
            top = NSPoint(x: homeFrame.midX, y: homeFrame.midY + size.height / 2)
        }
        let frame = NSRect(x: top.x - size.width / 2, y: top.y - size.height, width: size.width, height: size.height)
        if isNearHome && !isSnapped {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                window.animator().setFrame(frame, display: true)
            }
        } else if !isNearHome || !isSnapped {
            window.setFrameOrigin(frame.origin)
        }
        isSnapped = isNearHome
        outline.show(current.outlineFrame(homeFrame), isSnapped: isNearHome, below: window.windowNumber)
        guard ended else {
            moved(false)
            return
        }

        self.current = nil
        isSnapped = false
        outline.hide()
        if isNearHome {
            forgetTop(on: screen)
        } else {
            let kept = current.clamped(top, screen.visibleFrame)
            window.setFrameOrigin(NSPoint(x: kept.x - size.width / 2, y: kept.y - size.height))
            saveTop(kept, on: screen)
        }
        moved(true)
    }

    /// Whether a dragged panel's centre is close enough to home's centre to snap there.
    static func snapsHome(_ centre: NSPoint, home: NSPoint) -> Bool {
        hypot(centre.x - home.x, centre.y - home.y) < snapDistance
    }

    /// The top centre the panel was dropped at on this screen, if it is not at home.
    func savedTop(on screen: NSScreen) -> NSPoint? {
        let positions = UserDefaults.standard.dictionary(forKey: positionsKey) as? [String: [Double]]
        guard let offset = positions?[Self.key(for: screen)], offset.count == 2 else {
            return nil
        }
        return NSPoint(x: screen.frame.minX + offset[0], y: screen.frame.maxY + offset[1])
    }

    /// Forgets the places on every screen.
    func forgetAll() {
        UserDefaults.standard.removeObject(forKey: positionsKey)
    }

    private func saveTop(_ top: NSPoint, on screen: NSScreen) {
        var positions = UserDefaults.standard.dictionary(forKey: positionsKey) as? [String: [Double]] ?? [:]
        positions[Self.key(for: screen)] = [top.x - screen.frame.minX, top.y - screen.frame.maxY]
        UserDefaults.standard.set(positions, forKey: positionsKey)
    }

    private func forgetTop(on screen: NSScreen) {
        var positions = UserDefaults.standard.dictionary(forKey: positionsKey) as? [String: [Double]] ?? [:]
        positions[Self.key(for: screen)] = nil
        UserDefaults.standard.set(positions, forKey: positionsKey)
    }

    private static func key(for screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.stringValue ?? screen.localizedName
    }
}
