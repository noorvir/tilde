import AppKit

// The app keeps all screen geometry in Quartz global coordinates (top-left origin of the
// primary screen), which is what Accessibility, CGWindowList and ScreenCaptureKit use.
// AppKit window and screen frames use a bottom-left origin; `flipped` converts both ways.

private var primaryScreenHeight: CGFloat {
    NSScreen.screens.first?.frame.height ?? 0
}

extension CGRect {
    var flipped: CGRect {
        CGRect(x: minX, y: primaryScreenHeight - maxY, width: width, height: height)
    }
}

extension CGPoint {
    var flipped: CGPoint {
        CGPoint(x: x, y: primaryScreenHeight - y)
    }
}
