import Foundation

/// A JSON value that the installer writes. Members keep their order.
indirect enum JSONValue: Equatable {
    case string(String)
    case array([JSONValue])
    case object([Member])

    struct Member: Equatable {
        let key: String
        let value: JSONValue
    }

    var foundation: Any {
        switch self {
        case .string(let string):
            return string
        case .array(let values):
            return values.map(\.foundation)
        case .object(let members):
            return Dictionary(uniqueKeysWithValues: members.map { ($0.key, $0.value.foundation) })
        }
    }
}

/// Reads and edits one member of a JSON document by splicing text, so every other byte of the
/// file stays as it was. Accepts the comments and trailing commas of JSONC files (VS Code).
struct JSONEditor {
    enum Failure: Error, CustomStringConvertible {
        case syntax(String)
        case notAnObject([String])

        var description: String {
            switch self {
            case .syntax(let message):
                return "not valid JSON (\(message))"
            case .notAnObject(let path):
                return "\"\(path.joined(separator: "."))\" is not a JSON object"
            }
        }
    }

    private(set) var text: String

    init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = trimmed.isEmpty ? "{}\n" : text
    }

    /// The value at `path`, or nil when a key on the path is missing.
    func value(at path: [String]) throws -> Any? {
        let scanner = Scanner(text)
        guard let member = try scanner.member(at: path) else {
            return nil
        }
        let slice = Data(scanner.bytes[member.valueStart..<member.valueEnd])
        return try? JSONSerialization.jsonObject(with: slice, options: .fragmentsAllowed)
    }

    /// Sets the value at `path`, creating missing objects on the way.
    mutating func set(_ path: [String], to value: JSONValue) throws {
        let scanner = Scanner(text)
        var object = try scanner.rootObject()
        var depth = 0

        while depth < path.count - 1, let member = object.members.first(where: { $0.key == path[depth] }) {
            guard scanner.bytes[member.valueStart] == UInt8(ascii: "{") else {
                throw Failure.notAnObject(Array(path[...depth]))
            }
            object = try scanner.object(at: member.valueStart)
            depth += 1
        }

        var nested = value
        for key in path[(depth + 1)...].reversed() {
            nested = .object([.init(key: key, value: nested)])
        }
        let key = path[depth]

        if let member = object.members.first(where: { $0.key == key }) {
            let indent = scanner.lineIndent(at: member.start)
            replace(member.valueStart..<member.valueEnd, in: scanner, with: render(nested, indent: indent, unit: scanner.indentUnit))
        } else {
            insert(key, nested, into: object, scanner: scanner)
        }
    }

    /// Removes the member at `path`. Returns false when it does not exist.
    mutating func remove(_ path: [String]) throws -> Bool {
        let scanner = Scanner(text)
        let parent = path.count == 1 ? try scanner.rootObject() : try scanner.member(at: Array(path.dropLast())).map { try scanner.object(at: $0.valueStart) }
        guard let parent, let index = parent.members.firstIndex(where: { $0.key == path.last }) else {
            return false
        }

        let members = parent.members
        let range: Range<Int>
        if members.count == 1 {
            range = (parent.open + 1)..<parent.close
        } else if index > 0 {
            range = members[index - 1].valueEnd..<members[index].valueEnd
        } else {
            range = members[0].start..<members[1].start
        }
        replace(range, in: scanner, with: "")
        return true
    }

    private mutating func insert(_ key: String, _ value: JSONValue, into object: Scanner.Object, scanner: Scanner) {
        let unit = scanner.indentUnit

        guard let last = object.members.last else {
            let outer = scanner.lineIndent(at: object.open)
            let inner = outer + unit
            let member = "\(quoted(key)): \(render(value, indent: inner, unit: unit))"
            replace(object.open..<(object.close + 1), in: scanner, with: "{\n\(inner)\(member)\n\(outer)}")
            return
        }

        var indent = scanner.lineIndent(at: last.start)
        if !scanner.startsLine(last.start) {
            indent = scanner.lineIndent(at: object.open) + unit
        }
        let member = "\(quoted(key)): \(render(value, indent: indent, unit: unit))"
        let afterLast = scanner.skippingTrivia(from: last.valueEnd)
        if scanner.bytes[afterLast] == UInt8(ascii: ",") {
            // A JSONC trailing comma: keep one after the new last member.
            replace((afterLast + 1)..<(afterLast + 1), in: scanner, with: "\n\(indent)\(member),")
        } else {
            replace(last.valueEnd..<last.valueEnd, in: scanner, with: ",\n\(indent)\(member)")
        }
    }

    private mutating func replace(_ range: Range<Int>, in scanner: Scanner, with replacement: String) {
        var bytes = scanner.bytes
        bytes.replaceSubrange(range, with: Array(replacement.utf8))
        text = String(decoding: bytes, as: UTF8.self)
    }

    private func render(_ value: JSONValue, indent: String, unit: String) -> String {
        switch value {
        case .string(let string):
            return quoted(string)
        case .array(let values):
            return "[" + values.map { render($0, indent: indent, unit: unit) }.joined(separator: ", ") + "]"
        case .object(let members):
            guard !members.isEmpty else {
                return "{}"
            }
            let inner = indent + unit
            let lines = members.map { "\(inner)\(quoted($0.key)): \(render($0.value, indent: inner, unit: unit))" }
            return "{\n\(lines.joined(separator: ",\n"))\n\(indent)}"
        }
    }

    private func quoted(_ string: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}

/// Finds the byte ranges of objects and members in JSON text.
private struct Scanner {
    struct Object {
        let open: Int
        let close: Int
        let members: [Member]
    }

    struct Member {
        let key: String
        /// The opening quote of the key.
        let start: Int
        let valueStart: Int
        let valueEnd: Int
    }

    let bytes: [UInt8]

    init(_ text: String) {
        bytes = Array(text.utf8)
    }

    /// The whitespace one level of the document indents by, from its first member.
    var indentUnit: String {
        guard let root = try? rootObject(), let first = root.members.first else {
            return "  "
        }
        let indent = lineIndent(at: first.start)
        return indent.isEmpty ? "  " : indent
    }

    func rootObject() throws -> Object {
        let start = skippingTrivia(from: 0)
        guard start < bytes.count, bytes[start] == UInt8(ascii: "{") else {
            throw JSONEditor.Failure.notAnObject([])
        }
        return try object(at: start)
    }

    func member(at path: [String]) throws -> Member? {
        var object = try rootObject()
        for (depth, key) in path.enumerated() {
            guard let member = object.members.first(where: { $0.key == key }) else {
                return nil
            }
            if depth == path.count - 1 {
                return member
            }
            guard bytes[member.valueStart] == UInt8(ascii: "{") else {
                return nil
            }
            object = try self.object(at: member.valueStart)
        }
        return nil
    }

    func object(at open: Int) throws -> Object {
        var members: [Member] = []
        var index = skippingTrivia(from: open + 1)

        while index < bytes.count, bytes[index] != UInt8(ascii: "}") {
            let start = index
            let (key, afterKey) = try string(at: index)
            index = skippingTrivia(from: afterKey)
            try expect(":", at: index)
            let valueStart = skippingTrivia(from: index + 1)
            let valueEnd = try valueEnd(from: valueStart)
            members.append(Member(key: key, start: start, valueStart: valueStart, valueEnd: valueEnd))

            index = skippingTrivia(from: valueEnd)
            if index < bytes.count, bytes[index] == UInt8(ascii: ",") {
                index = skippingTrivia(from: index + 1)
            } else {
                try expect("}", at: index)
            }
        }
        try expect("}", at: index)
        return Object(open: open, close: index, members: members)
    }

    func skippingTrivia(from start: Int) -> Int {
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                index += 1
            } else if byte == UInt8(ascii: "/"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "/") {
                while index < bytes.count, bytes[index] != 0x0A {
                    index += 1
                }
            } else if byte == UInt8(ascii: "/"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "*") {
                index += 2
                while index + 1 < bytes.count, !(bytes[index] == UInt8(ascii: "*") && bytes[index + 1] == UInt8(ascii: "/")) {
                    index += 1
                }
                index += 2
            } else {
                break
            }
        }
        return min(index, bytes.count)
    }

    /// Whether only whitespace comes before `index` on its line.
    func startsLine(_ index: Int) -> Bool {
        var start = index
        while start > 0, bytes[start - 1] == 0x20 || bytes[start - 1] == 0x09 {
            start -= 1
        }
        return start == 0 || bytes[start - 1] == 0x0A
    }

    /// The leading whitespace of the line that holds `index`.
    func lineIndent(at index: Int) -> String {
        var lineStart = index
        while lineStart > 0, bytes[lineStart - 1] != 0x0A {
            lineStart -= 1
        }
        var end = lineStart
        while end < index, bytes[end] == 0x20 || bytes[end] == 0x09 {
            end += 1
        }
        return String(decoding: bytes[lineStart..<end], as: UTF8.self)
    }

    private func valueEnd(from start: Int) throws -> Int {
        guard start < bytes.count else {
            throw JSONEditor.Failure.syntax("unexpected end")
        }
        switch bytes[start] {
        case UInt8(ascii: "{"):
            return try object(at: start).close + 1
        case UInt8(ascii: "["):
            var index = skippingTrivia(from: start + 1)
            while index < bytes.count, bytes[index] != UInt8(ascii: "]") {
                index = skippingTrivia(from: try valueEnd(from: index))
                if index < bytes.count, bytes[index] == UInt8(ascii: ",") {
                    index = skippingTrivia(from: index + 1)
                }
            }
            try expect("]", at: index)
            return index + 1
        case UInt8(ascii: "\""):
            return try string(at: start).end
        default:
            var index = start
            while index < bytes.count, !",}] \t\r\n/".utf8.contains(bytes[index]) {
                index += 1
            }
            guard index > start else {
                throw JSONEditor.Failure.syntax("unexpected character at byte \(start)")
            }
            return index
        }
    }

    private func string(at start: Int) throws -> (value: String, end: Int) {
        try expect("\"", at: start)
        var index = start + 1
        while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
            index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
        }
        try expect("\"", at: index)
        let literal = Data(bytes[start...index])
        guard let value = try? JSONSerialization.jsonObject(with: literal, options: .fragmentsAllowed) as? String else {
            throw JSONEditor.Failure.syntax("bad string at byte \(start)")
        }
        return (value, index + 1)
    }

    private func expect(_ character: Character, at index: Int) throws {
        guard index < bytes.count, bytes[index] == character.asciiValue else {
            throw JSONEditor.Failure.syntax("expected \(character) at byte \(index)")
        }
    }
}
