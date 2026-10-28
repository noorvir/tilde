import Foundation

/// Replaces or removes one `[table]` of a TOML file, with its sub-tables, and keeps every other
/// line as it was. Enough for Codex's `config.toml`; it does not parse values.
struct TOMLEditor {
    enum Failure: Error, CustomStringConvertible {
        case otherForm(String)

        var description: String {
            switch self {
            case .otherForm(let table):
                return "\(table) is defined without a [\(table)] header; edit it by hand"
            }
        }
    }

    private(set) var lines: [String]

    init(_ text: String) {
        lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }
    }

    var text: String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// The table's lines, header included, without trailing blank lines.
    func table(_ name: String) throws -> [String]? {
        try range(of: name).map { Array(lines[$0]) }
    }

    /// Replaces the table, or appends it after a blank line.
    mutating func set(_ name: String, to table: [String]) throws {
        if let range = try range(of: name) {
            lines.replaceSubrange(range, with: table)
            return
        }
        if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("")
        }
        lines.append(contentsOf: table)
    }

    /// Removes the table and the blank lines after it. Returns false when it does not exist.
    mutating func remove(_ name: String) throws -> Bool {
        guard var range = try range(of: name) else {
            return false
        }
        while range.upperBound < lines.count, lines[range.upperBound].trimmingCharacters(in: .whitespaces).isEmpty {
            range = range.lowerBound..<(range.upperBound + 1)
        }
        lines.removeSubrange(range)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return true
    }

    private func range(of name: String) throws -> Range<Int>? {
        var start: Int?
        var end = lines.count
        var current = ""
        var isInMultilineString = false

        for (index, line) in lines.enumerated() {
            let delimiters = line.components(separatedBy: "\"\"\"").count + line.components(separatedBy: "'''").count - 2
            let wasInMultilineString = isInMultilineString
            if delimiters % 2 == 1 {
                isInMultilineString.toggle()
            }
            if wasInMultilineString {
                continue
            }

            if let header = Self.header(line) {
                current = header
                let isOurs = header == name || header.hasPrefix(name + ".")
                if start == nil, header == name {
                    start = index
                } else if start != nil, !isOurs, end == lines.count {
                    end = index
                }
                continue
            }

            // A dotted key or inline table that defines the same table under another header.
            let key = Self.key(line)
            guard let key, !(current == name || current.hasPrefix(name + ".")) else {
                continue
            }
            let full = current.isEmpty ? key : "\(current).\(key)"
            if full == name || full.hasPrefix(name + ".") {
                throw Failure.otherForm(name)
            }
        }

        guard let start else {
            return nil
        }
        while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            end -= 1
        }
        return start..<end
    }

    /// The table name of a `[table]` or `[[table]]` line, without spaces and quotes.
    private static func header(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let close = trimmed.lastIndex(of: "]") else {
            return nil
        }
        let inner = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
        return inner.filter { $0 != "[" && $0 != "]" && $0 != " " && $0 != "\"" && $0 != "'" }
    }

    /// The key of a `key = value` line, without spaces and quotes.
    private static func key(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else {
            return nil
        }
        return trimmed[..<equals].filter { $0 != " " && $0 != "\"" && $0 != "'" }
    }
}
