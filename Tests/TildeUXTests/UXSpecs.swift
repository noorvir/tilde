import AppKit
import AVFoundation
import CryptoKit
import Foundation
import Testing

/// What a user sees and does, one story per spec.
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
        try await app.press("Annotate")
        let end = Date().addingTimeInterval(1)
        while try await !app.seen().contains(where: { $0.name == "Annotating" }), Date() < end {
            try await Task.sleep(for: .milliseconds(50))
        }
        if try await !app.seen().contains(where: { $0.name == "Annotating" }) {
            try await app.press("Annotate")
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

    // MARK: - Another browser

    /// The first click on an element in another browser offers Tilde's browser, which opens
    /// that page; closing its window unloads the page, so nothing on it runs on.
    @Test func aClickInAnotherBrowserOffersTildesBrowserWhichUnloadsThePageOnClose() async throws {
        let page = try TestPage()
        defer { page.stop() }
        let safari = try await Safari.open(page.url + "live.html")
        defer { safari.quit() }
        try await withApp { app in
            let heading = try await app.waitToSee("Live page", inApp: "Safari")
            try await page.waitForBeats()
            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")

            // The click still opens the comment box; the offer stays after Esc closes it.
            try await app.click(at: CGPoint(x: heading.frame.midX, y: heading.frame.midY))
            try await app.waitToSee("add")
            try await app.waitToSee("Open in Tilde's browser")
            try await app.key(.escape)
            try await app.waitNotToSee("add")
            try await app.waitToSee("Open in Tilde's browser")

            // Tilde's browser opens the same page and runs it, with Safari gone.
            try await app.press("Open in Tilde's browser")
            try await app.waitToSee("Live page", timeout: 20)
            try await app.waitNotToSee("Open in Tilde's browser")
            safari.quit()
            try await page.waitForBeats()
            step("page in Tilde's browser")

            // ⌘W closes the window while the overlay on its page has the keyboard, and the
            // page stops.
            try await app.key(.w, command: true)
            try await app.waitNotToSee("Live page")
            try await page.waitForNoBeats()
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
            // A clip goes to the machine with the images. Recording mode starts by choosing;
            // Esc keeps the screen and stays in recording mode.
            try await app.press("Record screen")
            try await app.waitToSee("Choose a window")
            try await app.key(.escape)
            try await app.waitToSeeText(containing: "Ready to record")
            try await app.press("Record")
            try await app.waitToSeeText(containing: "Recording 0:0")
            try await Task.sleep(for: .seconds(1))
            try await app.press("Stop recording")
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
            // a warning names the machine. The session before ended in recording mode, so this
            // one starts with no mode.
            try app.setNodes(["no-such-host.invalid"])
            try await app.doubleTap("control")
            try await app.waitToSee("Paused")
            try await annotate(app)
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

    // MARK: - Pasted text

    /// A dictation app pastes, then asks Accessibility for the focused element: when that is not
    /// an editable text with the pasted text, it shows the text in its own window instead.
    @Test func aPasteInACommentBoxLandsInTheSystemsFocusedTextAndFocusGoesBackAfter() async throws {
        let window = try ChangingWindow()
        defer { window.close() }
        try await withApp { app in
            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")
            let before = try await app.focus()

            let frame = ChangingWindow.frame
            try await app.click(at: CGPoint(x: frame.midX, y: frame.midY))
            try await app.waitToSee("add")
            try await Task.sleep(for: .milliseconds(40))
            try await app.paste("dictated words")
            try await app.waitToSee("dictated words", timeout: 3)
            let inBox = try await app.focus()
            #expect(inBox.frontmost == app.pid)
            #expect(inBox.app == app.pid)
            #expect(inBox.role == "AXTextArea")
            #expect(inBox.value == "dictated words")
            #expect(inBox.isEditable)

            try await app.key(.enter)
            try await app.waitToSeeText(containing: "1 note")
            try await Task.sleep(for: .milliseconds(300))
            let after = try await app.focus()
            #expect(after.frontmost == before.frontmost)
            #expect(after.app == before.app)

            try await app.press("Show notes")
            try await app.press("dictated words")
            try await app.waitToSee("1 of 1")
            let previewOpen = try await app.focus()
            try await app.press("dictated words")
            try await app.key(.a, command: true)
            try await app.paste("dictated again")
            try await app.waitToSee("dictated again", timeout: 3)
            let inPreview = try await app.focus()
            #expect(inPreview.frontmost == app.pid)
            #expect(inPreview.app == app.pid)
            #expect(["AXTextArea", "AXTextField"].contains(inPreview.role))
            #expect(inPreview.value == "dictated again")
            #expect(inPreview.isEditable)

            try await app.key(.enter)
            try await Task.sleep(for: .milliseconds(300))
            let afterPreview = try await app.focus()
            #expect(afterPreview.frontmost == previewOpen.frontmost)
            #expect(afterPreview.app == previewOpen.app)
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
        try await first.press("Draw")
        try await first.waitToSee("Done, ⌘↩")
        try await first.waitToSee("Drawing canvas", timeout: 15)
        let frame = ChangingWindow.frame
        let start = CGPoint(x: frame.minX + 100, y: frame.minY + 100)
        let end = CGPoint(x: start.x + 200, y: start.y + 120)
        // R picks the rectangle while drawing; it does not go to recording mode.
        try await first.key(.r)
        try await first.drag(from: start, to: end)
        try await first.waitToSee("add", timeout: 15)
        try await first.type("On the window")
        try await first.waitToSee("On the window", timeout: 3)
        try await first.key(.enter)
        try await first.waitNotToSee("add")
        // Done ends Draw in no mode; Annotate goes back to annotating, where the notes are
        // checked while the page changes by itself.
        try await first.key(.enter, command: true)
        try await first.waitNotToSee("Done, ⌘↩")
        try await first.waitToSeeText(containing: "1 note")
        try await first.waitToSee("Paused")
        try await annotate(first)
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

            // The R key goes to recording mode, which starts by choosing; Esc keeps the screen.
            try await app.key(.r)
            try await app.waitToSee("Choose a window")
            try await app.key(.escape)
            try await app.waitToSeeText(containing: "Ready to record")
            let started = Date()
            try await app.press("Record")
            try await app.waitToSeeText(containing: "Recording 0:0")
            try await Task.sleep(for: .seconds(2))
            // Space pauses the clip, as the button does.
            try await app.key(.space)
            try await app.waitToSeeText(containing: "Paused 0:0")
            try await Task.sleep(for: .seconds(2))
            try await app.press("Resume")
            try await Task.sleep(for: .seconds(1))
            try await app.press("Stop recording")
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

            // Esc leaves recording mode, with no mode.
            try await app.key(.escape)
            try await app.waitToSee("Paused")

            // The record toggle chooses at once: a click on the fixture's window chooses it for
            // the next clip, and the subtitle names it.
            try await app.press("Record screen")
            try await app.waitToSee("Choose a window")
            let frame = ChangingWindow.frame
            try await app.click(at: CGPoint(x: frame.minX + 20, y: frame.maxY - 20))
            try await app.waitToSeeText(containing: "Ready to record")
            try await app.waitToSeeText(containing: "tilde-ux-fixture")

            // Send while a clip is in progress keeps that clip too. Before that, Esc asks to
            // discard the clip, and Esc again keeps it.
            try await app.press("Record")
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

    // MARK: - Draw

    /// In Draw, Esc on a shape's comment with text asks first, and Esc again keeps the comment
    /// with the keyboard in it, so typing goes on in the box.
    @Test func escTwiceOnAShapesCommentKeepsTypingInTheBox() async throws {
        let window = try ChangingWindow()
        defer { window.close() }
        try await withApp { app in
            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")
            try await app.key(.d)
            try await app.waitToSee("Done, ⌘↩")
            try await app.waitToSee("Drawing canvas", timeout: 15)
            let frame = ChangingWindow.frame
            try await app.key(.r)
            try await app.drag(from: CGPoint(x: frame.minX + 100, y: frame.minY + 100), to: CGPoint(x: frame.minX + 300, y: frame.minY + 220))
            try await app.waitToSee("add", timeout: 15)
            try await app.type("Keep this")
            try await app.waitToSee("Keep this", timeout: 3)

            try await app.key(.escape)
            try await app.waitToSee("Discard comment?")
            try await app.key(.escape)
            try await app.waitNotToSee("Discard comment?")
            try await app.type(" too")
            try await app.waitToSee("Keep this too", timeout: 3)
            let focus = try await app.focus()
            #expect(focus.app == app.pid)
            #expect(focus.role == "AXTextArea")
            #expect(focus.value == "Keep this too")

            try await app.key(.enter)
            try await app.waitNotToSee("add")
            try await app.waitToSeeText(containing: "1 note")
        }
    }

    // MARK: - Wireframe

    /// A wireframe drawn on another app's window reaches the agent. W starts wireframe mode, a
    /// tool's letter chooses the tool, an edge snaps to the window's layout with a guide, Esc
    /// puts the tool down and the components still move, and they keep to the window while it
    /// moves. Done asks for the comment at once, and Edit Wireframe in the preview draws the
    /// note again in place. The agent gets the component and two pictures: the wireframe over
    /// the window, and the window under it. The next session starts in the mode that was on
    /// last, and Tilde's browser with no mode.
    @Test func aWireframeOnAWindowReachesTheAgentWithItsTwoPictures() async throws {
        let window = try ChangingWindow()
        defer { window.close() }
        try await withApp { app in
            let agent = try await MCPAgent(port: app.port, name: "Codex")
            let reply = try await agent.call("start_annotation", ["wait_seconds": 0])
            let session = try #require(reply.text.components(separatedBy: "session_id: ").last?.prefix(while: { $0 != "." && $0 != " " && $0 != "\n" }))
            try await app.waitToSee("Annotating")

            try await app.key(.w)
            try await app.waitToSee("Done, ⌘↩")
            try await app.waitToSee("Section")
            try await app.waitToSee("Drawing canvas", timeout: 15)
            step("wireframe mode")

            // B chooses the button. Its bottom edge, drawn 1 pt below the top of the window's
            // fourth row, snaps to it, and a guide runs across the screen there.
            let frame = ChangingWindow.frame
            let row = frame.minY + 140
            let start = CGPoint(x: frame.minX + 100, y: frame.minY + 100)
            let end = CGPoint(x: start.x + 160, y: row + 1)
            try await app.key(.b)
            try await app.mouseDown(at: start)
            for part in 1...6 {
                let t = Double(part) / 6
                try await app.mouseDragged(to: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            }
            let guide = CGRect(x: 1000, y: row - 2, width: 600, height: 3)
            try await waitFor(app, at: guide, every: 1, Picture.isTildeBlue, atLeast: 150)
            try await app.mouseUp(at: end)
            try await waitFor(app, at: CGRect(x: start.x + 20, y: row - 6, width: 120, height: 4), Picture.isWireframe, atLeast: 40)
            try await waitFor(app, at: CGRect(x: start.x + 20, y: row + 2, width: 120, height: 4), Picture.isWireframe, atMost: 0)
            step("button snapped")

            // Esc puts the tool down: a drag where nothing is draws nothing, and a drag on the
            // button moves it.
            try await app.key(.escape)
            let empty = CGRect(x: frame.minX + 350, y: frame.minY + 250, width: 80, height: 80)
            try await app.drag(from: CGPoint(x: empty.minX, y: empty.minY), to: CGPoint(x: empty.maxX, y: empty.maxY))
            try await Task.sleep(for: .milliseconds(500))
            try await waitFor(app, at: empty, Picture.isWireframe, atMost: 0)
            try await app.drag(from: CGPoint(x: start.x + 80, y: start.y + 20), to: CGPoint(x: start.x + 80, y: start.y + 120))
            try await waitFor(app, at: CGRect(x: start.x + 20, y: start.y + 110, width: 120, height: 20), Picture.isWireframe, atLeast: 200)
            try await waitFor(app, at: CGRect(x: start.x + 20, y: start.y + 10, width: 120, height: 20), Picture.isWireframe, atMost: 0)
            step("tool down, button moved")

            // The window glides away and back to rest: in every picture of the screen, the
            // button keeps its place on the window.
            try window.show("marked")
            let middle = start.y + 120
            func place(on picture: Picture) -> (mark: Double, button: Double)? {
                guard let mark = picture.firstX(onRow: middle, from: frame.minX - 50, to: frame.maxX + 300, where: Picture.isMark),
                      let button = picture.firstX(onRow: middle, from: mark + 10, to: mark + 400, where: Picture.isWireframe)
                else {
                    return nil
                }
                return (mark, button - mark)
            }
            // A strip through the button's middle, from left of the window to past where it ends.
            let strip = CGRect(x: frame.minX - 50, y: middle - 1, width: frame.width + 400, height: 2)
            var resting: (mark: Double, button: Double)?
            for _ in 0..<20 where resting == nil {
                resting = try await place(on: app.screen(in: strip))
                try await Task.sleep(for: .milliseconds(100))
            }
            let before = try #require(resting, "No red mark and button on the window")
            // Every frame that the screen shows while the window glides 180 pt in 1.5 s.
            try window.show("glide")
            let frames = try await app.recordRow(at: middle, from: strip.minX, width: strip.width, seconds: 2.4)
            var places = frames.compactMap(place)
            if let place = try await place(on: app.screen(in: strip)) {
                places.append(place)
            }
            let moving = places.filter { $0.mark > before.mark + 4 && $0.mark < before.mark + 176 }
            #expect(moving.count >= 30, "Too few frames while the window moved: \(places)")
            // Two apps' windows show their changes one or two frames apart: at 120 pt a second,
            // the button is never more than 50 ms off (6 pt), and about 20 ms (2.5 pt) on average.
            let offsets = moving.map { abs($0.button - before.button) }
            #expect(offsets.allSatisfy { $0 <= 6 }, "The button lags the window: \(moving)")
            #expect(offsets.reduce(0, +) / Double(max(offsets.count, 1)) <= 2.5, "The button lags the window: \(moving)")
            let after = try #require(places.last)
            #expect(after.mark >= before.mark + 178)
            #expect(abs(after.button - before.button) <= 1)
            step("button kept to the window in \(moving.count) frames: \(moving.map { String(format: "%.0f", $0.button - before.button) }.joined(separator: " "))")

            // Done opens the comment box, and typing goes in with no click.
            try await app.key(.enter, command: true)
            try await app.waitToSee("add")
            try await app.type("A button here")
            try await app.waitToSee("A button here", timeout: 3)
            try await app.key(.enter)
            try await app.waitNotToSee("add")
            try await app.waitToSeeText(containing: "1 note")
            step("comment")

            // Edit Wireframe draws the button again where it was; moved and Done, it replaces
            // the note.
            try await app.press("Show notes")
            try await app.press("A button here")
            try await app.waitToSee("1 of 1")
            try await app.press("Edit Wireframe")
            try await app.waitToSee("Done, ⌘↩")
            let mark = after.mark
            let button = CGRect(x: mark + before.button + 10, y: middle - 10, width: 100, height: 20)
            try await waitFor(app, at: button, Picture.isWireframe, atLeast: 200)
            try await app.key(.escape)
            try await app.drag(from: CGPoint(x: button.midX, y: middle), to: CGPoint(x: button.midX, y: middle + 60))
            let moved = button.offsetBy(dx: 0, dy: 60)
            try await waitFor(app, at: moved, Picture.isWireframe, atLeast: 200)
            try await app.key(.enter, command: true)
            try await app.waitNotToSee("Done, ⌘↩")
            try await app.waitToSeeText(containing: "1 note")
            step("edited")

            // The agent gets one note with the button where it was last, and its two pictures:
            // the button over the window, and the window under it.
            try await app.key(.enter, command: true)
            let report = try await agent.call("wait_for_annotation", ["session_id": String(session), "wait_seconds": 15])
            #expect(report.text.contains("A button here"), "\(report.text)")
            #expect(report.text.contains("(1 annotations)"), "\(report.text)")
            #expect(report.text.contains(#""type":"button""#), "\(report.text)")
            let bounds = try #require(window.bounds)
            let rectText = try #require(report.text.firstMatch(of: #/"rect":\[([0-9.]+),([0-9.]+),([0-9.]+),([0-9.]+)\]/#), "\(report.text)")
            let rect = CGRect(x: Double(rectText.1)!, y: Double(rectText.2)!, width: Double(rectText.3)!, height: Double(rectText.4)!)
            // On the window, from its top left with the title bar.
            let shown = CGRect(x: before.button, y: middle + 60 - 20 - bounds.minY, width: 160, height: 40)
            #expect(abs(rect.minX - shown.minX) <= 4 && abs(rect.minY - shown.minY) <= 4, "\(rect), shown at \(shown)")
            let folder = try #require(report.text.components(separatedBy: "\n").first { $0.hasPrefix("Saved to: ") }?.dropFirst("Saved to: ".count))
            let closeUp = try Picture(Data(contentsOf: URL(fileURLWithPath: "\(folder)/annotation-1.png")), width: bounds.width)
            let context = try Picture(Data(contentsOf: URL(fileURLWithPath: "\(folder)/annotation-1-context.png")), width: bounds.width)
            let inside = rect.insetBy(dx: 10, dy: 8)
            let samples = Int(inside.width * inside.height)
            #expect(abs(closeUp.size.height - bounds.height) <= 1 && abs(context.size.height - bounds.height) <= 1, "\(closeUp.size), \(context.size), window \(bounds.size)")
            #expect(closeUp.count(in: inside, where: Picture.isWireframe) > samples / 2)
            #expect(context.count(in: inside, where: Picture.isWireframe) == 0)
            step("report")

            // The next session starts in the mode that was on last: none, after Done; then
            // wireframe mode. Tilde's browser starts with no mode.
            try await app.waitNotToSee("Close", timeout: 5)
            try await app.doubleTap("control")
            try await app.waitToSee("Paused")
            #expect(try await !app.seen().contains { $0.name == "Done, ⌘↩" })
            try await app.press("Wireframe")
            try await app.waitToSee("Done, ⌘↩")
            try await app.press("Close")
            try await app.waitNotToSee("Close")
            try await app.doubleTap("control")
            try await app.waitToSee("Done, ⌘↩")
            try await app.waitToSee("Annotating")
            try await app.press("Close")
            try await app.waitNotToSee("Close")
            try await app.menu("Open Browser")
            try await app.waitToSee("Paused", timeout: 15)
            #expect(try await !app.seen().contains { $0.name == "Done, ⌘↩" })
            step("start modes")
        }
    }

    /// Waits until the area of the screen has at least, or at most, this many pixels that match.
    private func waitFor(_ app: TildeApp, at area: CGRect, every step: Int = 2, _ matches: (Picture.Color) -> Bool, atLeast: Int = 0, atMost: Int = .max, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let end = Date().addingTimeInterval(6)
        var last = 0
        while Date() < end {
            last = try await app.screen().count(in: area, every: step, where: matches)
            if last >= atLeast, last <= atMost {
                return
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        Issue.record("\(last) pixels in \(area), expected \(atLeast)...\(atMost)", sourceLocation: sourceLocation)
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
