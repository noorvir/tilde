@testable import TildeUI
import AppKit
import SwiftUI
import WebKit

/// The drawing canvas with a wireframe over an app, as the screen shows it: the real page draws
/// the components in a look, over the app that `UnderBlurView` blurs under them.
@MainActor
enum CanvasSurface {
    static let size = CGSize(width: 680, height: 420)

    /// The components of the owner's reference picture, over `MockApp`.
    private static let shapes: [[String: Any]] = [
        ["type": "card", "rect": [18, 118, 216, 66], "label": "Plan card", "borders": allBorders],
        ["type": "card", "rect": [244, 118, 216, 66], "label": "Plan card", "borders": allBorders],
        ["type": "dropdown", "rect": [480, 132, 160, 30], "label": "Region", "borders": allBorders],
        ["type": "table", "rect": [20, 204, 420, 186], "label": "GPU table", "borders": allBorders, "rows": 3, "columns": 3],
        ["type": "list", "rect": [456, 204, 84, 186], "label": "Tags", "borders": allBorders, "rows": 4],
        ["type": "button", "rect": [556, 300, 84, 32], "label": "Launch", "borders": allBorders],
    ]
    private static let allBorders = ["top", "right", "bottom", "left"]

    static func image(look: WireframeLook, chip: UIState.Chip?) async throws -> CGImage {
        let app = try await Renderer.render(NSHostingView(rootView: MockApp()), size: size, appearance: .aqua)
        let page = try await Page.load(size: size)
        try await page.run("window.tildeDraw.setWireframeLook(\(look.pageJSON))")
        try await page.run("window.tildeDraw.restoreWireframe(\(DrawingPanel.json(["shapes": shapes, "origin": [0, 0]])))")
        let under = try await page.under()
        if let chip {
            try await page.showChip(isBordersOpen: chip == .borders)
        }

        // The app as the screen would show it under the canvas: blurred inside the shapes.
        let scale = CGFloat(Renderer.scale)
        let context = Renderer.bitmapContext(width: Int(size.width * scale), height: Int(size.height * scale))!
        context.draw(app, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        if look.blur > 0, let picture = UnderBlurView.picture(of: app, size: size), let blurred = UnderBlurView.blurred(picture, radius: look.blur) {
            context.scaleBy(x: scale, y: scale)
            context.addPath(UnderBlurView.path(of: under, height: size.height))
            context.clip()
            context.draw(blurred, in: CGRect(origin: .zero, size: size))
        }
        let screen = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
        try await page.run("document.documentElement.style.background = 'url(data:image/png;base64,\(screen.base64EncodedString())) 0 0 / \(Int(size.width))px \(Int(size.height))px no-repeat'")
        return try await page.snapshot()
    }

    /// The canvas's page from the sources, in a window that is not on the screen.
    @MainActor
    private final class Page: NSObject, WKScriptMessageHandler {
        struct Failed: Error {
            let reason: String
        }

        private let webView: WKWebView
        private let window: NSWindow
        private let size: CGSize
        private var messages: [String] = []

        /// The page is as large as a screen, as Excalidraw shows its own tools on a small one;
        /// the picture is its top left, `size`.
        private init(size: CGSize) {
            self.size = size
            let configuration = WKWebViewConfiguration()
            let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
            webView = WKWebView(frame: screen, configuration: configuration)
            window = NSWindow(contentRect: screen, styleMask: [.borderless], backing: .buffered, defer: false)
            super.init()
            configuration.userContentController.add(self, name: "tilde")
            window.contentView = webView
        }

        static func load(size: CGSize) async throws -> Page {
            let page = Page(size: size)
            let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../TildeUI/DrawingWeb")
            guard let html = DrawingCanvas.page(in: folder) else {
                throw Failed(reason: "no page in \(folder.path)")
            }
            page.webView.loadHTMLString(html, baseURL: URL(string: "https://drawing.tilde.invalid/"))
            try await page.wait { $0.contains("ready") }
            return page
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? String {
                messages.append(body)
            }
        }

        func run(_ script: String) async throws {
            _ = try await webView.evaluateJavaScript("\(script); 0")
        }

        /// The first component's chip, as the pointer over it shows it, and its borders menu.
        func showChip(isBordersOpen: Bool) async throws {
            let point = "clientX: 126, clientY: 150"
            try await run("window.tildeDraw.setWireframe({tool: '', icons: {}})")
            try await run("document.elementFromPoint(126, 150).dispatchEvent(new PointerEvent('pointermove', {bubbles: true, composed: true, \(point), pointerId: 1, pointerType: 'mouse', isPrimary: true}))")
            if isBordersOpen {
                for type in ["pointerdown", "pointerup"] {
                    try await run("document.querySelector('#tilde-chip [data-menu=borders]').dispatchEvent(new PointerEvent('\(type)', {bubbles: true, composed: true, \(point), pointerId: 1, pointerType: 'mouse', isPrimary: true, button: 0}))")
                }
            }
        }

        /// The shapes that the page posted last to blur under.
        func under() async throws -> [UnderBlurView.Shape] {
            try await wait { $0.contains { $0.hasPrefix("under:") && $0 != "under:[]" } }
            let last = messages.last { $0.hasPrefix("under:") } ?? "under:[]"
            let values = (try JSONSerialization.jsonObject(with: Data(last.dropFirst("under:".count).utf8)) as? [[Double]]) ?? []
            return values.map { UnderBlurView.Shape(rect: CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]), isEllipse: $0[4] == 1) }
        }

        func snapshot() async throws -> CGImage {
            // Lets the page draw its background and fonts.
            try await Task.sleep(for: .milliseconds(300))
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(origin: .zero, size: size)
            configuration.afterScreenUpdates = true
            let image = try await webView.takeSnapshot(configuration: configuration)
            let scale = CGFloat(Renderer.scale)
            let context = Renderer.bitmapContext(width: Int(size.width * scale), height: Int(size.height * scale))!
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            image.draw(in: CGRect(x: 0, y: 0, width: CGFloat(context.width), height: CGFloat(context.height)))
            NSGraphicsContext.restoreGraphicsState()
            return context.makeImage()!
        }

        private func wait(until condition: ([String]) -> Bool) async throws {
            for _ in 0..<500 {
                if condition(messages) {
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw Failed(reason: "the page did not answer: \(messages)")
        }
    }
}

/// An app under the wireframe, as in the owner's reference picture: a header, plans and a table.
private struct MockApp: View {
    private let ink = Color(red: 0.12, green: 0.12, blue: 0.11)
    private let muted = Color(red: 0.42, green: 0.42, blue: 0.4)
    private let accent = Color(red: 0.23, green: 0.13, blue: 0.79)
    private let line = Color(red: 0.85, green: 0.84, blue: 0.82)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.97, green: 0.97, blue: 0.96)
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Circle().fill(ink).frame(width: 16, height: 16)
                    Text("Acme cloud").font(.system(size: 14)).foregroundStyle(ink)
                    Spacer()
                    ForEach(["Models", "Pricing", "Docs"], id: \.self) { Text($0).font(.system(size: 13)).foregroundStyle(muted) }
                    Text("Sign in").font(.system(size: 12)).foregroundStyle(.white).padding(.horizontal, 14).frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 4).fill(ink))
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(.white)
                Rectangle().fill(line).frame(height: 1)
                VStack(alignment: .leading, spacing: 6) {
                    Text("GPUs for your own models").font(.system(size: 24)).foregroundStyle(ink)
                    Text("Rent GPUs directly, pay less with spot, or reserve capacity.").font(.system(size: 13)).foregroundStyle(muted)
                    HStack(spacing: 12) {
                        plan("On demand", "Billed per second", isChosen: true)
                        plan("Spot", "About 45% less", isChosen: false)
                        plan("Reserved", "Price per contract", isChosen: false)
                    }
                    .padding(.top, 10)
                    table.padding(.top, 12)
                }
                .padding(.horizontal, 28)
                .padding(.top, 16)
            }
        }
    }

    private func plan(_ title: String, _ subtitle: String, isChosen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 14)).foregroundStyle(isChosen ? .white : ink)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(isChosen ? Color(red: 0.79, green: 0.76, blue: 1) : muted)
        }
        .padding(.horizontal, 16)
        .frame(width: 200, height: 54, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(isChosen ? accent : .white))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isChosen ? .clear : line))
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(["GPU", "Memory", "On demand"], id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 170, alignment: .leading) }
            }
            .frame(height: 36)
            ForEach([("NVIDIA B300", "288 GB", "$12.79 / h"), ("NVIDIA B200", "192 GB", "$9.99 / h"), ("NVIDIA H200", "141 GB", "$7.09 / h")], id: \.0) { row in
                HStack(spacing: 0) {
                    Text(row.0).frame(width: 170, alignment: .leading)
                    Text(row.1).frame(width: 170, alignment: .leading)
                    Text(row.2).foregroundStyle(accent).frame(width: 170, alignment: .leading)
                    Text("Launch").font(.system(size: 12)).frame(width: 72, height: 26)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(ink))
                }
                .font(.system(size: 13))
                .foregroundStyle(ink)
                .frame(height: 48)
            }
        }
        .padding(.horizontal, 20)
        .frame(width: 624, height: 200, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(line))
    }
}
