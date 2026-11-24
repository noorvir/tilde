import AppKit
import AVFoundation
import Testing
@testable import TildeUI

@MainActor
struct ComposerDragTests {
    /// A drag moves the canvas's own layers: the layout goes out once, at its end, so no
    /// view redraws while the pointer moves.
    @Test func aDragHandsTheLayoutOverOnceAtItsEnd() throws {
        let view = ComposerCanvas.CanvasView(screen: AVPlayer(), camera: AVPlayer())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = view
        var layout = ClipLayout(background: .gradient(.dusk))
        layout.cameraCenter = CGPoint(x: 0.16, y: 0.74)
        let clip = CGSize(width: 1280, height: 800)
        view.show(layout, clipSize: clip, corner: VideoFramer.defaultCorner)
        var handed: [ClipLayout] = []
        view.onChange = { handed.append($0) }

        let camera = try #require(layout.frames(in: view.bounds.size, clip: clip).camera)
        let start = view.convert(NSPoint(x: camera.midX, y: camera.midY), to: nil)
        func send(_ type: NSEvent.EventType, dx: CGFloat) throws {
            let point = NSPoint(x: start.x + dx, y: start.y)
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
        }

        try send(.leftMouseDown, dx: 0)
        for tick in 1...60 {
            try send(.leftMouseDragged, dx: CGFloat(tick))
            // The controller's layout does not stop the drag.
            view.show(layout, clipSize: clip, corner: VideoFramer.defaultCorner)
        }
        #expect(handed.isEmpty)
        try send(.leftMouseUp, dx: 60)

        #expect(handed.count == 1)
        let moved = try #require(handed.first?.cameraCenter)
        #expect(abs(moved.x - (0.16 + 60 / 640)) < 0.001)
        #expect(moved.y == 0.74)
        #expect(view.shown == handed.first)
    }
}
