import AppKit
import Carbon.HIToolbox
import Combine

/// System-wide shortcuts. Carbon hot keys need no Accessibility or Input Monitoring permission.
/// They follow the `ShortcutStore` and are off while Settings records a new shortcut. While the
/// session holds the keyboard, Esc is one of them: no other app gets it, also one in full screen.
@MainActor
final class HotKeys {
    private let actions: [UInt32: () -> Void]
    private let shortcuts: ShortcutStore
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var subscription: AnyCancellable?
    private var holdsKeyboard = false

    init(controller: AnnotationController, shortcuts: ShortcutStore) {
        self.shortcuts = shortcuts
        actions = [
            1: { controller.dispatch(.startShortcut) },
            2: { controller.dispatch(.togglePause) },
            3: { controller.globalEscapePressed() },
        ]

        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else {
                return OSStatus(eventNotHandledErr)
            }
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            let keys = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                keys.actions[hotKey.id]?()
            }
            return noErr
        }, 1, &event, context, &handler)

        subscription = shortcuts.$shortcuts.combineLatest(shortcuts.$isRecording, controller.$holdsKeyboard.removeDuplicates())
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, holdsKeyboard in
                self?.holdsKeyboard = holdsKeyboard
                self?.registerAll()
            }
    }

    private func registerAll() {
        for reference in references {
            UnregisterEventHotKey(reference)
        }
        references = []
        guard !shortcuts.isRecording else {
            return
        }

        let ids: [ShortcutStore.Action: UInt32] = [.startAnnotation: 1, .togglePause: 2]
        for (action, id) in ids {
            // Double taps are watched by the controller, not registered as hot keys.
            guard let shortcut = shortcuts.shortcut(for: action)?.combo else {
                continue
            }
            register(keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers, id: id)
        }
        if holdsKeyboard {
            register(keyCode: UInt32(kVK_Escape), modifiers: 0, id: 3)
        }
    }

    private func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) {
        var reference: EventHotKeyRef?
        let hotKey = EventHotKeyID(signature: OSType(0x544C_4445), id: id) // "TLDE"
        let status = RegisterEventHotKey(keyCode, modifiers, hotKey, GetApplicationEventTarget(), 0, &reference)
        if status == noErr, let reference {
            references.append(reference)
        }
    }
}
