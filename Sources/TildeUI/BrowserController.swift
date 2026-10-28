import TildeCore
import AppKit
import Combine
import SwiftUI
import WebKit

/// Tilde's built-in browser. Pages opened here give full DOM and React data when annotated.
/// Uses the default persistent website data store, so logins survive restarts.
@MainActor
final class BrowserController: NSObject, ObservableObject, NSWindowDelegate {
    @Published var address = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false

    let webView: WKWebView
    private var window: NSWindow?
    private var observations: [AnyCancellable] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.addUserScript(
            WKUserScript(source: pickerScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
        super.init()

        observations = [
            webView.publisher(for: \.url).sink { [weak self] url in self?.address = url?.absoluteString ?? "" },
            webView.publisher(for: \.canGoBack).sink { [weak self] value in self?.canGoBack = value },
            webView.publisher(for: \.canGoForward).sink { [weak self] value in self?.canGoForward = value },
            webView.publisher(for: \.isLoading).sink { [weak self] value in self?.isLoading = value },
            webView.publisher(for: \.title).sink { [weak self] title in self?.window?.title = title ?? "Tilde Browser" },
        ]
    }

    /// The browser window's number while it is on screen.
    var windowNumber: Int? {
        guard let window, window.isVisible else {
            return nil
        }
        return window.windowNumber
    }

    func show(_ url: URL? = nil) {
        let window = self.window ?? makeWindow()
        self.window = window

        if let url {
            webView.load(URLRequest(url: url))
        }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        // Activation is cooperative since macOS 14 and may be refused; raise the window anyway.
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func load(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return
        }

        var candidate = trimmed
        if !trimmed.contains("://") {
            let isLocal = trimmed.hasPrefix("localhost") || trimmed.hasPrefix("127.0.0.1") || trimmed.hasPrefix("0.0.0.0")
            candidate = (isLocal ? "http://" : "https://") + trimmed
        }
        guard let url = URL(string: candidate) else {
            return
        }
        webView.load(URLRequest(url: url))
    }

    func reloadOrStop() {
        if isLoading {
            webView.stopLoading()
        } else {
            webView.reload()
        }
    }

    /// Inspects the DOM element at a Quartz screen point inside the web view.
    func inspect(at point: CGPoint) async -> Picked? {
        guard let window else {
            return nil
        }

        let windowPoint = window.convertPoint(fromScreen: point.flipped)
        let viewPoint = webView.convert(windowPoint, from: nil)
        guard webView.bounds.contains(viewPoint) else {
            return nil
        }

        let x = viewPoint.x
        let y = webView.isFlipped ? viewPoint.y : webView.bounds.height - viewPoint.y
        let result = try? await webView.callAsyncJavaScript(
            "return window.__tilde ? window.__tilde.inspect(x, y) : null",
            arguments: ["x": x, "y": y],
            contentWorld: .page
        )
        guard let json = result as? String,
              let data = json.data(using: .utf8),
              let element = try? JSONDecoder().decode(WebElement.self, from: data),
              let extras = try? JSONDecoder().decode(Inspection.self, from: data)
        else {
            return nil
        }

        let rect = extras.rect
        let viewRect: CGRect
        if webView.isFlipped {
            viewRect = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        } else {
            viewRect = CGRect(x: rect.x, y: webView.bounds.height - rect.y - rect.height, width: rect.width, height: rect.height)
        }
        let visible = viewRect.intersection(webView.bounds)
        let screenRect = window.convertToScreen(webView.convert(visible, to: nil))

        let details = [
            "\(element.tag)  \(Int(rect.width))×\(Int(rect.height))",
            "color  \(extras.color)",
            "font  \(extras.font)",
        ]
        return Picked(frame: screenRect.flipped, element: .web(element), chip: element.tag, details: details)
    }

    /// Snapshot of the web page under `rect` (Quartz coordinates). Needs no Screen Recording
    /// permission. Returns nil when the rect is outside the visible web view.
    func snapshot(of rect: CGRect, outline: CGRect?) async -> Data? {
        guard let window, window.isVisible else {
            return nil
        }

        let windowRect = window.convertFromScreen(rect.flipped)
        let viewRect = webView.convert(windowRect, from: nil).intersection(webView.bounds)
        guard !viewRect.isNull, viewRect.width >= 1, viewRect.height >= 1 else {
            return nil
        }

        let configuration = WKSnapshotConfiguration()
        configuration.rect = viewRect
        guard let image = try? await webView.takeSnapshot(configuration: configuration),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return nil
        }

        let area = window.convertToScreen(webView.convert(viewRect, to: nil)).flipped
        let scale = CGFloat(cgImage.width) / area.width
        return ScreenCapture.png(from: cgImage, outline: outline.map { $0.offsetBy(dx: -area.minX, dy: -area.minY) }, scale: scale, maxSide: 1600)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Tilde Browser"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: BrowserView(browser: self))
        window.setFrameAutosaveName("TildeBrowser")
        window.center()
        return window
    }

    private struct Inspection: Decodable {
        struct Rect: Decodable {
            let x: Double
            let y: Double
            let width: Double
            let height: Double
        }

        let rect: Rect
        let color: String
        let font: String
    }
}

private struct BrowserView: View {
    @ObservedObject var browser: BrowserController
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                toolbarButton("chevron.left", enabled: browser.canGoBack) { browser.webView.goBack() }
                toolbarButton("chevron.right", enabled: browser.canGoForward) { browser.webView.goForward() }
                toolbarButton(browser.isLoading ? "xmark" : "arrow.clockwise", enabled: true) { browser.reloadOrStop() }

                TextField("Enter a URL", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .multilineTextAlignment(.center)
                    .focused($editing)
                    .onSubmit { browser.load(draft) }
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)

                Image(systemName: "pencil.and.scribble")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.tildeBlue)
                    .frame(width: 28)
            }
            .padding(.leading, 78)
            .padding(.trailing, 10)
            .frame(height: 40)

            Divider()
            WebView(webView: browser.webView)
        }
        .ignoresSafeArea()
        .onAppear { draft = browser.address }
        .onChange(of: browser.address) { _, address in
            if !editing {
                draft = address
            }
        }
    }

    private func toolbarButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary.opacity(0.75) : Color.primary.opacity(0.25))
        .disabled(!enabled)
    }
}

private struct WebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
}
