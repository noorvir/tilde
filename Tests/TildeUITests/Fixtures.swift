@testable import TildeUI
import TildeCore
import AppKit

/// Fixed data for UI tests: sessions, drafts and generated screenshots that look the same on
/// every run and every Mac.
@MainActor
enum Fixtures {
    /// A controller with an empty store. Waits for the store's first update, which arrives
    /// on the next run loop pass and would otherwise reset the state a test sets.
    static func controller() async throws -> AnnotationController {
        let controller = AnnotationController(store: SessionStore(), browser: BrowserController())
        try await Task.sleep(for: .milliseconds(20))
        return controller
    }

    /// A session from a store the controller does not watch, so no window opens.
    static func session(client: String = "Codex", message: String? = nil, isLocal: Bool = false) -> SessionStore.Session {
        SessionStore().start(client: client, message: message, url: nil, isLocal: isLocal)
    }

    static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }

    /// Up to three drafts: a web element, a native element and a region, numbered 1 to 3.
    static func drafts(_ count: Int, withImages: Bool = true) -> [Draft] {
        let web = try! JSONDecoder().decode(WebElement.self, from: Data("""
            {"url":"http://localhost:3000/","title":"Docs","tag":"span","selector":"td > .chip","text":"Alex",
             "html":"<span class=\\"chip\\">Alex</span>","components":["App","OwnerChip"],"source":null,"styles":""}
            """.utf8))
        let native = NativeElement(
            app: "Finder", bundleID: "com.apple.finder", window: "Downloads", role: "AXButton",
            title: "Share", value: nil, label: nil, identifier: nil, url: nil, path: ["AXWindow \"Downloads\"", "AXToolbar", "AXButton"]
        )
        let all: [(Target, CGRect, String, String)] = [
            (.element(.web(web)), CGRect(x: 120, y: 90, width: 84, height: 22), "span", "Avatar and name are not vertically centered"),
            (.element(.native(native)), CGRect(x: 300, y: 60, width: 60, height: 28), "button", "Make this button primary"),
            (.region, CGRect(x: 80, y: 180, width: 320, height: 120), "Region", "Too much empty space under the table"),
        ]

        return all.prefix(count).enumerated().map { index, entry in
            let (target, frame, chip, comment) = entry
            let annotation = Annotation(
                id: id(index + 1), comment: comment, target: target, frame: frame,
                image: withImages ? closeUp(index) : nil, contextImage: withImages ? context(index) : nil
            )
            let marker = CGPoint(x: frame.maxX, y: frame.minY)
            return Draft(annotation: annotation, marker: marker, chip: chip, capture: Task { Captures(image: nil, contextImage: nil) })
        }
    }

    /// The hover highlight on the first draft's web element.
    static func hover() -> Picked {
        let draft = drafts(1)[0]
        guard case .element(let element) = draft.annotation.target else {
            fatalError("the first fixture draft is an element")
        }
        return Picked(frame: CGRect(x: 120, y: 240, width: 140, height: 32), element: element, chip: "button", details: ["button  140×32", "\"Save changes\"", "Finder"])
    }

    // MARK: - Images

    /// A close-up: a light card with a blue-outlined pill, like an annotated chip.
    static func closeUp(_ seed: Int) -> Data {
        image(width: 240, height: 80) { context, size in
            context.setFillColor(CGColor(gray: 0.97, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.95, alpha: 1))
            context.addPath(CGPath(roundedRect: CGRect(x: 30, y: 22, width: 180, height: 36), cornerWidth: 18, cornerHeight: 18, transform: nil))
            context.fillPath()
            context.setStrokeColor(CGColor(red: 0.18, green: 0.47, blue: 1, alpha: 1))
            context.setLineWidth(3)
            context.stroke(CGRect(x: 24 + CGFloat(seed) * 2, y: 16, width: 192, height: 48))
        }
    }

    /// A context screenshot: a window with a title bar, rows and an outlined target.
    static func context(_ seed: Int) -> Data {
        image(width: 640, height: 400) { context, size in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            context.setFillColor(CGColor(gray: 0.92, alpha: 1))
            context.fill(CGRect(x: 0, y: size.height - 36, width: size.width, height: 36))
            for row in 0..<6 {
                context.setFillColor(CGColor(gray: row % 2 == 0 ? 0.96 : 0.99, alpha: 1))
                context.fill(CGRect(x: 24, y: size.height - 80 - CGFloat(row) * 44, width: size.width - 48, height: 36))
            }
            context.setStrokeColor(CGColor(red: 0.18, green: 0.47, blue: 1, alpha: 1))
            context.setLineWidth(3)
            context.stroke(CGRect(x: 360, y: size.height - 124 - CGFloat(seed) * 44, width: 160, height: 36))
        }
    }

    private static func image(width: Int, height: Int, draw: (CGContext, CGSize) -> Void) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        draw(context, CGSize(width: width, height: height))
        return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    }
}
