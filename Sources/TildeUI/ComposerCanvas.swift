import AppKit
import AVFoundation
import SwiftUI

/// The clip and its camera as layers on the composer's background. The view owns a drag from
/// its first tick to its end; the layout it shows changes only between drags.
struct ComposerCanvas: NSViewRepresentable {
    let players: ClipPlayers
    let layout: ClipLayout
    let clipSize: CGSize
    let corner: CGFloat
    let cameraPoster: CGImage?
    /// Called once at the end of a drag that moved or resized something.
    let onChange: (ClipLayout) -> Void

    func makeNSView(context: Context) -> CanvasView {
        CanvasView(screen: players.screen, camera: players.camera)
    }

    func updateNSView(_ view: CanvasView, context: Context) {
        view.onChange = onChange
        view.cameraPoster = cameraPoster
        view.show(layout, clipSize: clipSize, corner: corner)
    }

    final class CanvasView: NSView {
        enum Part {
            case screen, camera
        }

        private struct Drag {
            let part: Part
            let resizes: Bool
            let start: NSPoint
            let layout: ClipLayout
            var hasMoved = false
        }

        var onChange: (ClipLayout) -> Void = { _ in }
        var cameraPoster: CGImage? {
            get { camera?.poster }
            set { camera?.poster = newValue }
        }
        private(set) var shown = ClipLayout(background: .gradient(.dusk))
        private var clipSize = CGSize(width: 16, height: 10)
        private var corner = VideoFramer.defaultCorner
        private var drag: Drag?
        private let screen: PartLayers
        private let camera: PartLayers?

        init(screen: AVPlayer, camera: AVPlayer?) {
            self.screen = PartLayers(player: screen, fills: false, mirrored: false)
            self.camera = camera.map { PartLayers(player: $0, fills: true, mirrored: true) }
            super.init(frame: .zero)
            wantsLayer = true
            self.screen.add(to: layer)
            self.camera?.add(to: layer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override var isFlipped: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// Ignored while a drag goes on: the drag's own layout shows until it ends.
        func show(_ layout: ClipLayout, clipSize: CGSize, corner: CGFloat) {
            guard drag == nil, layout != shown || clipSize != self.clipSize || corner != self.corner else {
                return
            }
            shown = layout
            self.clipSize = clipSize
            self.corner = corner
            place()
        }

        override func layout() {
            super.layout()
            place()
        }

        private func place() {
            let frames = shown.frames(in: bounds.size, clip: clipSize)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            screen.place(in: frames.screen, radius: min(frames.screen.width, frames.screen.height) * corner, rim: 0)
            if let camera {
                if let frame = frames.camera {
                    camera.place(in: frame, radius: shown.cameraShape.cornerRadius(side: frame.width), rim: CameraBubble.Shape.rim(side: frame.width))
                }
                camera.isHidden = frames.camera == nil
            }
            CATransaction.commit()
        }

        // MARK: Dragging

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard let (part, resizes) = target(at: point) else {
                super.mouseDown(with: event)
                return
            }
            drag = Drag(part: part, resizes: resizes, start: point, layout: shown)
        }

        override func mouseDragged(with event: NSEvent) {
            guard var drag else {
                return
            }
            let point = convert(event.locationInWindow, from: nil)
            let translation = CGSize(width: point.x - drag.start.x, height: point.y - drag.start.y)
            if !drag.hasMoved {
                guard hypot(translation.width, translation.height) >= (drag.resizes ? 1 : 2) else {
                    return
                }
                drag.hasMoved = true
                self.drag = drag
            }
            shown = dragged(drag, by: translation)
            place()
        }

        override func mouseUp(with event: NSEvent) {
            guard let drag else {
                return
            }
            self.drag = nil
            if drag.hasMoved, shown != drag.layout {
                onChange(shown)
            }
        }

        /// The part under `point`, top first; `resizes` on its corner dot.
        private func target(at point: NSPoint) -> (Part, resizes: Bool)? {
            let frames = shown.frames(in: bounds.size, clip: clipSize)
            if camera != nil, let frame = frames.camera {
                if PartLayers.dotArea(of: frame).contains(point) {
                    return (.camera, true)
                }
                if shown.cameraShape == .circle {
                    if hypot(point.x - frame.midX, point.y - frame.midY) <= frame.width / 2 {
                        return (.camera, false)
                    }
                } else if frame.contains(point) {
                    return (.camera, false)
                }
            }
            if PartLayers.dotArea(of: frames.screen).contains(point) {
                return (.screen, true)
            }
            if frames.screen.contains(point) {
                return (.screen, false)
            }
            return nil
        }

        /// A move keeps the part's centre on the canvas; a resize moves the bottom-right corner
        /// with the pointer, and the part keeps its centre and its shape.
        private func dragged(_ drag: Drag, by translation: CGSize) -> ClipLayout {
            let canvas = bounds.size
            let start = drag.layout
            var layout = start
            if drag.resizes {
                let frames = start.frames(in: canvas, clip: clipSize)
                switch drag.part {
                case .screen:
                    let width = frames.screen.width + 2 * translation.width
                    layout.screenScale = min(max(start.screenScale * width / max(frames.screen.width, 1), 0.2), 1)
                case .camera:
                    let side = start.cameraSide * canvas.height + translation.width + translation.height
                    layout.cameraSide = min(max(side / canvas.height, 0.1), 0.7)
                }
                return layout
            }
            let dx = translation.width / canvas.width
            let dy = translation.height / canvas.height
            switch drag.part {
            case .screen:
                layout.screenCenter = clamped(CGPoint(x: start.screenCenter.x + dx, y: start.screenCenter.y + dy))
            case .camera:
                if let center = start.cameraCenter {
                    layout.cameraCenter = clamped(CGPoint(x: center.x + dx, y: center.y + dy))
                }
            }
            return layout
        }

        private func clamped(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        }

        // MARK: Accessibility

        override func isAccessibilityElement() -> Bool { false }

        override func accessibilityChildren() -> [Any]? {
            let frames = shown.frames(in: bounds.size, clip: clipSize)
            var parts = [("Screen recording", frames.screen), ("Resize screen recording", PartLayers.dotArea(of: frames.screen))]
            if camera != nil, let frame = frames.camera {
                parts += [("Camera", frame), ("Resize camera", PartLayers.dotArea(of: frame))]
            }
            return parts.map { label, frame in
                let element = NSAccessibilityElement()
                element.setAccessibilityRole(.image)
                element.setAccessibilityLabel(label)
                element.setAccessibilityParent(self)
                element.setAccessibilityFrameInParentSpace(frame)
                return element
            }
        }
    }

    /// One part's layers: a shadow drawn from its outline alone, its player clipped to its
    /// shape with an optional white rim, and its corner dot. A path shadow costs no pass over
    /// the video's pixels as the part moves.
    final class PartLayers {
        private static let dot: CGFloat = 12
        private static let dotInset: CGFloat = 4

        private let shadow = CALayer()
        private let clip = CALayer()
        /// Under the player: shows where the player has no frame.
        private let still = CALayer()
        private let player: AVPlayerLayer
        private let dot = CALayer()
        private let mirrored: Bool

        init(player: AVPlayer, fills: Bool, mirrored: Bool) {
            self.player = AVPlayerLayer(player: player)
            self.mirrored = mirrored
            self.player.videoGravity = fills ? .resizeAspectFill : .resizeAspect
            shadow.shadowColor = NSColor.black.cgColor
            shadow.shadowOpacity = 0.4
            shadow.shadowRadius = mirrored ? 8 : 10
            shadow.shadowOffset = CGSize(width: 0, height: mirrored ? 4 : 5)
            clip.masksToBounds = true
            clip.cornerCurve = .continuous
            clip.borderColor = NSColor.white.cgColor
            still.contentsGravity = fills ? .resizeAspectFill : .resizeAspect
            still.masksToBounds = true
            clip.addSublayer(still)
            clip.addSublayer(self.player)
            dot.backgroundColor = NSColor.white.cgColor
            dot.cornerRadius = Self.dot / 2
            dot.shadowColor = NSColor.black.cgColor
            dot.shadowOpacity = 0.4
            dot.shadowRadius = 2
            dot.shadowOffset = .zero
            dot.shadowPath = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: Self.dot, height: Self.dot), transform: nil)
        }

        /// Where a press takes the corner dot: a little larger than the dot.
        static func dotArea(of frame: CGRect) -> CGRect {
            let side = dot + 2 * dotInset
            return CGRect(x: frame.maxX - side, y: frame.maxY - side, width: side, height: side)
        }

        var poster: CGImage? {
            didSet {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                still.contents = poster
                CATransaction.commit()
            }
        }

        var isHidden: Bool {
            get { clip.isHidden }
            set {
                shadow.isHidden = newValue
                clip.isHidden = newValue
                dot.isHidden = newValue
            }
        }

        func add(to parent: CALayer?) {
            parent?.addSublayer(shadow)
            parent?.addSublayer(clip)
            parent?.addSublayer(dot)
        }

        /// Call inside a transaction with actions off.
        func place(in frame: CGRect, radius: CGFloat, rim: CGFloat) {
            let local = CGRect(origin: .zero, size: frame.size)
            shadow.frame = frame
            shadow.shadowPath = CGPath(roundedRect: local, cornerWidth: radius, cornerHeight: radius, transform: nil)
            clip.frame = frame
            clip.cornerRadius = radius
            clip.borderWidth = rim
            let transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
            for layer in [still, player] {
                layer.bounds = local
                layer.position = CGPoint(x: local.midX, y: local.midY)
                layer.setAffineTransform(transform)
            }
            let area = Self.dotArea(of: frame)
            dot.frame = area.insetBy(dx: Self.dotInset, dy: Self.dotInset)
        }
    }
}
