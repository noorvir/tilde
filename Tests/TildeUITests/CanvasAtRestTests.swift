@testable import TildeUI
import AppKit
import Testing

/// The drawing canvas's page while nothing happens on it. A frame that the page asks for wakes
/// its process and Tilde, at the screen's rate: a page that asks for one after another uses
/// the processor for as long as Draw or Wireframe is on.
@MainActor
@Suite(.tags(.webKit), .webKitRuns)
struct CanvasAtRestTests {
    /// With a component drawn and a tool ready, the page asks for no frame once it has drawn
    /// what it shows. The page's timers are not throttled, so a page that asks without end
    /// asks many times in the 3 s.
    @Test func thePageAtRestAsksForNoFrames() async throws {
        let page = CanvasPage(countsFrames: true)
        try await page.load(takesSlot: false)
        try await page.draw("setWireframe({tool: 'card', icons: {}})")
        try await page.drag(from: CGPoint(x: 200, y: 150), to: CGPoint(x: 440, y: 270))
        #expect(try await page.shapes().count == 1)

        try await expectNoFrames(of: page, restingWithin: .seconds(1))

        // While the components' window moves, the page has frames, so that they do not lag
        // it; they stop soon after its last move.
        try await page.draw("setWireframeWindow([100, 100, 600, 400])")
        let resting = try await page.frameRequests()
        try await page.draw("setWireframeWindow([140, 100, 600, 400])")
        #expect(try await page.frameRequests() > resting)
        try await expectNoFrames(of: page, restingWithin: .seconds(3))
    }

    /// Expects no frame for 3 s from when the page stops asking: it has asked for none for
    /// 250 ms, or `limit` has passed, and then the frames that it still asks for fail.
    private func expectNoFrames(of page: CanvasPage, restingWithin limit: Duration, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let clock = ContinuousClock()
        let end = clock.now + limit
        var before = try await page.frameRequests()
        var unchangedSince = clock.now
        while clock.now < end, clock.now - unchangedSince < .milliseconds(250) {
            try await Task.sleep(for: .milliseconds(50))
            let count = try await page.frameRequests()
            if count != before {
                before = count
                unchangedSince = clock.now
            }
        }

        try await Task.sleep(for: .seconds(3))
        let after = try await page.frameRequests()
        #expect(after == before, "The page asked for \(after - before) frames in 3 s at rest", sourceLocation: sourceLocation)
    }
}
