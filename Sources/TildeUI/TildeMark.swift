import AppKit

/// Tilde's mark: a bold tilde inside the corners of a selection, drawn in code so the menu
/// bar icon stays sharp at every size.
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
