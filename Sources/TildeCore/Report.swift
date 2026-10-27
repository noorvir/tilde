import Foundation

/// Markdown report of a feedback batch. The same text goes to the agent and into
/// `feedback.md`; screenshot links are relative to the inbox folder.
public func reportText(for feedback: Feedback, folder: URL?) -> String {
    var lines = ["# Visual feedback (\(feedback.annotations.count) annotations)", ""]

    if let folder {
        lines.append("Saved to: \(folder.path)")
    }
    lines.append("Screenshots: one per annotation, in the same order. Frames are macOS screen points.")

    for (index, annotation) in feedback.annotations.enumerated() {
        let number = index + 1
        lines.append("")
        lines.append("## \(number). \(heading(for: annotation.target))")
        lines.append("")
        lines.append(contentsOf: quoted(annotation.comment))
        lines.append("")
        lines.append(contentsOf: details(for: annotation.target))
        lines.append("- Frame: \(frameText(annotation.frame))")

        if annotation.image != nil {
            lines.append("")
            lines.append("![annotation \(number)](\(imageName(number)))")
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

/// File name of the screenshot for the annotation with this 1-based number.
public func imageName(_ number: Int) -> String {
    "annotation-\(number).png"
}

private func heading(for target: Target) -> String {
    switch target {
    case .region:
        return "Screen region"
    case .element(.web(let element)):
        return "Web element on \(element.url)"
    case .element(.native(let element)):
        return "Element in \(element.app)"
    }
}

private func details(for target: Target) -> [String] {
    switch target {
    case .region:
        return []

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
        lines.append("- Role: \(element.role)")
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

private func frameText(_ frame: CGRect) -> String {
    "x=\(Int(frame.minX)) y=\(Int(frame.minY)) w=\(Int(frame.width)) h=\(Int(frame.height))"
}
