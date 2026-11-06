import AppKit
import AVFoundation
import CryptoKit
import Foundation
import Testing

/// What a user sees and does, one story per spec. See README.md.
@Suite(.serialized, .enabled(if: uxEnabled))
struct UXSpecs {
    private func withApp(_ body: (TildeApp) async throws -> Void) async throws {
        let app = try await TildeApp.launched()
        defer { app.quit() }
        try await body(app)
    }

    /// Clicks Annotate. A window of an inactive app takes its first click to come forward, as
    /// on any Mac, so a second click may be needed.
    private func annotate(_ app: TildeApp) async throws {
        try await app.press("Annotate (Double-tap ⌃)")
        try await Task.sleep(for: .milliseconds(100))
        if try await app.seen().contains(where: { $0.name == "Annotate (Double-tap ⌃)" }) {
            try await app.press("Annotate (Double-tap ⌃)")
        }
        try await app.waitToSee("Annotating")
    }

    /// Adds a note by clicking an element on the page in Tilde's browser.
    private func addNote(_ app: TildeApp, on text: String, comment: String) async throws {
        try await app.clickText(text)
        // The comment box shows its key hints once it is open and takes the keyboard.
        try await app.waitToSee("add")
        try await Task.sleep(for: .milliseconds(40))
        try await app.type(comment)
        try await app.waitToSee(comment, timeout: 3)
        try await app.key(.enter)
        try await app.waitNotToSee("add")
    }

    // MARK: - Agent flow

    @Test func anAgentOpensAPageTheUserNotesItAndTheAgentGetsAReportWithImages() async throws {
        let page = try TestPage()
        defer { page.stop() }
        try await withApp { app in
            // The menu, before a session.
            for item in ["Start Annotation", "Agents", "History", "Open Browser", "Settings", "Quit Tilde"] {
                try await app.waitToSee(item)
            }

            let agent = try await MCPAgent(port: app.port, name: "codex-mcp-client")
            let started = try await agent.call("start_annotation", ["url": page.url, "wait_seconds": 0])
            let session = try #require(started.text.components(separatedBy: "session_id: ").last?.prefix(while: { $0 != "." && $0 != " " && $0 != "\n" }))

            // The browser opens paused, so the user can browse first: a click reaches the page.
            try await app.waitToSee("Paused")
            try await app.waitToSeeText(containing: "Codex")
            try await app.waitToSee("Welcome page", timeout: 20)
            try await app.clickText("Other page")
            try await app.waitToSee("Other page heading", timeout: 20)
            try await app.key(.leftBracket, command: true)
            try await app.waitToSee("Welcome page", timeout: 20)

            try await annotate(app)
            try await app.waitToSee("Annotating")
            try await addNote(app, on: "Welcome page", comment: "Make this bigger")
            try await app.waitToSeeText(containing: "1 note")

            // With the hold key down, a click reaches the page while annotating.
            try await app.hold("option", down: true)
            try await app.clickText("Other page")
            try await app.hold("option", down: false)
            try await app.waitToSee("Other page heading", timeout: 20)

            try await app.key(.enter, command: true)
            let report = try await agent.call("wait_for_annotation", ["session_id": String(session), "wait_seconds": 5])
            #expect(report.text.contains("Make this bigger"))
            #expect(report.images.count >= 1)
        }
    }

    // MARK: - Remote machines

    /// A machine is installed from Settings and linked by its socket: its agents start
    /// tproxy, which Tilde copied from its own app, as a stdio server, and reach Tilde as that
    /// machine. `TILDE_UX_NODE` names the machine in the ssh config, with a `~/.claude.json`
    /// file and a `~/.codex` folder: "vmself", this Mac's own ssh (a macOS node), or a Linux VM.
    @Test func aNodeIsInstalledFromSettingsAndLinkedByItsSocket() async throws {
        let host = ProcessInfo.processInfo.environment["TILDE_UX_NODE"] ?? "vmself"
        let home = try onNode(host, "echo $HOME").trimmingCharacters(in: .whitespacesAndNewlines)
        let proxy = "\(home)/.tilde/bin/tproxy"
        let socket = "\(home)/.tilde/tilde.sock"
        let type = try onNode(host, "uname -sm").trimmingCharacters(in: .whitespacesAndNewlines)
        let names = ["Darwin arm64": "darwin-arm64", "Darwin x86_64": "darwin-amd64", "Linux x86_64": "linux-amd64", "Linux aarch64": "linux-arm64"]
        let name = try #require(names[type], "No tproxy for \(type)")
        let app = ProcessInfo.processInfo.environment["TILDE_UX_APP"] ?? "build/TildeUX.app"
        let file = try Data(contentsOf: URL(fileURLWithPath: "\(app)/Contents/Resources/tproxy/tproxy-\(name)"))
        let expected = SHA256.hash(data: file).map { String(format: "%02x", $0) }.joined()
        let hash = "{ sha256sum || shasum -a 256; } 2>/dev/null < \(proxy) | cut -c1-64"
        _ = try? onNode(host, "rm -f \(proxy) \(socket)")

        let window = try ChangingWindow()
        defer { window.close() }
        try await withApp { app in
            try await app.menu("Settings")
            try await app.waitToSee("Apps on this Mac")
            try await Task.sleep(for: .seconds(1))
            let apps = try await app.waitToSee("Apps on this Mac")
            try await app.scroll(at: CGPoint(x: apps.frame.midX, y: apps.frame.maxY + 200), by: -10)
            try await app.waitToSee(host, timeout: 15)
            try await app.press(host)
            try await app.waitToSee("Install \(host)", timeout: 20)
            try await app.press("Install \(host)")
            try await app.waitToSeeText(containing: "Installed and linked", timeout: 60)
            step("installed")

            // The entries start the proxy with the socket, and hold no token; the proxy is the
            // checked file, and only the user can open the folder and the socket.
            let configs = try onNode(host, "cat ~/.codex/config.toml ~/.claude.json")
            #expect(configs.contains("command = \"\(proxy)\""), "\(configs)")
            #expect(configs.contains("\"type\": \"stdio\""), "\(configs)")
            #expect(!configs.contains("Bearer"))
            #expect(try onNode(host, hash).hasPrefix(expected))
            let modes = try onNode(host, "ls -ld ~/.tilde ~/.tilde/bin \(proxy) \(socket) | cut -c1-10")
            #expect(modes.split(separator: "\n") == ["drwx------", "drwx------", "-rwx------", "srw-------"], "\(modes)")
            #expect(try onNode(host, "(ss -ltn 2>/dev/null || netstat -an -p tcp) | grep -c '[.:]7319 ' || true").hasPrefix("0"))
            print("NODE \(type), tproxy \(try onNode(host, hash))\(modes)\(configs)")
            step("files")

            // An agent there, through tproxy, as Codex. It runs until the end, through drops.
            let agent = try NodeAgent(host: host, command: "\(proxy) \(socket)")
            defer { agent.close() }
            let hello = try await agent.call("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "codex-mcp-client", "version": "1"]])
            #expect(hello["result"] != nil, "\(hello)")
            try agent.notify("notifications/initialized")
            let tools = try await agent.call("tools/list", [:])
            #expect("\(tools)".contains("wait_for_annotation"))
            step("agent")

            // Another user there can open neither the folder nor the socket.
            if (try? onNode(host, "id other")) != nil {
                let other = "sudo -n -u other python3 -c 'import socket; s=socket.socket(socket.AF_UNIX); s.connect(\"\(socket)\")' 2>&1; sudo -n -u other ls \(home)/.tilde 2>&1"
                let refused = (try? onNode(host, other + "; true")) ?? ""
                #expect(refused.components(separatedBy: "Permission denied").count == 3, "\(refused)")
                print("NODE other user: \(refused)")
                step("other user")
            }

            // A dropped tunnel comes back on the same socket, a changed tproxy is replaced, and
            // the entries stay as they were.
            func dropTunnel() throws {
                let tunnel = Process()
                tunnel.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                tunnel.arguments = ["-f", "tilde\\.sock:/"]
                try tunnel.run()
                tunnel.waitUntilExit()
            }
            // A running tproxy cannot be written to: the changed file replaces it.
            try onNode(host, "cp \(proxy) \(proxy).x && printf x >> \(proxy).x && mv \(proxy).x \(proxy)")
            try dropTunnel()
            let back = Date().addingTimeInterval(60)
            while try !onNode(host, hash).hasPrefix(expected), Date() < back {
                try await Task.sleep(for: .seconds(1))
            }
            #expect(try onNode(host, hash).hasPrefix(expected))
            #expect(try onNode(host, "cat ~/.codex/config.toml ~/.claude.json") == configs)
            step("relinked")

            // The same agent, with no new initialize, opens a session as Codex.
            let started = try await agent.call("tools/call", ["name": "start_annotation", "arguments": ["wait_seconds": 0]], timeout: 60)
            let session = try #require("\(started)".components(separatedBy: "session_id: ").last?.prefix { $0 != "." }).description
            try await app.waitToSee("Annotating", timeout: 15)
            try await app.waitToSeeText(containing: "for Codex")

            // A wait cut by a drop is answered at once, to call again; the next wait, sent while
            // the link is down, goes through when it is back and gets the report.
            let cut = Task { try await agent.call("tools/call", ["name": "wait_for_annotation", "arguments": ["session_id": session, "wait_seconds": 60]], timeout: 30) }
            try await Task.sleep(for: .seconds(1))
            try dropTunnel()
            let cutAnswer = try await cut.value
            #expect("\(cutAnswer)".contains("Call again"), "\(cutAnswer)")
            print("NODE cut wait: \(cutAnswer)")
            let waiting = Task { try await agent.call("tools/call", ["name": "wait_for_annotation", "arguments": ["session_id": session, "wait_seconds": 60]], timeout: 90) }
            let frame = ChangingWindow.frame
            try await app.click(at: CGPoint(x: frame.minX + 80, y: frame.minY + 55))
            try await app.waitToSee("add")
            try await app.type("From the node")
            try await app.waitToSee("From the node", timeout: 3)
            try await app.key(.enter)
            try await app.waitToSeeText(containing: "1 note")
            try await Task.sleep(for: .seconds(8))
            try await app.key(.enter, command: true)
            let report = try await waiting.value
            #expect("\(report)".contains("From the node"), "\(report)")
            print("NODE report: \(String("\(report)".prefix(300)))")
            step("same agent after drops")

            try await app.press("Remove \(host)")
            try await app.waitToSee("Install \(host)", timeout: 30)
            #expect(try !onNode(host, "cat ~/.codex/config.toml ~/.claude.json").contains("tproxy"))
            let removing = Date().addingTimeInterval(10)
            while try onNode(host, "ls ~/.tilde/bin ~/.tilde 2>/dev/null; true").contains("tproxy"), Date() < removing {
                try await Task.sleep(for: .milliseconds(200))
            }
            #expect(try onNode(host, "ls ~/.tilde/bin ~/.tilde 2>/dev/null; true").contains("tproxy") == false)
            step("removed")
        }
    }

    @Test func aCopiedReportGoesToTheRemoteMachineWithItsImages() async throws {
        let window = try ChangingWindow()
        defer { window.close() }
        try await withApp { app in
            // This machine's own ssh is the remote machine; the setup of the VM has its key.
            try app.setNodes(["localhost"])
            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")
            let frame = ChangingWindow.frame
            try await app.click(at: CGPoint(x: frame.minX + 80, y: frame.minY + 55))
            try await app.waitToSee("add")
            try await app.type("For the remote")
            try await app.waitToSee("For the remote", timeout: 3)
            try await app.key(.enter)
            try await app.waitToSeeText(containing: "1 note")
            // A clip goes to the machine with the images.
            try await app.press("Record a video")
            try await app.waitToSeeText(containing: "Ready to record")
            try await app.press("Start recording the screen")
            try await app.waitToSeeText(containing: "Recording 0:0")
            try await Task.sleep(for: .seconds(1))
            try await app.press("Stop and add the recording to the list")
            try await app.waitToSeeText(containing: "Ready to record")
            try await app.key(.enter, command: true)
            // "Copied" at once, and gone again while the images go to the machine.
            try await app.waitToSee("Copied", timeout: 5)
            try await app.waitNotToSee("Copied", timeout: 5)
            step("sent")

            // Its folder is on the machine, under the same name as here.
            let text = try #require(NSPasteboard.general.string(forType: .string))
            let saved = try #require(text.components(separatedBy: "Saved to: ").last?.prefix { $0 != "\n" })
            let name = URL(fileURLWithPath: String(saved)).lastPathComponent
            let remote = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tilde/inbox/\(name)")
            let pushed = Date().addingTimeInterval(20)
            while !FileManager.default.fileExists(atPath: remote.appendingPathComponent("feedback.md").path), Date() < pushed {
                try await Task.sleep(for: .milliseconds(200))
            }
            #expect(FileManager.default.fileExists(atPath: remote.appendingPathComponent("annotation-1.png").path))
            #expect(FileManager.default.fileExists(atPath: remote.appendingPathComponent("annotation-2.mp4").path))
            #expect(FileManager.default.fileExists(atPath: remote.appendingPathComponent("feedback.md").path))

            // A machine that cannot be reached: the report still copies, with local paths, and
            // a warning names the machine.
            try app.setNodes(["no-such-host.invalid"])
            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")
            try await app.click(at: CGPoint(x: frame.minX + 80, y: frame.minY + 55))
            try await app.waitToSee("add")
            try await app.type("Stays local")
            try await app.waitToSee("Stays local", timeout: 3)
            try await app.key(.enter)
            try await app.waitToSeeText(containing: "1 note")
            try await app.key(.enter, command: true)
            // A name that does not resolve fails at once, and its warning takes Copied's place.
            try await app.waitToSee("Could not send the images to no-such-host.invalid", timeout: 20)
            let local = try #require(NSPasteboard.general.string(forType: .string))
            #expect(local.contains("Stays local"), "\(local)")
            step("unreachable machine")
        }
    }

    // MARK: - Restore

    @Test func aRectangleLeavesALabelThatHidesOnAnotherPageAndACrashLeavesOnlyItsNote() async throws {
        let window = try ChangingWindow()
        defer { window.close() }
        let first = try await TildeApp.launched()
        defer { first.quit() }
        try await first.doubleTap("control")
        try await first.waitToSee("Annotating")
        try await first.press("Draw on the screen")
        try await first.waitToSee("Done, esc")
        try await first.waitToSee("Drawing canvas", timeout: 15)
        let frame = ChangingWindow.frame
        let start = CGPoint(x: frame.minX + 100, y: frame.minY + 100)
        let end = CGPoint(x: start.x + 200, y: start.y + 120)
        try await first.press("Rectangle")
        try await first.drag(from: start, to: end)
        try await first.waitToSee("add", timeout: 15)
        try await first.type("On the window")
        try await first.waitToSee("On the window", timeout: 3)
        try await first.key(.enter)
        try await first.waitNotToSee("add")
        try await first.key(.escape)
        try await first.waitNotToSee("Done, esc")
        try await first.waitToSeeText(containing: "1 note")
        let hud = try await first.waitToSee("Annotating")
        try await first.hover(over: CGPoint(x: hud.frame.midX, y: hud.frame.midY))
        step("rectangle saved")

        // Its label stays without the shape, and goes with the page.
        func left(of point: CGPoint, offset: CGFloat = 0) -> CGRect {
            CGRect(x: point.x + offset - 10, y: point.y + 30, width: 20, height: 40)
        }
        try await first.waitForBlue(in: left(of: start), atMost: 0)
        try await first.waitForBlue(in: frame, atLeast: 20)
        try window.show("b")
        try await first.waitForBlue(in: frame, atMost: 0)
        try window.show("a")
        try await first.waitForBlue(in: frame, atLeast: 20)
        step("another page")

        // The window moves, and the label with it. Its element's row ends past the old window.
        try window.show("moved")
        // Above the phone of Device Hub, which is blue too.
        let beside = CGRect(x: frame.maxX + 5, y: frame.minY, width: 170, height: 170)
        try await first.waitForBlue(in: beside, atLeast: 20)
        step("window moved")

        // A crash: the note and its images come back, with no shape, and no label that nothing confirms.
        // The app saves about a second after a change.
        func isSaved() -> Bool {
            let saved = (try? FileManager.default.subpathsOfDirectory(atPath: first.sessions.path)) ?? []
            let record = saved.first { $0.hasSuffix("session.json") }.flatMap { try? String(contentsOf: first.sessions.appendingPathComponent($0), encoding: .utf8) }
            return record?.contains("On the window") == true && saved.contains { $0.hasSuffix(".png") }
        }
        let saving = Date().addingTimeInterval(10)
        while !isSaved(), Date() < saving {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(isSaved())
        first.kill()
        let second = try await TildeApp.relaunched(after: first)
        defer { second.quit() }
        try await second.waitToSee("Restore unfinished session?")
        try await second.press("Restore")
        try await second.waitToSeeText(containing: "1 note", timeout: 15)
        try await second.waitForBlue(in: beside, atMost: 0)
        try await second.waitForBlue(in: left(of: start, offset: 200), atMost: 0)
        try await second.press("Show notes")
        try await second.waitToSee("On the window")
        step("restored")
    }

    // MARK: - Recording

    /// Two clips reach the agent as videos: the first of the screen without its 2 s pause, and
    /// the second of a chosen window, sent while it records. Esc asks before it drops a clip
    /// that is not stopped.
    @Test func twoClipsReachTheAgentAsVideos() async throws {
        let window = try ChangingWindow()
        defer { window.close() }
        try await withApp { app in
            let agent = try await MCPAgent(port: app.port, name: "Codex")
            let reply = try await agent.call("start_annotation", ["wait_seconds": 0])
            let session = try #require(reply.text.components(separatedBy: "session_id: ").last?.prefix(while: { $0 != "." && $0 != " " && $0 != "\n" }))
            try await app.waitToSee("Annotating")

            try await app.press("Record a video")
            try await app.waitToSeeText(containing: "Ready to record")
            let started = Date()
            try await app.press("Start recording the screen")
            try await app.waitToSeeText(containing: "Recording 0:0")
            try await Task.sleep(for: .seconds(2))
            try await app.press("Pause the recording")
            try await app.waitToSeeText(containing: "Paused 0:0")
            try await Task.sleep(for: .seconds(2))
            try await app.press("Resume the recording")
            try await Task.sleep(for: .seconds(1))
            try await app.press("Stop and add the recording to the list")
            let firstClipTime = Date().timeIntervalSince(started)
            try await app.waitToSeeText(containing: "Ready to record")

            // The clip waits in the preview's native player; Esc closes the preview.
            try await app.press("Show notes")
            try await app.press("No comment")
            try await app.waitToSee("1 of 1")
            try await app.waitToSee("play/pause")
            try await app.waitToSee("timeline")
            try await app.key(.escape)
            try await app.waitNotToSee("1 of 1")

            // Esc goes back to annotating.
            try await app.key(.escape)
            try await app.waitToSee("Annotating")
            try await app.press("Record a video")
            try await app.waitToSeeText(containing: "Ready to record")

            // A click on the fixture's window chooses it for the next clip.
            try await app.press("Choose a screen or window to record")
            try await app.waitToSee("Choose a window")
            let frame = ChangingWindow.frame
            try await app.click(at: CGPoint(x: frame.minX + 20, y: frame.maxY - 20))
            try await app.waitToSee("Start recording tilde-ux-fixture")

            // Send while a clip is in progress keeps that clip too. Before that, Esc asks to
            // discard the clip, and Esc again keeps it.
            try await app.press("Start recording tilde-ux-fixture")
            try await app.waitToSeeText(containing: "Recording 0:0")
            try await app.key(.escape)
            try await app.waitToSee("Discard the recording?")
            try await app.key(.escape)
            try await app.waitNotToSee("Discard the recording?")
            try await Task.sleep(for: .seconds(1))
            try await app.key(.enter, command: true)

            let report = try await agent.call("wait_for_annotation", ["session_id": String(session), "wait_seconds": 15])
            #expect(report.text.contains("Screen recording"))
            #expect(report.text.contains("Recorded: tilde-ux-fixture window"))
            let folder = try #require(report.text.components(separatedBy: "\n").first { $0.hasPrefix("Saved to: ") }?.dropFirst("Saved to: ".count))
            // The first clip leaves out its 2 s pause.
            for (number, shortest, longest) in [(1, 2.5, firstClipTime - 1.5), (2, 0.5, 4.0)] {
                let asset = AVURLAsset(url: URL(fileURLWithPath: "\(folder)/annotation-\(number).mp4"))
                let seconds = try await asset.load(.duration).seconds
                let tracks = try await asset.loadTracks(withMediaType: .video)
                step("recording \(number): \(seconds) s of \(longest + 1.5) s, \(tracks.count) video track")
                #expect(tracks.count == 1)
                #expect(seconds >= shortest && seconds <= longest)
            }
            // The second clip is the window, not the screen: it has the window's shape.
            let windowClip = AVURLAsset(url: URL(fileURLWithPath: "\(folder)/annotation-2.mp4"))
            let track = try #require(try await windowClip.loadTracks(withMediaType: .video).first)
            let size = try await track.load(.naturalSize)
            let bounds = try #require(window.bounds)
            step("window clip \(size.width) × \(size.height), window \(bounds.width) × \(bounds.height)")
            #expect(abs(size.width / size.height - bounds.width / bounds.height) < 0.02)
        }
    }
}

/// Runs a command on a node through ssh, as Tilde does, and gives its output.
@discardableResult
private func onNode(_ host: String, _ command: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = ["-o", "BatchMode=yes", host, command]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw POSIXError(.EIO)
    }
    return String(decoding: data, as: UTF8.self)
}

/// An agent on a node: its stdio MCP server is `command` (tproxy), started through ssh.
private final class NodeAgent: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 1

    init(host: String, command: String) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", host, command]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func notify(_ method: String) throws {
        try write(["jsonrpc": "2.0", "method": method])
    }

    /// Sends a request and gives its answer, past notifications such as progress.
    func call(_ method: String, _ params: [String: Any], timeout: Double = 15) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let process = process
        return try await withThrowingTaskGroup(of: [String: Any]?.self) { group in
            group.addTask { [self] in
                while true {
                    let message = try readMessage()
                    if message["id"] as? Int == id {
                        return message
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                process.terminate()
                return nil
            }
            let answer = try await group.next() ?? nil
            group.cancelAll()
            return try #require(answer, "No answer to \(method) in \(timeout) s")
        }
    }

    func close() {
        try? input.fileHandleForWriting.close()
        process.terminate()
    }

    private func write(_ message: [String: Any]) throws {
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: message) + Data("\n".utf8))
    }

    private func readMessage() throws -> [String: Any] {
        while true {
            if let end = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<end])
                buffer = Data(buffer[buffer.index(after: end)...])
                if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    return message
                }
                continue
            }
            let data = output.fileHandleForReading.availableData
            guard !data.isEmpty else {
                throw POSIXError(.ECONNRESET)
            }
            buffer.append(data)
        }
    }
}
