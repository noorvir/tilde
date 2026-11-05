import AppKit
import AVFoundation
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

    /// The pill moves the HUD; within 40 pt of home it snaps back, and dragged home again it
    /// forgets the place.
    @Test func theHUDMovesAndSnapsBackHome() async throws {
        try await withApp { app in
            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")
            // The title's place with the pill at rest: with the pointer off the pill, which
            // grows under it, and once its zoom and snap animations have ended.
            func title() async throws -> CGRect {
                try await app.hover(over: CGPoint(x: 100, y: 600))
                var frame = try await app.waitToSee("Annotating").frame
                for _ in 0..<20 {
                    try await Task.sleep(for: .milliseconds(150))
                    let next = try await app.waitToSee("Annotating").frame
                    if next == frame {
                        break
                    }
                    frame = next
                }
                return frame
            }
            let home = try await title()
            let pill = CGPoint(x: home.midX, y: home.midY)
            try await app.drag(from: pill, to: CGPoint(x: pill.x + 20, y: pill.y + 15))
            let snapped = try await title()
            #expect(abs(snapped.minX - home.minX) < 2 && abs(snapped.minY - home.minY) < 2, "\(home), then \(snapped)")

            try await app.drag(from: pill, to: CGPoint(x: pill.x - 200, y: pill.y + 80))
            let moved = try await title()
            #expect(abs(moved.minX - (home.minX - 200)) < 3 && abs(moved.minY - (home.minY + 80)) < 3, "\(home), then \(moved)")

            let away = CGPoint(x: moved.midX, y: moved.midY)
            try await app.drag(from: away, to: CGPoint(x: away.x + 200, y: away.y - 80))
            let back = try await title()
            #expect(abs(back.minX - home.minX) < 2 && abs(back.minY - home.minY) < 2, "\(home), then \(back)")
        }
    }

    @Test func aTooltipStaysWholeInsideTheHUD() async throws {
        try await withApp { app in
            try await app.doubleTap("control")
            try await app.waitToSee("Pause (Esc)")
            // Its frame once the HUD's zoom has ended; then off the button and back, so that
            // the HUD sees the pointer enter.
            try await Task.sleep(for: .milliseconds(600))
            let button = try await app.waitToSee("Pause (Esc)")
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
            try await app.waitToSee("Apps on this Mac")

            try await app.press("Configuration")
            try await app.waitToSee("Launch at login")
            try await app.waitToSee("Import logins")
            try await app.waitToSee("MCP server")

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
    func aLabelHidesWhenItsContentIsNotOnScreenAndComesBack(browser: WebPages.Browser) async throws {
        let pages = try WebPages(browser: browser)
        defer {
            pages.quitBrowser()
            pages.stop()
        }
        pages.go(to: pages.sameAddress)
        try await pages.waitForPage()
        try await withApp { app in
            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")
            // Chrome starts to describe its page when the session starts.
            try await Task.sleep(for: .seconds(2))
            let page = try #require(await app.pageArea(in: browser))
            let point = CGPoint(x: page.minX + 120, y: page.minY + 300)
            try await addSmallNote(app, at: point)
            // Below the HUD, whose Send button is blue too.
            // And above the bottom edge, where the Simulator's dock can show below the window.
            let area = page.divided(atDistance: 200, from: .minYEdge).remainder.divided(atDistance: 40, from: .maxYEdge).remainder
            try await app.waitForBlue(in: area, atLeast: 20)
            let hud = try await app.waitToSee("Annotating")
            step("note added")

            // With the browser in front, the hand shows over the label: at the end of its row, or
            // at the click when the browser had not described its page yet.
            let places = [point] + stride(from: page.maxX - 10, to: page.maxX - 130, by: -25).flatMap { x in
                [CGPoint(x: x, y: point.y - 20), CGPoint(x: x, y: point.y + 5)]
            }
            let foundHand = try await app.findHandCursor(over: places)
            #expect(foundHand, "No hand cursor over the label in \(browser)")
            try await app.hover(over: CGPoint(x: hud.frame.midX, y: hud.frame.midY))
            step("hand over the label")

            // Another screen on the same address and title.
            func press(_ button: CGPoint) async throws {
                try await app.hold("option", down: true)
                try await app.click(at: CGPoint(x: page.minX + button.x, y: page.minY + button.y))
                try await app.hold("option", down: false)
                try await app.hover(over: CGPoint(x: hud.frame.midX, y: hud.frame.midY))
            }
            try await press(WebPages.forward)
            try await app.waitForBlue(in: area, atMost: 0)
            try await press(WebPages.back)
            try await app.waitForBlue(in: area, atLeast: 20, timeout: 15)
            step("same address")

            // Its element scrolls off the screen, and back.
            try await app.scroll(at: point, by: -30)
            try await app.hover(over: CGPoint(x: hud.frame.midX, y: hud.frame.midY))
            try await app.waitForBlue(in: area, atMost: 0)
            try await app.scroll(at: point, by: 30)
            try await app.hover(over: CGPoint(x: hud.frame.midX, y: hud.frame.midY))
            try await app.waitForBlue(in: area, atLeast: 20, timeout: 15)
            step("scrolled off and back")

            // Another address.
            pages.go(to: pages.second)
            try await app.waitForBlue(in: area, atMost: 0)
            pages.go(to: pages.sameAddress)
            try await app.waitForBlue(in: area, atLeast: 20, timeout: 15)
            step("another address")
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
            let page = try #require(await app.pageArea(in: browser))
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
            let page = try #require(await app.pageArea(in: browser))
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

    @Test func notesInTheRealSimulatorHideOnAnotherScreenAndComeBack() async throws {
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
            // The phone at the size that fits the window, whatever an earlier run left.
            try await app.press("arrowtriangles.up.right.down.left.magnifyingglass", inApp: "Device Hub")
            try await app.menu("Start Annotation")
            try await app.waitToSee("Annotating")
            step("simulator ready")
            // A row on the phone, which sits right of the sidebar in Device Hub.
            try await addSmallNote(app, at: CGPoint(x: window.minX + window.width * 0.6, y: window.minY + window.height * 0.4))
            let area = CGRect(x: window.minX + window.width * 0.5, y: window.minY + window.height * 0.2, width: window.width * 0.3, height: window.height * 0.6)
            try await app.waitForBlue(in: area, atLeast: 20)

            try simulator.show("second")
            try await app.waitForBlue(in: area, atMost: 0, timeout: 10)
            try simulator.show("first")
            try await app.waitForBlue(in: area, atLeast: 20, timeout: 10)
            step("note")

            // A region, with the note.
            let start = CGPoint(x: window.minX + window.width * 0.56, y: window.minY + window.height * 0.35)
            try await app.drag(from: start, to: CGPoint(x: start.x + 90, y: start.y + 70))
            try await app.waitToSee("add")
            try await app.type("On a region")
            try await app.waitToSee("On a region", timeout: 3)
            try await app.key(.enter)
            try await app.waitToSeeText(containing: "2 notes")
            let hud = try await app.waitToSee("Annotating")
            try await app.hover(over: CGPoint(x: hud.frame.midX, y: hud.frame.midY))
            try await app.waitForBlue(in: area, atLeast: 20)

            try simulator.show("second")
            try await app.waitForBlue(in: area, atMost: 0, timeout: 10)
            try simulator.show("first")
            try await app.waitForBlue(in: area, atLeast: 20, timeout: 10)
            step("region")
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

    @Test func theHoldKeyIsASetting() async throws {
        try await withApp { app in
            try await app.menu("Settings")
            try await app.press("Shortcuts")
            try await app.waitToSee("Hold to use the app normally")
        }
    }

    // MARK: - Writing a comment

    @Test func theHoldKeyWorksACommentIsNeverLostAndItsBoxStepsWithoutFlashing() async throws {
        let window = try ChangingWindow()
        defer { window.close() }
        try await withApp { app in
            // The hold key does nothing before a session, and lets the mouse through in one.
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
            step("hold key")

            let frame = ChangingWindow.frame

            // Clicking away with text asks, and pauses so that the screen can be used.
            try await app.click(at: CGPoint(x: frame.minX + 80, y: frame.minY + 55))
            try await app.waitToSee("add")
            try await app.type("Keep me")
            try await app.waitToSee("Keep me", timeout: 3)
            try await app.click(at: CGPoint(x: frame.maxX + 100, y: frame.maxY + 100))
            try await app.waitToSee("Discard comment?")
            try await app.waitToSee("Paused")
            try await app.waitNotToSee("1 note", timeout: 1)

            // A click back in the box keeps writing and annotating.
            let box = try await app.waitToSee("Keep me")
            try await app.click(at: CGPoint(x: box.frame.midX, y: box.frame.midY))
            try await app.waitNotToSee("Discard comment?")
            try await app.waitToSee("Annotating")
            try await app.type(" too")
            try await app.waitToSee("Keep me too", timeout: 3)

            // So does Esc to the question.
            try await app.key(.escape)
            try await app.waitToSee("Discard comment?")
            try await app.key(.escape)
            try await app.waitNotToSee("Discard comment?")
            try await app.waitToSee("Annotating")
            try await app.waitToSee("Keep me too")

            // Return to the question discards.
            try await app.key(.escape)
            try await app.waitToSee("Discard comment?")
            try await app.key(.enter)
            try await app.waitNotToSee("Keep me too")
            try await app.waitToSee("Annotating")

            // Clicking away from an empty box just closes it.
            try await app.click(at: CGPoint(x: frame.minX + 80, y: frame.minY + 123))
            try await app.waitToSee("add")
            try await app.click(at: CGPoint(x: frame.maxX + 100, y: frame.maxY + 100))
            try await app.waitNotToSee("add")
            try await app.waitNotToSee("Discard comment?", timeout: 1)
            step("comment never lost")

            // With another app in front, the hand shows over a label. Its row ends 464 points in.
            try await app.click(at: CGPoint(x: frame.minX + 80, y: frame.minY + 55))
            try await app.waitToSee("add")
            try await app.type("A label")
            try await app.waitToSee("A label", timeout: 3)
            try await app.key(.enter)
            try await app.waitNotToSee("add")
            try await app.hover(over: CGPoint(x: frame.minX + 200, y: frame.minY + 200))
            try await app.waitForHandCursor(false)
            try await app.hover(over: CGPoint(x: frame.minX + 464, y: frame.minY + 45))
            try await app.waitForHandCursor(true)
            try await app.hover(over: CGPoint(x: frame.minX + 200, y: frame.minY + 200))
            try await app.waitForHandCursor(false)
            step("hand over a label")

            // The box grows and shrinks with its lines: the same frame never shows two sizes.
            try await app.click(at: CGPoint(x: frame.minX + 80, y: frame.minY + 55))
            try await app.waitToSee("add")
            try await Task.sleep(for: .milliseconds(300))
            let boxWidth = 356.0
            func expectOneWay(_ edges: [[Double]], growing: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
                // The top never moves, and the bottom only moves one way.
                let tops = edges.map { $0[0] }
                let bottoms = edges.map { $0[1] }
                #expect(tops.max()! - tops.min()! <= 1, "tops \(tops)", sourceLocation: sourceLocation)
                #expect(bottoms == (growing ? bottoms.sorted() : bottoms.sorted(by: >)), "bottoms \(bottoms)", sourceLocation: sourceLocation)
                #expect(Set(bottoms).count >= 3, "bottoms \(bottoms)", sourceLocation: sourceLocation)
            }
            let growing = try await app.edges(ofWindowWidth: boxWidth, seconds: 2) {
                for _ in 0..<5 {
                    try await app.key(.enter, shift: true)
                    try await Task.sleep(for: .milliseconds(150))
                }
            }
            expectOneWay(growing, growing: true)
            let shrinking = try await app.edges(ofWindowWidth: boxWidth, seconds: 2) {
                for _ in 0..<5 {
                    try await app.key(.delete)
                    try await Task.sleep(for: .milliseconds(150))
                }
            }
            expectOneWay(shrinking, growing: false)
            step("box steps")
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

    /// Draws one shape: its comment box opens at the mouse release.
    @Test func anArrowIsEditedAndLeavesALabelThatFollowsItsElement() async throws {
        let page = try TestPage()
        defer { page.stop() }
        try await withApp { app in
            let agent = try await MCPAgent(port: app.port, name: "Claude Code")
            let started = try await agent.call("start_annotation", ["url": page.url + "whole.html", "wait_seconds": 0])
            let session = try #require(started.text.components(separatedBy: "session_id: ").last?.prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" }))
            try await app.waitToSee("Paused")
            let row = try await app.waitToSee("Row 8", timeout: 20)
            try await annotate(app)
            try await app.press("Draw on the screen")
            try await app.waitToSee("Done, esc")
            try await app.waitToSee("Drawing canvas", timeout: 15)
            step("canvas ready")

            // A click starts an arrow, and Esc cancels it without leaving draw mode.
            let start = CGPoint(x: row.frame.minX + 120, y: row.frame.minY + 180)
            let clicked = CGPoint(x: start.x + 60, y: start.y + 150)
            try await app.click(at: clicked)
            try await Task.sleep(for: .milliseconds(300))
            try await app.key(.escape)
            try await Task.sleep(for: .milliseconds(300))
            try await app.waitToSee("Done, esc")
            #expect(try await !app.seen().contains { $0.name == "add" })

            // A second click finishes one, and its comment opens. Undo takes it back.
            try await app.click(at: clicked)
            try await Task.sleep(for: .milliseconds(300))
            #expect(try await !app.seen().contains { $0.name == "add" })
            try await app.hover(over: CGPoint(x: clicked.x + 80, y: clicked.y + 30))
            try await app.click(at: CGPoint(x: clicked.x + 120, y: clicked.y + 40))
            try await app.waitToSee("add", timeout: 15)
            try await app.type("Two clicks")
            try await app.waitToSee("Two clicks", timeout: 3)
            try await app.key(.enter)
            try await app.waitNotToSee("add")
            try await app.press("Undo")
            try await app.waitNotToSee("Two clicks")
            step("arrow by clicks")

            // The tip lands near the row's end, snaps to it, and the row is the arrow's element.
            let elementEnd = CGPoint(x: row.frame.minX + 300, y: row.frame.midY)
            let tip = CGPoint(x: elementEnd.x - 5, y: elementEnd.y)
            try await app.hover(over: tip)
            try await Task.sleep(for: .milliseconds(400))
            try await app.slowDrag(from: start, to: tip)
            try await app.waitToSee("add", timeout: 15)
            step("arrow drawn")

            // Its other end can be dragged with the comment open, and the box keeps the keyboard.
            try await Task.sleep(for: .milliseconds(500))
            let moved = CGPoint(x: start.x + 40, y: start.y + 60)
            try await app.slowDrag(from: start, to: moved)
            try await Task.sleep(for: .milliseconds(500))
            try await app.type("This row")
            try await app.waitToSee("This row", timeout: 3)
            step("arrow reshaped")

            // A drag elsewhere draws nothing: it is a click away, and words are not lost.
            try await app.drag(from: CGPoint(x: row.frame.minX + 20, y: row.frame.minY + 400), to: CGPoint(x: row.frame.minX + 70, y: row.frame.minY + 440))
            try await app.waitToSee("Discard comment?")
            try await app.key(.escape)
            try await app.waitToSee("This row", timeout: 3)
            try await app.key(.enter)
            try await app.waitNotToSee("add")
            step("comment saved")

            // A label opens its note in the preview, also in draw mode, which Esc then keeps.
            let marker = CGPoint(x: row.frame.minX + 300, y: row.frame.minY)
            try await app.hover(over: marker)
            try await app.waitForHandCursor(true)
            try await app.click(at: marker)
            try await app.waitToSee("1 of 1")
            try await app.key(.escape)
            try await app.waitNotToSee("1 of 1")
            try await app.waitToSee("Done, esc")
            try await app.key(.escape)
            try await app.waitNotToSee("Done, esc")
            try await app.waitToSeeText(containing: "1 note")
            try await app.hover(over: CGPoint(x: marker.x, y: marker.y + 100))
            try await app.waitForHandCursor(false)
            try await app.hover(over: marker)
            try await app.waitForHandCursor(true)
            try await app.click(at: marker)
            try await app.waitToSee("1 of 1")
            try await app.key(.escape)
            try await app.waitNotToSee("1 of 1")
            // Next to a label, its element is not highlighted.
            try await app.hover(over: CGPoint(x: marker.x - 15, y: marker.y + 5))
            try await Task.sleep(for: .milliseconds(300))
            try await app.waitForBlue(in: CGRect(x: row.frame.minX + 150, y: row.frame.minY, width: 100, height: 20), atMost: 0)
            let hud = try await app.waitToSee("Annotating")
            try await app.hover(over: CGPoint(x: hud.frame.midX, y: hud.frame.midY))
            step("label opens the preview")

            // Only the label stayed, and a real scroll moves the page and the label.
            func around(_ point: CGPoint) -> CGRect {
                CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
            }
            let middle = CGPoint(x: (moved.x + tip.x) / 2, y: (moved.y + tip.y) / 2)
            try await app.waitForBlue(in: around(marker), atLeast: 20)
            try await app.waitForBlue(in: around(middle), atMost: 0)
            try await app.scroll(at: CGPoint(x: row.frame.midX, y: row.frame.midY + 100), by: -1)
            try await app.hover(over: CGPoint(x: hud.frame.midX, y: hud.frame.midY))
            try await Task.sleep(for: .seconds(1))
            let scrolled = try await app.waitToSee("Row 8")
            #expect(scrolled.frame.minY < row.frame.minY - 20, "The page did not scroll")
            try await app.waitForBlue(in: around(CGPoint(x: marker.x, y: scrolled.frame.minY)), atLeast: 20)
            try await app.waitForBlue(in: around(marker), atMost: 0)
            step("page scrolled")

            try await app.key(.enter, command: true)
            let text = try await agent.call("wait_for_annotation", ["session_id": String(session), "wait_seconds": 15]).text
            #expect(text.components(separatedBy: "\"type\":\"arrow\"").count == 2, "\(text)")
            #expect(text.contains("\"element\""), "\(text)")
            let origin = try #require(firstNumber(after: "\"origin\":[", in: text))
            let to = try #require(firstNumber(after: "\"to\":[", in: text))
            let from = try #require(firstNumber(after: "\"from\":[", in: text))
            #expect(abs(origin + to - elementEnd.x) <= 1, "The tip did not snap: \(text)")
            // It may snap to an element near where it landed.
            #expect(abs(origin + from - start.x) >= 20, "The end did not move: \(text)")
        }
    }

    private func firstNumber(after key: String, in text: String) -> Double? {
        guard let rest = text.components(separatedBy: key).dropFirst().first else {
            return nil
        }
        return Double(String(rest.prefix { $0.isNumber || $0 == "." || $0 == "-" }))
    }

    /// This machine's own ssh is the node: the setup of the VM has `vmself` in its ssh config, and
    /// a `~/.claude.json` file and a `~/.codex` folder.
    @Test func aNodeIsInstalledFromSettingsLinkedWithAToken() async throws {
        try await withApp { app in
            try await app.menu("Settings")
            try await app.waitToSee("Apps on this Mac")
            try await Task.sleep(for: .seconds(1))
            let apps = try await app.waitToSee("Apps on this Mac")
            try await app.scroll(at: CGPoint(x: apps.frame.midX, y: apps.frame.maxY + 200), by: -10)
            try await app.waitToSee("vmself", timeout: 15)
            try await app.press("vmself")
            try await app.waitToSee("Install vmself", timeout: 20)
            try await app.press("Install vmself")
            try await app.waitToSeeText(containing: "Installed and linked", timeout: 30)
            step("installed")

            let home = FileManager.default.homeDirectoryForCurrentUser
            let config = try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
            let token = try #require(config.components(separatedBy: "Bearer ").last?.prefix { $0 != "\"" })
            #expect(try String(contentsOf: home.appendingPathComponent(".claude.json"), encoding: .utf8).contains("Bearer \(token)"))
            #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/skills/tilde/SKILL.md").path))

            // Through the tunnel, a request needs the token.
            func status(_ header: String?) async throws -> Int {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:7319/mcp")!)
                request.httpMethod = "POST"
                request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
                request.setValue(header, forHTTPHeaderField: "Authorization")
                let (_, response) = try await URLSession.shared.data(for: request)
                return (response as? HTTPURLResponse)?.statusCode ?? 0
            }
            #expect(try await status(nil) == 401)
            #expect(try await status("Bearer wrong") == 401)
            #expect(try await status("Bearer \(token)") == 200)
            step("token")

            try await app.press("Remove vmself")
            try await app.waitToSee("Install vmself", timeout: 30)
            #expect(try !String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8).contains("Bearer"))
            #expect(try !String(contentsOf: home.appendingPathComponent(".claude.json"), encoding: .utf8).contains("Bearer"))
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/skills/tilde").path))
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
            try await app.waitToSee("Copied", timeout: 5)
            try await app.waitToSee("Could not send the images to no-such-host.invalid", timeout: 20)
            let local = try #require(NSPasteboard.general.string(forType: .string))
            #expect(local.contains("Stays local"), "\(local)")
            step("unreachable machine")
        }
    }

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
        try await Task.sleep(for: .seconds(3))
        first.kill()
        let saved = try FileManager.default.subpathsOfDirectory(atPath: first.sessions.path)
        #expect(saved.contains { $0.hasSuffix("session.json") })
        #expect(saved.contains { $0.hasSuffix(".png") })
        let second = try await TildeApp.relaunched(after: first)
        defer { second.quit() }
        try await second.waitToSee("Restore unfinished session?")
        try await second.press("Restore")
        try await second.waitToSeeText(containing: "1 note", timeout: 15)
        try await second.waitForBlue(in: beside, atMost: 0)
        try await second.waitForBlue(in: left(of: start, offset: 200), atMost: 0)
        try await second.press("Show annotations")
        try await second.waitToSee("On the window")
        step("restored")
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
            try await app.press("Choose a screen or window to annotate")
            try await app.waitToSee("Choose a window")
            try await app.press("Use window picker")
            try await app.waitToSee("Screens")
            try await app.key(.escape)
            try await app.waitNotToSee("Screens")
            try await app.waitNotToSee("Use window picker")
            try await app.waitToSee("Annotating")
        }
    }

    // MARK: - Recording

    /// The window button picks on screen, with a "Use window picker" button that opens the picker
    /// and a cross that closes it again; a window clicked on screen, a screen tile or the tile
    /// of an app with one window each choose and close everything.
    @Test func theSourcePickerChoosesAWindowToRecord() async throws {
        let window = try ChangingWindow()
        defer { window.close() }
        try await withApp { app in
            let agent = try await MCPAgent(port: app.port, name: "Codex")
            let reply = try await agent.call("start_annotation", ["wait_seconds": 0])
            let session = try #require(reply.text.components(separatedBy: "session_id: ").last?.prefix(while: { $0 != "." && $0 != " " && $0 != "\n" }))
            try await app.waitToSee("Annotating")

            try await app.press("Record a video")
            try await app.waitToSeeText(containing: "Ready to record")
            try await app.press("Choose a screen or window to record")
            try await app.waitToSee("Choose a window")
            try await app.press("Use window picker")
            try await app.waitToSee("Screens")
            try await app.press("Back to clicking on screen")
            try await app.waitNotToSee("Screens")

            // A click on the window itself.
            let frame = ChangingWindow.frame
            try await app.click(at: CGPoint(x: frame.minX + 20, y: frame.maxY - 20))
            try await app.waitNotToSee("Use window picker")
            try await app.waitToSee("Start recording tilde-ux-fixture")

            // Limited to the window, the button chooses again; the screen's tile lifts the limit.
            try await app.press("Only tilde-ux-fixture. Choose another window or the whole screen")
            try await app.press("Use window picker")
            try await app.waitToSee("Screens")
            try await app.press(try #require(NSScreen.main?.localizedName))
            try await app.waitNotToSee("Screens")
            try await app.waitToSee("Start recording the screen")

            // Clicks in the picker choose in it, not on screen.
            try await app.press("Choose a screen or window to record")
            try await app.press("Use window picker")
            try await app.press("Windows")
            // The fixture has one window, so its app tile chooses it.
            try await app.press("tilde-ux-fixture")
            try await app.waitNotToSee("Screens")
            // The subtitle does not name the source; the window button shows it.
            try await app.waitToSeeText(containing: "for Codex")

            try await app.press("Start recording tilde-ux-fixture")
            try await app.waitToSeeText(containing: "Recording 0:0")
            try await Task.sleep(for: .seconds(1))
            try await app.key(.enter, command: true)

            let report = try await agent.call("wait_for_annotation", ["session_id": String(session), "wait_seconds": 15])
            #expect(report.text.contains("Recorded: tilde-ux-fixture window"), "\(report.text)")
        }
    }

    @Test func twoRecordingsOfTheScreenGoToTheAgentAsVideos() async throws {
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
            try await app.press("Show annotations")
            try await app.press("No comment")
            try await app.waitToSee("1 of 1")
            try await app.waitToSee("play/pause")
            try await app.waitToSee("timeline")

            // Its edge resizes it, and the next preview opens at that size.
            func height() async throws -> CGFloat {
                let close = try await app.waitToSee("Close")
                let delete = try await app.waitToSee("Delete")
                return delete.frame.maxY - close.frame.minY
            }
            let before = try await height()
            let delete = try await app.waitToSee("Delete")
            // The bottom edge, away from the rounded corner.
            let edge = CGPoint(x: delete.frame.minX - 100, y: delete.frame.maxY + 16)
            try await app.drag(from: edge, to: CGPoint(x: edge.x, y: edge.y + 80))
            try await Task.sleep(for: .milliseconds(300))
            let edgeResized = try await height()
            #expect(edgeResized > before + 60, "\(before) pt, then \(edgeResized) pt")

            // So does the grip in its corner.
            let grip = CGPoint(x: delete.frame.maxX + 10, y: try await app.waitToSee("Delete").frame.maxY + 10)
            try await app.drag(from: grip, to: CGPoint(x: grip.x + 60, y: grip.y + 40))
            try await Task.sleep(for: .milliseconds(300))
            let resized = try await height()
            #expect(resized > edgeResized + 25, "\(edgeResized) pt, then \(resized) pt")
            try await app.key(.escape)
            try await app.waitNotToSee("1 of 1")
            try await app.press("No comment")
            try await app.waitToSee("1 of 1")
            let reopened = try await height()
            #expect(abs(reopened - resized) < 2, "\(resized) pt, then \(reopened) pt")

            // The strip above the pictures moves it like the HUD's pill, from its top margin
            // too. A place away from home stays, with the size, also the next time.
            let home = try await app.waitToSee("1 of 1").frame
            let margin = CGPoint(x: home.minX - 80, y: home.midY - 22)
            try await app.slowDrag(from: margin, to: CGPoint(x: margin.x - 200, y: margin.y + 60))
            try await Task.sleep(for: .milliseconds(300))
            let moved = try await app.waitToSee("1 of 1").frame
            #expect(abs(moved.minX - (home.minX - 200)) < 3 && abs(moved.minY - (home.minY + 60)) < 3, "\(home), then \(moved)")
            try await app.press("Close")
            try await app.waitNotToSee("1 of 1")
            try await app.press("No comment")
            let again = try await app.waitToSee("1 of 1").frame
            #expect(abs(again.minX - moved.minX) < 2 && abs(again.minY - moved.minY) < 2, "\(moved), then \(again)")
            #expect(abs(try await height() - resized) < 2)

            // Resized, it still snaps to the centre, 30 pt short of it, and keeps its size; it
            // opens there next time.
            let header = CGPoint(x: again.minX - 80, y: again.midY)
            try await app.drag(from: header, to: CGPoint(x: header.x + home.midX - again.midX - 20, y: header.y + home.minY - again.minY + 20))
            try await Task.sleep(for: .milliseconds(400))
            let centred = try await app.waitToSee("1 of 1").frame
            #expect(abs(centred.minX - home.minX) < 2 && abs(centred.minY - home.minY) < 2, "\(home), then \(centred)")
            #expect(abs(try await height() - resized) < 2)
            try await app.key(.escape)
            try await app.waitNotToSee("1 of 1")
            try await app.press("No comment")
            let reopenedAtHome = try await app.waitToSee("1 of 1").frame
            #expect(abs(reopenedAtHome.minX - home.minX) < 2 && abs(reopenedAtHome.minY - home.minY) < 2)
            #expect(abs(try await height() - resized) < 2)
            try await app.key(.escape)
            try await app.waitNotToSee("1 of 1")

            // Esc goes back to annotating.
            try await app.key(.escape)
            try await app.waitToSee("Annotating")
            try await app.press("Record a video")
            try await app.waitToSeeText(containing: "Ready to record")

            // Send while a clip is in progress keeps that clip too. Before that, Esc asks to
            // discard the clip, and Esc again keeps it.
            try await app.press("Start recording the screen")
            try await app.waitToSeeText(containing: "Recording 0:0")
            try await app.key(.escape)
            try await app.waitToSee("Discard the recording?")
            try await app.key(.escape)
            try await app.waitNotToSee("Discard the recording?")
            try await Task.sleep(for: .seconds(1))
            try await app.key(.enter, command: true)

            let report = try await agent.call("wait_for_annotation", ["session_id": String(session), "wait_seconds": 15])
            #expect(report.text.contains("Screen recording"))
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
        }
    }
}
