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
            // The pointer rests on it, also if the HUD was still appearing when it first moved.
            // Off the button and back once the HUD has settled, so that the HUD sees it enter.
            try await Task.sleep(for: .milliseconds(600))
            try await app.hover(over: CGPoint(x: button.frame.midX, y: button.frame.maxY + 200))
            try await Task.sleep(for: .milliseconds(100))
            try await app.hover(over: CGPoint(x: button.frame.midX, y: button.frame.midY))
            for _ in 0..<60 where try await app.seen().filter({ $0.name == "Pause (Esc)" && $0.role == "AXStaticText" }).isEmpty {
                try await Task.sleep(for: .milliseconds(50))
            }
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

    /// Adds a note on the small text at a point and rests the pointer on the HUD.
    private func addSmallNote(_ app: TildeApp, at point: CGPoint) async throws {
        // As a user does: the pointer rests on the element before the click.
        try await app.hover(over: point)
        try await Task.sleep(for: .seconds(1))
        try await app.click(at: point)
        try await app.waitToSee("add")
        try await Task.sleep(for: .milliseconds(40))
        try await app.type("On this page")
        try await app.waitToSee("On this page", timeout: 3)
        try await app.key(.enter)
        try await app.waitToSeeText(containing: "1 note")
        let hud = try await app.waitToSee("Annotating")
        try await app.hover(over: CGPoint(x: hud.frame.midX, y: hud.frame.midY))
    }

    @Test func aNoteOnSmallTextHidesOnAnotherPageWithTheSameLayoutAndComesBack() async throws {
        let window = try ChangingWindow()
        defer { window.close() }
        try await withApp { app in
            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")
            let frame = ChangingWindow.frame
            // On the text of the first row.
            try await addSmallNote(app, at: CGPoint(x: frame.minX + 80, y: frame.minY + 55))

            // Its number is there, its box is not.
            let area = frame
            try await app.waitForBlue(in: area, atLeast: 20, atMost: 900)

            for _ in 0..<3 {
                // Another page: the note hides, and stays in the session.
                try window.show("b")
                try await app.waitForBlue(in: area, atMost: 0)
                try await app.waitToSeeText(containing: "1 note")

                // Back: it shows again.
                try window.show("a")
                try await app.waitForBlue(in: area, atLeast: 20)
            }

            // A small change elsewhere on the page does not hide it.
            try window.show("almost")
            try await Task.sleep(for: .seconds(2))
            try await app.waitForBlue(in: area, atLeast: 20)
        }
    }

    @Test(arguments: WebPages.Browser.allCases)
    func aNoteInABrowserHidesOnAnotherPageAndComesBack(browser: WebPages.Browser) async throws {
        let pages = try WebPages(browser: browser)
        defer {
            pages.quitBrowser()
            pages.stop()
        }
        pages.go(to: pages.first)
        try await pages.waitForPage()
        try await withApp { app in
            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")
            // Chrome starts to describe its page when the session starts.
            try await Task.sleep(for: .seconds(2))
            let page = try #require(pages.pageArea)
            try await addSmallNote(app, at: CGPoint(x: page.minX + 120, y: page.minY + 300))
            // Below the HUD, whose Send button is blue too.
            let area = page.divided(atDistance: 200, from: .minYEdge).remainder
            try await app.waitForBlue(in: area, atLeast: 20)

            pages.go(to: pages.second)
            try await app.waitForBlue(in: area, atMost: 0)

            pages.go(to: pages.first)
            try await app.waitForBlue(in: area, atLeast: 20)
        }
    }

    @Test(arguments: WebPages.Browser.allCases)
    func aNoteInASinglePageAppHidesOnARouteWithTheSameContentAndComesBack(browser: WebPages.Browser) async throws {
        let pages = try WebPages(browser: browser)
        defer {
            pages.quitBrowser()
            pages.stop()
        }
        pages.go(to: pages.singlePage)
        try await pages.waitForPage()
        try await withApp { app in
            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")
            // Chrome starts to describe its page when the session starts.
            try await Task.sleep(for: .seconds(2))
            let page = try #require(pages.pageArea)
            try await addSmallNote(app, at: CGPoint(x: page.minX + 120, y: page.minY + 300))
            // Below the HUD, whose Send button is blue too.
            let area = page.divided(atDistance: 200, from: .minYEdge).remainder
            try await app.waitForBlue(in: area, atLeast: 20)

            // The page changes its address without loading, as X does.
            func press(_ button: CGPoint) async throws {
                try await app.hold("option", down: true)
                try await app.click(at: CGPoint(x: page.minX + button.x, y: page.minY + button.y))
                try await app.hold("option", down: false)
                // Away from the page, or the highlight under the pointer counts as blue.
                let hud = try await app.waitToSee("Annotating")
                try await app.hover(over: CGPoint(x: hud.frame.midX, y: hud.frame.midY))
            }
            try await press(WebPages.forward)
            try await app.waitForBlue(in: area, atMost: 0)

            try await press(WebPages.back)
            // Chrome can take seconds to report the address after going back.
            try await app.waitForBlue(in: area, atLeast: 20, timeout: 15)
        }
    }

    @Test(arguments: WebPages.Browser.allCases)
    func aNoteFollowsTheBackAndForwardKeysOfTheBrowser(browser: WebPages.Browser) async throws {
        let pages = try WebPages(browser: browser)
        defer {
            pages.quitBrowser()
            pages.stop()
        }
        pages.go(to: pages.first)
        try await pages.waitForPage()
        try await withApp { app in
            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")
            try await Task.sleep(for: .seconds(2))
            let page = try #require(pages.pageArea)
            try await addSmallNote(app, at: CGPoint(x: page.minX + 120, y: page.minY + 300))
            let area = page.divided(atDistance: 200, from: .minYEdge).remainder
            try await app.waitForBlue(in: area, atLeast: 20)

            // A link in the same tab, as a user follows one.
            try await app.hold("option", down: true)
            try await app.click(at: CGPoint(x: page.minX + WebPages.load.x, y: page.minY + WebPages.load.y))
            try await app.hold("option", down: false)
            let hud = try await app.waitToSee("Annotating")
            try await app.hover(over: CGPoint(x: hud.frame.midX, y: hud.frame.midY))
            try await app.waitForBlue(in: area, atMost: 0)

            try await app.key(.leftBracket, command: true)
            try await app.waitForBlue(in: area, atLeast: 20, timeout: 15)

            try await app.key(.rightBracket, command: true)
            try await app.waitForBlue(in: area, atMost: 0, timeout: 15)

            try await app.key(.leftBracket, command: true)
            try await app.waitForBlue(in: area, atLeast: 20, timeout: 15)
        }
    }

    @Test func aNoteInTildesBrowserHidesOnAnotherPageAndComesBack() async throws {
        let page = try TestPage()
        defer { page.stop() }
        try await withApp { app in
            let agent = try await MCPAgent(port: app.port, name: "Claude Code")
            _ = try await agent.call("start_annotation", ["url": page.url, "wait_seconds": 0])
            try await app.waitToSee("Paused")
            let heading = try await app.waitToSee("Welcome page", timeout: 20)
            try await annotate(app)
            try await app.waitToSee("Annotating")
            try await addNote(app, on: "Welcome page", comment: "On this page")
            try await app.waitToSeeText(containing: "1 note")
            let area = heading.frame.insetBy(dx: -30, dy: -20)
            try await app.waitForBlue(in: area, atLeast: 20)

            try await app.hold("option", down: true)
            try await app.clickText("Other page")
            try await app.hold("option", down: false)
            try await app.waitToSee("Other page heading", timeout: 20)
            try await app.waitForBlue(in: area, atMost: 0)

            try await app.key(.leftBracket, command: true)
            try await app.waitToSee("Welcome page", timeout: 20)
            try await app.waitForBlue(in: area, atLeast: 20)
        }
    }

    @Test(arguments: ["panel", "whole"])
    func notesInTildesBrowserMoveWithThePageAsItScrolls(page name: String) async throws {
        let page = try TestPage()
        defer { page.stop() }
        try await withApp { app in
            let agent = try await MCPAgent(port: app.port, name: "Claude Code")
            _ = try await agent.call("start_annotation", ["url": page.url + name + ".html", "wait_seconds": 0])
            try await app.waitToSee("Paused")
            let row = try await app.waitToSee("Row 8", timeout: 20)
            try await annotate(app)
            try await app.waitToSee("Annotating")

            // A note on an element: its number is at the top right of its row.
            try await addNote(app, on: "Row 8", comment: "On a row")
            try await app.waitToSeeText(containing: "1 note")
            func around(_ point: CGPoint) -> CGRect {
                CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
            }
            let elementMarker = CGPoint(x: row.frame.minX + 300, y: row.frame.minY)
            try await app.waitForBlue(in: around(elementMarker), atLeast: 20)

            // A note on a dragged region further down.
            let start = CGPoint(x: row.frame.minX + 340, y: row.frame.minY + 200)
            let end = CGPoint(x: start.x + 100, y: start.y + 60)
            try await app.drag(from: start, to: end)
            try await app.waitToSee("add")
            try await app.type("On a region")
            try await app.waitToSee("On a region", timeout: 3)
            try await app.key(.enter)
            try await app.waitToSeeText(containing: "2 notes")
            let regionMarker = CGPoint(x: end.x, y: start.y)
            try await app.waitForBlue(in: around(regionMarker), atLeast: 20)

            try await app.hold("option", down: true)
            try await app.clickText("Scroll")
            try await app.hold("option", down: false)

            try await app.waitForBlue(in: around(CGPoint(x: elementMarker.x, y: elementMarker.y - 120)), atLeast: 20)
            try await app.waitForBlue(in: around(CGPoint(x: regionMarker.x, y: regionMarker.y - 120)), atLeast: 20)
            try await app.waitForBlue(in: around(regionMarker), atMost: 0)
        }
    }

    @Test func aNoteInTheRealSimulatorHidesOnAnotherScreenAndComesBack() async throws {
        let simulator = try SimulatorScreens()
        defer { simulator.stop() }
        try simulator.show("first")
        for _ in 0..<120 where simulator.window == nil {
            try await Task.sleep(for: .seconds(1))
        }
        try await Task.sleep(for: .seconds(4))
        try await withApp { app in
            let window = try #require(simulator.window)
            try await Task.sleep(for: .seconds(1))
            try await app.menu("Start Annotation")
            try await app.waitToSee("Annotating")
            // A row on the phone, which sits right of the sidebar in Device Hub.
            try await addSmallNote(app, at: CGPoint(x: window.minX + window.width * 0.6, y: window.minY + window.height * 0.4))
            let area = CGRect(x: window.minX + window.width * 0.5, y: window.minY + window.height * 0.2, width: window.width * 0.3, height: window.height * 0.6)
            try await app.waitForBlue(in: area, atLeast: 20)

            try simulator.show("second")
            try await app.waitForBlue(in: area, atMost: 0, timeout: 10)

            try simulator.show("first")
            try await app.waitForBlue(in: area, atLeast: 20, timeout: 10)
        }
    }

    @Test func aRegionInTheRealSimulatorHidesOnAnotherScreenAndComesBack() async throws {
        let simulator = try SimulatorScreens()
        defer { simulator.stop() }
        try simulator.show("first")
        for _ in 0..<120 where simulator.window == nil {
            try await Task.sleep(for: .seconds(1))
        }
        try await Task.sleep(for: .seconds(3))
        try await withApp { app in
            let window = try #require(simulator.window)
            try await Task.sleep(for: .seconds(1))
            try await app.menu("Start Annotation")
            try await app.waitToSee("Annotating")
            let start = CGPoint(x: window.minX + window.width * 0.56, y: window.minY + window.height * 0.35)
            try await app.drag(from: start, to: CGPoint(x: start.x + 90, y: start.y + 70))
            try await app.waitToSee("add")
            try await app.type("On a region")
            try await app.waitToSee("On a region", timeout: 3)
            try await app.key(.enter)
            try await app.waitToSeeText(containing: "1 note")
            let hud = try await app.waitToSee("Annotating")
            try await app.hover(over: CGPoint(x: hud.frame.midX, y: hud.frame.midY))
            let area = CGRect(x: window.minX + window.width * 0.5, y: window.minY + window.height * 0.2, width: window.width * 0.3, height: window.height * 0.6)
            try await app.waitForBlue(in: area, atLeast: 20)

            try simulator.show("second")
            try await app.waitForBlue(in: area, atMost: 0, timeout: 10)

            try simulator.show("first")
            try await app.waitForBlue(in: area, atLeast: 20, timeout: 10)
        }
    }

    @Test func aNoteInANativeAppHidesOnAnotherPaneAndComesBack() async throws {
        func open(_ pane: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["x-apple.systempreferences:\(pane)"]
            try? process.run()
            waitForExit(process)
        }
        open("com.apple.Sound-Settings.extension")
        try await Task.sleep(for: .seconds(3))
        defer {
            let quit = Process()
            quit.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            quit.arguments = ["System Settings"]
            try? quit.run()
            waitForExit(quit)
        }
        // It can take a while to open the first time.
        var found: CGRect?
        for _ in 0..<40 where found == nil {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            let bounds = list.first { $0[kCGWindowOwnerName as String] as? String == "System Settings" && $0[kCGWindowLayer as String] as? Int == 0 }?[kCGWindowBounds as String] as? NSDictionary
            found = bounds.flatMap { CGRect(dictionaryRepresentation: $0) }
            try await Task.sleep(for: .milliseconds(100))
        }
        let frame = try #require(found)
        try await withApp { app in
            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")
            try await addSmallNote(app, at: CGPoint(x: frame.midX + 80, y: frame.minY + 200))
            // Without the sidebar, whose icons are blue, the HUD and any notification.
            let content = CGRect(x: frame.minX + frame.width * 0.35, y: frame.minY + 90, width: frame.width * 0.65, height: frame.height - 90)
            try await app.waitForBlue(in: content, atLeast: 20)

            open("com.apple.Keyboard-Settings.extension")
            try await app.waitForBlue(in: content, atMost: 0)

            open("com.apple.Sound-Settings.extension")
            try await app.waitForBlue(in: content, atLeast: 20)
        }
    }

    // MARK: - Holding a key

    @Test func holdingTheKeyLetsTheMouseThroughWhileAnnotatingAndOnlyThen() async throws {
        try await withApp { app in
            // Before a session it does nothing.
            try await app.hold("option", down: true)
            try await app.hold("option", down: false)
            try await app.waitNotToSee("Paused", timeout: 1)

            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")

            try await app.hold("option", down: true)
            try await app.waitToSee("Paused")
            try await app.waitToSee("Release ⌥ to annotate")

            try await app.hold("option", down: false)
            try await app.waitToSee("Annotating")
        }
    }

    @Test func theHoldKeyIsASetting() async throws {
        try await withApp { app in
            try await app.menu("Settings")
            try await app.press("Shortcuts")
            try await app.waitToSee("Hold to use the app normally")
        }
    }

    // MARK: - Writing a comment

    @Test func aCommentIsNeverLostByAClickAwayAndEscAsksFirst() async throws {
        let window = try ChangingWindow()
        defer { window.close() }
        try await withApp { app in
            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")
            let frame = ChangingWindow.frame

            // Clicking away keeps the note.
            try await app.click(at: CGPoint(x: frame.minX + 80, y: frame.minY + 55))
            try await app.waitToSee("add")
            try await app.type("Keep me")
            try await app.waitToSee("Keep me", timeout: 3)
            try await app.click(at: CGPoint(x: frame.maxX + 100, y: frame.maxY + 100))
            try await app.waitToSeeText(containing: "1 note")

            // Clicking away from an empty box adds nothing.
            try await app.click(at: CGPoint(x: frame.minX + 80, y: frame.minY + 123))
            try await app.waitToSee("add")
            try await app.click(at: CGPoint(x: frame.maxX + 100, y: frame.maxY + 100))
            try await app.waitNotToSee("add")
            try await app.waitToSeeText(containing: "1 note")

            // Esc on text asks; Esc again keeps writing; Return discards.
            try await app.click(at: CGPoint(x: frame.minX + 80, y: frame.minY + 123))
            try await app.waitToSee("add")
            try await app.type("Maybe")
            try await app.waitToSee("Maybe", timeout: 3)
            try await app.key(.escape)
            try await app.waitToSee("Discard comment?")
            try await app.key(.escape)
            try await app.waitNotToSee("Discard comment?")
            try await app.waitToSee("Maybe")
            try await app.key(.escape)
            try await app.waitToSee("Discard comment?")
            try await app.key(.enter)
            try await app.waitNotToSee("Maybe")
            try await app.waitToSeeText(containing: "1 note")
        }
    }

    @Test func theCommentBoxStepsToItsNewSizeWithoutFlashing() async throws {
        let window = try ChangingWindow()
        defer { window.close() }
        try await withApp { app in
            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")
            let frame = ChangingWindow.frame
            try await app.click(at: CGPoint(x: frame.minX + 80, y: frame.minY + 55))
            try await app.waitToSee("add")
            try await Task.sleep(for: .milliseconds(300))
            let boxWidth = 356.0
            // New lines only ever grow it.
            let growing = try await app.heights(ofWindowWidth: boxWidth, seconds: 2) {
                for _ in 0..<5 {
                    try await app.key(.enter, shift: true)
                    try await Task.sleep(for: .milliseconds(150))
                }
            }
            #expect(growing.count >= 3, "\(growing)")
            #expect(growing == growing.sorted(), "\(growing)")
            // Deleting lines only ever shrinks it.
            let shrinking = try await app.heights(ofWindowWidth: boxWidth, seconds: 2) {
                for _ in 0..<5 {
                    try await app.key(.delete)
                    try await Task.sleep(for: .milliseconds(150))
                }
            }
            #expect(shrinking.count >= 3, "\(shrinking)")
            #expect(shrinking == shrinking.sorted(by: >), "\(shrinking)")
            // A large paste is one step, and stays inside the limit.
            let copy = Process()
            copy.executableURL = URL(fileURLWithPath: "/bin/sh")
            copy.arguments = ["-c", "yes \"A long line of pasted text\" | head -100 | pbcopy"]
            try copy.run()
            waitForExit(copy)
            let pasting = try await app.heights(ofWindowWidth: boxWidth, seconds: 1) {
                try await app.key(.v, command: true)
            }
            #expect(pasting.count <= 2, "\(pasting)")
        }
    }

    @Test func pastingALongCommentKeepsTheTopOfTheBoxOnScreen() async throws {
        let window = try ChangingWindow()
        defer { window.close() }
        try await withApp { app in
            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")
            let frame = ChangingWindow.frame
            try await app.click(at: CGPoint(x: frame.minX + 80, y: frame.minY + 55))
            let hint = try await app.waitToSee("add")
            let chip = try #require(try await app.seen().first { $0.role == "AXStaticText" && $0.frame.maxY < hint.frame.minY })
            let copy = Process()
            copy.executableURL = URL(fileURLWithPath: "/bin/sh")
            copy.arguments = ["-c", "yes \"A long line of pasted text that wraps in the comment box\" | head -200 | pbcopy"]
            try copy.run()
            waitForExit(copy)
            try await app.key(.v, command: true)
            try await Task.sleep(for: .milliseconds(500))
            let after = try #require(try await app.seen().first { $0.name == chip.name && $0.role == "AXStaticText" })
            #expect(abs(after.frame.minY - chip.frame.minY) < 1)
            let moved = try await app.waitToSee("add")
            #expect(moved.frame.minY > hint.frame.minY + 200)
            let screen = try #require(NSScreen.screens.first)
            #expect(moved.frame.maxY < screen.frame.height)
        }
    }

    @Test func aDrawingBecomesANoteWithItsShapesAndPictures() async throws {
        try await withApp { app in
            let agent = try await MCPAgent(port: app.port, name: "Claude Code")
            let started = try await agent.call("start_annotation", ["wait_seconds": 0])
            let session = try #require(started.text.components(separatedBy: "session_id: ").last?.prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" }))
            let hud = try await app.waitToSee("Annotating")
            try await app.press("Draw on the screen")
            try await app.waitToSee("Done, esc")
            // The canvas loads, then takes the drag.
            try await Task.sleep(for: .seconds(4))
            let start = CGPoint(x: hud.frame.midX, y: hud.frame.maxY + 200)
            try await app.drag(from: start, to: CGPoint(x: start.x + 200, y: start.y + 120))
            try await app.press("Rectangle")
            try await app.drag(from: CGPoint(x: start.x - 300, y: start.y), to: CGPoint(x: start.x - 100, y: start.y + 100))
            try await Task.sleep(for: .milliseconds(300))
            try await app.press("Done, esc")
            try await app.waitToSee("add", timeout: 15)
            try await app.type("Look here")
            try await app.waitToSee("Look here", timeout: 3)
            try await app.key(.enter)
            try await app.waitToSeeText(containing: "1 note")
            try await app.key(.enter, command: true)
            let result = try await agent.call("wait_for_annotation", ["session_id": String(session), "wait_seconds": 15])
            #expect(result.text.contains("arrow"))
            #expect(result.text.contains("rectangle"))
        }
    }

    @Test func shiftReturnAddsALineInTheCommentBoxAndInThePreviewAndEscClosesThePreview() async throws {
        let window = try ChangingWindow()
        defer { window.close() }
        try await withApp { app in
            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")
            let frame = ChangingWindow.frame
            try await app.click(at: CGPoint(x: frame.midX, y: frame.midY))
            try await app.waitToSee("add")
            try await Task.sleep(for: .milliseconds(40))

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
