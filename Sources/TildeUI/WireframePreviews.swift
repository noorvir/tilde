import AppKit
import SwiftUI
import WebKit

/// Pictures of wireframe components for Settings: a tile for each style, with one card drawn in
/// that style. The canvas's own page draws them, so they look as the canvas does. The page is
/// loaded only while Settings shows them, and draws only when the look changes.
@MainActor
final class WireframePreviews: ObservableObject {
    @Published private(set) var tiles: [WireframeLook.Style: NSImage] = [:]

    static let tileSize = CGSize(width: 240, height: 150)

    private let html: () -> String?
    private var page: WireframePicturePage?
    private var drawn: WireframeLook?
    private var wanted: WireframeLook?
    private var drawing: Task<Void, Never>?

    /// Whether pictures are being drawn.
    var isDrawing: Bool {
        drawing != nil
    }

    init(html: @escaping () -> String? = { DrawingCanvas.page() }) {
        self.html = html
    }

    /// Draws the pictures for `look` soon; while a drawing is under way, only the newest look
    /// that comes is drawn after it.
    func show(_ look: WireframeLook) {
        guard look != drawn else {
            return
        }
        wanted = look
        guard drawing == nil else {
            return
        }
        drawing = Task {
            while let look = wanted {
                wanted = nil
                try? await draw(look)
            }
            drawing = nil
        }
    }

    /// Lets the page go: Settings no longer shows the pictures.
    func stop() {
        drawing?.cancel()
        drawing = nil
        wanted = nil
        drawn = nil
        page = nil
    }

    /// Draws all the pictures for `look`, and returns when they show.
    func draw(_ look: WireframeLook) async throws {
        if page == nil {
            guard let html = html() else {
                return
            }
            page = try await WireframePicturePage.load(html: html)
        }
        guard let page else {
            return
        }
        var tiles: [WireframeLook.Style: NSImage] = [:]
        for style in WireframeLook.Style.allCases {
            var tileLook = look
            tileLook.style = style
            let picture = try await page.picture(of: [Self.card], look: tileLook, state: "normal", over: Self.background, size: Self.tileSize)
            tiles[style] = NSImage(cgImage: picture, size: Self.tileSize)
        }
        if Task.isCancelled {
            return
        }
        self.tiles = tiles
        drawn = look
    }

    /// One card with its label, in the middle of the tile.
    private static let card: [String: Any] = [
        "type": "card", "rect": [52, 51, 136, 64], "label": "Card", "borders": ["top", "right", "bottom", "left"],
    ]

    /// A plain white tile for the card to stand on.
    private static let background: CGImage = {
        let width = Int(tileSize.width * 2)
        let height = Int(tileSize.height * 2)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }()
}

/// The canvas's page in a web view that is in no window on the screen, drawing still pictures
/// of components: Settings' previews and the contract's pictures.
@MainActor
final class WireframePicturePage {
    struct Failed: Error {
        let reason: String
    }

    private let webView: WKWebView
    private let window: NSWindow
    private let messages = Messages()

    /// The page's posts: "ready" once it can draw.
    private final class Messages: NSObject, WKScriptMessageHandler {
        var all: [String] = []

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? String {
                all.append(body)
            }
        }
    }

    /// The page is as large as a screen: Excalidraw shows its own tools on a small one.
    private init() {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(messages, name: "tilde")
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        webView = WKWebView(frame: screen, configuration: configuration)
        window = FixedScaleWindow(contentRect: screen, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
    }

    static func load(html: String) async throws -> WireframePicturePage {
        let page = WireframePicturePage()
        page.webView.loadHTMLString(html, baseURL: URL(string: "https://drawing.tilde.invalid/"))
        for _ in 0..<1000 where !page.messages.all.contains("ready") {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard page.messages.all.contains("ready") else {
            throw Failed(reason: "the page did not load: \(page.messages.all)")
        }
        return page
    }

    /// `shapes`, as a report has them, in `look`, the first in `state`, over `app` as the blur
    /// and the fade show it under the components: the top left `size` of the page, at two
    /// pixels per point.
    func picture(of shapes: [[String: Any]], look: WireframeLook, state: String, over app: CGImage, size: CGSize) async throws -> CGImage {
        let under = shapes.filter { $0["filled"] as? Bool != false }.compactMap { shape -> UnderBlurView.Shape? in
            guard let rect = (shape["rect"] as? [NSNumber])?.map(\.doubleValue), rect.count == 4 else {
                return nil
            }
            return UnderBlurView.Shape(rect: CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]), isEllipse: shape["type"] as? String == "ellipse")
        }
        let screen = UnderBlurView.screen(app, blurredUnder: under, radius: look.blur, size: size)
        guard let png = NSBitmapImageRep(cgImage: screen).representation(using: .png, properties: [:]) else {
            throw Failed(reason: "no background")
        }
        let preview: [String: Any] = [
            "look": look.pageValues, "shapes": shapes, "state": state,
            "background": "data:image/png;base64,\(png.base64EncodedString())", "size": [size.width, size.height],
        ]
        _ = try await webView.callAsyncJavaScript("await window.tildeDraw.showPreview(preview)", arguments: ["preview": preview], contentWorld: .page)
        // WebKit paints a pattern, such as Hatched's lines, a moment after the page changes.
        try await Task.sleep(for: .milliseconds(40))

        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: size)
        configuration.afterScreenUpdates = true
        let image = try await webView.takeSnapshot(configuration: configuration)
        let context = CGContext(
            data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let context else {
            throw Failed(reason: "no bitmap")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        NSGraphicsContext.restoreGraphicsState()
        guard let picture = context.makeImage() else {
            throw Failed(reason: "no picture")
        }
        return picture
    }
}

/// A window at two pixels per point whatever the screen's scale: the web view draws at its
/// window's scale, so the pictures are the same on every Mac.
private final class FixedScaleWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 2 }
}
