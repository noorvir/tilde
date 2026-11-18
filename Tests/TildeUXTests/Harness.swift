import os
import AppKit
import Foundation
import Testing

/// Whether the UX specs run at all: only from scripts/ux.sh, as they take over the screen.
let uxEnabled = ProcessInfo.processInfo.environment["TILDE_UX"] == "1"

/// Waits a limited time: `waitUntilExit` can hang for ever on a concurrency thread.
func waitForExit(_ process: Process, limit: TimeInterval = 10) {
    let end = Date().addingTimeInterval(limit)
    while process.isRunning, Date() < end {
        Thread.sleep(forTimeInterval: 0.05)
    }
}

struct UXFailure: Error, CustomStringConvertible {
    let description: String
}

/// What the user sees: one element of the app's accessibility tree.
struct Seen {
    let role: String
    let name: String?
    let enabled: Bool
    let frame: CGRect
    let children: [Seen]

    init(_ json: [String: Any]) {
        role = json["role"] as? String ?? ""
        name = json["name"] as? String
        enabled = json["enabled"] as? Bool ?? true
        let numbers = json["frame"] as? [Double] ?? [0, 0, 0, 0]
        frame = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        children = (json["children"] as? [[String: Any]] ?? []).map(Seen.init)
    }

    var flattened: [Seen] {
        [self] + children.flatMap(\.flattened)
    }
}

/// A key on the keyboard, by what a user would call it.
enum Key: Int {
    case escape = 53
    case enter = 36
    case w = 13
    case a = 0
    case v = 9
    case leftBracket = 33
    case r = 15
    case space = 49
    case b = 11
    case d = 2
    case c = 8
}

/// A picture of the screen, or an image of the app's, read in points.
struct Picture {
    typealias Color = (red: Double, green: Double, blue: Double)

    private let bitmap: NSBitmapImageRep
    private let scale: Double
    /// Where the picture's top left is: points are read where they are on the screen.
    private let origin: CGPoint

    /// `width`: the picture's width in points.
    init(_ data: Data, width: Double, origin: CGPoint = .zero) throws {
        guard let bitmap = NSBitmapImageRep(data: data) else {
            throw UXFailure(description: "not a picture")
        }
        self.init(bitmap, width: width, origin: origin)
    }

    /// One row of 8-bit BGRA pixels in sRGB, as the driver records them.
    init(row: Data, width: Double, origin: CGPoint) throws {
        let pixels = row.count / 4
        guard let provider = CGDataProvider(data: row as CFData),
              let image = CGImage(
                  width: pixels, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row.count,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else {
            throw UXFailure(description: "not a row of pixels")
        }
        self.init(NSBitmapImageRep(cgImage: image), width: width, origin: origin)
    }

    private init(_ bitmap: NSBitmapImageRep, width: Double, origin: CGPoint) {
        self.bitmap = bitmap
        self.origin = origin
        scale = Double(bitmap.pixelsWide) / width
    }

    var size: CGSize {
        CGSize(width: Double(bitmap.pixelsWide) / scale, height: Double(bitmap.pixelsHigh) / scale)
    }

    private func pixel(x: Int, y: Int) -> Color? {
        guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh, let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
            return nil
        }
        return (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
    }

    /// How many places in the area match, on a grid of every `step` half points in each
    /// direction: the pixels of a 2x screen, so a count is the same whatever the screen's scale.
    func count(in area: CGRect, every step: Int = 2, where matches: (Color) -> Bool) -> Int {
        var count = 0
        let area = area.offsetBy(dx: -origin.x, dy: -origin.y)
        let half = scale / 2
        for y in stride(from: Int(area.minY * 2), to: Int(area.maxY * 2), by: step) {
            for x in stride(from: Int(area.minX * 2), to: Int(area.maxX * 2), by: step) {
                if let color = pixel(x: Int(Double(x) * half), y: Int(Double(y) * half)), matches(color) {
                    count += 1
                }
            }
        }
        return count
    }

    /// The first point from the left on this row that matches, in points.
    func firstX(onRow y: Double, from start: Double, to end: Double, where matches: (Color) -> Bool) -> Double? {
        for x in stride(from: Int((start - origin.x) * scale), to: Int((end - origin.x) * scale), by: 1) {
            if let color = pixel(x: x, y: Int((y - origin.y) * scale)), matches(color) {
                return Double(x) / scale + origin.x
            }
        }
        return nil
    }

    /// Tilde's blue: its outlines, labels and snap guides.
    static func isTildeBlue(_ color: Color) -> Bool {
        color.blue > 0.8 && color.red < 0.35 && color.green > 0.25 && color.green < 0.65
    }

    /// A colour of a wireframe component, in any of its kinds' colours: its fill, lines and
    /// edges, unlike the greys of a window and its text.
    static func isWireframe(_ color: Color) -> Bool {
        isWireframeBlue(color) || isWireframeTeal(color) || isWireframeOrange(color)
    }

    /// The blue of a section, a card, a rectangle and a circle, and of all in One colour.
    static func isWireframeBlue(_ color: Color) -> Bool {
        color.blue > 0.8 && color.blue - color.red > 0.1
    }

    /// The teal of a table and a list.
    static func isWireframeTeal(_ color: Color) -> Bool {
        color.green - color.red > 0.25 && color.blue - color.red > 0.2 && color.blue < color.green + 0.15
    }

    /// The orange of a button and a dropdown, also a button's light inside and its dark edge;
    /// not the fixture's red mark, which has no green.
    static func isWireframeOrange(_ color: Color) -> Bool {
        color.red > 0.65 && color.green > 0.25 && color.red - color.blue > 0.25
    }

    /// The fixture's red mark.
    static func isMark(_ color: Color) -> Bool {
        color.red > 0.85 && color.green < 0.2 && color.blue < 0.2
    }
}

/// The built app in a throwaway environment, driven from outside: real input and the
/// accessibility tree through TildeDriver, MCP over HTTP, and files on disk.
final class TildeApp {
    let port: Int
    let sessions: URL
    let nodes: URL
    let inbox: URL
    private static let driver = URL(string: "http://127.0.0.1:7320")!
    private static var nextPort = 7340

    /// `sharing`: keeps the saved sessions of an app run before, as after a crash.
    init(sharing other: TildeApp? = nil) throws {
        Self.nextPort += 1
        port = Self.nextPort
        let root = other?.sessions.deletingLastPathComponent()
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("tilde-ux-\(UUID().uuidString)", isDirectory: true)
        sessions = root.appendingPathComponent("sessions", isDirectory: true)
        nodes = root.appendingPathComponent("nodes.json")
        inbox = root.appendingPathComponent("inbox", isDirectory: true)
        try launch()
    }

    /// Starts the app as Finder would, so macOS applies its own permissions.
    private func launch() throws {
        Self.stopAll()
        let bundle = ProcessInfo.processInfo.environment["TILDE_UX_APP"] ?? "build/TildeUX.app"
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [
            "-n", "--env", "TILDE_PORT=\(port)", "--env", "TILDE_SESSIONS=\(sessions.path)", "--env", "TILDE_NODES=\(nodes.path)", "--env", "TILDE_INBOX=\(inbox.path)", bundle,
        ]
        try open.run()
        waitForExit(open)
    }

    /// Stops every copy of the test app and waits until they are gone, so the next launch is
    /// the only one that answers.
    private static func stopAll() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.tilde.ux")
        // A screen capture that reaches replayd from a process that is gone counts as denied,
        // and macOS asks its screen capture question again. Stopped first, the app sends no
        // more, and replayd answers the ones under way while the process is still there.
        for app in running {
            Darwin.kill(app.processIdentifier, SIGSTOP)
        }
        if !running.isEmpty {
            // Not the run loop: on a test's thread it has no sources and returns at once.
            Thread.sleep(forTimeInterval: 0.2)
        }
        for app in running {
            Darwin.kill(app.processIdentifier, SIGKILL)
        }
        for _ in 0..<50 where !NSRunningApplication.runningApplications(withBundleIdentifier: "dev.tilde.ux").filter({ !$0.isTerminated }).isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    private var running: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "dev.tilde.ux").first { !$0.isTerminated }
    }

    static func resetSettings() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["delete", "dev.tilde.ux"]
        task.standardError = FileHandle.nullDevice
        try? task.run()
        waitForExit(task)
    }

    /// Fresh settings and sessions, as on a new Mac, with `defaults` set.
    static func launched(defaults: [String: String] = [:]) async throws -> TildeApp {
        // A macOS question, such as the screen capture one, would take the spec's clicks; the
        // specs never answer it.
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.UserNotificationCenter").isEmpty {
            throw UXFailure(description: "A macOS question is on the screen (UserNotificationCenter), such as the screen capture one: answer it, then run again")
        }
        resetSettings()
        for (key, value) in defaults {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            task.arguments = ["write", "dev.tilde.ux", key, value]
            try task.run()
            waitForExit(task)
        }
        let app = try TildeApp()
        try await app.waitForServer()
        return app
    }

    static func relaunched(after other: TildeApp) async throws -> TildeApp {
        let app = try TildeApp(sharing: other)
        try await app.waitForServer()
        return app
    }

    func quit() {
        Self.stopAll()
    }

    /// As a crash: the app gets no chance to save.
    func kill() {
        Self.stopAll()
    }

    var pid: Int {
        Int(running?.processIdentifier ?? 0)
    }

    func waitForServer() async throws {
        for _ in 0..<50 {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!, timeoutInterval: 2)
            request.httpMethod = "GET"
            if (try? await URLSession.shared.data(for: request)) != nil {
                try await Task.sleep(for: .milliseconds(100))
                return
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw UXFailure(description: "Tilde did not start its MCP server")
    }

    // MARK: - Driver

    @discardableResult
    private func drive(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: Self.driver.appendingPathComponent(path), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// A picture that the driver makes, such as a part of the screen.
    private func drivePicture(_ path: String, _ body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: Self.driver.appendingPathComponent(path), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UXFailure(description: "no picture from \(path)")
        }
        return data
    }

    /// Tilde's list of remote machines, as if they were installed.
    func setNodes(_ hosts: [String]) throws {
        let list = hosts.map { ["host": $0, "token": "test"] }
        try FileManager.default.createDirectory(at: nodes.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: list).write(to: nodes)
    }

    /// Everything on screen from the app.
    func seen() async throws -> [Seen] {
        let result = try await drive("ax", ["pid": pid])
        return (result["tree"] as? [[String: Any]] ?? []).map(Seen.init).flatMap(\.flattened)
    }

    /// Waits until another app, such as Safari, shows an element with this name.
    func waitToSee(_ name: String, inApp appName: String, timeout: Double = 20, sourceLocation: SourceLocation = #_sourceLocation) async throws -> Seen {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) {
                let result = try await drive("ax", ["pid": app.processIdentifier])
                if let found = (result["tree"] as? [[String: Any]] ?? []).map(Seen.init).flatMap(\.flattened).first(where: { $0.name == name }) {
                    return found
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        await saveFailure(named: name)
        Issue.record("\"\(name)\" is not on screen in \(appName)", sourceLocation: sourceLocation)
        throw UXFailure(description: "\(name) is not on screen in \(appName)")
    }

    /// Presses the control with this name through Accessibility, as VoiceOver does: also when
    /// another app's window is in front of it.
    func accessibilityPress(_ name: String, role: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await waitToSee(name, role: role, sourceLocation: sourceLocation)
        var body: [String: Any] = ["pid": pid, "name": name]
        body["role"] = role
        _ = try await drive("press", body)
    }

    /// Clicks the control with this name with the mouse, as a user does: unlike an
    /// accessibility press, this also makes the app active.
    func press(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await clickText(name, sourceLocation: sourceLocation)
    }

    func key(_ key: Key, command: Bool = false, shift: Bool = false, option: Bool = false) async throws {
        try await drive("key", ["code": key.rawValue, "command": command, "shift": shift, "option": option])
        try await Task.sleep(for: .milliseconds(40))
    }

    func type(_ text: String) async throws {
        try await drive("type", ["text": text])
        try await Task.sleep(for: .milliseconds(30))
    }

    /// Puts text on the clipboard and presses ⌘V, as a dictation app does with what it heard.
    func paste(_ text: String) async throws {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        try await key(.v, command: true)
    }

    /// What a dictation app checks after a paste: the app in front, and the app and element
    /// that have the keyboard on the whole Mac.
    struct Focus {
        let frontmost: Int
        let app: Int?
        let role: String?
        let value: String?
        let isEditable: Bool
    }

    func focus() async throws -> Focus {
        let result = try await drive("focus", [:])
        return Focus(
            frontmost: result["frontmost"] as? Int ?? 0, app: result["app"] as? Int, role: result["role"] as? String,
            value: result["value"] as? String, isEditable: result["editable"] as? Bool ?? false
        )
    }

    /// A double tap as a hand makes it. For about half a second after a window closes, macOS
    /// can hold keys on their way to the apps and stamp them late, so that the taps reach the
    /// apps as a long press: the driver says so, and the double tap is made again once that
    /// time is over, as a user would.
    func doubleTap(_ modifier: String) async throws {
        for _ in 0..<3 {
            let result = try await drive("tap", ["key": modifier, "count": 2])
            try await Task.sleep(for: .milliseconds(80))
            if result["onTime"] as? Bool != false {
                return
            }
            try await Task.sleep(for: .milliseconds(400))
        }
    }

    func hold(_ modifier: String, down: Bool) async throws {
        try await drive("modifier", ["key": modifier, "down": down])
        try await Task.sleep(for: .milliseconds(80))
    }

    func click(at point: CGPoint) async throws {
        try await drive("mouse", ["type": "move", "x": point.x, "y": point.y])
        try await Task.sleep(for: .milliseconds(100))
        try await drive("mouse", ["type": "click", "x": point.x, "y": point.y])
        try await Task.sleep(for: .milliseconds(100))
    }

    /// A drag that rests at its end before the release, as a hand does.
    func slowDrag(from start: CGPoint, to end: CGPoint) async throws {
        try await drive("mouse", ["type": "move", "x": start.x, "y": start.y])
        try await Task.sleep(for: .milliseconds(50))
        try await drive("mouse", ["type": "down", "x": start.x, "y": start.y])
        for step in 1...8 {
            let t = CGFloat(step) / 8
            try await drive("mouse", ["type": "dragged", "x": start.x + (end.x - start.x) * t, "y": start.y + (end.y - start.y) * t])
            try await Task.sleep(for: .milliseconds(40))
        }
        try await Task.sleep(for: .milliseconds(400))
        try await drive("mouse", ["type": "dragged", "x": end.x, "y": end.y])
        try await Task.sleep(for: .milliseconds(60))
        try await drive("mouse", ["type": "up", "x": end.x, "y": end.y])
    }

    /// A drag in its parts, to look at the screen while the button is down.
    func mouseDown(at point: CGPoint) async throws {
        try await drive("mouse", ["type": "move", "x": point.x, "y": point.y])
        try await Task.sleep(for: .milliseconds(50))
        try await drive("mouse", ["type": "down", "x": point.x, "y": point.y])
    }

    func mouseDragged(to point: CGPoint) async throws {
        try await drive("mouse", ["type": "dragged", "x": point.x, "y": point.y])
        try await Task.sleep(for: .milliseconds(40))
    }

    func mouseUp(at point: CGPoint) async throws {
        try await drive("mouse", ["type": "up", "x": point.x, "y": point.y])
    }

    func drag(from start: CGPoint, to end: CGPoint) async throws {
        try await drive("mouse", ["type": "drag", "x": start.x, "y": start.y, "toX": end.x, "toY": end.y])
    }

    /// A real scroll wheel at a point; negative scrolls the page down.
    func scroll(at point: CGPoint, by lines: Int) async throws {
        try await drive("mouse", ["type": "move", "x": point.x, "y": point.y])
        try await drive("mouse", ["type": "scroll", "x": point.x, "y": point.y, "lines": lines])
    }

    func hover(over point: CGPoint) async throws {
        try await drive("mouse", ["type": "move", "x": point.x, "y": point.y])
    }

    /// Clicks the element with this text, such as on a web page.
    func clickText(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        // Windows can still be moving just after they open: wait until it holds still.
        var element = try await waitToSee(text, sourceLocation: sourceLocation)
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(30))
            let again = try await waitToSee(text, sourceLocation: sourceLocation)
            if again.frame == element.frame {
                break
            }
            element = again
        }
        try await click(at: CGPoint(x: element.frame.midX, y: element.frame.midY))
    }

    // MARK: - Expectations

    /// Waits until an element with this name, and this role when one is given, is on screen.
    @discardableResult
    func waitToSee(_ name: String, role: String? = nil, timeout: Double = 10, sourceLocation: SourceLocation = #_sourceLocation) async throws -> Seen {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let found = try await seen().first(where: { $0.name == name && (role == nil || $0.role == role) }) {
                return found
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        await saveFailure(named: name)
        let names = try await seen().compactMap(\.name)
        Issue.record("\"\(name)\" is not on screen. On screen: \(names.prefix(40))", sourceLocation: sourceLocation)
        throw UXFailure(description: "\(name) is not on screen")
    }

    /// Keeps a picture of the screen for a failed expectation, and the app's last 30 s of note
    /// decisions, in the temporary folder.
    func saveFailure(named name: String) async {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-ux-failure-\(name.prefix(12))")
        let log = Process()
        log.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        log.arguments = ["show", "--last", "30s", "--style", "compact", "--predicate", #"subsystem == "dev.tilde.app" AND category == "annotate""#]
        FileManager.default.createFile(atPath: base.appendingPathExtension("log").path, contents: nil)
        log.standardOutput = try? FileHandle(forWritingTo: base.appendingPathExtension("log"))
        try? log.run()
        waitForExit(log)

        guard let (data, _) = try? await URLSession.shared.data(from: Self.driver.appendingPathComponent("screenshot")) else {
            return
        }
        try? data.write(to: base.appendingPathExtension("png"))
    }

    /// Waits until no element with this name is on screen.
    func waitNotToSee(_ name: String, timeout: Double = 10, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if try await !seen().contains(where: { $0.name == name }) {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("\"\(name)\" is still on screen", sourceLocation: sourceLocation)
    }

    /// Waits until some text containing this is on screen.
    @discardableResult
    func waitToSeeText(containing part: String, timeout: Double = 10, sourceLocation: SourceLocation = #_sourceLocation) async throws -> Seen {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let found = try await seen().first(where: { $0.name?.contains(part) == true }) {
                return found
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let names = try await seen().compactMap(\.name)
        Issue.record("No text with \"\(part)\" on screen. On screen: \(names.prefix(40))", sourceLocation: sourceLocation)
        throw UXFailure(description: "\(part) is not on screen")
    }

    // MARK: - Menu bar

    /// Clicks the menu bar item to open its menu, as a user does.
    func openMenu() async throws {
        let item = try await waitToSeeRole("AXMenuBarItem")
        try await click(at: CGPoint(x: item.frame.midX, y: item.frame.midY))
        try await Task.sleep(for: .milliseconds(80))
    }

    /// Opens the menu and presses an item. The app keeps the keyboard in the menu afterwards,
    /// so flows that type next start another way.
    func menu(_ item: String) async throws {
        try await openMenu()
        try await waitToSee(item)
        try await drive("press", ["pid": pid, "name": item, "role": "AXMenuItem"])
        try await Task.sleep(for: .milliseconds(100))
    }

    private func waitToSeeRole(_ role: String) async throws -> Seen {
        for _ in 0..<30 {
            if let found = try await seen().first(where: { $0.role == role }) {
                return found
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw UXFailure(description: "no \(role) on screen")
    }

    // MARK: - Screen pictures

    /// The whole screen now.
    func screen() async throws -> Picture {
        let (data, _) = try await URLSession.shared.data(from: Self.driver.appendingPathComponent("screenshot"))
        guard let screen = NSScreen.screens.first else {
            throw UXFailure(description: "no screen")
        }
        return try Picture(data, width: screen.frame.width)
    }

    /// One row of the screen in every frame that it showed for `seconds`, oldest first, without
    /// repeats: what a user saw there, frame by frame.
    func recordRow(at y: Double, from x: Double, width: Double, seconds: Double) async throws -> [Picture] {
        let result = try await drive("row", ["x": x, "y": y, "width": width, "seconds": seconds])
        let frames = result["frames"] as? [String] ?? []
        return try frames.compactMap { Data(base64Encoded: $0) }.map { try Picture(row: $0, width: width, origin: CGPoint(x: x, y: y)) }
    }

    /// Waits until the row that `recordRow` records has its first frame, so that input sent
    /// after this shows in it.
    func waitForRowRecording() async throws {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            let (data, _) = try await URLSession.shared.data(from: Self.driver.appendingPathComponent("row/started"))
            if (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["started"] as? Bool == true {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw UXFailure(description: "The row recording did not start")
    }

    /// An area of the screen now, the part of it on the screen, quicker to take than the whole
    /// screen: a 2x screen has four times the pixels to take and read.
    func screen(in area: CGRect) async throws -> Picture {
        let screens = Self.screenFrames
        guard let screen = screens.first(where: { $0.contains(CGPoint(x: area.midX, y: area.midY)) }) ?? screens.first else {
            throw UXFailure(description: "no screen")
        }
        let area = area.intersection(screen)
        guard !area.isEmpty else {
            throw UXFailure(description: "\(area) is off the screen")
        }
        let data = try await drivePicture("strip", ["x": area.minX, "y": area.minY, "width": area.width, "height": area.height])
        return try Picture(data, width: area.width, origin: area.origin)
    }

    /// The frames of the displays in Quartz points, from the main one's top left; the main one
    /// first. From the window server: AppKit's list in this process can lag behind it.
    static var screenFrames: [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        let main = CGMainDisplayID()
        return displays.sorted { first, _ in first == main }.map(CGDisplayBounds)
    }

    /// How many Tilde-blue pixels are on screen in this area: notes are drawn, so they have no
    /// accessibility elements to read.
    func bluePixels(in area: CGRect) async throws -> Int {
        try await screen(in: area).count(in: area, where: Picture.isTildeBlue)
    }

    /// Waits until the area has at least, or at most, this many blue pixels.
    func waitForBlue(in area: CGRect, atLeast: Int = 0, atMost: Int = .max, timeout: Double = 6, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let end = Date().addingTimeInterval(timeout)
        var last = 0
        while Date() < end {
            last = try await bluePixels(in: area)
            if last >= atLeast, last <= atMost {
                return
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        Issue.record("\(last) blue pixels, expected \(atLeast)...\(atMost)", sourceLocation: sourceLocation)
        await saveFailure(named: "blue-\(sourceLocation.line)")
    }

}

/// An agent connected over MCP, as Codex or Claude Code would be.
final class MCPAgent {
    struct Reply {
        let text: String
        let images: [Data]
    }

    private let endpoint: URL
    private var sessionID: String?
    private var nextID = 1

    init(port: Int, name: String) async throws {
        endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!
        _ = try await post("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": name, "version": "1"]])
    }

    func call(_ tool: String, _ arguments: [String: Any]) async throws -> Reply {
        let result = try await post("tools/call", ["name": tool, "arguments": arguments])
        let content = result["content"] as? [[String: Any]] ?? []
        return Reply(
            text: content.compactMap { $0["text"] as? String }.joined(separator: "\n"),
            images: content.compactMap { ($0["data"] as? String).flatMap { Data(base64Encoded: $0) } }
        )
    }

    private func post(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Tilde's listener asks agents on this Mac for the token in the owner's private file.
        let token = try String(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tilde/local-token"), encoding: .utf8)
        request.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": nextID, "method": method, "params": params])
        nextID += 1
        let (data, response) = try await URLSession.shared.data(for: request)
        if let id = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionID = id
        }
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let result = body["result"] as? [String: Any] else {
            throw UXFailure(description: "\(method) failed: \(body)")
        }
        return result
    }
}

/// Prints the time since the last step of a flow, for the log of a run.
func step(_ name: String) {
    let now = Date()
    print("STEP \(String(format: "%.1f", now.timeIntervalSince(lastStep.withLock { $0 }))) s: \(name)")
    lastStep.withLock { $0 = now }
}

private let lastStep = OSAllocatedUnfairLock(initialState: Date())

/// A window of another app whose whole content changes, like a page change in the Simulator.
final class ChangingWindow {
    /// The window on screen, in screen points from the top left.
    static let frame = CGRect(x: 300, y: 200, width: 500, height: 400)
    private let file = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-ux-page-\(UUID().uuidString)")
    private let process = Process()

    init() throws {
        try "a".write(to: file, atomically: true, encoding: .utf8)
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TILDE_UX_FIXTURE"] ?? "")
        process.arguments = [file.path]
        try process.run()
        for _ in 0..<50 where !Self.isOnScreen(process.processIdentifier) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        // Its first page draws just after the window shows.
        Thread.sleep(forTimeInterval: 0.2)
    }

    /// The window's frame with its title bar, as the window server has it.
    var bounds: CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let info = list.first { $0[kCGWindowOwnerPID as String] as? Int32 == process.processIdentifier }
        return (info?[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
    }

    private static func isOnScreen(_ pid: Int32) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { $0[kCGWindowOwnerPID as String] as? Int32 == pid }
    }

    /// On the page "fullscreen": whether the window is in full screen, and how many times it
    /// left it.
    var fullScreen: (isOn: Bool, exits: Int)? {
        guard let state = try? String(contentsOf: URL(fileURLWithPath: file.path + ".state"), encoding: .utf8),
              let exits = state.components(separatedBy: "exits=").last.flatMap({ Int($0) })
        else {
            return nil
        }
        return (state.contains("fullscreen=true"), exits)
    }

    /// The classes of the window sharing windows that macOS put in the app, such as
    /// NSLocalWindowSharingWindow, while another app captured its window.
    var sharingWindows: [String] {
        let text = (try? String(contentsOf: URL(fileURLWithPath: file.path + ".sharing"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    /// The process's id: the app whose text field has the keyboard on the page "typing".
    var pid: Int { Int(process.processIdentifier) }

    /// On the page "typing": the key code of each key the app got, in order.
    var keys: [Int] {
        let text = (try? String(contentsOf: URL(fileURLWithPath: file.path + ".keys"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { Int($0) }
    }

    /// On the page "typing": a point on the text field, in screen points from the top left.
    var field: CGPoint? {
        let text = (try? String(contentsOf: URL(fileURLWithPath: file.path + ".field"), encoding: .utf8)) ?? ""
        let numbers = text.split(separator: " ").compactMap { Double($0) }
        return numbers.count == 2 ? CGPoint(x: numbers[0], y: numbers[1]) : nil
    }

    /// Whether the pointer moved over the window since `forgetPointer()`.
    var hasPointer: Bool {
        FileManager.default.fileExists(atPath: file.path + ".pointer")
    }

    func forgetPointer() {
        try? FileManager.default.removeItem(atPath: file.path + ".pointer")
    }

    func show(_ page: String) throws {
        try page.write(to: file, atomically: true, encoding: .utf8)
    }

    func close() {
        guard process.isRunning else {
            return
        }
        process.terminate()
        waitForExit(process)
    }
}

/// A second display, as a user's external monitor, while it exists: the VM has one display.
final class SecondDisplay {
    /// Its frame in Quartz points, from the main display's top left.
    let frame: CGRect
    private let process = Process()

    /// `frame`: where it goes, in Quartz points, such as above and to the right of the main one.
    init(_ frame: CGRect) throws {
        let fixture = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TILDE_UX_FIXTURE"] ?? "")
        process.executableURL = fixture.deletingLastPathComponent().appendingPathComponent("tilde-ux-display")
        process.arguments = [frame.width, frame.height, frame.minX, frame.minY].map { String(Int($0)) }
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        let numbers = line.split(separator: " ").dropFirst(2).compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard line.hasPrefix("ready"), numbers.count == 4 else {
            process.terminate()
            throw UXFailure(description: "No second display: \(line)")
        }
        self.frame = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        for _ in 0..<50 where TildeApp.screenFrames.count < 2 {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    func remove() {
        guard process.isRunning else {
            return
        }
        process.terminate()
        waitForExit(process)
        for _ in 0..<50 where TildeApp.screenFrames.count > 1 {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}

/// A small web page on localhost for the browser flows.
final class TestPage {
    let url: String
    private let server = Process()
    private let requests: URL

    init(port: Int = 7399) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-ux-page-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>Test page</title></head>
        <body style="font: 16px sans-serif; margin: 40px; min-height: 3000px">
        <h1>Welcome page</h1><p><button id="save">Save changes</button></p><p>Second paragraph</p>
        <p><a href="other.html">Other page</a></p></body></html>
        """
        try html.write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let rows = (1...80).map { "<p style=\"margin:0;height:30px;width:300px\">Row \($0)</p>" }.joined()
        func scrollPage(_ name: String, body: String, scroll: String) throws {
            let html = "<!doctype html><meta charset=utf-8><title>\(name)</title>\(body)<button style=\"position:fixed;right:20px;top:10px\" onclick=\"\(scroll)\">Scroll</button>"
            try html.write(to: folder.appendingPathComponent("\(name).html"), atomically: true, encoding: .utf8)
        }
        try scrollPage("panel", body: "<body style=\"margin:0;overflow:hidden\"><main id=panel style=\"height:100vh;overflow:auto\">\(rows)</main>", scroll: "panel.scrollTop=120")
        try scrollPage("whole", body: "<body style=\"margin:0\">\(rows)", scroll: "window.scrollTo(0,120)")
        try "<!doctype html><title>Other</title><h1>Other page heading</h1>".write(to: folder.appendingPathComponent("other.html"), atomically: true, encoding: .utf8)
        // A page that runs: it asks the server for /beat five times a second while it is loaded.
        try """
        <!doctype html><meta charset=utf-8><title>Live</title><h1 style="margin: 300px 40px">Live page</h1>
        <script>setInterval(() => fetch("beat?" + Date.now()).catch(() => {}), 200)</script>
        """.write(to: folder.appendingPathComponent("live.html"), atomically: true, encoding: .utf8)
        requests = folder.appendingPathComponent("requests.log")
        FileManager.default.createFile(atPath: requests.path, contents: nil)
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", folder.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = try FileHandle(forWritingTo: requests)
        try server.run()
        url = "http://127.0.0.1:\(port)/"
        // The page must not fail to load because the server is not listening yet.
        for _ in 0..<50 {
            let check = Process()
            check.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
            check.arguments = ["-z", "127.0.0.1", String(port)]
            try check.run()
            waitForExit(check)
            if check.terminationStatus == 0 {
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    func stop() {
        server.terminate()
        waitForExit(server)
    }

    /// How many times a live page has asked for /beat; the server logs each request.
    var beats: Int {
        ((try? String(contentsOf: requests, encoding: .utf8)) ?? "").components(separatedBy: "GET /beat").count - 1
    }

    /// Waits until a live page runs: new beats arrive.
    func waitForBeats(timeout: Double = 10, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let before = beats
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if beats >= before + 3 {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("No live page runs", sourceLocation: sourceLocation)
        throw UXFailure(description: "No live page runs")
    }

    /// Waits until no live page runs: no beat for a whole second, five times its interval.
    func waitForNoBeats(timeout: Double = 10, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        var last = (count: beats, at: Date())
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            try await Task.sleep(for: .milliseconds(100))
            if beats != last.count {
                last = (beats, Date())
            } else if Date().timeIntervalSince(last.at) >= 1 {
                return
            }
        }
        Issue.record("A live page still runs", sourceLocation: sourceLocation)
        throw UXFailure(description: "A live page still runs")
    }
}

/// Safari with one page, as the user's other browser.
final class Safari {
    private let app: NSRunningApplication

    private init(app: NSRunningApplication) {
        self.app = app
    }

    static func open(_ url: String) async throws -> Safari {
        let page = try #require(URL(string: url))
        let app = try await NSWorkspace.shared.open([page], withApplicationAt: URL(fileURLWithPath: "/Applications/Safari.app"), configuration: NSWorkspace.OpenConfiguration())
        return Safari(app: app)
    }

    /// Quits it and waits until it is gone, so that its pages run no more. It asks the
    /// process, as `isTerminated` changes only on the main thread's run loop, not on a test's.
    func quit() {
        let pid = app.processIdentifier
        let isGone = { Darwin.kill(pid, 0) != 0 && errno == ESRCH }
        app.terminate()
        let end = Date().addingTimeInterval(10)
        while !isGone(), Date() < end {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if !isGone() {
            app.forceTerminate()
        }
    }
}
