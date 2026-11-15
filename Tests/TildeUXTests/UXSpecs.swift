import AppKit
import AVFoundation
import CryptoKit
import Foundation
import Testing

/// What a user sees and does, one story per spec.
@Suite(.serialized, .enabled(if: uxEnabled))
struct UXSpecs {
    private func withApp(defaults: [String: String] = [:], _ body: (TildeApp) async throws -> Void) async throws {
        let app = try await TildeApp.launched(defaults: defaults)
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
            // Remote machines are a beta, off on a new Mac: the Agents page shows them once
            // Configuration's switch is on.
            try await Task.sleep(for: .seconds(1))
            #expect(try await !app.seen().contains { $0.name == "Remote machines" || $0.name == host })
            try await app.accessibilityPress("Configuration")
            try await app.accessibilityPress("Remote machines", role: "AXCheckBox")
            try await app.accessibilityPress("Home")
            let home = try await app.waitToSee("Apps on this Mac")
            try await app.scroll(at: CGPoint(x: home.frame.midX, y: home.frame.maxY + 200), by: -10)
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
            // The skill is under the command name with Tilde's mark, and no backup is beside it.
            let skill = try onNode(host, "cat ~/.claude/skills/annotate/SKILL.md")
            #expect(skill.contains("\nname: annotate\n") && skill.contains("tilde-checksum: "), "\(skill)")
            #expect(try onNode(host, "ls -A ~/.claude/skills/annotate") == "SKILL.md\n")
            #expect(try onNode(host, "ls -A ~/.claude/skills ~/.agents/skills 2>/dev/null | grep -c backup || true").hasPrefix("0"))
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
        try await withApp(defaults: ["remoteMachines": "true"]) { app in
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

    /// Two clips reach the agent as videos: the first of the screen without its 2 s pause, kept
    /// when Annotate stops it, and the second of a chosen window, sent while it records. Esc
    /// asks before it drops a clip that is not stopped.
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
            // Another mode's button stops the clip and keeps it, as Stop does, then switches.
            try await app.press("Annotate")
            let firstClipTime = Date().timeIntervalSince(started)
            try await app.waitToSee("Annotating")

            // The clip waits in the preview's native player; Esc closes the preview.
            try await app.press("Show notes")
            try await app.press("No comment")
            try await app.waitToSee("1 of 1")
            try await app.waitToSee("play/pause")
            try await app.waitToSee("timeline")
            try await app.key(.escape)
            try await app.waitNotToSee("1 of 1")

            // Esc pauses annotating.
            try await app.key(.escape)
            try await app.waitToSee("Paused")

            // The record toggle chooses at once: a click on the fixture's window chooses it for
            // the next clip, and the source button names it.
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

    // MARK: - Draw and the keyboard

    /// In Draw, Esc on a shape's comment with text asks first, and Esc again keeps the comment
    /// with the keyboard in it, so typing goes on in the box. With the comment saved, Esc puts
    /// the tool down, and a click goes through the canvas to the window behind. When that
    /// window's app goes to full screen, in a Space of its own, Tilde keeps the keyboard: Esc
    /// does not take the app out of full screen, and ⌘↩ ends Draw.
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

            // The window shows its red mark once a press reaches it.
            try await app.key(.escape)
            let mark = CGRect(x: frame.minX + 1, y: frame.minY + 50, width: 4, height: 300)
            try await waitFor(app, at: mark, Picture.isMark, atMost: 0)
            let beside = CGPoint(x: frame.minX + 480, y: frame.minY + 330)
            try await move(app, to: beside, reaching: window)
            try await app.click(at: beside)
            try await waitFor(app, at: mark, Picture.isMark, atLeast: 200)

            try window.show("fullscreen")
            for _ in 0..<60 where window.fullScreen?.isOn != true {
                try await Task.sleep(for: .milliseconds(100))
            }
            // The new Space slides in, and the canvas takes the keyboard back there.
            for _ in 0..<40 where try await app.focus().app != app.pid {
                try await Task.sleep(for: .milliseconds(50))
            }
            try await app.key(.escape)
            try await app.key(.enter, command: true)
            try await app.waitNotToSee("Done, ⌘↩")
            #expect(window.fullScreen?.isOn == true)
            #expect(window.fullScreen?.exits == 0)
        }
    }

    /// Double Ctrl in another app, while the user types in its text field, opens the HUD with the
    /// keyboard: ↩, a letter and the HUD's shortcuts reach Tilde without a click, and Esc closes
    /// it, also when it opens paused, as the last session ended, and after another app took the
    /// keyboard. The text field gets none of them. Then the same in an app in full screen, which
    /// stays in full screen.
    @Test func doubleControlInATextFieldGivesTheHUDTheKeys() async throws {
        let window = try ChangingWindow()
        defer { window.close() }
        try await withApp { app in
            try await useHUDKeys(app, over: window, page: "typing", opensAs: "Annotating")
            #expect(window.keys == [])

            // In annotation mode another app comes in front with the keyboard: Esc still steps
            // back, to a pause, and closes the HUD.
            try await app.doubleTap("control")
            try await app.waitToSee("Paused")
            try await app.key(.a)
            try await app.waitToSee("Annotating", timeout: 5)
            let other = try ChangingWindow()
            defer { other.close() }
            try other.show("typing")
            for _ in 0..<60 where try await app.focus().app != other.pid {
                try await Task.sleep(for: .milliseconds(100))
            }
            try #require(try await app.focus().app == other.pid)
            try await app.key(.escape)
            try await app.waitToSee("Paused", timeout: 5)
            try await app.key(.escape)
            try await app.waitNotToSee("Paused", timeout: 5)
            #expect(other.keys == [])
            other.close()

            try window.show("fullscreen typing")
            for _ in 0..<60 where window.fullScreen?.isOn != true {
                try await Task.sleep(for: .milliseconds(100))
            }
            try await useHUDKeys(app, over: window, page: "fullscreen typing", opensAs: "Paused")
            #expect(window.keys == [])
            #expect(window.fullScreen?.isOn == true)
            #expect(window.fullScreen?.exits == 0)
        }
    }

    /// With the keyboard in the window's text field, double Ctrl opens the HUD, as `opensAs`
    /// says; ↩, B, D (Draw) and ⌘↩ (Done, which pauses) work in Tilde, and Esc closes the HUD.
    /// Opened again, paused as it ended, Esc closes it at once. Opened once more, Esc still
    /// closes it after a click in the text field gave the app the keyboard back.
    private func useHUDKeys(_ app: TildeApp, over window: ChangingWindow, page: String, opensAs title: String) async throws {
        try window.show(page)
        for _ in 0..<60 where try await app.focus().app != window.pid {
            try await Task.sleep(for: .milliseconds(100))
        }
        let typing = try await app.focus()
        try #require(typing.app == window.pid)
        #expect(typing.role == "AXTextField")

        try await app.doubleTap("control")
        try await app.waitToSee(title)
        try await app.key(.enter)
        try await app.key(.b)
        try await app.key(.d)
        try await app.waitToSee("Done, ⌘↩", timeout: 5)
        try await app.key(.enter, command: true)
        try await app.waitToSee("Paused", timeout: 5)
        try await app.key(.escape)
        try await app.waitNotToSee("Paused", timeout: 5)

        try await app.doubleTap("control")
        try await app.waitToSee("Paused")
        try await app.key(.escape)
        try await app.waitNotToSee("Paused", timeout: 5)

        try await app.doubleTap("control")
        try await app.waitToSee("Paused")
        let field = try #require(window.field)
        try await app.click(at: field)
        for _ in 0..<40 where try await app.focus().app != window.pid {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try await app.focus().app == window.pid)
        try await app.key(.escape)
        try await app.waitNotToSee("Paused", timeout: 5)
    }

    /// Moves the pointer to `point`, a little at a time as a hand does, until the window behind
    /// the canvas gets it: the canvas lets it through once the page checked the place.
    private func move(_ app: TildeApp, to point: CGPoint, reaching window: ChangingWindow, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        window.forgetPointer()
        for step in 0..<40 where !window.hasPointer {
            try await app.hover(over: CGPoint(x: point.x + Double(step % 2), y: point.y))
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(window.hasPointer, "the pointer does not reach the window behind", sourceLocation: sourceLocation)
    }

    // MARK: - Wireframe

    /// A wireframe drawn on another app's window reaches the agent. W starts wireframe mode, a
    /// tool's letter chooses the tool, an edge snaps to the window's layout with a guide, Esc
    /// puts the tool down: the components still move, and the pointer goes through to the
    /// window beside them. The components keep to the window while it moves. Done asks for the comment at once, and Edit Wireframe in the preview draws the
    /// note again in place. The agent gets the component and two pictures: the wireframe over
    /// the window, and the window under it. The next session starts in the mode that was on
    /// last, and Tilde's browser with no mode.
    @Test func aWireframeOnAWindowReachesTheAgentWithItsTwoPictures() async throws {
        let window = try ChangingWindow()
        defer { window.close() }
        try await withApp(defaults: ["wireframes": "true"]) { app in
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
            // fourth row, snaps to it, and a guide runs across the screen there. Under the edge
            // is the window.
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
            // The button's inside, which ends 6 pt above the edge: the fill alone is too pale.
            try await waitFor(app, at: CGRect(x: start.x + 20, y: row - 12, width: 120, height: 4), Picture.isWireframe, atLeast: 40)
            try await waitFor(app, at: CGRect(x: start.x + 20, y: row + 7, width: 120, height: 4), Picture.isWireframe, atMost: 0)
            step("button snapped")

            // Esc puts the tool down: the canvas takes the pointer only on the button. A drag
            // beside it goes to the window behind, which shows its red mark, and draws nothing;
            // a drag on the button moves it. The pointer gets to each place before the press,
            // as a hand does.
            try await app.key(.escape)
            let pressMark = CGRect(x: frame.minX + 1, y: frame.minY + 50, width: 4, height: 300)
            try await waitFor(app, at: pressMark, Picture.isMark, atMost: 0)
            let empty = CGRect(x: frame.minX + 350, y: frame.minY + 250, width: 80, height: 80)
            try await move(app, to: CGPoint(x: empty.maxX + 50, y: empty.minY), reaching: window)
            try await app.drag(from: CGPoint(x: empty.maxX + 50, y: empty.minY), to: CGPoint(x: empty.minX, y: empty.maxY))
            try await waitFor(app, at: pressMark, Picture.isMark, atLeast: 200)
            try await Task.sleep(for: .milliseconds(300))
            try await waitFor(app, at: empty, Picture.isWireframe, atMost: 0)
            let grab = CGPoint(x: start.x + 80, y: start.y + 20)
            try await app.hover(over: grab)
            try await Task.sleep(for: .milliseconds(50))
            try await app.drag(from: grab, to: CGPoint(x: start.x + 80, y: start.y + 120))
            try await waitFor(app, at: CGRect(x: start.x + 20, y: start.y + 110, width: 120, height: 20), Picture.isWireframe, atLeast: 200)
            try await waitFor(app, at: CGRect(x: start.x + 20, y: start.y + 10, width: 120, height: 20), Picture.isWireframe, atMost: 0)
            step("tool down, the window behind clicked, button moved")

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

            // The comment is the button's own: its chip's Comment button opens a box for it,
            // and ⌘↩ keeps it. Done then makes the note at once, with no comment box.
            try await app.press("Comment")
            try await app.waitToSee("⌘↩ keeps it · Esc closes")
            try await app.type("A button here")
            try await app.key(.enter, command: true)
            try await app.waitNotToSee("⌘↩ keeps it · Esc closes")
            try await app.key(.enter, command: true)
            try await app.waitNotToSee("Done, ⌘↩")
            try await app.waitToSeeText(containing: "1 note")
            #expect(try await !app.seen().contains { $0.name == "add" })
            step("comment")

            // Edit Wireframe draws the button again where it was; moved and Done, it replaces
            // the note.
            try await app.press("Show notes")
            try await app.press("No comment")
            try await app.waitToSee("1 of 1")
            try await app.press("Edit Wireframe")
            try await app.waitToSee("Done, ⌘↩")
            let mark = after.mark
            let button = CGRect(x: mark + before.button + 10, y: middle - 10, width: 100, height: 20)
            try await waitFor(app, at: button, Picture.isWireframe, atLeast: 200)
            try await app.key(.escape)
            try await app.hover(over: CGPoint(x: button.midX, y: middle))
            try await Task.sleep(for: .milliseconds(50))
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

    /// The look of the components comes from the style and colour tiles of Settings' Appearance
    /// page, and a change shows at once on the components drawn. Blueprint's lines run past the
    /// corners and it has no offset edge; Technical has a hard offset edge under the bottom and
    /// no lines past the corners. A button is orange by kind, and blue in One colour.
    @Test func aStyleChosenInSettingsShowsOnTheWireframe() async throws {
        let window = try ChangingWindow()
        defer { window.close() }
        // A button on the fixture's white window, left of where Settings opens.
        let frame = ChangingWindow.frame
        let button = CGRect(x: frame.minX + 12, y: frame.minY + 100, width: 84, height: 40)
        let pastCorner = CGRect(x: button.minX - 6, y: button.minY - 1, width: 4, height: 2)
        let offsetEdge = CGRect(x: button.midX - 20, y: button.maxY + 2, width: 40, height: 2)
        try await withApp(defaults: ["wireframes": "true"]) { app in
            // The fixture's window can be in front of Settings, which stays open meanwhile.
            try await app.menu("Settings")
            try await app.accessibilityPress("Appearance")
            try await app.waitToSee("Dragged, snapping")
            try await app.accessibilityPress("Blueprint")
            step("blueprint chosen")

            // ⌘ draws without snapping, at the very place of the drag.
            try await app.menu("Start Annotation")
            try await app.waitToSee("Annotating")
            try await app.key(.w)
            try await app.waitToSee("Done, ⌘↩")
            try await app.waitToSee("Drawing canvas", timeout: 15)
            try await app.key(.b)
            try await app.hold("command", down: true)
            try await app.slowDrag(from: button.origin, to: CGPoint(x: button.maxX, y: button.maxY))
            try await app.hold("command", down: false)
            try await waitFor(app, at: button.insetBy(dx: 10, dy: 10), Picture.isWireframe, atLeast: 200)
            try await waitFor(app, at: pastCorner, every: 1, Picture.isWireframe, atLeast: 2)
            try await waitFor(app, at: offsetEdge, every: 1, Picture.isWireframe, atMost: 0)
            step("blueprint drawn")

            // Settings, under the canvas, change the style: the button shows it at once.
            try await app.accessibilityPress("Technical")
            try await waitFor(app, at: offsetEdge, every: 1, Picture.isWireframe, atLeast: 40)
            try await waitFor(app, at: pastCorner, every: 1, Picture.isWireframe, atMost: 0)
            step("technical shown")

            let inside = button.insetBy(dx: 10, dy: 10)
            try await waitFor(app, at: inside, Picture.isWireframeOrange, atLeast: 200)
            try await app.accessibilityPress("One colour")
            try await waitFor(app, at: inside, Picture.isWireframeBlue, atLeast: 200)
            try await waitFor(app, at: inside, Picture.isWireframeOrange, atMost: 0)
            step("one colour shown")
        }
    }

    /// Tilde's Settings, open during a session, works as a window and is never annotated: the
    /// pointer on it highlights nothing, also where it covers another app's window; a click
    /// turns its switch on, opens no comment and leaves the session open; and in Draw a drag on
    /// it draws nothing.
    @Test func settingsWorkAsUsualDuringASession() async throws {
        let window = try ChangingWindow()
        defer { window.close() }
        try window.show("normal")
        try await Task.sleep(for: .milliseconds(300))
        let fixture = ChangingWindow.frame
        try await withApp { app in
            // Settings opens in front of the fixture's window.
            try await app.menu("Settings")
            try await app.accessibilityPress("Configuration")
            let settings = try await app.waitToSee("Tilde Settings", role: "AXWindow").frame
            // Its page scrolls to the beta switches.
            var toggle = try await app.waitToSee("Wireframes", role: "AXCheckBox").frame
            for _ in 0..<8 where !settings.insetBy(dx: 0, dy: 20).contains(toggle) {
                try await app.scroll(at: CGPoint(x: settings.maxX - 200, y: settings.midY), by: -10)
                try await Task.sleep(for: .milliseconds(500))
                toggle = try await app.waitToSee("Wireframes", role: "AXCheckBox").frame
            }
            let screen = try #require(NSScreen.screens.first).frame
            try #require(screen.contains(toggle) && settings.contains(toggle), "The switch is at \(toggle), Settings at \(settings)")
            // Where Settings covers the fixture's window.
            let over = CGPoint(x: max(settings.minX, fixture.minX) + 120, y: fixture.minY + 160)
            try #require(settings.contains(over) && fixture.contains(over))

            try await app.menu("Start Annotation")
            let hud = try await app.waitToSee("Annotating")
            step("session on Settings")

            // A highlight would outline an element of the fixture's window behind Settings.
            let behind = (window.bounds ?? fixture).insetBy(dx: -30, dy: -30)
            try await app.hover(over: CGPoint(x: hud.frame.midX, y: hud.frame.midY))
            try await Task.sleep(for: .milliseconds(500))
            let before = try await app.bluePixels(in: behind)
            try await app.hover(over: CGPoint(x: over.x - 20, y: over.y))
            try await app.hover(over: over)
            try await Task.sleep(for: .seconds(1))
            #expect(try await app.bluePixels(in: behind) <= before + 10)
            step("no highlight")

            // As on any Mac, the first click on a window of an app in the background may only
            // bring it forward.
            let center = CGPoint(x: toggle.midX, y: toggle.midY)
            try await app.hover(over: CGPoint(x: center.x - 30, y: center.y))
            try await app.click(at: center)
            try await Task.sleep(for: .milliseconds(500))
            if try readDefault("wireframes") != "1" {
                try await app.click(at: center)
            }
            let end = Date().addingTimeInterval(3)
            while try readDefault("wireframes") != "1", Date() < end {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(try readDefault("wireframes") == "1")
            #expect(try await !app.seen().contains { $0.name == "add" })
            try await app.waitToSee("Annotating")
            step("switch on")

            // Draw's rectangle, dragged on Settings, starts no shape.
            try await app.press("Draw")
            try await app.waitToSee("Drawing canvas", timeout: 15)
            try await app.key(.r)
            try await app.hover(over: CGPoint(x: over.x - 20, y: over.y))
            try await app.hover(over: over)
            try await Task.sleep(for: .milliseconds(300))
            try await app.slowDrag(from: over, to: CGPoint(x: over.x + 120, y: over.y + 80))
            try await Task.sleep(for: .seconds(1))
            #expect(try await !app.seen().contains { $0.name == "add" })
            try await app.waitToSee("Done, ⌘↩")
            step("no shape")
        }
    }

    /// A value of the test app's settings, as `defaults` reads it; nil when it has none.
    private func readDefault(_ key: String) throws -> String? {
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["read", "dev.tilde.ux", key]
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        try task.run()
        waitForExit(task)
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return task.terminationStatus == 0 ? text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    /// The wireframe bar's palette button shows the controls of the look in the place of the
    /// tools, and a second press shows the tools again; the bar keeps its width, so the palette
    /// button and Done stay put. The style and colours menus change the components drawn at
    /// once, Esc closes an open menu and then the Adjust popover first, and the Fill slider
    /// in the popover changes them as it moves. Construction, the default, has ticks past the
    /// corners and no offset edge; Technical has an offset edge and no ticks. A button is
    /// orange by kind, the default, and blue in One colour.
    @Test func theStyleControlsInTheBarChangeTheLookAtOnce() async throws {
        let window = try ChangingWindow()
        defer { window.close() }
        let frame = ChangingWindow.frame
        let button = CGRect(x: frame.minX + 12, y: frame.minY + 100, width: 84, height: 40)
        let pastCorner = CGRect(x: button.minX - 6, y: button.minY - 1, width: 4, height: 2)
        let offsetEdge = CGRect(x: button.midX - 20, y: button.maxY + 2, width: 40, height: 2)
        let inside = button.insetBy(dx: 10, dy: 10)
        try await withApp(defaults: ["wireframes": "true"]) { app in
            try await app.menu("Start Annotation")
            try await app.waitToSee("Annotating")
            try await app.key(.w)
            try await app.waitToSee("Done, ⌘↩")
            try await app.waitToSee("Drawing canvas", timeout: 15)
            try await app.key(.b)
            try await app.hold("command", down: true)
            try await app.slowDrag(from: button.origin, to: CGPoint(x: button.maxX, y: button.maxY))
            try await app.hold("command", down: false)
            try await waitFor(app, at: pastCorner, every: 1, Picture.isWireframe, atLeast: 2)
            try await waitFor(app, at: offsetEdge, every: 1, Picture.isWireframe, atMost: 0)
            step("construction drawn")

            func place(of name: String) async throws -> CGRect {
                try #require(try await app.seen().first { $0.name == name }).frame
            }
            let palette = try await place(of: "Style")
            let done = try await place(of: "Done, ⌘↩")
            try await app.press("Style")
            try await app.waitToSee("Wireframe style")
            try await app.waitNotToSee("Card")
            #expect(try await place(of: "Style") == palette)
            #expect(try await place(of: "Done, ⌘↩") == done)
            step("style mode")

            try await app.press("Wireframe style")
            try await app.press("Technical")
            try await waitFor(app, at: offsetEdge, every: 1, Picture.isWireframe, atLeast: 40)
            try await waitFor(app, at: pastCorner, every: 1, Picture.isWireframe, atMost: 0)
            step("technical chosen")

            try await waitFor(app, at: inside, Picture.isWireframeOrange, atLeast: 200)
            try await app.press("Colours")
            try await app.press("One colour")
            try await waitFor(app, at: inside, Picture.isWireframeBlue, atLeast: 200)
            try await waitFor(app, at: inside, Picture.isWireframeOrange, atMost: 0)
            step("one colour chosen")

            // Esc closes the open menu, and the bar stays in style mode.
            #expect(try await !app.seen().contains { $0.name == "Blueprint" })
            try await app.press("Wireframe style")
            try await app.waitToSee("Blueprint")
            // The menu takes the keys once it has opened.
            try await Task.sleep(for: .milliseconds(300))
            try await app.key(.escape)
            try await app.waitNotToSee("Blueprint")
            try await app.waitToSee("Wireframe style")
            step("menu closed")

            // The Fill slider at its end fills the button with strong blue.
            let isStrongBlue = { (color: Picture.Color) in color.blue - color.red > 0.4 }
            try await waitFor(app, at: inside, isStrongBlue, atMost: 20)
            try await app.press("Adjust")
            try await app.waitToSee("Fade under")
            let fill = try #require(try await app.seen().first { $0.role == "AXSlider" && $0.name == "Fill" })
            try await app.click(at: CGPoint(x: fill.frame.maxX - 2, y: fill.frame.midY))
            try await waitFor(app, at: inside, isStrongBlue, atLeast: 200)
            step("fill changed")

            // Esc closes the popover, then shows the tools again; the bar has kept its width.
            try await app.key(.escape)
            try await app.waitNotToSee("Fade under")
            try await app.waitToSee("Wireframe style")
            try await app.key(.escape)
            try await app.waitToSee("Card")
            try await app.waitNotToSee("Wireframe style")
            #expect(try await place(of: "Style") == palette)
            #expect(try await place(of: "Done, ⌘↩") == done)
            step("tools again")
        }
    }

    /// Each corner of a part resizes it from that corner: the opposite sides stay, and the two
    /// sides of the corner follow the pointer. The grip on its top edge moves it whole. Lines
    /// on the window behind can snap a side by a few points, so the sides are found on the
    /// screen.
    @Test func eachCornerResizesAPartAndTheTopGripMovesIt() async throws {
        let window = try ChangingWindow()
        defer { window.close() }
        let frame = ChangingWindow.frame
        let drawn = CGRect(x: frame.minX + 80, y: frame.minY + 120, width: 200, height: 100)
        try await withApp(defaults: ["wireframes": "true"]) { app in
            try await drawCard(app, in: drawn)
            try await app.key(.escape)
            var part = try await sides(app, near: drawn)
            step("card drawn")

            let corners: [(name: String, corner: (CGRect) -> CGPoint, by: CGVector)] = [
                ("se", { CGPoint(x: $0.maxX, y: $0.maxY) }, CGVector(dx: 20, dy: 20)),
                ("nw", { CGPoint(x: $0.minX, y: $0.minY) }, CGVector(dx: -20, dy: -20)),
                ("ne", { CGPoint(x: $0.maxX, y: $0.minY) }, CGVector(dx: 20, dy: -20)),
                ("sw", { CGPoint(x: $0.minX, y: $0.maxY) }, CGVector(dx: -20, dy: 20)),
            ]
            for (name, corner, by) in corners {
                try await drag(app, from: corner(part), by: by)
                let wanted = CGRect(
                    x: by.dx < 0 ? part.minX + by.dx : part.minX, y: by.dy < 0 ? part.minY + by.dy : part.minY,
                    width: part.width + abs(by.dx), height: part.height + abs(by.dy)
                )
                let resized = try await sides(app, near: wanted)
                // The sides away from the corner stay; those of the corner move 20 points out,
                // or a few points more or less where they snap.
                let moved = (
                    left: part.minX - resized.minX, right: resized.maxX - part.maxX,
                    top: part.minY - resized.minY, bottom: resized.maxY - part.maxY
                )
                let stays = (by.dx < 0 ? [moved.right] : [moved.left]) + (by.dy < 0 ? [moved.bottom] : [moved.top])
                let grows = (by.dx < 0 ? [moved.left] : [moved.right]) + (by.dy < 0 ? [moved.top] : [moved.bottom])
                #expect(stays.allSatisfy { abs($0) <= 1 }, "\(name): \(part) became \(resized)")
                #expect(grows.allSatisfy { (11...29).contains($0) }, "\(name): \(part) became \(resized)")
                part = resized
                step("\(name) corner resized")
            }

            // The grip is on the middle of the top edge, from 2 points above it.
            try await drag(app, from: CGPoint(x: part.midX, y: part.minY + 2), by: CGVector(dx: 30, dy: 30), restingAt: CGPoint(x: part.midX, y: part.midY))
            let moved = try await sides(app, near: part.offsetBy(dx: 30, dy: 30))
            #expect(abs(moved.width - part.width) <= 1 && abs(moved.height - part.height) <= 1, "\(part) became \(moved)")
            #expect((21...39).contains(moved.minX - part.minX) && (21...39).contains(moved.minY - part.minY), "\(part) became \(moved)")
            step("moved by the grip")
        }
    }

    /// A drag starts where it was pressed. The pointer leaves a part at its right, clicks the
    /// window behind, and comes back to drag the part to the left at once: in every frame of the
    /// screen, the part is where it was or left of it, never on the side where the pointer left.
    @Test func aDragStartsWhereItWasPressed() async throws {
        let window = try ChangingWindow()
        defer { window.close() }
        let frame = ChangingWindow.frame
        let drawn = CGRect(x: frame.minX + 120, y: frame.minY + 120, width: 200, height: 100)
        try await withApp(defaults: ["wireframes": "true"]) { app in
            try await drawCard(app, in: drawn)
            try await app.key(.escape)
            let part = try await sides(app, near: drawn)
            try await app.hover(over: CGPoint(x: part.maxX - 10, y: part.midY))
            try await Task.sleep(for: .milliseconds(200))
            try await app.hover(over: CGPoint(x: part.maxX + 120, y: part.midY))
            try await Task.sleep(for: .milliseconds(200))
            try await app.click(at: CGPoint(x: part.maxX + 120, y: part.maxY + 60))
            step("pointer left at the right")

            // A row through the part's label tag, which is solid from the part's left side.
            let row = part.minY - 10
            let start = try #require(try await app.screen().firstX(onRow: row, from: part.minX - 100, to: part.maxX, where: Picture.isWireframe))
            async let recorded = app.recordRow(at: row, from: part.minX - 100, width: part.width + 300, seconds: 2)
            try await Task.sleep(for: .milliseconds(150))
            let press = CGPoint(x: part.minX + 30, y: part.midY)
            try await app.mouseDown(at: press)
            for step in 1...8 {
                try await app.mouseDragged(to: CGPoint(x: press.x - CGFloat(step) * 5, y: press.y))
            }
            try await app.mouseUp(at: CGPoint(x: press.x - 40, y: press.y))
            let frames = try await recorded
            let lefts = frames.compactMap { $0.firstX(onRow: row, from: part.minX - 100, to: part.maxX + 200, where: Picture.isWireframe) }
            #expect(lefts.count >= 10, "Too few frames: \(lefts)")
            #expect(lefts.allSatisfy { $0 <= start + 1 }, "The part went right of \(start): \(lefts)")
            #expect(lefts.contains { $0 <= start - 30 }, "The part did not move left of \(start): \(lefts)")
            step("drag recorded")
        }
    }

    /// Starts wireframe mode and draws a card with ⌘ over `rect`.
    private func drawCard(_ app: TildeApp, in rect: CGRect) async throws {
        try await app.menu("Start Annotation")
        try await app.waitToSee("Annotating")
        try await app.key(.w)
        try await app.waitToSee("Done, ⌘↩")
        try await app.waitToSee("Drawing canvas", timeout: 15)
        try await app.key(.c)
        try await app.hold("command", down: true)
        try await app.slowDrag(from: rect.origin, to: CGPoint(x: rect.maxX, y: rect.maxY))
        try await app.hold("command", down: false)
    }

    /// A drag with ⌘ from a point, by an offset, after the pointer rests on the part so that its
    /// handles show: by default inside it, back from the start.
    private func drag(_ app: TildeApp, from start: CGPoint, by offset: CGVector, restingAt rest: CGPoint? = nil) async throws {
        try await app.hover(over: rest ?? CGPoint(x: start.x - offset.dx * 2, y: start.y - offset.dy * 2))
        try await Task.sleep(for: .milliseconds(150))
        try await app.hold("command", down: true)
        try await app.mouseDown(at: start)
        for step in 1...4 {
            try await app.mouseDragged(to: CGPoint(x: start.x + offset.dx * CGFloat(step) / 4, y: start.y + offset.dy * CGFloat(step) / 4))
        }
        try await app.mouseUp(at: CGPoint(x: start.x + offset.dx, y: start.y + offset.dy))
        try await app.hold("command", down: false)
    }

    /// The sides of the part near `rect` as the screen shows them: for each side, the line
    /// within 12 points of that side of `rect` with the most wireframe pixels, along a part of
    /// it clear of the corners, the tag, the grip and the chip.
    private func sides(_ app: TildeApp, near rect: CGRect, sourceLocation: SourceLocation = #_sourceLocation) async throws -> CGRect {
        let offsets = stride(from: -12.0, through: 12.0, by: 0.5)
        let end = Date().addingTimeInterval(4)
        while true {
            try await Task.sleep(for: .milliseconds(300))
            let picture = try await app.screen()
            func line(_ around: Double, _ strip: (Double) -> CGRect) -> Double? {
                let scored = offsets.map { (around + $0, picture.count(in: strip(around + $0), every: 1, where: Picture.isWireframe)) }
                guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= 10 else {
                    return nil
                }
                return best.0
            }
            let column = { (x: Double) in CGRect(x: x, y: rect.minY + rect.height * 0.3, width: 0.5, height: rect.height * 0.4) }
            let row = { (y: Double) in CGRect(x: rect.minX + rect.width * 0.25, y: y, width: rect.width * 0.15, height: 0.5) }
            if let left = line(rect.minX, column), let right = line(rect.maxX, column), let top = line(rect.minY, row), let bottom = line(rect.maxY, row) {
                return CGRect(x: left, y: top, width: right - left, height: bottom - top)
            }
            if Date() > end {
                await app.saveFailure(named: "sides-\(sourceLocation.line)")
                throw UXFailure(description: "No part near \(rect)")
            }
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
        await app.saveFailure(named: "pixels-\(sourceLocation.line)")
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
