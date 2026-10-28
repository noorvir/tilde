import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut: a key with at least one of ⌃ ⌥ ⌘ (⇧ may be added).
struct Shortcut: Codable, Equatable {
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

    /// The shortcut for a key-down event, or nil without ⌃, ⌥ or ⌘.
    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !modifiers.intersection([.control, .option, .command]).isEmpty else {
            return nil
        }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers.rawValue, key: Self.name(of: event))
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

/// Tilde's global shortcuts, editable in Settings and saved in user defaults.
@MainActor
final class ShortcutStore: ObservableObject {
    enum Action: String, CaseIterable, Identifiable {
        case startAnnotation
        case togglePause

        var id: String { rawValue }

        var title: String {
            switch self {
            case .startAnnotation: "Start annotation"
            case .togglePause: "Pause annotation"
            }
        }

        var subtitle: String {
            switch self {
            case .startAnnotation: "Begin a local annotation session"
            case .togglePause: "Pause or resume the current session"
            }
        }

        var defaultShortcut: Shortcut {
            let controlOption = NSEvent.ModifierFlags([.control, .option]).rawValue
            switch self {
            case .startAnnotation: return Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: controlOption, key: "A")
            case .togglePause: return Shortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: controlOption, key: "P")
            }
        }
    }

    /// No entry: the user cleared the shortcut.
    @Published private(set) var shortcuts: [Action: Shortcut] = [:]
    /// While a shortcut is being recorded, the hot keys are off so they do not fire.
    @Published var isRecording = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for action in Action.allCases {
            shortcuts[action] = Self.load(action, from: defaults)
        }
    }

    func shortcut(for action: Action) -> Shortcut? {
        shortcuts[action]
    }

    /// Saves the shortcut, or returns the action that already uses it.
    func set(_ shortcut: Shortcut?, for action: Action) -> Action? {
        if let shortcut, let other = Action.allCases.first(where: { $0 != action && self.shortcut(for: $0) == shortcut }) {
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
