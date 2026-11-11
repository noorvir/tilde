@testable import TildeUI
import AppKit
import Testing

/// Wireframe mode on the drawing canvas's page: what the pointer and the keys do to its
/// components, and what the page reports of them. The page is the real one, in no window;
/// each test has its own.
@MainActor
struct WireframeCanvasTests {
    typealias Shape = CanvasPage.Shape
    let page: CanvasPage

    /// A component is drawn here: 240 × 120 at (200, 150).
    private let corner = CGPoint(x: 200, y: 150)
    private let oppositeCorner = CGPoint(x: 440, y: 270)
    private let inside = CGPoint(x: 320, y: 210)
    private let allBorders = ["top", "right", "bottom", "left"]

    init() async throws {
        page = CanvasPage()
        try await page.load()
    }

    private func start(tool: String) async throws {
        try await page.draw("setWireframe({tool: '\(tool)', icons: {}})")
    }

    /// Draws a component of `tool` with a drag between two corners.
    private func drawComponent(_ tool: String, from start: CGPoint? = nil, to end: CGPoint? = nil) async throws {
        try await self.start(tool: tool)
        try await page.drag(from: start ?? corner, to: end ?? oppositeCorner)
    }

    private func rects() async throws -> [[Double]] {
        try await page.shapes().map(\.rect)
    }

    // MARK: - Tools

    /// A drag with a tool draws that tool's component in the dragged rectangle, with all four
    /// borders; a rectangle and a circle are filled. Done takes it, once.
    @Test func eachToolDrawsItsComponent() async throws {
        for (tool, _, _, _) in WireframeMode.tools {
            try await drawComponent(tool)
            let isPlainShape = tool == "rectangle" || tool == "ellipse"
            let expected = Shape(type: tool, rect: [200, 150, 240, 120], borders: allBorders, filled: isPlainShape ? true : nil)
            var drawn = try await page.shapes()
            #expect(drawn.count == 1, "\(tool) drew \(drawn.count) components")
            drawn.indices.forEach { drawn[$0].id = "" }
            #expect(drawn == [expected], "\(tool)")

            let taken = try await page.takeShapes()
            #expect(taken.map(\.type) == [tool])
            #expect(try await page.takeShapes().isEmpty)
        }
    }

    /// A click on empty space draws nothing, and a drag of a few points too.
    @Test func aClickDrawsNothing() async throws {
        try await start(tool: "card")
        try await page.click(corner)
        try await page.drag(from: corner, to: CGPoint(x: corner.x + 2, y: corner.y + 2))
        #expect(try await page.shapes().isEmpty)
    }

    /// The components are drawn in order, the last one in front; Draw's colour does not reach
    /// a component.
    @Test func componentsStackInTheOrderTheyAreDrawn() async throws {
        try await drawComponent("section", from: CGPoint(x: 100, y: 100), to: CGPoint(x: 700, y: 500))
        try await drawComponent("table", from: CGPoint(x: 150, y: 160), to: CGPoint(x: 550, y: 400))
        try await page.draw("setColor('#FF3B30')")
        try await drawComponent("button", from: CGPoint(x: 580, y: 420), to: CGPoint(x: 680, y: 460))

        #expect(try await page.shapes().map(\.type) == ["section", "table", "button"])
        let raw = try await page.rawShapes()
        #expect(raw.allSatisfy { $0["color"] == nil })
    }

    // MARK: - Labels

    /// A double-click on a component opens its label in place; Return keeps the text, and the
    /// component keeps its place and kind.
    @Test func aDoubleClickLabelsAComponent() async throws {
        try await drawComponent("card")
        try await page.click(inside)
        #expect(try await !page.shows("#tilde-label"))
        try await page.click(inside)
        #expect(try await page.shows("#tilde-label"))

        try await page.typeLabel("Plan")
        try await page.press("Enter")
        #expect(try await !page.shows("#tilde-label"))
        let labelled = try await page.shapes()
        #expect(labelled.map(\.label) == ["Plan"])
        #expect(labelled.map(\.type) == ["card"])
        #expect(labelled.map(\.rect) == [[200, 150, 240, 120]])
    }

    /// Esc in the label field keeps the label as it was; a click elsewhere keeps the new text;
    /// an empty text takes the label away.
    @Test func escKeepsTheOldLabelAndAClickAwayKeepsTheNewOne() async throws {
        try await drawComponent("button")
        try await page.click(inside)
        try await page.click(inside)
        try await page.typeLabel("Save")
        try await page.press("Enter")

        try await page.click(inside)
        try await page.click(inside)
        try await page.typeLabel("Cancel")
        try await page.press("Escape")
        #expect(try await page.shapes().map(\.label) == ["Save"])
        // Esc in the field is the field's: Tilde does not get it.
        #expect(!page.messages.contains("escape"))

        try await page.click(inside)
        try await page.click(inside)
        try await page.typeLabel("Send")
        try await page.click(CGPoint(x: 900, y: 600))
        #expect(try await page.shapes().map(\.label) == ["Send"])

        try await page.click(inside)
        try await page.click(inside)
        try await page.typeLabel("")
        try await page.press("Enter")
        #expect(try await page.shapes().map(\.label) == [nil])
    }

    /// A section takes a label too, though a drag on it draws in it.
    @Test func aSectionTakesALabel() async throws {
        try await drawComponent("section")
        try await page.click(inside)
        try await page.click(inside)
        try await page.typeLabel("Billing")
        try await page.press("Enter")
        let shapes = try await page.shapes()
        #expect(shapes.map(\.type) == ["section"])
        #expect(shapes.map(\.label) == ["Billing"])
    }

    // MARK: - No tool, after Esc

    /// With no tool, as after Esc, a drag on empty space draws nothing; components can still be
    /// moved (a section too), resized and labelled. A tool draws again.
    @Test func withNoToolNothingDrawsAndComponentsStillChange() async throws {
        try await drawComponent("section")
        try await start(tool: "")

        try await page.drag(from: CGPoint(x: 600, y: 500), to: CGPoint(x: 800, y: 650))
        #expect(try await page.shapes().count == 1)

        try await page.drag(from: inside, to: CGPoint(x: inside.x + 50, y: inside.y + 30))
        #expect(try await rects() == [[250, 180, 240, 120]])

        try await page.hover(CGPoint(x: 370, y: 240))
        try await page.drag(from: CGPoint(x: 490, y: 300), to: CGPoint(x: 530, y: 340), on: Self.resizer)
        #expect(try await rects() == [[250, 180, 280, 160]])

        try await page.click(CGPoint(x: 370, y: 240))
        try await page.click(CGPoint(x: 370, y: 240))
        try await page.typeLabel("Header")
        try await page.press("Enter")
        #expect(try await page.shapes().map(\.label) == ["Header"])

        try await drawComponent("card", from: CGPoint(x: 700, y: 500), to: CGPoint(x: 900, y: 650))
        #expect(try await page.shapes().map(\.type) == ["section", "card"])
    }

    // MARK: - Move, resize and copy

    /// A drag on a component moves it, also while a tool is chosen, and draws nothing.
    @Test func aDragOnAComponentMovesIt() async throws {
        try await drawComponent("card")
        try await page.drag(from: inside, to: CGPoint(x: inside.x + 60, y: inside.y + 40))
        let moved = try await page.shapes()
        #expect(moved.map(\.rect) == [[260, 190, 240, 120]])
        #expect(moved.map(\.type) == ["card"])
    }

    /// A drag on a section draws in it while a tool is chosen: the section stays. Its chip
    /// moves it.
    @Test func aDragOnASectionDrawsInIt() async throws {
        try await drawComponent("section", from: CGPoint(x: 100, y: 100), to: CGPoint(x: 700, y: 500))
        try await drawComponent("card", from: CGPoint(x: 150, y: 150), to: CGPoint(x: 350, y: 250))
        var shapes = try await page.shapes()
        #expect(shapes.map(\.type) == ["section", "card"])
        #expect(shapes.map(\.rect) == [[100, 100, 600, 400], [150, 150, 200, 100]])

        try await page.hover(CGPoint(x: 600, y: 450))
        try await page.drag(from: CGPoint(x: 110, y: 90), to: CGPoint(x: 140, y: 130), on: Self.chip)
        shapes = try await page.shapes()
        #expect(shapes.map(\.rect) == [[130, 140, 600, 400], [150, 150, 200, 100]])
    }

    /// The handle at the bottom right resizes a component; the top left stays, and it is never
    /// smaller than 16 × 12.
    @Test func theCornerHandleResizesAComponent() async throws {
        try await drawComponent("table")
        try await page.hover(inside)
        #expect(try await page.shows(Self.resizer))
        try await page.drag(from: oppositeCorner, to: CGPoint(x: 480, y: 300), on: Self.resizer)
        #expect(try await rects() == [[200, 150, 280, 150]])

        try await page.hover(inside)
        try await page.drag(from: CGPoint(x: 480, y: 300), to: CGPoint(x: 100, y: 100), on: Self.resizer)
        #expect(try await rects() == [[200, 150, 16, 12]])
        #expect(try await page.shapes().map(\.type) == ["table"])
    }

    /// ⌥ and a drag moves a copy: the first component stays, and the copy has its kind, its
    /// label and its size.
    @Test func optionAndADragCopiesAComponent() async throws {
        try await drawComponent("button")
        try await page.click(inside)
        try await page.click(inside)
        try await page.typeLabel("Save")
        try await page.press("Enter")

        try await page.drag(from: inside, to: CGPoint(x: inside.x + 300, y: inside.y + 200), alt: true)
        let shapes = try await page.shapes()
        #expect(shapes.map(\.type) == ["button", "button"])
        #expect(shapes.map(\.label) == ["Save", "Save"])
        #expect(shapes.map(\.rect) == [[200, 150, 240, 120], [500, 350, 240, 120]])
        #expect(shapes[0].id != shapes[1].id)
    }

    /// ⌥ and a drag copies a section too, which a plain drag does not move.
    @Test func optionAndADragCopiesASection() async throws {
        try await drawComponent("section")
        try await page.drag(from: inside, to: CGPoint(x: inside.x + 300, y: inside.y + 200), alt: true)
        #expect(try await page.shapes().map(\.type) == ["section", "section"])
        #expect(try await rects() == [[200, 150, 240, 120], [500, 350, 240, 120]])
    }

    // MARK: - Snapping

    /// A new component's corners go to the lines of the layout under the pointer within 8
    /// points.
    @Test func aNewComponentSnapsToTheLayoutLines() async throws {
        try await page.draw("setSnapTargets({rects: [[400, 300, 200, 100]], containers: [], window: null, screen: null})")
        try await drawComponent("card", from: CGPoint(x: 404, y: 305), to: CGPoint(x: 595, y: 394))
        #expect(try await rects() == [[400, 300, 200, 100]])
        _ = try await page.takeShapes()

        // 9 points away is out of reach.
        try await page.drag(from: CGPoint(x: 409, y: 309), to: CGPoint(x: 591, y: 391))
        #expect(try await rects() == [[409, 309, 182, 82]])
    }

    /// ⌘ turns the snapping to the layout's lines off.
    @Test func commandDrawsWithoutSnapping() async throws {
        try await page.draw("setSnapTargets({rects: [[400, 300, 200, 100]], containers: [], window: null, screen: [0, 0, 1200, 800]})")
        try await start(tool: "card")
        try await page.drag(from: CGPoint(x: 404, y: 305), to: CGPoint(x: 595, y: 394), meta: true)
        #expect(try await rects() == [[404, 305, 191, 89]])
    }

    /// ⌘ turns all snapping off: a component drawn next to another one does not snap to it
    /// either, by Tilde's lines or by the canvas's own.
    @Test func commandDrawsWithoutSnappingToOtherComponents() async throws {
        try await drawComponent("card")
        // 4 points from the first one's left edge, right edge and bottom edge.
        try await page.drag(from: CGPoint(x: 204, y: 274), to: CGPoint(x: 436, y: 394), meta: true)
        #expect(try await rects() == [[200, 150, 240, 120], [204, 274, 232, 120]])

        // Without ⌘ the same drag snaps to them.
        try await page.draw("undoWireframe()")
        try await page.drag(from: CGPoint(x: 204, y: 274), to: CGPoint(x: 436, y: 394))
        #expect(try await rects() == [[200, 150, 240, 120], [200, 270, 240, 124]])
    }

    /// The halves and thirds of the screen, the window and the containers are lines too, and
    /// the guide says which one.
    @Test func aNewComponentSnapsToHalvesAndThirds() async throws {
        try await page.draw("setSnapTargets({rects: [], containers: [[300, 100, 600, 300]], window: [100, 50, 900, 600], screen: [0, 0, 1200, 800]})")
        try await start(tool: "card")
        // The half of the screen: x 600, y 400.
        try await page.hover(CGPoint(x: 597, y: 403))
        #expect(try await page.run("document.body.textContent.includes('½ screen')") as? Bool == true)
        // A third of the window: x 100 + 300, y 50 + 200; the container's right and bottom edges.
        try await page.drag(from: CGPoint(x: 403, y: 247), to: CGPoint(x: 896, y: 397))
        #expect(try await rects() == [[400, 250, 500, 150]])
    }

    /// Components line up with each other: a new one, a moved one and a resized one snap to
    /// the edges and centres of the others, before the layout's lines.
    @Test func componentsSnapToEachOther() async throws {
        try await drawComponent("card")
        // Its left edge is 200, its right 440, its centre 320.
        try await page.drag(from: CGPoint(x: 205, y: 400), to: CGPoint(x: 436, y: 500))
        #expect(try await rects().last == [200, 400, 240, 100])

        // Moved by 243 to the right: its left edge is 3 points from the first one's right edge.
        try await page.drag(from: CGPoint(x: 320, y: 450), to: CGPoint(x: 563, y: 450))
        #expect(try await rects().last == [440, 400, 240, 100])

        // Resized: the corner snaps to the first one's bottom edge, 270.
        try await page.hover(CGPoint(x: 560, y: 450))
        try await page.drag(from: CGPoint(x: 680, y: 500), to: CGPoint(x: 800, y: 273), on: Self.resizer)
        #expect(try await rects().last == [440, 400, 360, 12])
    }

    /// A moved component snaps by its edges and its centre; ⌘ turns that off.
    @Test func aMovedComponentSnapsToTheLayoutLines() async throws {
        try await page.draw("setSnapTargets({rects: [[600, 400, 300, 200]], containers: [], window: null, screen: null})")
        try await drawComponent("card")
        // Its right edge would be at 596 and its bottom at 396: 4 points from the lines.
        try await page.drag(from: inside, to: CGPoint(x: inside.x + 156, y: inside.y + 126))
        #expect(try await rects() == [[360, 280, 240, 120]])

        try await page.drag(from: CGPoint(x: 480, y: 340), to: CGPoint(x: 476, y: 337), meta: true)
        #expect(try await rects() == [[356, 277, 240, 120]])
    }

    // MARK: - Undo, redo and delete

    /// Undo and redo step through every change: a new component, a move, a label, a delete.
    @Test func undoAndRedoStepThroughEveryChange() async throws {
        try await drawComponent("card")
        try await page.drag(from: inside, to: CGPoint(x: inside.x + 60, y: inside.y + 40))
        try await page.click(CGPoint(x: 380, y: 250))
        try await page.click(CGPoint(x: 380, y: 250))
        try await page.typeLabel("Plan")
        try await page.press("Enter")
        try await page.hover(CGPoint(x: 380, y: 250))
        try await page.press("Backspace")
        #expect(try await page.shapes().isEmpty)

        try await page.press("z", meta: true)
        #expect(try await page.shapes().map(\.label) == ["Plan"])
        try await page.press("z", meta: true)
        #expect(try await page.shapes().map(\.label) == [nil])
        #expect(try await rects() == [[260, 190, 240, 120]])
        try await page.draw("undoWireframe()")
        #expect(try await rects() == [[200, 150, 240, 120]])
        try await page.draw("undoWireframe()")
        #expect(try await page.shapes().isEmpty)
        // Nothing is left to undo.
        try await page.draw("undoWireframe()")
        #expect(try await page.shapes().isEmpty)

        try await page.press("z", meta: true, shift: true)
        try await page.press("z", meta: true, shift: true)
        try await page.draw("redoWireframe()")
        let redone = try await page.shapes()
        #expect(redone.map(\.label) == ["Plan"])
        #expect(redone.map(\.rect) == [[260, 190, 240, 120]])
        try await page.draw("redoWireframe()")
        #expect(try await page.shapes().isEmpty)
    }

    /// Delete removes the component under the pointer, or the selected one; the chip's × does
    /// the same.
    @Test func deleteRemovesAComponent() async throws {
        try await drawComponent("card")
        try await drawComponent("list", from: CGPoint(x: 600, y: 400), to: CGPoint(x: 800, y: 600))
        try await page.hover(inside)
        try await page.press("Delete")
        #expect(try await page.shapes().map(\.type) == ["list"])

        try await page.hover(CGPoint(x: 700, y: 500))
        try await page.click(on: "[data-action=\"delete\"]")
        #expect(try await page.shapes().isEmpty)
    }

    // MARK: - The chip

    /// The chip's name opens the kinds; a kind changes the component and keeps its place, its
    /// label and its borders.
    @Test func theChipChangesTheKind() async throws {
        try await drawComponent("card")
        try await page.click(inside)
        try await page.click(inside)
        try await page.typeLabel("Plans")
        try await page.press("Enter")
        try await page.hover(inside)
        #expect(try await !page.shows("[data-kind=\"table\"]"))

        try await page.click(on: Self.chip)
        #expect(try await page.shows("[data-kind=\"table\"]"))
        try await page.click(on: "[data-kind=\"table\"]")
        let changed = try await page.shapes()
        #expect(changed.map(\.type) == ["table"])
        #expect(changed.map(\.label) == ["Plans"])
        #expect(changed.map(\.rect) == [[200, 150, 240, 120]])
        #expect(changed.map(\.borders) == [allBorders])
        #expect(try await !page.shows("[data-kind=\"table\"]"))
    }

    /// The chip's controls set the borders, the rows and columns of a table, and the fill of a
    /// rectangle, which the next rectangle takes.
    @Test func theChipSetsBordersRowsAndFill() async throws {
        try await drawComponent("table")
        try await page.hover(inside)
        try await page.click(on: "[data-action=\"border:top\"]")
        #expect(try await page.shapes().map(\.borders) == [["right", "bottom", "left"]])
        try await page.click(on: "[data-action=\"border:left\"]")
        #expect(try await page.shapes().map(\.borders) == [["right", "bottom"]])
        try await page.click(on: "[data-action=\"border:all\"]")
        #expect(try await page.shapes().map(\.borders) == [allBorders])
        try await page.click(on: "[data-action=\"border:all\"]")
        #expect(try await page.shapes().map(\.borders) == [[]])

        // A table of 240 × 120 has 3 rows and 2 columns until they are set.
        try await page.click(on: "[data-action=\"rows:1\"]")
        try await page.click(on: "[data-action=\"columns:1\"]")
        try await page.click(on: "[data-action=\"columns:1\"]")
        try await page.click(on: "[data-action=\"rows:-1\"]")
        try await page.click(on: "[data-action=\"rows:-1\"]")
        let table = try await page.shapes()
        #expect(table.map(\.rows) == [2])
        #expect(table.map(\.columns) == [4])
        _ = try await page.takeShapes()

        try await drawComponent("rectangle")
        try await page.hover(inside)
        try await page.click(on: "[data-action=\"filled\"]")
        #expect(try await page.shapes().map(\.filled) == [false])
        try await drawComponent("ellipse", from: CGPoint(x: 600, y: 400), to: CGPoint(x: 800, y: 600))
        #expect(try await page.shapes().map(\.filled) == [false, false])
    }

    // MARK: - Esc

    /// Esc steps back one level at a time: the kinds, then the selection; only with nothing
    /// selected does it reach Tilde, which puts the tool down.
    @Test func escStepsBackBeforeItReachesTilde() async throws {
        try await drawComponent("card")
        try await page.click(inside)
        try await page.click(on: Self.chip)
        #expect(try await page.shows("[data-kind=\"card\"]"))

        try await page.press("Escape")
        #expect(try await !page.shows("[data-kind=\"card\"]"))
        #expect(!page.messages.contains("escape"))

        try await page.press("Escape")
        #expect(!page.messages.contains("escape"))

        try await page.press("Escape")
        #expect(page.messages.filter { $0 == "escape" }.count == 1)
        #expect(try await page.shapes().count == 1)
    }

    // MARK: - The window, a note shown again, and the end of the mode

    /// The components keep their place on their window when it moves, and so does what Undo
    /// goes back to.
    @Test func theComponentsFollowTheirWindow() async throws {
        try await drawComponent("card")
        try await page.draw("setWireframeWindow([100, 100, 800, 600])")
        #expect(try await rects() == [[200, 150, 240, 120]])
        try await page.drag(from: inside, to: CGPoint(x: inside.x + 60, y: inside.y + 40))

        try await page.draw("setWireframeWindow([130, 120, 800, 600])")
        #expect(try await rects() == [[290, 210, 240, 120]])
        // A resize alone moves nothing.
        try await page.draw("setWireframeWindow([130, 120, 900, 700])")
        #expect(try await rects() == [[290, 210, 240, 120]])

        try await page.draw("undoWireframe()")
        #expect(try await rects() == [[230, 170, 240, 120]])
    }

    /// A note's components show again from its report, at their window's place now, and can
    /// be changed as new ones.
    @Test func aNotesComponentsShowAgain() async throws {
        let report = WireframeMode.report(of: Fixtures.wireframeShapes, origin: Fixtures.window.frame.origin, isOnWindow: true)
        let saved = try #require(WireframeMode.Saved(Fixtures.wireframe()))
        #expect(report.contains("\"originIs\":\"window\""))
        try await start(tool: "card")
        // The window is now at (150, 120).
        try await page.draw("restoreWireframe({shapes: \(DrawingPanel.json(saved.shapes)), origin: [150, 120]})")

        let shown = try await page.shapes()
        #expect(shown.map(\.type) == ["card", "table"])
        #expect(shown.map(\.label) == ["Plan", nil])
        #expect(shown.map(\.rect) == [[190, 180, 240, 120], [190, 320, 400, 160]])
        #expect(shown.map(\.rows) == [nil, 3])
        #expect(shown.map(\.columns) == [nil, 2])
        #expect(shown.map(\.borders) == [allBorders, ["top", "bottom"]])

        try await page.drag(from: CGPoint(x: 300, y: 240), to: CGPoint(x: 700, y: 240), meta: true)
        #expect(try await rects().first == [590, 180, 240, 120])
    }

    /// Done takes the components with their labels, in points from the top left of the page;
    /// the report then has them from their window. The mode's end drops what was not taken
    /// and keeps what was.
    @Test func doneTakesTheComponentsAndTheModesEndDropsTheRest() async throws {
        try await drawComponent("card")
        try await page.click(inside)
        try await page.click(inside)
        try await page.typeLabel("Plan")
        try await page.press("Enter")
        let raw = try await page.rawShapes()
        let taken = try await page.takeShapes()
        #expect(taken.map(\.label) == ["Plan"])

        let report = WireframeMode.report(of: raw, origin: CGPoint(x: 100, y: 100), isOnWindow: true)
        let object = try #require(JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any])
        let shapes = try #require(object["shapes"] as? [[String: Any]])
        #expect(shapes.first?["type"] as? String == "card")
        #expect(shapes.first?["label"] as? String == "Plan")
        #expect(shapes.first?["rect"] as? [Double] == [100, 50, 240, 120])
        #expect(shapes.first?["id"] == nil)

        try await drawComponent("list", from: CGPoint(x: 600, y: 400), to: CGPoint(x: 800, y: 600))
        #expect(try await page.shapes().map(\.type) == ["list"])
        try await page.draw("setWireframe(null)")
        #expect(try await page.shapes().isEmpty)
        let kept = try await page.run("window.tildeDraw.shapesOf(['\(taken[0].id)'])") as? String
        #expect(kept?.contains("\"label\":\"Plan\"") == true)
    }

    // MARK: - Draw mode on the same page

    /// Draw mode still draws its shapes in its colour and says so to Tilde. With no tool, as
    /// after Esc, nothing draws until a tool is chosen.
    @Test func drawModeDrawsAndNoToolDrawsNothing() async throws {
        try await page.draw("setTool('rectangle')")
        try await page.draw("setColor('#FF3B30')")
        try await page.drag(from: corner, to: oppositeCorner)
        try await page.wait { self.page.messages.contains("shape") }
        let raw = try await page.rawShapes()
        #expect(raw.count == 1)
        #expect(raw.first?["type"] as? String == "rectangle")
        #expect(raw.first?["color"] as? String == "#FF3B30")
        #expect((raw.first?["rect"] as? [NSNumber])?.map(\.doubleValue) == [200, 150, 240, 120])
        _ = try await page.takeShapes()
        try await page.draw("endEditing()")

        try await page.draw("setNoTool()")
        try await page.drag(from: CGPoint(x: 600, y: 400), to: CGPoint(x: 800, y: 600))
        #expect(try await page.shapes().isEmpty)
        #expect(page.messages.filter { $0 == "shape" }.count == 1)

        try await page.draw("setTool('ellipse')")
        try await page.drag(from: CGPoint(x: 600, y: 400), to: CGPoint(x: 800, y: 600))
        try await page.wait { self.page.messages.filter { $0 == "shape" }.count == 2 }
        #expect(try await page.rawShapes().first?["type"] as? String == "ellipse")
    }

    /// The handles of a component, which have no ids: the chip at its top left, and the square
    /// at its bottom right.
    private static let chip = "[data-wireframe-handle][style*=\"cursor: move\"]"
    private static let resizer = "[data-wireframe-handle][style*=\"nwse-resize\"]"
}
