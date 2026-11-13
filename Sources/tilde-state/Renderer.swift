import AppKit

/// Renders a view offscreen at a fixed scale, with no animations.
@MainActor
enum Renderer {
    static let scale = 2

    /// Overlay scrollers whatever the Mac's scroll bar setting (it follows a connected mouse),
    /// so scroll views have the same width everywhere. SwiftUI reads the class property when
    /// it lays out, so setting the style on the views afterwards is too late.
    static let fixesScrollerStyle: Void = {
        guard let original = class_getClassMethod(NSScroller.self, #selector(getter: NSScroller.preferredScrollerStyle)),
              let fixed = class_getClassMethod(NSScroller.self, #selector(getter: NSScroller.tildeSnapshotScrollerStyle))
        else {
            return
        }
        method_exchangeImplementations(original, fixed)
    }()

    static func render(_ view: NSView, size: CGSize, windowOrigin: NSPoint = .zero, appearance: NSAppearance.Name = .darkAqua) async throws -> CGImage {
        _ = fixesScrollerStyle
        let window = ActiveWindow(contentRect: NSRect(origin: windowOrigin, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        window.setFrameOrigin(windowOrigin)
        view.layoutSubtreeIfNeeded()
        // Lets SwiftUI commit its layers; animations are off, so the result is final.
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()

        let context = bitmapContext(width: Int(size.width) * scale, height: Int(size.height) * scale)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

        if let layer = view.layer {
            // Layers draw with a top-left origin here.
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            layer.render(in: context)
        } else {
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            view.displayIgnoringOpacity(view.bounds, in: graphics)
        }
        window.contentView = nil
        return context.makeImage()!
    }

    static func bitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

}

/// Draws as the window in front does, with active controls and placeholders.
private final class ActiveWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

private extension NSScroller {
    @objc class var tildeSnapshotScrollerStyle: NSScroller.Style { .overlay }
}
