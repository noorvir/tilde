@testable import TildeUI
import AppKit
import WebKit

/// The drawing canvas's page, as the app loads it, in a web view that is in no window. A test
/// sends it the pointer and key events that the mouse and the keyboard give it, and reads the
/// shapes that it would report. Nothing shows on the screen.
@MainActor
final class CanvasPage {
    struct NotReady: Error {}
    struct BadAnswer: Error {}

    /// A shape as the page reports it.
    struct Shape: Equatable {
        var id = ""
        var type = ""
        /// x, y, width and height, in points from the top left of the page.
        var rect: [Double] = []
        var label: String?
        var borders: [String]?
        var rows: Int?
        var columns: Int?
        var filled: Bool?
    }

    static let size = CGSize(width: 1200, height: 800)
    private let webView: WKWebView
    /// What the page posted to Tilde, oldest first, without the pointer's moves.
    private(set) var messages: [String] = []
    /// The pointer's places that the page posted, oldest first, as "x,y".
    private(set) var pointers: [String] = []

    /// `countsFrames`: the page has frames from its start, as in a window, and
    /// `frameRequests()` says how many it asked for.
    init(countsFrames: Bool = false) {
        let configuration = WKWebViewConfiguration()
        if countsFrames {
            configuration.userContentController.addUserScript(WKUserScript(source: Self.countedFrames, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        configuration.userContentController.addUserScript(WKUserScript(source: Self.queuedWork, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: CGRect(origin: .zero, size: Self.size), configuration: configuration)
        configuration.userContentController.add(Messages(page: self), name: "tilde")
    }

    /// Takes the page's messages for a `CanvasPage` without keeping it: the web view keeps its
    /// message handler, and the page object must go at the end of its test.
    private final class Messages: NSObject, WKScriptMessageHandler {
        weak var page: CanvasPage?

        init(page: CanvasPage) {
            self.page = page
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let body = message.body as? String
            MainActor.assumeIsolated {
                page?.received(body)
            }
        }
    }

    /// Each page has a web process of its own. Only a few load and run at one time, so the
    /// tests of other suites that measure time keep their speed.
    private static var freeSlots = 4
    private static var waiting: [CheckedContinuation<Void, Never>] = []
    private var hasSlot = false

    private static func takeSlot() async {
        if freeSlots > 0 {
            freeSlots -= 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private static func giveSlot() {
        if waiting.isEmpty {
            freeSlots += 1
        } else {
            waiting.removeFirst().resume()
        }
    }

    deinit {
        if hasSlot {
            Task { @MainActor in
                CanvasPage.giveSlot()
            }
        }
    }

    /// Loads the page and waits until Excalidraw is ready.
    func load() async throws {
        await Self.takeSlot()
        hasSlot = true
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/TildeUI/DrawingWeb")
        guard let page = DrawingCanvas.page(in: folder) else {
            throw NotReady()
        }
        webView.loadHTMLString(page, baseURL: URL(string: "https://drawing.tilde.invalid/"))
        try await wait { self.messages.contains("ready") }
        try await run(Self.helpers)
    }

    /// Counts the work that the page queued for soon and that has not run yet, from before its
    /// own scripts run: its timers of less than 100 ms, which finish a shape, post the pointer
    /// and give frames, and React's renders, which go through `setImmediate` when the page has
    /// one. Excalidraw's longer timers, such as its debounces, change no shape.
    /// `window.queuedWork()` says how much is left.
    private static let queuedWork = """
    (() => {
      const queued = new Set();
      const setTimer = window.setTimeout;
      const clearTimer = window.clearTimeout;
      window.setTimeout = (run, delay = 0, ...args) => {
        const id = setTimer(() => {
          queued.delete(id);
          run(...args);
        }, delay);
        if (delay < 100) queued.add(id);
        return id;
      };
      window.clearTimeout = (id) => {
        queued.delete(id);
        clearTimer(id);
      };
      window.setImmediate = (run, ...args) => window.setTimeout(run, 0, ...args);
      window.queuedWork = () => queued.size;
    })();
    """

    /// Frames for a page in no window, from before its own scripts run, each one counted.
    private static let countedFrames = """
    window.frameRequests = 0;
    window.requestAnimationFrame = (run) => {
      window.frameRequests += 1;
      return setTimeout(() => run(performance.now()), 0);
    };
    window.cancelAnimationFrame = clearTimeout;
    """

    /// What a page in no window does not have: frames to draw in, and a real pointer to
    /// capture. `fire` sends a pointer event to the element at its point, or to `target`, as a
    /// captured pointer does.
    private static let helpers = """
    if (window.frameRequests === undefined) window.requestAnimationFrame = (run) => setTimeout(() => run(performance.now()), 0);
    Element.prototype.setPointerCapture = () => {};
    Element.prototype.releasePointerCapture = () => {};
    window.fire = (type, x, y, options = {}) => {
      const target = options.target ?? document.elementFromPoint(x, y) ?? document.querySelector("canvas.interactive");
      target.dispatchEvent(new PointerEvent(type, {
        bubbles: true, cancelable: true, composed: true, view: window, clientX: x, clientY: y, pointerId: 1, pointerType: "mouse",
        isPrimary: true, button: 0, buttons: type === "pointerdown" || options.isPressed ? 1 : 0, altKey: Boolean(options.alt), metaKey: Boolean(options.meta),
      }));
      return target;
    };
    window.press = (key, options = {}) => {
      const target = document.activeElement ?? document.body;
      const event = new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, composed: true, metaKey: Boolean(options.meta), shiftKey: Boolean(options.shift) });
      target.dispatchEvent(event);
      return event.defaultPrevented;
    };
    0
    """

    private func received(_ text: String?) {
        guard let text else {
            return
        }
        if text.hasPrefix("pointer:") {
            pointers.append(String(text.dropFirst("pointer:".count)))
        } else {
            messages.append(text)
        }
    }

    /// Waits until `condition` holds, for at most 5 s.
    func wait(until condition: @MainActor () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NotReady()
    }

    /// Waits until the page has done all that the last event or call queued: React has drawn
    /// the change, and a drag's shape is finished. A page in no window can get its timers late,
    /// so no fixed time is enough.
    func settle() async throws {
        try await wait { try await self.run("window.queuedWork()") as? Int == 0 }
    }

    @discardableResult
    func run(_ script: String) async throws -> Any? {
        try await webView.evaluateJavaScript(script)
    }

    /// Calls a function of `window.tildeDraw`, such as `setWireframe({"tool": "card"})`.
    func draw(_ call: String) async throws {
        try await run("window.tildeDraw.\(call); 0")
        try await settle()
    }

    // MARK: - The pointer and the keyboard

    /// The pointer moves to a point with no button down.
    func hover(_ point: CGPoint) async throws {
        try await run("fire('pointermove', \(point.x), \(point.y)); 0")
        try await settle()
    }

    /// A press at `start`, a move to `end` in steps, and the release there. The moves and the
    /// release go to the element of the press, as the page captures the pointer. `on`: a CSS
    /// selector of the element to press, in place of the one at `start`.
    func drag(from start: CGPoint, to end: CGPoint, alt: Bool = false, meta: Bool = false, on selector: String? = nil) async throws {
        let options = "alt: \(alt), meta: \(meta)"
        let target = selector.map { "document.querySelector('\($0)')" } ?? "undefined"
        try await run("fire('pointermove', \(start.x), \(start.y), {\(options)}); 0")
        try await run("window.pressed = fire('pointerdown', \(start.x), \(start.y), {\(options), target: \(target)}); 0")
        for step in 1...4 {
            let x = start.x + (end.x - start.x) * CGFloat(step) / 4
            let y = start.y + (end.y - start.y) * CGFloat(step) / 4
            try await run("fire('pointermove', \(x), \(y), {\(options), isPressed: true, target: window.pressed}); 0")
        }
        try await run("fire('pointerup', \(end.x), \(end.y), {\(options), target: window.pressed}); 0")
        try await settle()
    }

    /// A press and release at one point.
    func click(_ point: CGPoint) async throws {
        try await run("window.pressed = fire('pointerdown', \(point.x), \(point.y)); fire('pointerup', \(point.x), \(point.y), {target: window.pressed}); 0")
        try await settle()
    }

    /// A press on the element of a CSS selector, such as a control of a component's chip.
    func click(on selector: String) async throws {
        let script = """
        (() => {
          const element = document.querySelector('\(selector)');
          if (!element) return false;
          const box = element.getBoundingClientRect();
          const x = box.left + box.width / 2, y = box.top + box.height / 2;
          fire('pointerdown', x, y, {target: element});
          fire('pointerup', x, y, {target: element});
          return true;
        })()
        """
        guard try await run(script) as? Bool == true else {
            throw BadAnswer()
        }
        try await settle()
    }

    /// A key to the element that has the keyboard, such as "Escape", "Backspace" or "z".
    /// Returns whether the page marked it as used: one that it does not, WebKit gives back to
    /// macOS, which plays the alert sound when no window takes it.
    @discardableResult
    func press(_ key: String, meta: Bool = false, shift: Bool = false) async throws -> Bool {
        let isUsed = try await run("press('\(key)', {meta: \(meta), shift: \(shift)})") as? Bool == true
        try await settle()
        return isUsed
    }

    /// How many frames the page asked for since it loaded; for a page that counts them.
    func frameRequests() async throws -> Int {
        guard let count = try await run("window.frameRequests") as? Int else {
            throw BadAnswer()
        }
        return count
    }

    /// Whether a press at a point is for the page, as Tilde asks it with no tool.
    func takesPointer(_ point: CGPoint) async throws -> Bool {
        try await run("window.tildeDraw.takesPointer(\(point.x), \(point.y))") as? Bool == true
    }

    /// Types into the label field that is open on a component.
    func typeLabel(_ text: String) async throws {
        let script = """
        (() => {
          const field = document.getElementById('tilde-label');
          if (field.style.display === 'none') return false;
          field.value = '\(text)';
          field.dispatchEvent(new Event('input', { bubbles: true }));
          return true;
        })()
        """
        guard try await run(script) as? Bool == true else {
            throw BadAnswer()
        }
    }

    /// Whether an element of the page shows, by its CSS selector: it and what it is in are
    /// laid out.
    func shows(_ selector: String) async throws -> Bool {
        let script = "(() => { const element = document.querySelector('\(selector)'); return Boolean(element) && element.getClientRects().length > 0; })()"
        return try await run(script) as? Bool == true
    }

    // MARK: - Shapes

    /// The shapes drawn and not taken, back to front.
    func shapes() async throws -> [Shape] {
        try Self.shapes(in: try await run("window.tildeDraw.newShapes()"))
    }

    /// The same shapes as dictionaries, as `DrawingPanel` gets them.
    func rawShapes() async throws -> [[String: Any]] {
        guard let text = try await run("window.tildeDraw.newShapes()") as? String,
              let shapes = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]
        else {
            throw BadAnswer()
        }
        return shapes
    }

    /// Takes the new shapes, as Done does. Empty when there is none.
    func takeShapes() async throws -> [Shape] {
        let text = try await run("window.tildeDraw.takeNewShapes()") as? String
        return text == "" ? [] : try Self.shapes(in: text)
    }

    private static func shapes(in answer: Any?) throws -> [Shape] {
        guard let text = answer as? String, let list = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else {
            throw BadAnswer()
        }
        return list.map { item in
            Shape(
                id: item["id"] as? String ?? "", type: item["type"] as? String ?? "", rect: (item["rect"] as? [NSNumber] ?? []).map(\.doubleValue),
                label: item["label"] as? String, borders: item["borders"] as? [String], rows: item["rows"] as? Int, columns: item["columns"] as? Int,
                filled: item["filled"] as? Bool
            )
        }
    }
}
