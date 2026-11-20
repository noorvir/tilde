import AppKit
import AVFoundation
import Foundation
import Testing

extension UXSpecs {
    // MARK: - Recording over other apps

    /// On a second display, above and to the right of the main one as a user's monitor can be,
    /// over an app in full screen with the keyboard in its text field: double Ctrl shows the HUD
    /// on that display's Space, where the pointer is, in front of the app, and the HUD takes the
    /// keys: R starts recording mode, whose choosing shows there too. While the app's window
    /// records, the user works in it as usual: a click puts the keyboard in its text field, and
    /// what they type arrives there. The HUD stays on that Space, the app keeps its window and
    /// its full screen, and the clip lasts until Stop.
    @Test func theHUDShowsOverAFullScreenAppOnASecondDisplayWhoseWindowRecordsWhileTheUserTypesInIt() async throws {
        let display = try SecondDisplay(CGRect(x: 1728, y: -271, width: 1920, height: 1080))
        defer { display.remove() }
        let window = try ChangingWindow()
        defer { window.close() }
        try await withApp { app in
            try await goFullScreen(window, page: "second fullscreen typing", app: app)
            try await app.hover(over: CGPoint(x: display.frame.midX, y: display.frame.midY))

            try await app.doubleTap("control")
            let hud = try await waitToShow(app, "Annotating")
            #expect(display.frame.contains(hud.frame), "The HUD is at \(hud.frame), not on the display at \(display.frame)")
            try await app.key(.r)
            try await waitToShow(app, "Choose a window")
            try await app.click(at: CGPoint(x: display.frame.midX, y: display.frame.midY))
            try await app.waitToSeeText(containing: "tilde-ux-fixture")
            #expect(window.keys == [])
            step("full-screen window chosen")

            try await app.press("Record")
            let started = Date()
            try await app.waitToSeeText(containing: "Recording 0:0")
            let field = try #require(window.field)
            try await app.click(at: field)
            for _ in 0..<40 where try await app.focus().app != window.pid {
                try await Task.sleep(for: .milliseconds(50))
            }
            try await app.type("hello")
            for _ in 0..<40 where try await app.focus().value != "hello" {
                try await Task.sleep(for: .milliseconds(50))
            }
            let focus = try await app.focus()
            #expect(focus.app == window.pid)
            #expect(focus.value == "hello")
            step("typed while recording")

            try await waitToShow(app, "Stop recording")
            try await app.press("Stop recording")
            let length = Date().timeIntervalSince(started)
            try await app.waitToSeeText(containing: "1 note")
            let seconds = try await savedClip(in: app).load(.duration).seconds
            step("full-screen clip: \(seconds) s of \(length) s")
            #expect(seconds >= 1 && seconds <= length)
            // The capture leaves the recorded app as it is: macOS put no window of its window
            // sharing in it, on which AppKit asserts in some apps, and they crash.
            #expect(window.sharingWindows == [])
            #expect(window.fullScreen?.isOn == true)
            #expect(window.fullScreen?.exits == 0)
        }
    }

    /// An app in full screen is in the window picker when its Space is not the one that shows,
    /// as when the user opens the picker from the desktop: its window is listed, and its clip
    /// shows the window once the user goes back to its Space.
    @Test func theWindowPickerListsAnAppInFullScreenOnASpaceThatDoesNotShowAndItsClipRecordsIt() async throws {
        let window = try ChangingWindow()
        defer { window.close() }
        try await withApp { app in
            try await goFullScreen(window, page: "fullscreen", app: app)
            // The user goes to the desktop: Finder opens a window there, which is closed again.
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()))
            for _ in 0..<60 where isOnScreen(window.pid) {
                try await Task.sleep(for: .milliseconds(100))
            }
            try #require(!isOnScreen(window.pid), "The full-screen Space still shows")
            try await app.key(.w, command: true)
            step("desktop shows")

            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")
            try await app.key(.r)
            try await app.waitToSee("Choose a window")
            try await app.press("Use window picker")
            try await app.press("Windows")
            try await app.waitToSee("tilde-ux-fixture")
            try await app.press("tilde-ux-fixture")
            try await app.waitToSeeText(containing: "Ready to record")
            try await app.waitToSeeText(containing: "tilde-ux-fixture")
            step("full-screen window chosen")

            try await app.press("Record")
            try await app.waitToSeeText(containing: "Recording 0:0")
            try window.show("fullscreen front")
            for _ in 0..<60 where !isOnScreen(window.pid) {
                try await Task.sleep(for: .milliseconds(100))
            }
            try #require(isOnScreen(window.pid), "The full-screen Space does not show")
            // The clip records its Space for a moment.
            try await Task.sleep(for: .seconds(1))
            try await app.press("Stop recording")
            try await app.waitToSeeText(containing: "1 note")

            // The clip's last frame is the window: its white page.
            let clip = try await savedClip(in: app)
            let generator = AVAssetImageGenerator(asset: clip)
            generator.requestedTimeToleranceBefore = .positiveInfinity
            let duration = try await clip.load(.duration)
            let (image, _) = try await generator.image(at: CMTime(seconds: duration.seconds - 0.05, preferredTimescale: 600))
            let picture = try Picture(try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])), width: Double(image.width))
            let whole = CGRect(origin: .zero, size: picture.size)
            let white = Double(picture.count(in: whole, every: 8) { min($0.red, $0.green, $0.blue) > 0.9 }) / Double(picture.count(in: whole, every: 8) { _ in true })
            step("full-screen clip: \(duration.seconds) s, \(Int(white * 100))% white")
            #expect(white > 0.7)
            #expect(window.sharingWindows == [])
            #expect(window.fullScreen?.exits == 0)
        }
    }

    /// Whether a normal window of the app is on screen: in a Space that shows.
    private func isOnScreen(_ pid: Int) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { $0[kCGWindowOwnerPID as String] as? Int == pid && $0[kCGWindowLayer as String] as? Int == 0 }
    }

    /// Puts the window in full screen, in a Space of its own on its display, and waits until
    /// that Space shows.
    private func goFullScreen(_ window: ChangingWindow, page: String, app: TildeApp) async throws {
        try window.show(page)
        for _ in 0..<60 where window.fullScreen?.isOn != true {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(window.fullScreen?.isOn == true)
        // The Space slides in after the window is in full screen; the window has the keyboard once it is in.
        for _ in 0..<40 where try await app.focus().app != window.pid {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Waits until the element with this name is on screen and drawn there, on whichever display,
    /// in front of the window in full screen: its frame shows more than that window's white.
    @discardableResult
    private func waitToShow(_ app: TildeApp, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) async throws -> Seen {
        let element = try await app.waitToSee(name, sourceLocation: sourceLocation)
        let end = Date().addingTimeInterval(5)
        var drawn = 0
        while Date() < end {
            let area = try await app.screen(in: element.frame)
            drawn = area.count(in: element.frame) { min($0.red, $0.green, $0.blue) < 0.8 }
            if drawn >= 20 {
                return element
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        await app.saveFailure(named: "not-drawn-\(sourceLocation.line)")
        Issue.record("\"\(name)\" is in the accessibility tree but not drawn on screen (\(drawn) places)", sourceLocation: sourceLocation)
        return element
    }

    /// The session's one clip, once it is saved.
    func savedClip(in app: TildeApp) async throws -> AVURLAsset {
        let end = Date().addingTimeInterval(10)
        while Date() < end {
            let files = FileManager.default.enumerator(at: app.sessions, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
            if let file = files.first(where: { $0.pathExtension == "mp4" }),
               let seconds = try? await AVURLAsset(url: file).load(.duration).seconds, seconds > 0
            {
                return AVURLAsset(url: file)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw UXFailure(description: "No clip was saved")
    }
}
