import AppKit
import SwiftUI
import WebKit

/// Pictures of wireframe components for Settings: a tile for each style, and one component in
/// each state in the chosen style. The canvas's own page draws them, so they look as the canvas
/// does. The page is loaded only while Settings shows them, and draws only when the look
/// changes.
@MainActor
final class WireframePreviews: ObservableObject {
    enum State: String, CaseIterable, Identifiable {
        case normal, hovered, selected, dragging, bordersOff

        var id: String { rawValue }

        var caption: String {
            switch self {
            case .normal: "Normal"
            case .hovered: "Pointer over it"
            case .selected: "Selected"
            case .dragging: "Dragged, snapping"
            case .bordersOff: "Some borders off"
            }
        }
    }

    @Published private(set) var tiles: [WireframeLook.Style: NSImage] = [:]
    @Published private(set) var states: [State: NSImage] = [:]

    static let tileSize = CGSize(width: 240, height: 150)
    static let stateSize = CGSize(width: 176, height: 120)

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
        let tileApp = Self.sampleApp(size: Self.tileSize)
        let stateApp = Self.sampleApp(size: Self.stateSize)
        var tiles: [WireframeLook.Style: NSImage] = [:]
        for style in WireframeLook.Style.allCases {
            var tileLook = look
            tileLook.style = style
            let picture = try await page.picture(of: Self.tileShapes, look: tileLook, state: "normal", over: tileApp, size: Self.tileSize)
            tiles[style] = NSImage(cgImage: picture, size: Self.tileSize)
        }
        var states: [State: NSImage] = [:]
        for state in State.allCases {
            var card: [String: Any] = ["type": "card", "rect": [16, 24, 104, 44], "label": "Card", "borders": ["top", "right", "bottom", "left"]]
            if state == .bordersOff {
                card["borders"] = ["bottom", "left"]
            }
            let pageState = state == .bordersOff ? "normal" : state.rawValue
            let picture = try await page.picture(of: [card], look: look, state: pageState, over: stateApp, size: Self.stateSize)
            states[state] = NSImage(cgImage: picture, size: Self.stateSize)
        }
        if Task.isCancelled {
            return
        }
        self.tiles = tiles
        self.states = states
        drawn = look
    }

    /// A card, a table, a button and a dropdown with their labels.
    private static let tileShapes: [[String: Any]] = {
        let borders = ["top", "right", "bottom", "left"]
        return [
            ["type": "card", "rect": [12, 30, 112, 50], "label": "Card", "borders": borders],
            ["type": "dropdown", "rect": [140, 40, 88, 24], "label": "Menu", "borders": borders],
            ["type": "table", "rect": [12, 100, 132, 42], "label": "Table", "borders": borders, "rows": 2, "columns": 2],
            ["type": "button", "rect": [160, 108, 68, 28], "label": "Save", "borders": borders],
        ]
    }()

    /// A small app for the components to stand over, so that the blur and the fade show.
    static func sampleApp(size: CGSize) -> CGImage {
        let renderer = ImageRenderer(content: SampleApp().frame(width: size.width, height: size.height))
        renderer.scale = 2
        return renderer.cgImage ?? NSImage(size: size).cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }
}

/// An app's window in a few blocks and lines of text, in light colours whatever the appearance.
private struct SampleApp: View {
    private let ink = Color(red: 0.12, green: 0.12, blue: 0.11)
    private let muted = Color(red: 0.62, green: 0.62, blue: 0.6)
    private let accent = Color(red: 0.23, green: 0.13, blue: 0.79)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(ink).frame(width: 8, height: 8)
                Capsule().fill(ink).frame(width: 40, height: 5)
                Spacer()
                Capsule().fill(muted).frame(width: 22, height: 4)
                Capsule().fill(muted).frame(width: 22, height: 4)
                RoundedRectangle(cornerRadius: 3).fill(ink).frame(width: 30, height: 12)
            }
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Color.white)
            Rectangle().fill(Color(white: 0.88)).frame(height: 1)
            VStack(alignment: .leading, spacing: 7) {
                Text("Plans for your team").font(.system(size: 12, weight: .semibold)).foregroundStyle(ink)
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(accent).overlay(alignment: .topLeading) {
                        Text("Pro").font(.system(size: 9)).foregroundStyle(.white).padding(5)
                    }
                    RoundedRectangle(cornerRadius: 4).fill(Color.white).overlay(alignment: .topLeading) {
                        Text("Free").font(.system(size: 9)).foregroundStyle(ink).padding(5)
                    }
                }
                .frame(height: 34)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(["Starter  $9", "Team  $29", "Scale  $99"], id: \.self) { row in
                        Text(row).font(.system(size: 9)).foregroundStyle(ink)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white))
            }
            .padding(10)
            Spacer(minLength: 0)
        }
        .background(Color(red: 0.96, green: 0.96, blue: 0.95))
    }
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
        window = NSWindow(contentRect: screen, styleMask: [.borderless], backing: .buffered, defer: false)
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
