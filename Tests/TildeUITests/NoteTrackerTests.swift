@testable import TildeUI
import AppKit
import Testing

/// When the notes' content is checked, and how a lost element is searched for.
struct NoteTrackerTests {
    @Test func aRoundRunsAfterAChangeAndWhileANoteIsAboutToChange() {
        #expect(NoteTracker.runsRound(isChanged: true, isSettling: false, sinceLastRound: 0.5, isPaused: true, isAnyNoteShown: false))
        #expect(NoteTracker.runsRound(isChanged: false, isSettling: true, sinceLastRound: 0.5, isPaused: true, isAnyNoteShown: false))
    }

    @Test func withNoChangeARoundRunsOnceASecond() {
        #expect(!NoteTracker.runsRound(isChanged: false, isSettling: false, sinceLastRound: 0.5, isPaused: false, isAnyNoteShown: true))
        #expect(NoteTracker.runsRound(isChanged: false, isSettling: false, sinceLastRound: 1, isPaused: false, isAnyNoteShown: true))
        #expect(NoteTracker.runsRound(isChanged: false, isSettling: false, sinceLastRound: 1, isPaused: true, isAnyNoteShown: true))
    }

    @Test func whilePausedWithNoNoteOnScreenOnlyAChangeRunsARound() {
        #expect(!NoteTracker.runsRound(isChanged: false, isSettling: false, sinceLastRound: 60, isPaused: true, isAnyNoteShown: false))
    }

    @Test func aLostElementIsSearchedForLessAndLessOften() {
        var delays: [TimeInterval] = []
        var last: TimeInterval?
        for _ in 0..<7 {
            let delay = NoteTracker.searchDelay(after: last)
            delays.append(delay)
            last = delay
        }
        #expect(delays == [0.2, 0.4, 0.8, 1.6, 3.2, 5, 5])
    }

    /// A screenshot of several notes' areas gives each note the fingerprint that a screenshot of
    /// its area alone gives, so notes made one by one are checked together.
    @Test func aFingerprintCutFromAScreenshotOfSeveralAreasIsTheSameAsAlone() throws {
        let window = try #require(Self.stripes(width: 1200, height: 800))
        let scale: CGFloat = 2
        let note = CGRect(x: 100, y: 60, width: 150, height: 40)
        let other = CGRect(x: 400, y: 250, width: 90, height: 90)
        let union = note.union(other)
        func screenshot(of rect: CGRect) -> CGImage? {
            window.cropping(to: CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale))
        }

        let noteShot = try #require(screenshot(of: note))
        let unionShot = try #require(screenshot(of: union))
        let alone = try #require(NoteFingerprint.cut(rect: note, from: noteShot, of: note, scale: scale))
        let together = try #require(NoteFingerprint.cut(rect: note, from: unionShot, of: union, scale: scale))
        #expect(alone == together)
        #expect(alone.levels.count == 300 * 80)

        // A large area is scaled down to 400 pixels on its longer side.
        let large = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let largeShot = try #require(screenshot(of: large))
        let scaled = try #require(NoteFingerprint.cut(rect: large, from: largeShot, of: large, scale: scale))
        #expect(scaled.levels.count == 400 * 200)
    }

    /// A picture with a pattern that differs everywhere, like a page of text.
    private static func stripes(width: Int, height: Int) -> CGImage? {
        let context = CGContext(
            data: nil, width: width * 2, height: height * 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
        guard let context else {
            return nil
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width * 2, height: height * 2))
        context.setFillColor(gray: 0, alpha: 1)
        for row in stride(from: 0, to: height * 2, by: 14) {
            for column in stride(from: (row * 7) % 23, to: width * 2, by: 31) {
                context.fill(CGRect(x: column, y: row, width: 9 + (row + column) % 11, height: 6))
            }
        }
        return context.makeImage()
    }
}
