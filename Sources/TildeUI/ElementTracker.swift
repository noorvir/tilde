import AppKit
import ApplicationServices
import TildeCore

/// An Accessibility element a note is on, in another app's window, so the note can follow it
/// when the content scrolls or the window moves.
struct TrackedElement: @unchecked Sendable {
    let element: AXUIElement
    let pid: pid_t
    let identity: ElementTracker.Identity
}

/// Where tracked elements are now: their frame clipped to the scroll areas around them, or
/// nil when they scrolled out of view or are gone. An element that the app made again (as
/// React apps do when they render) is found again by role and name, nearest to where it
/// was; with no match the note hides rather than show in the wrong place.
enum ElementTracker {
    struct Identity: Equatable, Sendable {
        let role: String
        /// Title, label, value or identifier, whichever the element had.
        let name: String?
        /// The first text inside an element with no name, which tells its content apart.
        var text: String? = nil
    }

    struct Candidate: Equatable {
        let role: String
        let name: String?
        let frame: CGRect
    }

    /// How much of an element must be in view for its note to show.
    static let visibleShare: CGFloat = 0.3

    /// Reads a tracked element's frame now; returns it with the element, which may be a new
    /// one found again. Call off the main thread: Accessibility waits for the other app.
    /// `isGone`: the element no longer exists, as opposed to being scrolled out of view.
    static func locate(_ tracked: TrackedElement, lastFrame: CGRect, findsAgain: Bool = false) -> (frame: CGRect?, tracked: TrackedElement, isGone: Bool) {
        var tracked = tracked
        if findsAgain || !isAlive(tracked.element), let found = refind(tracked, near: lastFrame) {
            tracked = TrackedElement(element: found, pid: tracked.pid, identity: tracked.identity)
        }
        guard isAlive(tracked.element), let frame = frame(of: tracked.element) else {
            return (nil, tracked, true)
        }
        // Lists reuse their rows: the same element with other text is other content.
        if showsOtherText(tracked) {
            return (nil, tracked, false)
        }
        return (visibleFrame(frame, clips: clips(of: tracked.element)), tracked, false)
    }

    // MARK: - Rules

    /// The part of `frame` inside every clip, or nil when too little of it is.
    static func visibleFrame(_ frame: CGRect, clips: [CGRect]) -> CGRect? {
        var visible = frame
        for clip in clips {
            visible = visible.intersection(clip)
            if visible.isNull {
                return nil
            }
        }
        let area = frame.width * frame.height
        guard area > 0, visible.width * visible.height >= area * visibleShare else {
            return nil
        }
        return visible
    }

    /// The candidate with the same role and name nearest to where the element was. Without a
    /// name, only a candidate at almost the same place counts, as many unnamed elements share
    /// a role.
    static func bestMatch(_ candidates: [Candidate], for identity: Identity, near last: CGRect) -> Int? {
        let center = CGPoint(x: last.midX, y: last.midY)
        func distance(_ frame: CGRect) -> CGFloat {
            hypot(frame.midX - center.x, frame.midY - center.y)
        }
        let matches = candidates.indices.filter { index in
            let candidate = candidates[index]
            guard candidate.role == identity.role else {
                return false
            }
            if identity.name == nil {
                return candidate.name == nil && distance(candidate.frame) < 8 && abs(candidate.frame.width - last.width) < 8
            }
            return candidate.name == identity.name
        }
        return matches.min { distance(candidates[$0].frame) < distance(candidates[$1].frame) }
    }

    // MARK: - Accessibility

    static func identity(of element: AXUIElement) -> Identity {
        let role: String = attribute(element, kAXRoleAttribute) ?? "AXUnknown"
        let name = name(of: element)
        return Identity(role: role, name: name, text: name == nil ? firstText(in: element) : nil)
    }

    private static func name(of element: AXUIElement) -> String? {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, "AXIdentifier"] {
            if let text: String = attribute(element, key), !text.isEmpty {
                return String(text.prefix(200))
            }
        }
        return nil
    }

    private static func firstText(in element: AXUIElement) -> String? {
        var queue = [element]
        var visited = 0
        while !queue.isEmpty, visited < 12 {
            let current = queue.removeFirst()
            visited += 1
            let role: String? = attribute(current, kAXRoleAttribute)
            if role == kAXStaticTextRole, let text = name(of: current) {
                return text
            }
            let children: [AXUIElement] = attribute(current, kAXChildrenAttribute) ?? []
            queue.append(contentsOf: children)
        }
        return nil
    }

    private static func showsOtherText(_ tracked: TrackedElement) -> Bool {
        if let original = tracked.identity.text {
            return firstText(in: tracked.element) != original
        }
        guard tracked.identity.role == kAXStaticTextRole, let original = tracked.identity.name else {
            return false
        }
        return name(of: tracked.element) != original
    }

    /// Whether the element is still in its window. An element of a page that left can go on
    /// answering for its role, with no size and no parent.
    private static func isAlive(_ element: AXUIElement) -> Bool {
        guard let frame = frame(of: element), frame.width > 0, frame.height > 0 else {
            return false
        }
        let parent: AXUIElement? = attribute(element, kAXParentAttribute)
        return parent != nil
    }

    /// Frames of the scroll areas and the window around the element.
    private static func clips(of element: AXUIElement) -> [CGRect] {
        var clips: [CGRect] = []
        var current = element
        for _ in 0..<40 {
            guard let parent: AXUIElement = attribute(current, kAXParentAttribute) else {
                break
            }
            let role: String? = attribute(parent, kAXRoleAttribute)
            if role == kAXScrollAreaRole || role == kAXWindowRole, let frame = frame(of: parent) {
                clips.append(frame)
            }
            if role == kAXWindowRole {
                break
            }
            current = parent
        }
        return clips
    }

    /// Searches the app's windows, breadth first and within a budget, for the element again.
    private static func refind(_ tracked: TrackedElement, near last: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(tracked.pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute) ?? []
        var queue = windows.filter { window in
            frame(of: window).map { $0.intersects(last) } ?? false
        }
        var elements: [AXUIElement] = []
        var candidates: [Candidate] = []
        var visited = 0
        while !queue.isEmpty, visited < 4000 {
            let element = queue.removeFirst()
            visited += 1
            let role: String? = attribute(element, kAXRoleAttribute)
            if role == tracked.identity.role, let frame = frame(of: element) {
                elements.append(element)
                candidates.append(Candidate(role: role ?? "", name: name(of: element), frame: frame))
            }
            let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
            queue.append(contentsOf: children)
        }
        return bestMatch(candidates, for: tracked.identity, near: last).map { elements[$0] }
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = attribute(element, kAXPositionAttribute),
              let size: AXValue = attribute(element, kAXSizeAttribute)
        else {
            return nil
        }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &point)
        AXValueGetValue(size, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else {
            return nil
        }
        // AXUIElement and AXValue are CF types: cast without a runtime check.
        if T.self == AXUIElement.self, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return (value as! T)
        }
        if T.self == AXValue.self, CFGetTypeID(value) == AXValueGetTypeID() {
            return (value as! T)
        }
        if T.self == [AXUIElement].self, let array = value as? [AXUIElement] {
            return (array as! T)
        }
        return value as? T
    }
}
