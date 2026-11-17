import AppKit
import AVFoundation
import Foundation
import Testing

extension UXSpecs {
    // MARK: - Recording over other apps

    /// Over an app in full screen, with the keyboard in its text field, double Ctrl shows the HUD
    /// on that Space, in front of the app, and the HUD takes the keys: R starts recording mode,
    /// whose choosing shows there too. The app stays in full screen and gets none of the keys.
    @Test func theHUDShowsOverAnAppInFullScreenAndTakesItsKeys() async throws {
        let window = try ChangingWindow()
        defer { window.close() }
        try await withApp { app in
            try await goFullScreen(window, page: "fullscreen typing", app: app)

            try await app.doubleTap("control")
            try await waitToShow(app, "Annotating")
            try await app.key(.r)
            try await waitToShow(app, "Choose a window")
            #expect(window.keys == [])
            #expect(window.fullScreen?.isOn == true)
            #expect(window.fullScreen?.exits == 0)
        }
    }

    /// A clip of a window in full screen records until the user stops it: the HUD stays on that
    /// Space, counting, the app keeps its window, and the video is as long as the clip.
    @Test func aWindowInFullScreenRecordsUntilStop() async throws {
        let window = try ChangingWindow()
        defer { window.close() }
        try await withApp { app in
            try await goFullScreen(window, page: "fullscreen", app: app)

            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")
            try await app.key(.r)
            try await app.waitToSee("Choose a window")
            let screen = try #require(NSScreen.screens.first?.frame)
            try await app.click(at: CGPoint(x: screen.midX, y: screen.midY))
            try await app.waitToSeeText(containing: "tilde-ux-fixture")
            try await app.press("Record")
            let started = Date()
            try await app.waitToSeeText(containing: "Recording 0:0")
            try await app.waitToSeeText(containing: "Recording 0:03", timeout: 8)
            try await waitToShow(app, "Stop recording")
            try await app.press("Stop recording")
            let length = Date().timeIntervalSince(started)
            try await app.waitToSeeText(containing: "1 note")

            let seconds = try await savedClip(in: app).load(.duration).seconds
            step("full-screen clip: \(seconds) s of \(length) s")
            #expect(seconds >= 3 && seconds <= length)
            // The capture leaves the recorded app as it is: macOS put no window of its window
            // sharing in it, on which AppKit asserts in some apps, and they crash.
            #expect(window.sharingWindows == [])
            #expect(window.fullScreen?.isOn == true)
            #expect(window.fullScreen?.exits == 0)
        }
    }

    /// While a window records, the user works in it as usual: a click puts the keyboard in its
    /// text field, and what they type arrives there. The clip keeps to the window when it moves.
    @Test func typingReachesTheRecordedWindow() async throws {
        let window = try ChangingWindow()
        defer { window.close() }
        try await withApp { app in
            try window.show("typing")
            for _ in 0..<60 where try await app.focus().app != window.pid {
                try await Task.sleep(for: .milliseconds(100))
            }

            try await app.doubleTap("control")
            try await app.waitToSee("Annotating")
            try await app.key(.r)
            try await app.waitToSee("Choose a window")
            let frame = ChangingWindow.frame
            try await app.click(at: CGPoint(x: frame.minX + 20, y: frame.maxY - 20))
            try await app.waitToSeeText(containing: "tilde-ux-fixture")
            try await app.press("Record")
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
            try await app.waitToSeeText(containing: "Recording 0:0")

            try window.show("moved typing")
            for _ in 0..<40 where (window.bounds?.minX ?? 0) < frame.minX + 200 {
                try await Task.sleep(for: .milliseconds(50))
            }
            try await Task.sleep(for: .milliseconds(500))
            try await app.press("Stop recording")
            try await app.waitToSeeText(containing: "1 note")
            // The clip's last frame is the window: its white page, not the dark of what the clip
            // leaves out where the window was.
            let clip = try await savedClip(in: app)
            let generator = AVAssetImageGenerator(asset: clip)
            generator.requestedTimeToleranceBefore = .positiveInfinity
            let duration = try await clip.load(.duration)
            let (image, _) = try await generator.image(at: CMTime(seconds: duration.seconds - 0.05, preferredTimescale: 600))
            let picture = try Picture(try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])), width: Double(image.width))
            let whole = CGRect(origin: .zero, size: picture.size)
            let white = Double(picture.count(in: whole, every: 8) { min($0.red, $0.green, $0.blue) > 0.9 }) / Double(picture.count(in: whole, every: 8) { _ in true })
            step("moved window's clip: \(Int(white * 100))% white")
            #expect(white > 0.7)
            #expect(window.sharingWindows == [])
        }
    }

    /// Puts the window in full screen, in a Space of its own, and waits until that Space shows.
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

    /// Waits until the element with this name is on screen and drawn there, in front of the
    /// window in full screen: its frame shows more than that window's white.
    private func waitToShow(_ app: TildeApp, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let element = try await app.waitToSee(name, sourceLocation: sourceLocation)
        let end = Date().addingTimeInterval(5)
        var drawn = 0
        while Date() < end {
            let area = try await app.screen(in: element.frame)
            drawn = area.count(in: element.frame) { min($0.red, $0.green, $0.blue) < 0.8 }
            if drawn >= 20 {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        await app.saveFailure(named: "not-drawn-\(sourceLocation.line)")
        Issue.record("\"\(name)\" is in the accessibility tree but not drawn on screen (\(drawn) places)", sourceLocation: sourceLocation)
    }

    /// The session's one clip, once it is saved.
    private func savedClip(in app: TildeApp) async throws -> AVURLAsset {
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
