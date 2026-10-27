// Test driver for running Tilde end to end on a real screen. It posts real mouse and
// keyboard events and captures the screen, controlled over HTTP on 127.0.0.1:7320.
// It needs Accessibility and Screen Recording, so it runs as its own app (TildeDriver.app)
// and the permissions stay with this driver only. See scripts/build-driver.sh.
//
//   GET  /status                       {"accessibility": bool, "screenRecording": bool}
//   GET  /screenshot                   PNG of the main display
//   POST /mouse {"type": "move|click|down|up|drag", "x", "y", "toX"?, "toY"?}
//   POST /type  {"text": "..."}
//   POST /key   {"code": 36, "command": true}
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

    case ("POST", "/mouse"):
        await mouse(body)
        return json(["ok": true])

    case ("POST", "/type"):
        await type(body["text"] as? String ?? "")
        return json(["ok": true])

    case ("POST", "/key"):
        key(CGKeyCode(body["code"] as? Int ?? 0), command: body["command"] as? Bool ?? false)
        return json(["ok": true])

    default:
        return HTTPResponse(status: 404)
    }
}

func mouse(_ body: [String: Any]) async {
    let point = CGPoint(x: body["x"] as? Double ?? 0, y: body["y"] as? Double ?? 0)

    switch body["type"] as? String {
    case "move":
        post(.mouseMoved, at: point)
    case "down":
        post(.leftMouseDown, at: point)
    case "up":
        post(.leftMouseUp, at: point)
    case "click":
        post(.mouseMoved, at: point)
        try? await Task.sleep(for: .milliseconds(80))
        post(.leftMouseDown, at: point)
        try? await Task.sleep(for: .milliseconds(60))
        post(.leftMouseUp, at: point)
    case "drag":
        let end = CGPoint(x: body["toX"] as? Double ?? point.x, y: body["toY"] as? Double ?? point.y)
        post(.mouseMoved, at: point)
        try? await Task.sleep(for: .milliseconds(80))
        post(.leftMouseDown, at: point)
        for step in 1...12 {
            let t = CGFloat(step) / 12
            try? await Task.sleep(for: .milliseconds(25))
            post(.leftMouseDragged, at: CGPoint(x: point.x + (end.x - point.x) * t, y: point.y + (end.y - point.y) * t))
        }
        try? await Task.sleep(for: .milliseconds(60))
        post(.leftMouseUp, at: end)
    default:
        break
    }
}

func post(_ type: CGEventType, at point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}

func type(_ text: String) async {
    for character in text {
        let units = Array(String(character).utf16)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: isDown)
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event?.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(for: .milliseconds(15))
    }
}

func key(_ code: CGKeyCode, command: Bool) {
    for isDown in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: isDown)
        if command {
            event?.flags = .maskCommand
        }
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
