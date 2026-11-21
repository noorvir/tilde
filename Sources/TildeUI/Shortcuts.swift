import AppKit
import Carbon.HIToolbox

/// A global shortcut: a key combination, or a modifier tapped twice by itself.
enum Shortcut: Codable, Equatable {
    case keys(KeyCombo)
    case doubleTap(DoubleTapKey)

    /// The combination, for hot keys and menus; a double tap has none.
    var combo: KeyCombo? {
        if case .keys(let combo) = self {
            return combo
        }
        return nil
    }

    var doubleTapKey: DoubleTapKey? {
        if case .doubleTap(let key) = self {
            return key
        }
        return nil
    }

    /// Key caps: "⌃ ⌥ A", or the modifier twice for a double tap.
    var caps: [String] {
        switch self {
        case .keys(let combo): combo.caps
        case .doubleTap(let key): [key.symbol, key.symbol]
        }
    }

    /// "⌃⌥A" or "Double-tap ⌃".
    var title: String {
        switch self {
        case .keys(let combo): combo.title
        case .doubleTap(let key): "Double-tap \(key.symbol)"
        }
    }

    /// "⌃⌥A" or "⌃⌃", in a key hint.
    var chip: String {
        caps.joined()
    }

    private enum CodingKeys: String, CodingKey {
        case doubleTap
    }

    /// Saved combinations from before double taps decode as combinations.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let key = try container.decodeIfPresent(DoubleTapKey.self, forKey: .doubleTap) {
            self = .doubleTap(key)
            return
        }
        self = .keys(try KeyCombo(from: decoder))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .keys(let combo):
            try combo.encode(to: encoder)
        case .doubleTap(let key):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(key, forKey: .doubleTap)
        }
    }
}

/// A key with at least one of ⌃ ⌥ ⌘ (⇧ may be added); for an in-app action, a key alone.
struct KeyCombo: Codable, Equatable {
    let keyCode: UInt32
    /// `NSEvent.ModifierFlags` raw value, limited to ⌃ ⌥ ⇧ ⌘.
    let modifiers: UInt
    /// The key as shown on its cap, such as "A" or "Space".
    let key: String

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    /// The symbols of the modifiers in the standard order, then the key.
    var caps: [String] {
        let symbols: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return symbols.filter { modifierFlags.contains($0.0) }.map(\.1) + [key]
    }

    var title: String {
        caps.joined()
    }

    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifierFlags.contains(.control) { flags |= UInt32(controlKey) }
        if modifierFlags.contains(.option) { flags |= UInt32(optionKey) }
        if modifierFlags.contains(.shift) { flags |= UInt32(shiftKey) }
        if modifierFlags.contains(.command) { flags |= UInt32(cmdKey) }
        return flags
    }

    /// The menu key equivalent for this shortcut, lowercased as NSMenuItem expects.
    var keyEquivalent: String {
        key.count == 1 ? key.lowercased() : ""
    }

    /// The shortcut for a key-down event, or nil without ⌃, ⌥ or ⌘ unless `allowsKeyAlone`.
    /// Return is never a key alone: it answers the HUD's questions.
    init?(event: NSEvent, allowsKeyAlone: Bool = false) {
        let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        let isKeyAlone = modifiers.intersection([.control, .option, .command]).isEmpty
        guard !isKeyAlone || (allowsKeyAlone && event.keyCode != UInt16(kVK_Return)) else {
            return nil
        }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers.rawValue, key: Self.name(of: event))
    }

    /// The same keys as an event, whatever the names.
    func matches(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        UInt32(keyCode) == self.keyCode && modifiers.intersection([.control, .option, .shift, .command]).rawValue == self.modifiers
    }

    init(keyCode: UInt32, modifiers: UInt, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    private static func name(of event: NSEvent) -> String {
        let named: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = named[Int(event.keyCode)] {
            return name
        }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

/// Tilde's shortcuts, editable in Settings and saved in user defaults: global ones, and keys
/// for the HUD's buttons while Tilde has the keyboard.
@MainActor
final class ShortcutStore: ObservableObject {
    enum Action: String, CaseIterable, Identifiable {
        case startAnnotation
        case togglePause
        case annotationMode
        case recordingMode
        case drawingMode
        case pauseOrResume
        case arrowTool
        case rectangleTool
        case ellipseTool
        case penTool
        case textTool
        case color1
        case color2
        case color3
        case color4
        case color5
        case color6

        /// Where an action works, and its section in Settings.
        enum Group: CaseIterable {
            /// In every app.
            case global
            /// While Tilde's overlay, HUD or browser has the keyboard, where Esc works.
            case modes
            /// The same, while drawing; these keys come before the modes' keys there.
            case drawingTools
            case colors

            var title: String {
                switch self {
                case .global: "Keyboard Shortcuts"
                case .modes: "Modes"
                case .drawingTools: "Drawing Tools"
                case .colors: "Colours"
                }
            }
        }

        var id: String { rawValue }

        var group: Group {
            switch self {
            case .startAnnotation, .togglePause: .global
            case .annotationMode, .recordingMode, .drawingMode, .pauseOrResume: .modes
            case .arrowTool, .rectangleTool, .ellipseTool, .penTool, .textTool: .drawingTools
            case .color1, .color2, .color3, .color4, .color5, .color6: .colors
            }
        }

        /// The drawing tool it picks, as the drawing bar names it.
        var drawingTool: String? {
            switch self {
            case .arrowTool: "arrow"
            case .rectangleTool: "rectangle"
            case .ellipseTool: "ellipse"
            case .penTool: "freedraw"
            case .textTool: "text"
            default: nil
            }
        }

        /// The colour it picks, in the drawing bar's order.
        var drawingColor: (hex: String, name: String)? {
            let colors: [Action] = [.color1, .color2, .color3, .color4, .color5, .color6]
            return colors.firstIndex(of: self).map { HUDView.drawingColors[$0] }
        }

        var title: String {
            switch self {
            case .startAnnotation: "Start or resume annotating"
            case .togglePause: "Pause"
            case .annotationMode: "Annotate"
            case .recordingMode: "Recording mode"
            case .drawingMode: "Draw"
            case .pauseOrResume: "Pause or resume"
            case .arrowTool: "Arrow"
            case .rectangleTool: "Rectangle"
            case .ellipseTool: "Circle"
            case .penTool: "Freehand"
            case .textTool: "Text"
            default: drawingColor?.name ?? rawValue
            }
        }

        var subtitle: String {
            switch self {
            case .startAnnotation: "Starts a session, or resumes a paused one"
            case .togglePause: "Esc also pauses; Esc again discards"
            case .annotationMode: "Annotation mode on or off"
            case .recordingMode: "Into or out of recording mode, as the record toggle"
            case .drawingMode: "Starts drawing, as Draw; Esc puts the tool down"
            case .pauseOrResume: "Pauses or resumes, or records in recording mode"
            case .arrowTool, .rectangleTool, .ellipseTool, .penTool, .textTool: "Draws with this tool"
            default: "Draws in this colour"
            }
        }

        /// Pause has none: Esc pauses.
        var defaultShortcut: Shortcut? {
            switch self {
            case .startAnnotation: .doubleTap(.control)
            case .togglePause: nil
            case .annotationMode, .arrowTool: Self.key(kVK_ANSI_A, "A")
            case .recordingMode, .rectangleTool: Self.key(kVK_ANSI_R, "R")
            case .drawingMode: Self.key(kVK_ANSI_D, "D")
            case .pauseOrResume: Self.key(kVK_Space, "Space")
            case .ellipseTool: Self.key(kVK_ANSI_O, "O")
            case .penTool: Self.key(kVK_ANSI_P, "P")
            case .textTool: Self.key(kVK_ANSI_T, "T")
            case .color1: Self.key(kVK_ANSI_1, "1")
            case .color2: Self.key(kVK_ANSI_2, "2")
            case .color3: Self.key(kVK_ANSI_3, "3")
            case .color4: Self.key(kVK_ANSI_4, "4")
            case .color5: Self.key(kVK_ANSI_5, "5")
            case .color6: Self.key(kVK_ANSI_6, "6")
            }
        }

        private static func key(_ keyCode: Int, _ name: String) -> Shortcut {
            .keys(KeyCombo(keyCode: UInt32(keyCode), modifiers: 0, key: name))
        }

        /// Whether two actions may not share keys. A drawing key may be a mode's key too: while
        /// drawing it wins, so A is the arrow there and annotating elsewhere.
        func clashes(with other: Action) -> Bool {
            let drawing: Set<Group> = [.drawingTools, .colors]
            let isDrawingOverMode = drawing.contains(group) && other.group == .modes || drawing.contains(other.group) && group == .modes
            return !isDrawingOverMode
        }
    }

    /// No entry: the user cleared the shortcut.
    @Published private(set) var shortcuts: [Action: Shortcut] = [:]
    /// While a shortcut is being recorded, the hot keys are off so they do not fire.
    @Published var isRecording = false

    /// The modifier to hold during a session to use the mouse as usual; nil is off.
    @Published var holdKey: DoubleTapKey? {
        didSet { defaults.set(holdKey?.rawValue ?? "off", forKey: "Shortcut.holdKey") }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        // Not through `holdKey`, whose observer would save the key at each launch.
        _holdKey = Published(initialValue: DoubleTapKey(rawValue: defaults.string(forKey: "Shortcut.holdKey") ?? DoubleTapKey.option.rawValue))
        for action in Action.allCases {
            shortcuts[action] = Self.load(action, from: defaults)
        }
    }

    func shortcut(for action: Action) -> Shortcut? {
        shortcuts[action]
    }

    /// The modifiers set to be tapped twice, to watch for.
    var doubleTapKeys: Set<DoubleTapKey> {
        Set(shortcuts.values.compactMap(\.doubleTapKey))
    }

    /// The in-app action for a key press while Tilde has the keyboard: while drawing a tool or
    /// colour first, then a mode, which does nothing while drawing.
    func inAppAction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isDrawing: Bool) -> Action? {
        let groups: [Action.Group] = isDrawing ? [.drawingTools, .colors, .modes] : [.modes]
        for group in groups {
            if let action = Action.allCases.first(where: { $0.group == group && shortcut(for: $0)?.combo?.matches(keyCode: keyCode, modifiers: modifiers) == true }) {
                return action
            }
        }
        return nil
    }

    /// Saves the shortcut, or returns the action that already uses it. Both global actions may
    /// share a double tap: it starts a session when there is none, and pauses or resumes one.
    func set(_ shortcut: Shortcut?, for action: Action) -> Action? {
        if let shortcut, let combo = shortcut.combo,
           let other = Action.allCases.first(where: { $0 != action && action.clashes(with: $0) && self.shortcut(for: $0)?.combo.map { $0.keyCode == combo.keyCode && $0.modifiers == combo.modifiers } == true })
        {
            return other
        }
        shortcuts[action] = shortcut
        let data = try? JSONEncoder().encode(shortcut.map { [$0] } ?? [])
        defaults.set(data, forKey: Self.key(action))
        return nil
    }

    func reset(_ action: Action) {
        shortcuts[action] = action.defaultShortcut
        defaults.removeObject(forKey: Self.key(action))
    }

    /// A missing value is the default; an empty list is a cleared shortcut.
    private static func load(_ action: Action, from defaults: UserDefaults) -> Shortcut? {
        guard let data = defaults.data(forKey: key(action)), let list = try? JSONDecoder().decode([Shortcut].self, from: data) else {
            return action.defaultShortcut
        }
        return list.first
    }

    private static func key(_ action: Action) -> String {
        "Shortcut.\(action.rawValue)"
    }
}
