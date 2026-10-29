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
    /// The current page without its fragment.
    @Published private(set) var pageURL: String?
    /// Where each annotation on the current page is, in web view points from the top left.
    /// Annotations on other pages, or not found on this one, have no entry.
    @Published private(set) var anchorRects: [UUID: CGRect] = [:]
    /// Changes when ⌘L asks the toolbar to focus and select the address field.
    @Published private(set) var addressFocusRequest = 0
    /// Whether the notes panel is open beside the page.
    @Published var showsNotes = true
    #if DEBUG
    private var pageFrameForTesting: CGRect?
    #endif
    /// The note whose element the page highlights.
    @Published var selectedNote: UUID?
    /// The note whose outline flashes after Tilde scrolled to it.
    @Published private(set) var flashedNote: UUID?
    /// A note to scroll to once its page has loaded and its element is found.
    private var pendingReveal: UUID?

    /// The session's annotations, which the notes panel lists. Set by the controller.
    weak var controller: AnnotationController?
    /// The annotations to find on each page; set when the drafts change.
    var anchors: [UUID: PageAnchor] = [:] {
        didSet {
            if anchors != oldValue {
                resolveAnchors()
            }
        }
    }

    let webView: WKWebView
    private(set) var window: NSWindow?
    private var observations: [AnyCancellable] = []
    private var isResolving = false
    private var resolvesAgain = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.addUserScript(
            WKUserScript(source: pickerScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        let messages = PageMessages()
        configuration.userContentController.add(messages, name: "tilde")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        messages.onChange = { [weak self] in
            self?.resolveAnchors()
            self?.controller?.refreshHover()
        }

        observations = [
            webView.publisher(for: \.url).sink { [weak self] url in
                self?.address = url?.absoluteString ?? ""
                self?.pageURL = PageAnchor.pageURL(url)
                self?.resolveAnchors()
            },
            webView.publisher(for: \.canGoBack).sink { [weak self] value in self?.canGoBack = value },
            webView.publisher(for: \.canGoForward).sink { [weak self] value in self?.canGoForward = value },
            webView.publisher(for: \.isLoading).sink { [weak self] value in
                self?.isLoading = value
                if !value {
                    self?.resolveAnchors()
                }
            },
            webView.publisher(for: \.title).sink { [weak self] title in self?.window?.title = title ?? "Tilde Browser" },
        ]
    }

    /// The browser window's number while it is on screen.
    /// The page's frame on screen, in AppKit coordinates, while the window is open.
    var pageFrame: CGRect? {
        #if DEBUG
        if let pageFrameForTesting {
            return pageFrameForTesting
        }
        #endif
        guard let window = webView.window, window.isVisible else {
            return nil
        }
        return window.convertToScreen(webView.convert(webView.bounds, to: nil))
    }

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
            // Words without a domain are a search, as in Safari's address bar.
            if !isLocal, trimmed.contains(" ") || !trimmed.contains(".") {
                var search = URLComponents(string: "https://www.google.com/search")!
                search.queryItems = [URLQueryItem(name: "q", value: trimmed)]
                candidate = search.string ?? candidate
            }
        }
        guard let url = URL(string: candidate) else {
            return
        }
        webView.load(URLRequest(url: url))
    }

    func close() {
        window?.close()
    }

    /// Adds cookies, such as logins imported from Chrome, to the browser's persistent store.
    func add(_ cookies: [HTTPCookie]) async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        for cookie in cookies {
            await store.setCookie(cookie)
        }
    }

    /// Removes the browser's cookies, logins, cache and other site data.
    func clearData() async {
        await webView.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    // MARK: - Menu and mouse commands

    @objc func goBack(_ sender: Any?) {
        webView.goBack()
    }

    @objc func goForward(_ sender: Any?) {
        webView.goForward()
    }

    @objc func reload(_ sender: Any?) {
        webView.reload()
    }

    @objc func openLocation(_ sender: Any?) {
        addressFocusRequest += 1
    }

    @objc func zoomIn(_ sender: Any?) {
        webView.pageZoom = min(webView.pageZoom + 0.1, 3)
    }

    @objc func zoomOut(_ sender: Any?) {
        webView.pageZoom = max(webView.pageZoom - 0.1, 0.3)
    }

    @objc func actualSize(_ sender: Any?) {
        webView.pageZoom = 1
    }

    @objc func toggleNotes(_ sender: Any?) {
        showsNotes.toggle()
    }

    /// Browser commands work while the browser window is in front.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard window?.isKeyWindow == true else {
            return false
        }
        switch item.action {
        case #selector(goBack(_:)):
            return webView.canGoBack
        case #selector(goForward(_:)):
            return webView.canGoForward
        case #selector(toggleNotes(_:)):
            item.title = showsNotes ? "Hide Notes" : "Show Notes"
            return true
        default:
            return true
        }
    }

    /// The mouse's side buttons go back and forward over the browser window, and ⌘← and ⌘→
    /// do too while no text field has the keyboard. Runs before the overlay sees the event.
    func handle(_ event: NSEvent) -> Bool {
        guard let window, window.isVisible else {
            return false
        }
        switch event.type {
        case .otherMouseDown where window.frame.contains(NSEvent.mouseLocation):
            if event.buttonNumber == 3 {
                webView.goBack()
                return true
            }
            if event.buttonNumber == 4 {
                webView.goForward()
                return true
            }
        // Esc and ↩ for the session, unless a text field (address, note) has the keyboard.
        case .keyDown where window.isKeyWindow && [53, 36].contains(event.keyCode) && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty:
            guard let controller, controller.session != nil, !(window.firstResponder is NSText) else {
                return false
            }
            if event.keyCode == 53 {
                controller.escapePressed()
                return true
            }
            if controller.confirmation != nil {
                controller.confirm()
                return true
            }
        case .keyDown where window.isKeyWindow && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command:
            guard !(window.firstResponder is NSText) else {
                return false
            }
            if event.keyCode == 123 {
                webView.goBack()
                return true
            }
            if event.keyCode == 124 {
                webView.goForward()
                return true
            }
        default:
            break
        }
        return false
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
        let anchor = PageAnchor(
            url: PageAnchor.pageURL(URL(string: element.url)) ?? element.url, selector: element.selector,
            text: element.text.isEmpty ? nil : String(element.text.prefix(80)),
            documentRect: CGRect(x: rect.x + extras.scrollX, y: rect.y + extras.scrollY, width: rect.width, height: rect.height)
        )
        var picked = Picked(frame: screenRect.flipped, element: .web(element), chip: element.tag, details: details)
        picked.anchor = anchor
        return picked
    }

    /// The anchor of a dragged region (Quartz screen rect) on the current page, or nil when
    /// the region is not over the page.
    func regionAnchor(for rect: CGRect) async -> PageAnchor? {
        guard let window, window.isVisible, let pageURL else {
            return nil
        }
        let viewRect = webView.convert(window.convertFromScreen(rect.flipped), from: nil)
        guard webView.bounds.intersects(viewRect) else {
            return nil
        }
        let top = webView.isFlipped ? viewRect.minY : webView.bounds.height - viewRect.maxY
        let scroll = try? await webView.callAsyncJavaScript("return window.__tilde ? window.__tilde.scroll() : [0, 0]", arguments: [:], contentWorld: .page)
        let offsets = scroll as? [Double] ?? [0, 0]
        let documentRect = CGRect(x: viewRect.minX + offsets[0], y: top + offsets[1], width: viewRect.width, height: viewRect.height)
        return PageAnchor(url: pageURL, selector: nil, text: nil, documentRect: documentRect)
    }

    /// Selects a note and shows its element: scrolls to it on the open page, or opens its page
    /// and scrolls once the element is found there (for up to 3 s).
    func reveal(_ id: UUID) {
        guard let anchor = anchors[id] else {
            return
        }
        selectedNote = id
        guard anchor.url == pageURL else {
            pendingReveal = id
            if let url = URL(string: anchor.url) {
                show(url)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                if self?.pendingReveal == id {
                    self?.pendingReveal = nil
                }
            }
            return
        }
        scroll(to: id)
    }

    /// Centres the note's element in the page, smoothly, and flashes its outline.
    private func scroll(to id: UUID) {
        guard let rect = anchorRects[id] else {
            return
        }
        let offset = rect.midY - webView.bounds.height / 2
        if rect.minY < 0 || rect.maxY > webView.bounds.height {
            webView.evaluateJavaScript("window.scrollBy({ top: \(offset), behavior: 'smooth' })")
        }
        flashedNote = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            if self?.flashedNote == id {
                self?.flashedNote = nil
            }
        }
    }

    /// Finds the anchors of the current page in it again. Runs one lookup at a time; changes
    /// during a lookup run one more.
    func resolveAnchors() {
        guard !isResolving else {
            resolvesAgain = true
            return
        }
        let onPage = anchors.filter { $0.value.url == pageURL }
        guard !onPage.isEmpty else {
            if !anchorRects.isEmpty {
                anchorRects = [:]
            }
            return
        }

        isResolving = true
        let list = onPage.map { id, anchor -> [String: Any] in
            let rect = anchor.documentRect
            var entry: [String: Any] = ["id": id.uuidString, "rect": ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]]
            entry["selector"] = anchor.selector
            entry["text"] = anchor.text
            return entry
        }
        Task {
            defer {
                isResolving = false
                if resolvesAgain {
                    resolvesAgain = false
                    resolveAnchors()
                }
            }
            let result = try? await webView.callAsyncJavaScript(
                "return window.__tilde ? window.__tilde.resolve(anchors) : null", arguments: ["anchors": list], contentWorld: .page
            )
            guard let json = result as? String, let data = json.data(using: .utf8),
                  let rects = try? JSONDecoder().decode([String: Inspection.Rect?].self, from: data)
            else {
                return
            }
            var resolved: [UUID: CGRect] = [:]
            for (id, rect) in rects {
                if let id = UUID(uuidString: id), let rect {
                    resolved[id] = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
                }
            }
            if resolved != anchorRects {
                anchorRects = resolved
            }
            if let id = pendingReveal, resolved[id] != nil {
                pendingReveal = nil
                scroll(to: id)
            }
        }
    }

    /// Snapshot of the web page under `rect` (Quartz coordinates). Needs no Screen Recording
    /// permission. Returns nil when the rect is outside the visible web view.
    func snapshot(of rect: CGRect, outline: CGRect?, maxSide: Double = 1600) async -> Data? {
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
        return ScreenCapture.png(from: cgImage, outline: outline.map { $0.offsetBy(dx: -area.minX, dy: -area.minY) }, scale: scale, maxSide: maxSide)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Tilde Browser"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // An empty unified toolbar makes the title bar toolbar-height, so the traffic lights
        // centre on the address bar that the content draws there.
        window.toolbar = NSToolbar(identifier: "TildeBrowser")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: BrowserView(browser: self))
        // The frame the user last left wins, moved onto a screen if its display is gone; the
        // first time, the window fills the height and half the width of the pointer's screen.
        let screens = NSScreen.screens.map(\.visibleFrame)
        if window.setFrameUsingName(Self.frameName) {
            window.setFrame(Self.onScreen(window.frame, screens: screens), display: false)
        } else if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            window.setFrame(Self.defaultFrame(in: screen.visibleFrame), display: false)
        }
        window.minSize = NSSize(width: BrowserMetrics.minWindowWidth, height: 400)
        window.setFrameAutosaveName(Self.frameName)
        return window
    }

    private static let frameName = "TildeBrowserWindow"

    /// Full height and half the width of a screen's visible area (at least the toolbar's
    /// width), centred, with a small margin.
    nonisolated static func defaultFrame(in visible: CGRect) -> CGRect {
        let margin: CGFloat = 8
        let width = min(max((visible.width / 2).rounded(), BrowserMetrics.minWindowWidth), visible.width - 2 * margin)
        return CGRect(x: (visible.midX - width / 2).rounded(), y: visible.minY + margin, width: width, height: visible.height - 2 * margin)
    }

    /// `frame`, or, when it is not mostly on a screen, the same size moved and shrunk onto the
    /// screen nearest to it. All rectangles in AppKit screen coordinates.
    nonisolated static func onScreen(_ frame: CGRect, screens: [CGRect]) -> CGRect {
        func overlap(_ screen: CGRect) -> CGFloat {
            let shared = frame.intersection(screen)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        if screens.contains(where: { overlap($0) >= frame.width * frame.height * 0.5 }) {
            return frame
        }
        func distance(_ screen: CGRect) -> CGFloat {
            hypot(screen.midX - frame.midX, screen.midY - frame.midY)
        }
        guard let screen = screens.max(by: { overlap($0) == overlap($1) ? distance($0) > distance($1) : overlap($0) < overlap($1) }) else {
            return frame
        }
        let width = min(frame.width, screen.width)
        let height = min(frame.height, screen.height)
        return CGRect(
            x: min(max(frame.minX, screen.minX), screen.maxX - width),
            y: min(max(frame.minY, screen.minY), screen.maxY - height),
            width: width, height: height
        )
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
        let scrollX: Double
        let scrollY: Double
    }
}

/// Receives the page script's "changed" messages. A separate object, because the user
/// content controller keeps its handlers strongly.
private final class PageMessages: NSObject, WKScriptMessageHandler {
    var onChange: @MainActor () -> Void = {}

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            onChange()
        }
    }
}

#if DEBUG
extension BrowserController {
    /// Sets the current page and the found anchors without loading anything, for snapshot
    /// tests. Debug builds only.
    func setStateForTesting(pageURL: String?, anchorRects: [UUID: CGRect], pageFrame: CGRect? = nil, showsNotes: Bool = true) {
        self.pageURL = pageURL
        self.anchorRects = anchorRects
        pageFrameForTesting = pageFrame
        self.showsNotes = showsNotes
    }
}
#endif
