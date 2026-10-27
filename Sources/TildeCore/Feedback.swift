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

    public init(id: UUID = UUID(), comment: String, target: Target, frame: CGRect, image: Data?) {
        self.id = id
        self.comment = comment
        self.target = target
        self.frame = frame
        self.image = image
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
    public let window: String?
    public let role: String
    public let title: String?
    public let value: String?
    public let label: String?
    public let identifier: String?
    /// Accessibility roles from the window down to the picked element.
    public let path: [String]

    public init(
        app: String,
        window: String?,
        role: String,
        title: String?,
        value: String?,
        label: String?,
        identifier: String?,
        path: [String]
    ) {
        self.app = app
        self.window = window
        self.role = role
        self.title = title
        self.value = value
        self.label = label
        self.identifier = identifier
        self.path = path
    }
}
