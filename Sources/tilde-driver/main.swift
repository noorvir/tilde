import CoreMedia
import CoreVideo
// Test driver for running Tilde end to end on a real screen. It posts real mouse and
// keyboard events and captures the screen, controlled over HTTP on 127.0.0.1:7320.
// It needs Accessibility and Screen Recording, so it runs as its own app (TildeDriver.app)
// and the permissions stay with this driver only. See scripts/build-driver.sh.
//
//   GET  /status                       {"accessibility": bool, "screenRecording": bool}
//   GET  /screenshot                   PNG of the main display
//   POST /mouse {"type": "move|click|down|up|drag|scroll", "lines"?, "x", "y", "toX"?, "toY"?}
//   POST /cursor                       {"isHand": bool}
//   POST /type  {"text": "..."}
//   POST /key   {"code": 36, "command": true}
//   POST /tap   {"key": "control|option|shift|command|function"}  a modifier pressed and released
//   POST /ax    {"pid": 123}               the app's windows and menu bar extras as a JSON tree
//   POST /press {"pid": 123, "name": "..."} AXPress on the first element with that name
//   POST /window {"pid": 123, "title": "..."} a picture of that window, as base64 PNG
//   POST /focus                        what a dictation app checks after a paste: the app in
//                                      front, the system-wide focused app and element
// Coordinates are Quartz screen points (top-left origin of the main display).

import TildeCore
import AppKit
import ScreenCaptureKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    if !CGPreflightScreenCaptureAccess() {
        CGRequestScreenCaptureAccess()
    }
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)

    let server = try! HTTPServer(port: 7320) { request in
        await handle(request)
    }
    server.start { status in
        print("driver: \(status)")
    }
    withExtendedLifetime(server) {
        app.run()
    }
}

func handle(_ request: HTTPRequest) async -> HTTPResponse {
    let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]

    switch (request.method, request.path) {
    case ("GET", "/status"):
        return json(["accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess()])

    case ("GET", "/screenshot"):
        guard let png = await screenshot() else {
            return HTTPResponse(status: 500)
        }
        return HTTPResponse(status: 200, headers: ["Content-Type": "image/png"], body: png)

    case ("POST", "/cursor"):
        // The cursor on screen, whichever app set it.
        let current = NSCursor.currentSystem
        return json(["isHand": current?.hotSpot == NSCursor.pointingHand.hotSpot && current?.image.size == NSCursor.pointingHand.image.size])

    case ("POST", "/mouse"):
        await mouse(body)
        return json(["ok": true])

    case ("POST", "/type"):
        await type(body["text"] as? String ?? "")
        return json(["ok": true])

    case ("POST", "/key"):
        key(CGKeyCode(body["code"] as? Int ?? 0), command: body["command"] as? Bool ?? false, shift: body["shift"] as? Bool ?? false, option: body["option"] as? Bool ?? false)
        return json(["ok": true])

    case ("POST", "/modifier"):
        modifier(body["key"] as? String ?? "", down: body["down"] as? Bool ?? false)
        return json(["ok": true])

    case ("POST", "/tap"):
        await tap(body["key"] as? String ?? "")
        return json(["ok": true])

    case ("POST", "/ax"):
        let pid = pid_t(body["pid"] as? Int ?? 0)
        maxDepth = body["depth"] as? Int ?? 40
        return json(["tree": roots(of: pid).map { node($0, depth: 0) }])

    case ("POST", "/window"):
        return json(["png": windowPicture(pid: body["pid"] as? Int ?? 0, title: body["title"] as? String ?? "") as Any])

    case ("POST", "/frames"):
        return json(["heights": await windowHeights(pid: body["pid"] as? Int ?? 0, width: body["width"] as? Double ?? 0, seconds: body["seconds"] as? Double ?? 1)])

    case ("POST", "/edges"):
        let edges = await WindowEdges.record(pid: body["pid"] as? Int ?? 0, width: body["width"] as? Double ?? 0, seconds: body["seconds"] as? Double ?? 1)
        return json(["edges": edges])

    case ("POST", "/focus"):
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1)
        var result: [String: Any] = ["frontmost": frontmostPID()]
        if let app: AXUIElement = axValue(system, kAXFocusedApplicationAttribute) {
            var pid: pid_t = 0
            AXUIElementGetPid(app, &pid)
            result["app"] = Int(pid)
        }
        if let element: AXUIElement = axValue(system, kAXFocusedUIElementAttribute) {
            var isEditable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &isEditable)
            result["role"] = axValue(element, kAXRoleAttribute) as String?
            result["value"] = axValue(element, kAXValueAttribute) as String?
            result["editable"] = isEditable.boolValue
        }
        return json(result)

    case ("POST", "/press"):
        let pid = pid_t(body["pid"] as? Int ?? 0)
        let name = body["name"] as? String ?? ""
        for root in roots(of: pid) {
            if let element = find(name, role: body["role"] as? String, in: root, depth: 0) {
                // Off this thread: pressing a menu bar item blocks until its menu closes.
                nonisolated(unsafe) let target = element
                DispatchQueue.global().async {
                    AXUIElementPerformAction(target, kAXPressAction as CFString)
                }
                return json(["ok": true])
            }
        }
        return json(["ok": false])

    default:
        return HTTPResponse(status: 404)
    }
}

/// The app in front as LaunchServices has it. NSWorkspace in this process can name the app
/// before it for a long time.
func frontmostPID() -> Int {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", #"lsappinfo info -only pid "$(lsappinfo front)""#]
    let output = Pipe()
    process.standardOutput = output
    guard (try? process.run()) != nil else {
        return 0
    }
    process.waitUntilExit()
    // As `"pid"=123`.
    let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return Int(text.split(separator: "=").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
}

func windowPicture(pid: Int, title: String) -> String? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let window = list.first { $0[kCGWindowOwnerPID as String] as? Int == pid && $0[kCGWindowName as String] as? String == title }
    guard let number = window?[kCGWindowNumber as String] as? Int else {
        return nil
    }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l\(number)", file.path]
    try? capture.run()
    capture.waitUntilExit()
    return (try? Data(contentsOf: file))?.base64EncodedString()
}

func modifier(_ name: String, down: Bool) {
    let keys: [String: (CGKeyCode, CGEventFlags)] = [
        "control": (59, .maskControl), "option": (58, .maskAlternate), "shift": (56, .maskShift),
    ]
    guard let (code, flag) = keys[name] else {
        return
    }
    let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
    event?.flags = down ? flag : []
    currentHeldFlags = down ? flag : []
    event?.post(tap: .cghidEventTap)
}

func tap(_ name: String) async {
    let keys: [String: (CGKeyCode, CGEventFlags)] = [
        "control": (59, .maskControl), "option": (58, .maskAlternate), "shift": (56, .maskShift),
        "command": (55, .maskCommand), "function": (63, .maskSecondaryFn),
    ]
    guard let (code, flag) = keys[name] else {
        return
    }
    let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
    down?.flags = flag
    down?.post(tap: .cghidEventTap)
    try? await Task.sleep(for: .milliseconds(40))
    let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
    up?.flags = []
    up?.post(tap: .cghidEventTap)
}

func roots(of pid: pid_t) -> [AXUIElement] {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1)
    // Some of the app's panels report the application itself, which would loop for ever.
    var roots: [AXUIElement] = (axValue(app, kAXWindowsAttribute) as [AXUIElement]? ?? []).filter(isNotApplication)
    if let extras: AXUIElement = axValue(app, "AXExtrasMenuBar") {
        roots.append(extras)
    }
    return roots
}

func axValue<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value as? T
}

/// The element's user-visible name: its title, description or text value.
func axName(_ element: AXUIElement) -> String? {
    for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
        if let text: String = axValue(element, key), !text.isEmpty {
            return text
        }
    }
    return nil
}

nonisolated(unsafe) var maxDepth = 40

func isNotApplication(_ element: AXUIElement) -> Bool {
    (axValue(element, kAXRoleAttribute) as String?) != kAXApplicationRole
}

func node(_ element: AXUIElement, depth: Int) -> [String: Any] {
    var result: [String: Any] = ["role": axValue(element, kAXRoleAttribute) as String? ?? ""]
    result["name"] = axName(element)
    result["enabled"] = axValue(element, kAXEnabledAttribute) as Bool? ?? true
    var position = CGPoint.zero
    var size = CGSize.zero
    var value: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success, let value {
        AXValueGetValue(value as! AXValue, .cgPoint, &position)
    }
    value = nil
    if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success, let value {
        AXValueGetValue(value as! AXValue, .cgSize, &size)
    }
    result["frame"] = [position.x, position.y, size.width, size.height]
    if depth < maxDepth {
        let children: [AXUIElement] = axValue(element, kAXChildrenAttribute) ?? []
        result["children"] = children.filter(isNotApplication).prefix(500).map { node($0, depth: depth + 1) }
    }
    return result
}

func find(_ name: String, role: String?, in element: AXUIElement, depth: Int) -> AXUIElement? {
    if axName(element) == name, role == nil || role == axValue(element, kAXRoleAttribute) as String? {
        return element
    }
    guard depth < 40 else {
        return nil
    }
    let children: [AXUIElement] = axValue(element, kAXChildrenAttribute) ?? []
    for child in children.filter(isNotApplication) {
        if let found = find(name, role: role, in: child, depth: depth + 1) {
            return found
        }
    }
    return nil
}

func mouse(_ body: [String: Any]) async {
    let point = CGPoint(x: body["x"] as? Double ?? 0, y: body["y"] as? Double ?? 0)

    switch body["type"] as? String {
    case "move":
        post(.mouseMoved, at: point)
    case "down":
        post(.leftMouseDown, at: point)
    case "scroll":
        let lines = Int32(body["lines"] as? Int ?? 0)
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
    case "up":
        post(.leftMouseUp, at: point)
    case "dragged":
        post(.leftMouseDragged, at: point)
    case "click":
        post(.mouseMoved, at: point)
        try? await Task.sleep(for: .milliseconds(70))
        post(.leftMouseDown, at: point)
        try? await Task.sleep(for: .milliseconds(50))
        post(.leftMouseUp, at: point)
    case "drag":
        let end = CGPoint(x: body["toX"] as? Double ?? point.x, y: body["toY"] as? Double ?? point.y)
        post(.mouseMoved, at: point)
        try? await Task.sleep(for: .milliseconds(20))
        post(.leftMouseDown, at: point)
        for step in 1...12 {
            let t = CGFloat(step) / 12
            try? await Task.sleep(for: .milliseconds(25))
            post(.leftMouseDragged, at: CGPoint(x: point.x + (end.x - point.x) * t, y: point.y + (end.y - point.y) * t))
        }
        try? await Task.sleep(for: .milliseconds(20))
        post(.leftMouseUp, at: end)
    default:
        break
    }
}

func post(_ type: CGEventType, at point: CGPoint) {
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
    // Explicitly none: posted events otherwise keep the modifiers of the last shortcut.
    event?.flags = currentHeldFlags
    event?.post(tap: .cghidEventTap)
}

/// What `/modifier` holds down now: mouse events carry it, as real ones do.
nonisolated(unsafe) var currentHeldFlags: CGEventFlags = []

func type(_ text: String) async {
    for character in text {
        let units = Array(String(character).utf16)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: isDown)
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            // Explicitly none: posted events otherwise keep the modifiers of the last shortcut.
            event?.flags = []
            event?.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

func key(_ code: CGKeyCode, command: Bool, shift: Bool, option: Bool) {
    for isDown in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: isDown)
        var flags: CGEventFlags = []
        if command {
            flags.insert(.maskCommand)
        }
        if shift {
            flags.insert(.maskShift)
        }
        if option {
            flags.insert(.maskAlternate)
        }
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
}

func screenshot() async -> Data? {
    guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
          let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
    else {
        return nil
    }

    let filter = SCContentFilter(display: display, excludingWindows: [])
    let configuration = SCStreamConfiguration()
    configuration.width = Int(display.frame.width * CGFloat(filter.pointPixelScale))
    configuration.height = Int(display.frame.height * CGFloat(filter.pointPixelScale))
    configuration.showsCursor = true

    guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else {
        return nil
    }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

func json(_ value: [String: Any]) -> HTTPResponse {
    let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
    return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: data)
}

/// Every height a window of this width and app has, in order, without repeats, read as fast as
/// the window list allows.
func windowHeights(pid: Int, width: Double, seconds: Double) async -> [Double] {
    var heights: [Double] = []
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in list where window[kCGWindowOwnerPID as String] as? Int == pid {
            guard let bounds = window[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: bounds), abs(frame.width - width) < 1 else {
                continue
            }
            if heights.last != frame.height {
                heights.append(frame.height)
            }
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return heights
}

/// Records, frame by frame, where the visible part of a window starts and ends, in points from
/// its top. It sees what the screen sees, also when the window itself keeps its size.
final class WindowEdges: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var edges: [[Double]] = []
    private static let scale = 2

    static func record(pid: Int, width: Double, seconds: Double) async -> [[Double]] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { Int($0.owningApplication?.processID ?? 0) == pid && abs($0.frame.width - width) < 1 })
        else {
            return []
        }
        let recorder = WindowEdges()
        let configuration = SCStreamConfiguration()
        configuration.width = Int(width) * scale
        configuration.height = 1000 * scale
        configuration.scalesToFit = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        configuration.showsCursor = false
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration, delegate: nil)
        let queue = DispatchQueue(label: "edges")
        guard (try? stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: queue)) != nil,
              (try? await stream.startCapture()) != nil
        else {
            return []
        }
        try? await Task.sleep(for: .seconds(seconds))
        try? await stream.stopCapture()
        return recorder.lock.withLock { recorder.edges }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let pixels = CMSampleBufferGetImageBuffer(buffer) else {
            return
        }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else {
            return
        }
        let row = CVPixelBufferGetBytesPerRow(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let column = CVPixelBufferGetWidth(pixels) / 2
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        // The middle of the window, from the top: the first and last solid pixel.
        var top = -1
        var bottom = -1
        for y in 0..<height where bytes[y * row + column * 4 + 3] > 200 {
            if top < 0 {
                top = y
            }
            bottom = y
        }
        guard top >= 0 else {
            return
        }
        let edge = [Double(top) / Double(Self.scale), Double(bottom) / Double(Self.scale)]
        lock.withLock {
            if edges.last != edge {
                edges.append(edge)
            }
        }
    }
}
