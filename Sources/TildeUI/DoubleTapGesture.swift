import AppKit

/// A modifier key that can be a shortcut by tapping it twice alone.
enum DoubleTapKey: String, CaseIterable, Identifiable, Codable {
    case control
    case option
    case shift
    case command
    case function

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        case .function: "fn"
        }
    }

    /// The key's name in the hold key menu.
    var holdTitle: String {
        switch self {
        case .control: "⌃ Control"
        case .option: "⌥ Option"
        case .shift: "⇧ Shift"
        case .command: "⌘ Command"
        case .function: "fn"
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .control: .control
        case .option: .option
        case .shift: .shift
        case .command: .command
        case .function: .function
        }
    }
}

/// Recognises a modifier key tapped twice alone. Any other key, modifier or click while it is
/// down makes it a chord (⌃⌥A, ⌃C, ⌃-click), and a long press is no tap.
struct DoubleTapGesture {
    /// The longest press that still counts as a tap.
    static let tapLength: TimeInterval = 0.3
    /// The longest gap between the first tap's release and the second press.
    static let gap: TimeInterval = 0.3

    private enum State {
        case idle
        case down(since: TimeInterval)
        /// Part of a chord until the key is released.
        case chord
    }

    private var state = State.idle
    private var lastTapEnd: TimeInterval?
    /// The second press came soon enough after a tap.
    private var isSecondPress = false

    /// `key` is whether the modifier is down; `others` whether any other modifier is. Returns
    /// true on the release that completes a double tap.
    mutating func flagsChanged(key: Bool, others: Bool, at time: TimeInterval) -> Bool {
        if others {
            chord()
            return false
        }
        switch (state, key) {
        case (.idle, true):
            isSecondPress = lastTapEnd.map { time - $0 <= Self.gap } ?? false
            state = .down(since: time)
        case (.down(let since), false):
            state = .idle
            guard time - since <= Self.tapLength else {
                lastTapEnd = nil
                return false
            }
            if isSecondPress {
                lastTapEnd = nil
                isSecondPress = false
                return true
            }
            lastTapEnd = time
        case (.chord, false):
            state = .idle
        default:
            break
        }
        return false
    }

    /// Another key or a click, which breaks a tap in progress.
    mutating func otherInput() {
        chord()
    }

    private mutating func chord() {
        lastTapEnd = nil
        isSecondPress = false
        if case .down = state {
            state = .chord
        }
    }
}

/// Finds a double tap of any of some modifiers in a stream of events.
struct DoubleTapDetector {
    private var gestures: [DoubleTapKey: DoubleTapGesture] = [:]

    /// `isFlagsChanged`: a modifier went down or up; otherwise a key or a click. Returns the
    /// key whose double tap this event completed.
    mutating func handle(isFlagsChanged: Bool, flags: NSEvent.ModifierFlags, at time: TimeInterval, watching keys: Set<DoubleTapKey>) -> DoubleTapKey? {
        let flags = flags.intersection([.control, .option, .shift, .command, .function])
        var tapped: DoubleTapKey?
        for key in keys {
            var gesture = gestures[key] ?? DoubleTapGesture()
            if isFlagsChanged {
                if gesture.flagsChanged(key: flags.contains(key.flag), others: !flags.subtracting(key.flag).isEmpty, at: time) {
                    tapped = key
                }
            } else {
                gesture.otherInput()
            }
            gestures[key] = gesture
        }
        return tapped
    }
}

/// Watches every modifier press, key and click, in Tilde and other apps, for a double tap.
/// Other apps' keys need Accessibility; without it, only Tilde's own windows count.
@MainActor
final class DoubleTapMonitor {
    private var detector = DoubleTapDetector()
    private var monitors: [Any] = []
    private let keys: () -> Set<DoubleTapKey>
    private let onDoubleTap: (DoubleTapKey) -> Void

    /// `global`: also watch other apps, not only Tilde.
    init(global: Bool = true, keys: @escaping () -> Set<DoubleTapKey>, onDoubleTap: @escaping (DoubleTapKey) -> Void) {
        self.keys = keys
        self.onDoubleTap = onDoubleTap
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        if global, let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(monitor)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    func invalidate() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
    }

    private func handle(_ event: NSEvent) {
        if let key = detector.handle(isFlagsChanged: event.type == .flagsChanged, flags: event.modifierFlags, at: event.timestamp, watching: keys()) {
            onDoubleTap(key)
        }
    }
}

/// Recognises a modifier held by itself for a moment, to use the mouse as usual while it is
/// down. Another key or modifier first makes it a chord (⌃⌥A, ⌥2), which is no hold.
struct HoldGesture {
    enum Output: Equatable {
        case began
        case ended
    }

    /// How long the key stays down before it counts as held; shorter is a tap.
    static let delay: TimeInterval = 0.15

    private enum State {
        case idle
        case down(since: TimeInterval)
        case holding
        case chord
    }

    private var state = State.idle

    mutating func flagsChanged(key: Bool, others: Bool, at time: TimeInterval) -> Output? {
        if !key {
            let wasHolding: Bool
            if case .holding = state {
                wasHolding = true
            } else {
                wasHolding = false
            }
            state = .idle
            return wasHolding ? .ended : nil
        }
        if others {
            otherInput()
            return nil
        }
        if case .idle = state {
            state = .down(since: time)
        }
        return nil
    }

    /// Another key, which makes a press in progress a chord; a hold goes on.
    mutating func otherInput() {
        if case .down = state {
            state = .chord
        }
    }

    mutating func delayPassed(at time: TimeInterval) -> Output? {
        guard case .down(let since) = state, time - since >= Self.delay - 0.001 else {
            return nil
        }
        state = .holding
        return .began
    }
}

/// Watches the hold key. It exists only while a session is on screen, so nothing is hooked up
/// at any other time.
@MainActor
final class HoldMonitor {
    private var gesture = HoldGesture()
    private var monitors: [Any] = []
    private var timer: Timer?
    private let key: DoubleTapKey
    private let onOutput: (HoldGesture.Output) -> Void

    init(key: DoubleTapKey, onOutput: @escaping (HoldGesture.Output) -> Void) {
        self.key = key
        self.onOutput = onOutput
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    func invalidate() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
        timer?.invalidate()
    }

    private func handle(_ event: NSEvent) {
        guard event.type == .flagsChanged else {
            gesture.otherInput()
            return
        }
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command, .function])
        let time = event.timestamp
        if let output = gesture.flagsChanged(key: flags.contains(key.flag), others: !flags.subtracting(key.flag).isEmpty, at: time) {
            onOutput(output)
        }
        if flags == key.flag {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: HoldGesture.delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let output = self.gesture.delayPassed(at: time + HoldGesture.delay) else {
                        return
                    }
                    self.onOutput(output)
                }
            }
        }
    }
}

/// While the hold key is down, left clicks lose its flag, so they stay plain clicks (a ⌃-click
/// would be a right click). The tap exists only during a hold. Needs Accessibility.
enum PlainClickTap {
    nonisolated(unsafe) private static var port: CFMachPort?
    nonisolated(unsafe) private static var source: CFRunLoopSource?
    nonisolated(unsafe) private static var removed: CGEventFlags = []

    static func start(removing flag: NSEvent.ModifierFlags) {
        stop()
        removed = CGEventFlags(rawValue: UInt64(flag.rawValue))
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        let callback: CGEventTapCallBack = { _, _, event, _ in
            event.flags.remove(PlainClickTap.removed)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: nil) else {
            return
        }
        let loop = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), loop, .commonModes)
        port = tap
        source = loop
    }

    static func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        port = nil
        source = nil
    }
}
