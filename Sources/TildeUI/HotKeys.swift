import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts. Carbon hot keys need no Accessibility or Input Monitoring permission.
@MainActor
final class HotKeys {
    static let pauseTitle = "⌃⌥P"

    private let actions: [UInt32: () -> Void]
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    init(controller: AnnotationController) {
        actions = [
            1: { controller.startLocal() },
            2: { controller.togglePause() },
        ]
        register(id: 1, keyCode: kVK_ANSI_A)
        register(id: 2, keyCode: kVK_ANSI_P)

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
    }

    private func register(id: UInt32, keyCode: Int) {
        var reference: EventHotKeyRef?
        let hotKey = EventHotKeyID(signature: OSType(0x544C_4445), id: id) // "TLDE"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(controlKey | optionKey), hotKey, GetApplicationEventTarget(), 0, &reference)
        if status == noErr, let reference {
            references.append(reference)
        }
    }
}
