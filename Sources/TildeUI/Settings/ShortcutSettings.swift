import AppKit
import SwiftUI

struct ShortcutSettings: View {
    @ObservedObject var shortcuts: ShortcutStore
    @Binding var recording: ShortcutStore.Action?

    var body: some View {
        Form {
        SettingsSection("Keyboard Shortcuts") {
            ForEach(Array(ShortcutStore.Action.allCases.enumerated()), id: \.element) { index, action in
                ShortcutRow(shortcuts: shortcuts, action: action, recording: $recording)
            }
            SettingsRow(title: "Hold to use the app normally", subtitle: "While annotating only: hold the key to click and navigate") {
                Picker("Hold key", selection: $shortcuts.holdKey) {
                    ForEach([DoubleTapKey.control, .option, .shift]) { key in
                        Text(key.holdTitle).tag(DoubleTapKey?.some(key))
                    }
                    Text("Off").tag(DoubleTapKey?.none)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
        }
        .settingsForm()
        .onChange(of: recording, initial: true) { _, action in
            shortcuts.isRecording = action != nil
        }
    }
}

private struct ShortcutRow: View {
    @ObservedObject var shortcuts: ShortcutStore
    let action: ShortcutStore.Action
    @Binding var recording: ShortcutStore.Action?
    @State private var conflict: String?
    @State private var monitor: Any?
    /// Takes a modifier tapped twice as the shortcut while recording.
    @State private var doubleTaps: DoubleTapMonitor?

    private var isRecording: Bool {
        recording == action
    }

    var body: some View {
        let shortcut = shortcuts.shortcut(for: action)

        SettingsRow(title: action.title, subtitle: conflict ?? Self.hint(for: shortcut) ?? action.subtitle, subtitleIsError: conflict != nil) {
            HStack(spacing: 10) {
                if shortcut != action.defaultShortcut {
                    Button {
                        shortcuts.reset(action)
                        conflict = nil
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset to \(action.defaultShortcut?.title ?? "no shortcut")")
                    .accessibilityLabel("Reset to \(action.defaultShortcut?.title ?? "no shortcut")")
                }

                Button {
                    recording = isRecording ? nil : action
                } label: {
                    KeyCaps(caps: shortcut?.caps, isRecording: isRecording)
                }
                .buttonStyle(.plain)
                .help(isRecording ? "Press the new keys, or tap a modifier twice. Esc stops" : "Click to record a new shortcut")
            }
        }
        .onChange(of: isRecording, initial: true) { _, isRecording in
            if isRecording {
                startMonitor()
            } else {
                stopMonitor()
            }
        }
        .onDisappear(perform: stopMonitor)
    }

    /// Takes the next key press: Esc stops, Delete clears the shortcut, and a key with ⌃, ⌥
    /// or ⌘ becomes the shortcut unless another Tilde shortcut has it; so does a modifier
    /// tapped twice.
    private func startMonitor() {
        conflict = nil
        stopMonitor()
        startDoubleTapMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53:
                recording = nil
            case 51, 117:
                _ = shortcuts.set(nil, for: action)
                recording = nil
            default:
                guard let combo = KeyCombo(event: event) else {
                    NSSound.beep()
                    return nil
                }
                if let other = shortcuts.set(.keys(combo), for: action) {
                    conflict = "\(combo.title) is already used by \(other.title)"
                    NSSound.beep()
                    return nil
                }
                recording = nil
            }
            return nil
        }
    }

    private func stopMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        doubleTaps?.invalidate()
        doubleTaps = nil
    }

    /// While recording, a modifier tapped twice by itself becomes the shortcut.
    private func startDoubleTapMonitor() {
        doubleTaps = DoubleTapMonitor(global: false) {
            Set(DoubleTapKey.allCases)
        } onDoubleTap: { key in
            _ = shortcuts.set(.doubleTap(key), for: action)
            recording = nil
        }
    }

    /// A known clash of a double tap with a macOS shortcut.
    static func hint(for shortcut: Shortcut?) -> String? {
        switch shortcut?.doubleTapKey {
        case .control: "If Dictation uses Control twice, pick another"
        case .function: "fn twice is the usual Dictation shortcut"
        default: nil
        }
    }
}

/// Each key in its own light grey cap; "Record shortcut" without one.
struct KeyCaps: View {
    let caps: [String]?
    var isRecording = false

    var body: some View {
        HStack(spacing: 4) {
            if isRecording {
                Text("Press shortcut")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.tildeBlue)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.tildeBlue))
            } else if let caps {
                ForEach(Array(caps.enumerated()), id: \.offset) { _, key in
                    Text(key)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, key.count > 1 ? 6 : 0)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
                }
            } else {
                Text("Record shortcut")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
