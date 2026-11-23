@testable import TildeUI
import AppKit
import Testing

/// Draw mode on the drawing canvas's page: the arrow that a click starts, a shape that is
/// edited while its comment is open, and snapping to the element under the pointer. The page
/// is the real one, in no window; each test has its own.
@MainActor
@Suite(.tags(.webKit), .webKitRuns)
struct DrawCanvasTests {
    let page: CanvasPage

    init() async throws {
        page = CanvasPage()
        try await page.load()
    }

    /// Each new group of shapes that Tilde hears of; the tests end each group before the next.
    private func groupMessages() -> Int {
        page.messages.filter { $0 == "group" }.count
    }

    private func rect(of shape: [String: Any]?) -> [Double]? {
        (shape?["rect"] as? [NSNumber])?.map(\.doubleValue)
    }

    private func point(_ shape: [String: Any]?, _ key: String) -> [Double]? {
        (shape?[key] as? [NSNumber])?.map(\.doubleValue)
    }

    /// The page loads and Excalidraw is ready, with no script error.
    @Test func thePageLoadsWithNoError() async throws {
        #expect(page.messages.contains("ready"))
        try await page.draw("setTool('arrow')")
        try await page.hover(CGPoint(x: 300, y: 300))
        #expect(!page.messages.contains { $0.hasPrefix("error: ") })
    }

    /// A drag draws an arrow from the press to the release, and Tilde hears of the shape.
    @Test func aDragDrawsAnArrow() async throws {
        try await page.draw("setTool('arrow')")
        try await page.drag(from: CGPoint(x: 200, y: 150), to: CGPoint(x: 440, y: 270))
        try await page.wait { self.groupMessages() == 1 }
        let shapes = try await page.rawShapes()
        #expect(shapes.count == 1)
        #expect(shapes.first?["type"] as? String == "arrow")
        #expect(point(shapes.first, "from") == [200, 150])
        #expect(point(shapes.first, "to") == [440, 270])
        #expect(shapes.first?["color"] as? String == "#2F76FF")
    }

    /// A click starts an arrow, which is no shape for Tilde yet. Esc throws that arrow away and
    /// does not reach Tilde; with no arrow under way, Esc is Tilde's.
    @Test func escThrowsAwayTheArrowThatAClickStarted() async throws {
        try await page.draw("setTool('arrow')")
        try await page.click(CGPoint(x: 200, y: 150))
        #expect(try await page.rawShapes().first?["type"] as? String == "arrow")
        #expect(groupMessages() == 0, "\(page.messages)")

        #expect(try await page.press("Escape"))
        #expect(!page.messages.contains("escape"))
        #expect(try await page.rawShapes().isEmpty)

        #expect(try await page.press("Escape"))
        #expect(page.messages.filter { $0 == "escape" }.count == 1)
    }

    @Test func aClickWithTheRectangleToolDrawsNothing() async throws {
        try await page.draw("setTool('rectangle')")
        try await page.click(CGPoint(x: 200, y: 150))
        #expect(try await page.rawShapes().isEmpty)
        #expect(groupMessages() == 0, "\(page.messages)")
    }

    /// While a shape's comment is open, only that shape changes: a press beside it is a click
    /// away for Tilde and draws nothing, and a drag on it moves it. After the edit the tool
    /// draws again.
    @Test func aShapeIsEditedWhileItsCommentIsOpen() async throws {
        try await page.draw("setTool('rectangle')")
        try await page.drag(from: CGPoint(x: 200, y: 150), to: CGPoint(x: 440, y: 270))
        try await page.wait { self.groupMessages() == 1 }
        let taken = try await page.takeShapes()
        let id = try #require(taken.first?.id)
        try await page.draw("editShapes(['\(id)'])")

        try await page.drag(from: CGPoint(x: 700, y: 500), to: CGPoint(x: 900, y: 650))
        #expect(page.messages.contains("clickAway"))
        #expect(try await page.rawShapes().isEmpty)
        #expect(groupMessages() == 1)

        // The edge of the rectangle, which the selection tool takes hold of.
        try await page.drag(from: CGPoint(x: 320, y: 150), to: CGPoint(x: 380, y: 190))
        try await page.wait { self.page.messages.contains("edited") }
        let moved = try await page.run("window.tildeDraw.shapesOf(['\(id)'])") as? String
        #expect(moved?.contains("\"rect\":[260,190,240,120]") == true)

        try await page.draw("endEditing()")
        try await page.drag(from: CGPoint(x: 700, y: 500), to: CGPoint(x: 900, y: 650))
        try await page.wait { self.groupMessages() == 2 }
        #expect(rect(of: try await page.rawShapes().first) == [700, 500, 200, 150])
    }

    /// The session's end clears the canvas: no shape is left, taken or new.
    @Test func clearRemovesEveryShape() async throws {
        try await page.draw("setTool('ellipse')")
        try await page.drag(from: CGPoint(x: 200, y: 150), to: CGPoint(x: 440, y: 270))
        try await page.wait { self.groupMessages() == 1 }
        let taken = try await page.takeShapes()
        let id = try #require(taken.first?.id)
        try await page.draw("clear()")
        #expect(try await page.rawShapes().isEmpty)
        #expect(try await page.run("window.tildeDraw.shapesOf(['\(id)'])") as? String == "[]")
    }
}
