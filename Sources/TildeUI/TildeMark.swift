import AppKit

/// Tilde's mark: a bold tilde inside the corners of a selection, drawn in code so the menu
/// bar icon and the app icon stay sharp at every size and come from the same paths.
public enum TildeMark {
    /// The menu bar icon, 18 pt. A template image, so macOS colours it for light and dark
    /// menu bars and the status item can tint it while annotating.
    public static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.set()
            // A square frame that fills the 18 pt image with 1 pt to spare. Its 1.5 pt lines
            // sit on whole pixels at 2x (centres at 1.75 and 16.25 pt), so all four sides look
            // the same. The tilde inside is small, so the frame reads first.
            let frame = NSRect(x: 1.75, y: 1.75, width: 14.5, height: 14.5)
            let corners = cornersPath(in: frame, length: 4)
            corners.lineWidth = 1.5
            corners.stroke()
            let tilde = tildePath(in: frame.insetBy(dx: 2, dy: 2))
            tilde.lineWidth = 1.8
            tilde.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Tilde"
        return image
    }

    /// The app icon at `size` pixels: a white selection frame with a small white tilde on a
    /// blue rounded square with the standard macOS icon margin.
    public static func appIconImage(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let scale = size / 1024
            let tile = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
            let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * scale, yRadius: 185 * scale)

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 24 * scale
            shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
            shadow.shadowColor = .black.withAlphaComponent(0.35)
            shadow.set()
            let top = NSColor(srgbRed: 0.32, green: 0.6, blue: 1, alpha: 1)
            let bottom = NSColor(srgbRed: 0.1, green: 0.36, blue: 0.92, alpha: 1)
            NSGradient(starting: top, ending: bottom)?.draw(in: shape, angle: -90)
            NSGraphicsContext.restoreGraphicsState()

            // The frame is a 584 px square, 71% of the tile, centred on it; the tilde is about
            // half the frame's width.
            let frame = tile.insetBy(dx: 120 * scale, dy: 120 * scale)
            NSColor.white.setStroke()
            let corners = cornersPath(in: frame, length: 140 * scale)
            corners.lineWidth = 36 * scale
            corners.stroke()

            let tilde = tildePath(in: frame.insetBy(dx: 90 * scale, dy: 90 * scale))
            tilde.lineWidth = 64 * scale
            tilde.stroke()
            return true
        }
    }

    /// The tilde wave across a square, designed on an 18 × 18 grid with the origin at the
    /// bottom left.
    static func tildePath(in rect: NSRect) -> NSBezierPath {
        let unit = rect.width / 18
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * unit, y: rect.minY + y * unit)
        }

        let path = NSBezierPath()
        path.move(to: point(3, 7.2))
        path.curve(to: point(9, 9), controlPoint1: point(4.3, 11.2), controlPoint2: point(6.6, 11.2))
        path.curve(to: point(15, 10.8), controlPoint1: point(11.4, 6.8), controlPoint2: point(13.7, 6.8))
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }

    /// Four L-shaped corners of a selection around `rect`, each `length` long.
    static func cornersPath(in rect: NSRect, length: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let corners: [(NSPoint, CGFloat, CGFloat)] = [
            (NSPoint(x: rect.minX, y: rect.minY), 1, 1),
            (NSPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (NSPoint(x: rect.minX, y: rect.maxY), 1, -1),
            (NSPoint(x: rect.maxX, y: rect.maxY), -1, -1),
        ]
        for (corner, dx, dy) in corners {
            path.move(to: NSPoint(x: corner.x, y: corner.y + dy * length))
            path.line(to: corner)
            path.line(to: NSPoint(x: corner.x + dx * length, y: corner.y))
        }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }
}
