import AppKit
import os

/// Logs every cursor change with its caller, for finding who changes the cursor while
/// annotating. Off by default; turn it on with
/// `defaults write dev.tilde.app DebugCursor -bool true` and read it with
/// `log show --last 5m --predicate 'subsystem == "dev.tilde.app" AND category == "cursor"'`.
enum CursorDebug {
    static let log = Logger(subsystem: "dev.tilde.app", category: "cursor")
    static let isEnabled = UserDefaults.standard.bool(forKey: "DebugCursor")

    static func install() {
        guard isEnabled,
              let original = class_getInstanceMethod(NSCursor.self, #selector(NSCursor.set)),
              let logging = class_getInstanceMethod(NSCursor.self, #selector(NSCursor.tildeLoggingSet))
        else {
            return
        }
        method_exchangeImplementations(original, logging)
        log.notice("cursor logging on")
    }

    static func name(of cursor: NSCursor) -> String {
        switch cursor {
        case .arrow:
            return "arrow"
        case .crosshair:
            return "crosshair"
        case .iBeam:
            return "iBeam"
        case .pointingHand:
            return "pointingHand"
        default:
            return "other"
        }
    }
}

extension NSCursor {
    /// Swapped with `set` by `CursorDebug.install`, so calling it runs the original `set`.
    @objc fileprivate func tildeLoggingSet() {
        let point = NSEvent.mouseLocation
        let callers = Thread.callStackSymbols.dropFirst(1).prefix(6).map { $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).prefix(1).joined() }
        CursorDebug.log.notice("set \(CursorDebug.name(of: self), privacy: .public) at \(Int(point.x), privacy: .public),\(Int(point.y), privacy: .public) from \(callers.joined(separator: " < "), privacy: .public)")
        tildeLoggingSet()
    }
}
