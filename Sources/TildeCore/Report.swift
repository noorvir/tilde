import Foundation

/// Markdown report of a feedback batch. The same text goes to the agent and into
/// `feedback.md`; screenshot links are relative to the inbox folder.
public func reportText(for feedback: Feedback, folder: URL?) -> String {
    var lines = ["# Visual feedback (\(feedback.annotations.count) annotations)", ""]

    if let folder {
        lines.append("Saved to: \(folder.path)")
    }
    lines.append("Screenshots: each annotation has a close-up of the target (primary) and, when captured, a smaller context image of its surroundings with the target outlined in blue. Use the context image only when you need to know where the target sits. Frames are macOS screen points.")

    // With more than one web page, a line names each page before its annotations.
    let pages = Set(feedback.annotations.compactMap(pageURL(of:)))
    var lastPage: String?
    for (index, annotation) in feedback.annotations.enumerated() {
        let number = index + 1
        if pages.count > 1, let page = pageURL(of: annotation), page != lastPage {
            lines.append("")
            lines.append("# Page: \(page)")
            lastPage = page
        }
        lines.append("")
        lines.append("## \(number). \(heading(for: annotation.target))")
        lines.append("")
        lines.append(contentsOf: quoted(annotation.comment))
        lines.append("")
        lines.append(contentsOf: details(for: annotation.target))
        lines.append("- Frame: \(frameText(annotation.frame))")

        if let image = annotation.image {
            lines.append("")
            lines.append("\(closeUpLabel(number)), \(sizeText(image)):")
            lines.append("![annotation \(number)](\(imageName(number)))")
        }
        if let contextImage = annotation.contextImage {
            lines.append("")
            lines.append("\(contextLabel(number)), \(sizeText(contextImage)):")
            lines.append("![annotation \(number) in context](\(contextImageName(number)))")
        }
        if case .element(.web(let element)) = annotation.target, !element.html.isEmpty {
            lines.append("")
            lines.append("```html")
            lines.append(element.html)
            lines.append("```")
        }
    }

    return lines.joined(separator: "\n") + "\n"
}

/// Caption of an annotation's close-up, in the report and before the image sent to the agent.
public func closeUpLabel(_ number: Int) -> String {
    "Annotation \(number) close-up (primary)"
}

/// Caption of an annotation's context image, in the report and before the image sent to the agent.
public func contextLabel(_ number: Int) -> String {
    "Annotation \(number) context (secondary, only to see where the target sits)"
}

/// File name of the close-up for the annotation with this 1-based number.
public func imageName(_ number: Int) -> String {
    "annotation-\(number).png"
}

/// File name of the context screenshot for the annotation with this 1-based number.
public func contextImageName(_ number: Int) -> String {
    "annotation-\(number)-context.png"
}

private func heading(for target: Target) -> String {
    switch target {
    case .region:
        return "Screen region"
    case .drawing:
        return "Drawing on the screen"
    case .element(.web(let element)):
        return "Web element on \(element.url)"
    case .element(.native(let element)):
        guard let bundleID = element.bundleID else {
            return "Element in \(element.app)"
        }
        return "Element in \(element.app) (\(bundleID))"
    }
}

private func details(for target: Target) -> [String] {
    switch target {
    case .region:
        return []

    case .drawing(let shapes):
        return ["- Shapes, in points from the top left of the screen: `\(shapes)`"]

    case .element(.web(let element)):
        var lines = [
            "- Page title: \(element.title)",
            "- Element: <\(element.tag)>\(snippet(element.text))",
            "- Selector: `\(element.selector)`",
        ]
        if !element.components.isEmpty {
            lines.append("- React components: \(element.components.joined(separator: " › "))")
        }
        if let source = element.source {
            lines.append("- Source: \(source)")
        }
        if !element.styles.isEmpty {
            lines.append("- Styles: \(element.styles)")
        }
        return lines

    case .element(.native(let element)):
        var lines: [String] = []
        if let window = element.window {
            lines.append("- Window: \(window)")
        }
        if let url = element.url {
            lines.append("- URL: \(url)")
        }
        lines.append("- Role: \(friendlyRoleName(element.role)) (\(element.role))")
        if let title = element.title {
            lines.append("- Title: \(title)")
        }
        if let label = element.label {
            lines.append("- Label: \(label)")
        }
        if let value = element.value {
            lines.append("- Value: \(value)")
        }
        if let identifier = element.identifier {
            lines.append("- Identifier: \(identifier)")
        }
        if !element.path.isEmpty {
            lines.append("- Path: \(element.path.joined(separator: " › "))")
        }
        return lines
    }
}

private func quoted(_ comment: String) -> [String] {
    let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty {
        return ["> (no comment)"]
    }
    return text.components(separatedBy: .newlines).map { "> \($0)" }
}

private func snippet(_ text: String) -> String {
    let words = text.split(whereSeparator: { $0.isWhitespace })
    if words.isEmpty {
        return ""
    }
    return " \"\(words.joined(separator: " ").prefix(120))\""
}

/// Pixel size of a PNG, read from its IHDR header, such as "640×120 px".
private func sizeText(_ png: Data) -> String {
    let bytes = [UInt8](png.prefix(24))
    guard bytes.count == 24 else {
        return "size unknown"
    }
    let width = bytes[16..<20].reduce(0) { $0 << 8 | Int($1) }
    let height = bytes[20..<24].reduce(0) { $0 << 8 | Int($1) }
    return "\(width)×\(height) px"
}

private func frameText(_ frame: CGRect) -> String {
    "x=\(Int(frame.minX)) y=\(Int(frame.minY)) w=\(Int(frame.width)) h=\(Int(frame.height))"
}

private func pageURL(of annotation: Annotation) -> String? {
    if case .element(.web(let element)) = annotation.target {
        return element.url
    }
    return nil
}
