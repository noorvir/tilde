import Foundation

/// The flow as the contract rows write it: one flat object, such as
/// `{"mode": "recording", "clip": "paused", "notes": 2}`. A key left out has its default: a
/// session annotating with no notes. `sending` keeps the session it goes back to in `returnTo`.
/// An unknown key or value is an error, so a typo cannot test another state.
extension SessionFlow: Codable {
    private enum Key: String, CodingKey, CaseIterable {
        case mode, pauses, drawing, panel, question, clip, operation, thenSend, recordMode, pickerOpen, returnTo
        case notes, commentHasText, commentIsOnDrawing, lastOperation
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }

    private static func unknown(_ value: String, _ decoder: Decoder) -> DecodingError {
        .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown \(value)"))
    }

    init(from decoder: Decoder) throws {
        let known = Set(Key.allCases.map(\.rawValue))
        if let key = try decoder.container(keyedBy: AnyKey.self).allKeys.first(where: { !known.contains($0.stringValue) }) {
            throw Self.unknown("key \(key.stringValue)", decoder)
        }
        let values = try decoder.container(keyedBy: Key.self)
        notes = try values.decodeIfPresent(Int.self, forKey: .notes) ?? 0
        commentHasText = try values.decodeIfPresent(Bool.self, forKey: .commentHasText) ?? false
        commentIsOnDrawing = try values.decodeIfPresent(Bool.self, forKey: .commentIsOnDrawing) ?? false
        lastOperation = try values.decodeIfPresent(Int.self, forKey: .lastOperation) ?? 0
        let operation = try values.decodeIfPresent(Int.self, forKey: .operation) ?? 0

        switch try values.decodeIfPresent(String.self, forKey: .mode) ?? "annotating" {
        case "idle":
            mode = .idle
        case "sent":
            mode = .sent(operation: operation)
        case "sending":
            let returnTo = try values.decodeIfPresent(SessionFlow.self, forKey: .returnTo)
            mode = .sending(operation: operation, returnTo: returnTo?.session ?? Open())
        case "annotating", "recording", "picking":
            mode = .open(try Self.open(from: values, operation: operation, decoder: decoder))
        case let other:
            throw Self.unknown("mode \(other)", decoder)
        }
    }

    private static func open(from values: KeyedDecodingContainer<Key>, operation: Int, decoder: Decoder) throws -> Open {
        var open = Open()
        open.pauses = Set(try values.decodeIfPresent([PauseReason].self, forKey: .pauses) ?? [])
        open.isDrawing = try values.decodeIfPresent(Bool.self, forKey: .drawing) ?? false
        open.panel = try values.decodeIfPresent(Panel.self, forKey: .panel)
        open.question = try values.decodeIfPresent(Question.self, forKey: .question)

        switch try values.decodeIfPresent(String.self, forKey: .mode) ?? "annotating" {
        case "recording":
            let clip: Clip = switch try values.decodeIfPresent(String.self, forKey: .clip) ?? "ready" {
            case "ready": .ready
            case "starting": .starting(operation: operation)
            case "recording": .recording
            case "paused": .paused
            case "finishing": .finishing(operation: operation, thenSend: try values.decodeIfPresent(Bool.self, forKey: .thenSend) ?? false)
            case let other: throw unknown("clip \(other)", decoder)
            }
            open.activity = .recording(clip)
        case "picking":
            open.activity = .picking(
                isRecordMode: try values.decodeIfPresent(Bool.self, forKey: .recordMode) ?? false,
                isPickerOpen: try values.decodeIfPresent(Bool.self, forKey: .pickerOpen) ?? false
            )
        default:
            open.activity = .annotating
        }
        return open
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Key.self)
        try values.encode(notes, forKey: .notes)
        try values.encode(commentHasText, forKey: .commentHasText)
        try values.encode(commentIsOnDrawing, forKey: .commentIsOnDrawing)
        try values.encode(lastOperation, forKey: .lastOperation)

        switch mode {
        case .idle:
            try values.encode("idle", forKey: .mode)
        case .sent(let operation):
            try values.encode("sent", forKey: .mode)
            try values.encode(operation, forKey: .operation)
        case .sending(let operation, let returnTo):
            try values.encode("sending", forKey: .mode)
            try values.encode(operation, forKey: .operation)
            try values.encode(SessionFlow(mode: .open(returnTo)), forKey: .returnTo)
        case .open(let open):
            try Self.encode(open, to: &values)
        }
    }

    private static func encode(_ open: Open, to values: inout KeyedEncodingContainer<Key>) throws {
        try values.encode(open.pauses.sorted(), forKey: .pauses)
        try values.encode(open.isDrawing, forKey: .drawing)
        try values.encodeIfPresent(open.panel, forKey: .panel)
        try values.encodeIfPresent(open.question, forKey: .question)

        switch open.activity {
        case .annotating:
            try values.encode("annotating", forKey: .mode)
        case .picking(let isRecordMode, let isPickerOpen):
            try values.encode("picking", forKey: .mode)
            try values.encode(isRecordMode, forKey: .recordMode)
            try values.encode(isPickerOpen, forKey: .pickerOpen)
        case .recording(let clip):
            try values.encode("recording", forKey: .mode)
            switch clip {
            case .ready:
                try values.encode("ready", forKey: .clip)
            case .starting(let operation):
                try values.encode("starting", forKey: .clip)
                try values.encode(operation, forKey: .operation)
            case .recording:
                try values.encode("recording", forKey: .clip)
            case .paused:
                try values.encode("paused", forKey: .clip)
            case .finishing(let operation, let thenSend):
                try values.encode("finishing", forKey: .clip)
                try values.encode(operation, forKey: .operation)
                try values.encode(thenSend, forKey: .thenSend)
            }
        }
    }
}

/// An event as the contract rows write it: its name, and after a colon what it carries, such
/// as `"clipStarted:1"`, `"choose:phone"` or `"begin:browser"`.
extension SessionFlow.Event: Codable {
    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        let value = parts.count == 2 ? parts[1] : ""
        let operation = Int(value) ?? 0
        let events: [String: SessionFlow.Event] = [
            "begin": .begin(inBrowser: value == "browser"), "ended": .ended, "escape": .escape, "togglePause": .togglePause, "resume": .resume,
            "startShortcut": .startShortcut, "requestClearAll": .requestClearAll, "requestCancel": .requestCancel, "restore": .restore, "openBrowser": .openBrowser, "deleteNote": .deleteNote, "editNote": .editNote,
            "confirm": .confirm, "dismissConfirmation": .dismissConfirmation, "holdBegan": .holdBegan, "holdEnded": .holdEnded,
            "otherAppInFront": .otherAppInFront, "scopeAppInFront": .scopeAppInFront, "openComment": .openComment, "clickAway": .clickAway,
            "submitComment": .submitComment, "closeComment": .closeComment, "openPreview": .openPreview, "closePreview": .closePreview,
            "toggleList": .toggleList, "startDrawing": .startDrawing, "finishDrawing": .finishDrawing, "undoDrawing": .undoDrawing,
            "redoDrawing": .redoDrawing, "shapeFinished": .shapeFinished, "toggleRecordingMode": .toggleRecordingMode, "record": .record,
            "stop": .stop, "clipStarted": .clipStarted(operation), "clipStartFailed": .clipStartFailed(operation),
            "clipFinished": .clipFinished(operation), "clipFailed": .clipFailed(operation), "captureStopped": .captureStopped,
            "windowButton": .windowButton, "openPicker": .openPicker, "choose": .choose(drawable: value != "phone"),
            "send": .send, "sendFinished": .sendFinished(operation), "sendFailed": .sendFailed(operation), "sentShown": .sentShown(operation),
            "pushFailed": .pushFailed,
        ]
        guard let event = events[parts[0]] else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "No event \(text)"))
        }
        self = event
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(describing: self))
    }
}
