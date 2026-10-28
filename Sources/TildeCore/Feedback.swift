import CoreGraphics
import Foundation

/// What the user sends back to the agent when they press Send.
public struct Feedback: Sendable {
    public var annotations: [Annotation]

    public init(annotations: [Annotation]) {
        self.annotations = annotations
    }
}

public struct Annotation: Sendable, Identifiable {
    public let id: UUID
    public var comment: String
    public let target: Target
    /// Global screen frame in points, top-left origin (Quartz coordinates).
    public let frame: CGRect
    /// PNG crop of the annotated area. Nil when the screen could not be captured.
    public let image: Data?
    /// PNG of the window (or screen area) around the target, with the target outlined.
    /// Nil when the session asked for no context or it could not be captured.
    public let contextImage: Data?

    public init(id: UUID = UUID(), comment: String, target: Target, frame: CGRect, image: Data?, contextImage: Data?) {
        self.id = id
        self.comment = comment
        self.target = target
        self.frame = frame
        self.image = image
        self.contextImage = contextImage
    }
}

public enum Target: Sendable {
    case region
    case element(Element)
}

public enum Element: Sendable {
    case web(WebElement)
    case native(NativeElement)
}

/// A DOM element picked in the built-in browser.
public struct WebElement: Sendable, Codable, Equatable {
    public let url: String
    public let title: String
    public let tag: String
    public let selector: String
    public let text: String
    public let html: String
    /// React component names from the outermost to the picked element.
    public let components: [String]
    /// Source location such as `src/App.tsx:42`, when the page exposes React debug info.
    public let source: String?
    public let styles: String
}

/// An accessibility element picked in any other app.
public struct NativeElement: Sendable, Equatable {
    public let app: String
    public let bundleID: String?
    public let window: String?
    public let role: String
    public let title: String?
    public let value: String?
    public let label: String?
    public let identifier: String?
    /// Page URL when the element is web content inside the app, such as in Electron or Safari.
    public let url: String?
    /// Compact ancestor chain from the window down to the picked element; see `compactPath`.
    public let path: [String]

    public init(
        app: String,
        bundleID: String?,
        window: String?,
        role: String,
        title: String?,
        value: String?,
        label: String?,
        identifier: String?,
        url: String?,
        path: [String]
    ) {
        self.app = app
        self.bundleID = bundleID
        self.window = window
        self.role = role
        self.title = title
        self.value = value
        self.label = label
        self.identifier = identifier
        self.url = url
        self.path = path
    }
}

/// One Accessibility element on the way from a window to the picked element.
public struct AccessibilityNode: Sendable, Equatable {
    public let role: String
    /// Title, label or identifier.
    public let name: String?
    /// DOM id and classes of web content, such as `#nav.sidebar`.
    public let selector: String?

    public init(role: String, name: String?, selector: String?) {
        self.role = role
        self.name = name
        self.selector = selector
    }
}

/// Formats ancestors, outermost first, as path segments such as `AXGroup "Sidebar"`.
/// For web content the path starts at the innermost web area, which drops the browser or
/// Electron window chrome. Runs of unnamed ancestors with the same role collapse to one
/// segment, such as `AXGroup ×9`. Longer paths keep the last `limit` segments after "…".
public func compactPath(_ nodes: [AccessibilityNode], limit: Int = 8) -> [String] {
    var nodes = nodes[...]
    if let webArea = nodes.lastIndex(where: { $0.role == "AXWebArea" }) {
        nodes = nodes[webArea...]
    }

    var segments: [String] = []
    var run: (role: String, count: Int)?

    func endRun() {
        guard let current = run else {
            return
        }
        segments.append(current.count == 1 ? current.role : "\(current.role) ×\(current.count)")
        run = nil
    }

    for node in nodes {
        if node.name == nil && node.selector == nil {
            if run?.role == node.role {
                run?.count += 1
            } else {
                endRun()
                run = (node.role, 1)
            }
            continue
        }

        endRun()
        var segment = node.role
        if let name = node.name {
            segment += " \"\(name)\""
        }
        if let selector = node.selector {
            segment += " \(selector)"
        }
        segments.append(segment)
    }
    endRun()

    if segments.count > limit {
        return ["…"] + segments.suffix(limit)
    }
    return segments
}
