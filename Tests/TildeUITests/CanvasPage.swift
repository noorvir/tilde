@testable import TildeUI
import AppKit
import WebKit

/// The drawing canvas's page, as the app loads it, in a web view that is in no window. A test
/// sends it the pointer and key events that the mouse and the keyboard give it, and reads the
/// shapes that it would report. Nothing shows on the screen.
@MainActor
final class CanvasPage: NSObject, WKScriptMessageHandler {
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

    override init() {
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(frame: CGRect(origin: .zero, size: Self.size), configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "tilde")
    }

    /// Loads the page and waits until Excalidraw is ready.
    func load() async throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/TildeUI/DrawingWeb")
        guard let page = DrawingCanvas.page(in: folder) else {
            throw NotReady()
        }
        webView.loadHTMLString(page, baseURL: URL(string: "https://drawing.tilde.invalid/"))
        try await wait { self.messages.contains("ready") }
        try await run(Self.helpers)
    }

    /// What a page in no window does not have: frames to draw in, and a real pointer to
    /// capture. `fire` sends a pointer event to the element at its point, or to `target`, as a
    /// captured pointer does.
    private static let helpers = """
    window.requestAnimationFrame = (run) => setTimeout(() => run(performance.now()), 0);
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
      target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, composed: true, metaKey: Boolean(options.meta), shiftKey: Boolean(options.shift) }));
    };
    0
    """

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let text = message.body as? String, !text.hasPrefix("pointer:") {
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

    /// Lets the page finish what its timers and React hold.
    func settle() async throws {
        try await Task.sleep(for: .milliseconds(60))
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
    func press(_ key: String, meta: Bool = false, shift: Bool = false) async throws {
        try await run("press('\(key)', {meta: \(meta), shift: \(shift)}); 0")
        try await settle()
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
