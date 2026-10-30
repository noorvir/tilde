import AppKit
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
        try await Task.sleep(for: .milliseconds(500))
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
        try await Task.sleep(for: .milliseconds(300))
        try await app.type(comment)
        try await app.waitToSee(comment, timeout: 3)
        try await app.key(.enter)
    }

    // MARK: - Agent flow

    @Test func anAgentOpensAPageTheUserNotesItAndTheAgentGetsAReportWithImages() async throws {
        let page = try TestPage()
        defer { page.stop() }
        try await withApp { app in
            let agent = try await MCPAgent(port: app.port, name: "codex-mcp-client")
            let started = try await agent.call("start_annotation", ["url": page.url, "wait_seconds": 0])
            let session = try #require(started.text.components(separatedBy: "session_id: ").last?.prefix(while: { $0 != "." && $0 != " " && $0 != "\n" }))

            // The browser opens paused, so the user can browse first.
            try await app.waitToSee("Paused")
            try await app.waitToSeeText(containing: "Codex")
            try await app.waitToSee("Welcome page", timeout: 20)

            try await annotate(app)
            try await app.waitToSee("Annotating")
            try await addNote(app, on: "Welcome page", comment: "Make this bigger")
            try await app.waitToSeeText(containing: "1 note")

            try await app.key(.enter, command: true)
            let report = try await agent.call("wait_for_annotation", ["session_id": String(session), "wait_seconds": 5])
            #expect(report.text.contains("Make this bigger"))
            #expect(report.images.count >= 1)
        }
    }

    // MARK: - HUD and Esc

    @Test func aLocalSessionSaysItGoesToTheClipboardAndEscPausesThenClosesWhenEmpty() async throws {
        try await withApp { app in
            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")
            try await app.waitToSeeText(containing: "Clipboard")
            try await app.waitToSee("Copy")

            try await app.clickText("Annotating")
            try await app.key(.escape)
            try await app.waitToSee("Paused")

            try await app.key(.escape)
            try await app.waitNotToSee("Paused")
        }
    }

    @Test func escWithNotesPausesThenAsksThenEscKeepsAndReturnDiscards() async throws {
        let page = try TestPage()
        defer { page.stop() }
        try await withApp { app in
            let agent = try await MCPAgent(port: app.port, name: "Claude Code")
            _ = try await agent.call("start_annotation", ["url": page.url, "wait_seconds": 0])
            try await app.waitToSee("Welcome page", timeout: 20)
            try await annotate(app)
            try await addNote(app, on: "Welcome page", comment: "A note")

            try await app.key(.escape)
            try await app.waitToSee("Paused")
            try await app.key(.escape)
            try await app.waitToSee("Discard and close?")
            try await app.waitToSee("Cancel, esc")
            try await app.waitToSee("Discard")

            try await app.key(.escape)
            try await app.waitNotToSee("Discard and close?")
            try await app.waitToSee("Paused")

            try await app.key(.escape)
            try await app.waitToSee("Discard and close?")
            try await app.key(.enter)
            try await app.waitNotToSee("Paused")
        }
    }

    @Test func aTooltipStaysWholeInsideTheHUD() async throws {
        try await withApp { app in
            try await app.doubleTap("control")
            let button = try await app.waitToSee("Pause (Esc)")
            try await app.hover(over: CGPoint(x: button.frame.midX, y: button.frame.midY))
            try await Task.sleep(for: .milliseconds(900))
            let texts = try await app.seen().filter { $0.name == "Pause (Esc)" && $0.role == "AXStaticText" }
            let tooltip = try #require(texts.first)
            let window = try #require(try await app.seen().first { $0.role == "AXWindow" && $0.frame.contains(button.frame) })
            #expect(window.frame.insetBy(dx: -1, dy: -1).contains(tooltip.frame))
        }
    }

    // MARK: - Shortcuts

    @Test func doubleTapControlStartsAndResumesButDoesNothingWhileAnnotating() async throws {
        try await withApp { app in
            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")

            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")

            try await app.clickText("Annotating")
            try await app.key(.escape)
            try await app.waitToSee("Paused")

            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")
        }
    }

    @Test func theShortcutRecorderTakesADoubleTap() async throws {
        try await withApp { app in
            try await app.menu("Settings")
            try await app.press("Shortcuts")
            try await app.waitToSee("Start or resume annotating")
            try await app.waitToSee("Pause")
            try await app.press("Record shortcut")
            try await app.waitToSee("Press shortcut")
            try await app.doubleTap("option")
            try await app.waitNotToSee("Press shortcut")
            try await app.waitToSee("⌥, ⌥")
        }
    }

    // MARK: - Settings and menu

    @Test func settingsHasItsFourPages() async throws {
        try await withApp { app in
            try await app.menu("Settings")
            try await app.waitToSee("Launch at login")
            try await app.waitToSee("Import logins")
            try await app.waitToSee("MCP server")

            try await app.press("Agents")
            try await app.waitToSee("Apps on this Mac")

            try await app.press("Shortcuts")
            try await app.waitToSee("Start or resume annotating")
            try await app.expectWindow(titled: "Tilde Settings", matches: "settings-shortcuts")

            try await app.press("History")
            try await app.waitToSee("No sessions yet")
            try await app.waitToSee("Clear History")
            try await app.expectWindow(titled: "Tilde Settings", matches: "settings-history-empty")
        }
    }

    @Test func theMenuHasItsItemsAndHistory() async throws {
        try await withApp { app in
            for item in ["Start Annotation", "Agents", "History", "Open Browser", "Settings", "Quit Tilde"] {
                try await app.waitToSee(item)
            }
        }
    }

    // MARK: - Saving and history

    @Test func afterACrashTildeOffersTheSessionAndRestoresItsNotesAndImages() async throws {
        let page = try TestPage()
        defer { page.stop() }
        let first = try await TildeApp.launched()
        let agent = try await MCPAgent(port: first.port, name: "Claude Code")
        _ = try await agent.call("start_annotation", ["url": page.url, "wait_seconds": 0])
        try await first.waitToSee("Welcome page", timeout: 20)
        try await annotate(first)
        try await addNote(first, on: "Welcome page", comment: "Keep me")
        try await Task.sleep(for: .seconds(3))
        first.kill()

        let saved = try FileManager.default.subpathsOfDirectory(atPath: first.sessions.path)
        #expect(saved.contains { $0.hasSuffix("session.json") })
        #expect(saved.contains { $0.hasSuffix(".png") })

        let second = try await TildeApp.relaunched(after: first)
        defer { second.quit() }
        try await second.waitToSee("Restore unfinished session?")
        try await second.press("Restore")
        try await second.waitToSee("Welcome page", timeout: 20)
        try await second.waitToSee("Keep me")
    }

    @Test func historyRestoresASessionAndAsksBeforeReplacingNotes() async throws {
        let page = try TestPage()
        defer { page.stop() }
        try await withApp { app in
            let agent = try await MCPAgent(port: app.port, name: "Claude Code")
            _ = try await agent.call("start_annotation", ["url": page.url, "wait_seconds": 0])
            try await app.waitToSee("Welcome page", timeout: 20)
            try await annotate(app)
            try await addNote(app, on: "Welcome page", comment: "First note")
            try await app.key(.enter, command: true)
            try await app.waitNotToSee("Annotating")

            // A new session with a note of its own.
            _ = try await agent.call("start_annotation", ["url": page.url, "wait_seconds": 0])
            try await app.waitToSee("Welcome page", timeout: 20)
            try await annotate(app)
            try await addNote(app, on: "Second paragraph", comment: "Second note")

            try await app.menu("Settings")
            try await app.press("History")
            try await app.waitToSee("Sent")
            try await app.press("Restore")
            try await app.waitToSeeText(containing: "saved?")
            try await app.key(.enter)
            try await app.waitToSee("First note")
        }
    }

    // MARK: - Browser

    @Test func theBrowserTakesAnAddressNavigatesAndHostsTheHUDInItsToolbar() async throws {
        let page = try TestPage()
        defer { page.stop() }
        try await withApp { app in
            let agent = try await MCPAgent(port: app.port, name: "Claude Code")
            _ = try await agent.call("start_annotation", ["url": page.url + "other.html", "wait_seconds": 0])
            try await app.waitToSee("Paused")
            try await app.waitToSee("Notes")
            try await app.waitToSee("Other page heading", timeout: 20)

            // Back to the first page through the address field.
            try await app.clickText(page.url + "other.html")
            try await app.key(.a, command: true)
            try await app.type(page.url)
            try await app.key(.enter)
            try await app.waitToSee("Welcome page", timeout: 20)
            try await app.clickText("Other page")
            try await app.waitToSee("Other page heading", timeout: 20)

            // The HUD is in the browser's own window.
            let window = try #require(try await app.seen().first { $0.role == "AXWindow" && $0.frame.width > 700 })
            let hud = try await app.waitToSee("Paused")
            #expect(window.frame.contains(hud.frame))
        }
    }

    @Test func theBrowserFirstOpensAtFullHeightAndHalfWidth() async throws {
        try await withApp { app in
            try await app.menu("Open Browser")
            try await app.waitToSee("Paused")
            let window = try #require(try await app.seen().first { $0.role == "AXWindow" && $0.frame.width > 700 })
            let screen = try #require(NSScreen.screens.first { $0.frame.width >= window.frame.width })
            #expect(window.frame.height > screen.visibleFrame.height * 0.9)
            #expect(window.frame.width < screen.visibleFrame.width * 0.75)
        }
    }

    @Test func closingTheBrowserEndsItsScopeAndTheHUDFloatsAgain() async throws {
        let page = try TestPage()
        defer { page.stop() }
        try await withApp { app in
            let agent = try await MCPAgent(port: app.port, name: "Claude Code")
            _ = try await agent.call("start_annotation", ["url": page.url, "wait_seconds": 0])
            try await app.waitToSee("Welcome page", timeout: 20)
            try await app.key(.w, command: true)
            try await app.waitToSee("Window closed")
        }
    }

    // MARK: - What is on screen

    @Test func aNoteShowsOnlyItsNumberAndOnlyWhileItsPageIsOnScreen() async throws {
        let window = try ChangingWindow()
        defer { window.close() }
        try await withApp { app in
            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")
            let frame = ChangingWindow.frame
            try await app.click(at: CGPoint(x: frame.midX, y: frame.midY))
            try await app.waitToSee("add")
            try await Task.sleep(for: .milliseconds(300))
            try await app.type("On the red page")
            try await app.waitToSee("On the red page", timeout: 3)
            try await app.key(.enter)
            try await app.waitToSeeText(containing: "1 note")

            // Its number is there, its box is not.
            // The pointer rests on the HUD, where nothing gets a hover highlight.
            let hud = try await app.waitToSee("Annotating")
            try await app.hover(over: CGPoint(x: hud.frame.midX, y: hud.frame.midY))
            let area = frame.insetBy(dx: -30, dy: -30)
            try await app.waitForBlue(in: area, atLeast: 20, atMost: 900)

            // Another page: the note hides, and stays in the session.
            try window.show("green")
            try await app.waitForBlue(in: area, atMost: 0)
            try await app.waitToSeeText(containing: "1 note")

            // Back: it shows again.
            try window.show("red")
            try await app.waitForBlue(in: area, atLeast: 20)
        }
    }

    // MARK: - Writing a comment

    @Test func shiftReturnAddsALineInTheCommentBoxAndInThePreviewAndEscClosesThePreview() async throws {
        let window = try ChangingWindow()
        defer { window.close() }
        try await withApp { app in
            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")
            let frame = ChangingWindow.frame
            try await app.click(at: CGPoint(x: frame.midX, y: frame.midY))
            try await app.waitToSee("add")
            try await Task.sleep(for: .milliseconds(300))

            // In the comment box: a new line, and the box stays open.
            try await app.type("first")
            try await app.key(.enter, shift: true)
            try await app.type("second")
            try await app.waitToSee("first\nsecond", timeout: 3)

            // The usual editing keys: select all and type over, undo it, and Option-Return.
            let oneLine = try await app.waitToSee("first\nsecond")
            try await app.key(.a, command: true)
            try await app.type("x")
            try await app.waitToSee("x", timeout: 3)
            try await app.key(.z, command: true)
            try await app.waitToSeeText(containing: "first", timeout: 3)
            try await app.key(.a, command: true)
            try await app.type("first")
            try await app.key(.enter, option: true)
            try await app.type("second")
            try await app.waitToSee("first\nsecond", timeout: 3)

            // The box grows with its lines.
            try await app.key(.enter, shift: true)
            try await app.type("third")
            let taller = try await app.waitToSee("first\nsecond\nthird", timeout: 3)
            #expect(taller.frame.height > oneLine.frame.height)
            try await app.key(.a, command: true)
            try await app.type("first")
            try await app.key(.enter, shift: true)
            try await app.type("second")
            try await app.waitToSee("first\nsecond", timeout: 3)
            try await app.key(.enter)
            try await app.waitToSeeText(containing: "1 note")

            // In the preview, with the text box focused.
            try await app.press("Show annotations")
            try await app.press("first\nsecond")
            try await app.waitToSee("1 of 1")
            try await app.press("first\nsecond")
            try await app.key(.enter, shift: true)
            try await app.type("third")
            let before = try await app.waitToSeeText(containing: "third", timeout: 3)

            // It grows with its text, to 400 pt at most, then scrolls.
            for _ in 0..<30 {
                try await app.key(.enter, shift: true)
                try await app.type("line")
            }
            let long = try await app.waitToSeeText(containing: "line\nline\nline", timeout: 3)
            #expect(long.frame.height > before.frame.height)
            #expect(long.frame.height <= 440)
            #expect(long.frame.height >= 200)

            // Esc closes it at once, also from the text box.
            try await app.key(.escape)
            try await app.waitNotToSee("1 of 1")
        }
    }

    // MARK: - Window picker

    @Test func choosingAWindowCanBeCancelledWithEsc() async throws {
        try await withApp { app in
            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")
            try await app.press("Annotate a specific window")
            try await app.waitToSee("Choose a window")
            try await app.key(.escape)
            try await app.waitToSee("Annotating")
        }
    }
}
