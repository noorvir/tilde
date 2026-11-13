@testable import TildeUI
import AppKit
import Testing

/// The drawing canvas's page while nothing happens on it. A frame that the page asks for wakes
/// its process and Tilde, at the screen's rate: a page that asks for one after another uses
/// the processor for as long as Draw or Wireframe is on.
@MainActor
struct CanvasAtRestTests {
    /// With a component drawn and a tool ready, the page asks for no frame once it has drawn
    /// what it shows. A page in no window gets its timers about once a second, so a page that
    /// asks without end asks a few times in the 3 s.
    @Test func thePageAtRestAsksForNoFrames() async throws {
        let page = CanvasPage(countsFrames: true)
        try await page.load()
        try await page.draw("setWireframe({tool: 'card', icons: {}})")
        try await page.drag(from: CGPoint(x: 200, y: 150), to: CGPoint(x: 440, y: 270))
        #expect(try await page.shapes().count == 1)

        try await Task.sleep(for: .seconds(1))
        let before = try await page.frameRequests()
        try await Task.sleep(for: .seconds(3))
        let after = try await page.frameRequests()
        #expect(after == before, "The page asked for \(after - before) frames in 3 s at rest")
    }
}
