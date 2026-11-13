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
        #expect(try await page.press("Enter"))
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
        #expect(try await page.press("Escape"))
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

    /// With no tool, the page takes a press only on a component, its label tag and its
    /// handles, and anywhere while a label or a comment is typed; Tilde lets every other press through to
    /// the app behind. A press that went through ends the selection. With a tool, it takes
    /// every press.
    @Test func withNoToolOnlyComponentsTakeThePointer() async throws {
        let empty = CGPoint(x: 800, y: 600)
        try await drawComponent("card")
        #expect(page.messages.last { $0 == "tool" || $0 == "noTool" } == "tool")
        #expect(try await page.takesPointer(empty))

        try await start(tool: "")
        #expect(page.messages.last { $0 == "tool" || $0 == "noTool" } == "noTool")
        #expect(try await page.takesPointer(inside))
        #expect(try await !page.takesPointer(empty))
        // The label tag stands on the component's top edge, partly above it.
        #expect(try await page.takesPointer(CGPoint(x: corner.x + 20, y: corner.y - 8)))
        // The chip shows below the selected component.
        try await page.click(inside)
        #expect(try await page.shows(Self.chip))
        let center = "(() => { const box = document.querySelector('\(Self.chip)').getBoundingClientRect(); return [box.left + box.width / 2, box.top + box.height / 2]; })()"
        let values = try #require(try await page.run(center) as? [Double])
        let chip = CGPoint(x: values[0], y: values[1])
        #expect(chip.y > oppositeCorner.y)
        #expect(try await page.takesPointer(chip))

        try await page.draw("pointerWentThrough(true)")
        #expect(try await !page.shows(Self.chip))
        #expect(try await !page.takesPointer(chip))

        // Two clicks apart from the one before are a double-click.
        try await Task.sleep(for: .milliseconds(450))
        try await page.click(inside)
        try await page.click(inside)
        #expect(try await page.shows("#tilde-label"))
        #expect(try await page.takesPointer(empty))
        try await page.press("Enter")
        #expect(try await !page.takesPointer(empty))

        // So does a comment that is typed: a press elsewhere keeps it.
        try await page.hover(inside)
        try await page.click(on: "#tilde-chip [data-menu=\"comment\"]")
        #expect(try await page.shows("#tilde-comment"))
        #expect(try await page.takesPointer(empty))
        #expect(try await page.press("Escape"))
        #expect(try await !page.takesPointer(empty))
    }

    // MARK: - Move, resize and copy

    /// With no tool a drag on a component moves it. With a tool a drag draws, also on a
    /// component: a section in a section, a card in it; the chip still moves one.
    @Test func aToolDrawsInAComponentAndNoToolMovesIt() async throws {
        try await drawComponent("section", from: CGPoint(x: 100, y: 100), to: CGPoint(x: 700, y: 500))
        try await drawComponent("section", from: CGPoint(x: 150, y: 150), to: CGPoint(x: 450, y: 400))
        try await drawComponent("card", from: CGPoint(x: 200, y: 200), to: CGPoint(x: 400, y: 300))
        let drawn = try await page.shapes()
        #expect(drawn.map(\.type) == ["section", "section", "card"])
        #expect(drawn.map(\.rect) == [[100, 100, 600, 400], [150, 150, 300, 250], [200, 200, 200, 100]])

        try await page.hover(CGPoint(x: 300, y: 250))
        try await page.drag(from: CGPoint(x: 210, y: 315), to: CGPoint(x: 230, y: 325), on: Self.chip)
        #expect(try await rects().last == [220, 210, 200, 100])

        try await start(tool: "")
        try await page.drag(from: CGPoint(x: 300, y: 250), to: CGPoint(x: 360, y: 290))
        let moved = try await page.shapes()
        #expect(moved.map(\.rect) == [[100, 100, 600, 400], [150, 150, 300, 250], [280, 250, 200, 100]])
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
        try await page.drag(from: CGPoint(x: 110, y: 515), to: CGPoint(x: 140, y: 555), on: Self.chip)
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

    /// Each corner resizes a component from that corner, with the cursor of its diagonal: the
    /// opposite corner stays, also when the pointer goes past it, and the component is never
    /// smaller than 16 × 12. The pointer finds each corner's square itself.
    @Test(arguments: [
        ("nw", CGPoint(x: 200, y: 150), CGPoint(x: 160, y: 120), [160.0, 120, 280, 150], [424.0, 258, 16, 12], "nwse-resize"),
        ("ne", CGPoint(x: 440, y: 150), CGPoint(x: 480, y: 120), [200.0, 120, 280, 150], [200.0, 258, 16, 12], "nesw-resize"),
        ("sw", CGPoint(x: 200, y: 270), CGPoint(x: 160, y: 300), [160.0, 150, 280, 150], [424.0, 150, 16, 12], "nesw-resize"),
        ("se", CGPoint(x: 440, y: 270), CGPoint(x: 480, y: 300), [200.0, 150, 280, 150], [200.0, 150, 16, 12], "nwse-resize"),
    ])
    func eachCornerResizesFromThatCorner(corner: String, from: CGPoint, to: CGPoint, grown: [Double], smallest: [Double], cursor: String) async throws {
        try await drawComponent("table")
        try await start(tool: "")
        try await page.hover(inside)
        let found = "(() => { const e = document.elementFromPoint(\(from.x), \(from.y)); return [e.dataset.corner, getComputedStyle(e).cursor].join(); })()"
        #expect(try await page.run(found) as? String == "\(corner),\(cursor)")
        try await page.drag(from: from, to: to)
        #expect(try await rects() == [grown])

        // Past the opposite corner, from the original size.
        try await page.draw("undoWireframe()")
        try await page.hover(inside)
        let opposite = CGPoint(x: 640 - from.x, y: 420 - from.y)
        try await page.drag(from: from, to: CGPoint(x: opposite.x + (opposite.x - from.x), y: opposite.y + (opposite.y - from.y)))
        #expect(try await rects() == [smallest])
        #expect(try await page.shapes().map(\.type) == ["table"])
    }

    /// The place, colour and cursor of the grip on a component's top edge.
    private func gripInfo() async throws -> String? {
        try await page.run("(() => { const e = document.getElementById('tilde-grip'); if (getComputedStyle(e).display === 'none') return null; const box = e.getBoundingClientRect(); return [box.left, box.top, box.width, box.height, getComputedStyle(e).backgroundColor, getComputedStyle(e).cursor].join(); })()") as? String
    }

    /// A grip on the middle of a component's top edge, in its kind's colour, moves it: with no
    /// tool and with one. It shows with the pointer over the component, and while it is
    /// selected.
    @Test func theTopGripMovesAComponent() async throws {
        try await page.draw("restoreWireframe({shapes: [{type: 'card', rect: [200, 150, 240, 120], label: 'Plan'}, {type: 'table', rect: [600, 150, 200, 120]}], origin: [0, 0]})")
        try await start(tool: "")
        #expect(try await gripInfo() == nil)
        try await page.hover(inside)
        // 24 × 8, from 2 points above the edge, clear of the tag at the left.
        #expect(try await gripInfo() == "308,148,24,8,rgb(47, 123, 246),move")
        try await page.hover(CGPoint(x: 700, y: 210))
        #expect(try await gripInfo() == "688,148,24,8,rgb(14, 147, 132),move")

        try await page.hover(inside)
        try await page.drag(from: CGPoint(x: 320, y: 152), to: CGPoint(x: 360, y: 192))
        #expect(try await rects() == [[240, 190, 240, 120], [600, 150, 200, 120]])

        // With a tool, a press on the grip moves and draws nothing.
        try await start(tool: "card")
        try await page.hover(CGPoint(x: 360, y: 250))
        try await page.drag(from: CGPoint(x: 360, y: 192), to: CGPoint(x: 340, y: 172))
        #expect(try await rects() == [[220, 170, 240, 120], [600, 150, 200, 120]])

        // A click on it selects the component: the grip stays with the pointer away.
        try await start(tool: "")
        try await page.hover(CGPoint(x: 340, y: 230))
        try await page.click(CGPoint(x: 340, y: 172))
        try await page.hover(CGPoint(x: 1000, y: 700))
        #expect(try await gripInfo() == "328,168,24,8,rgb(47, 123, 246),move")
    }

    /// On a narrow component the grip stays at the middle, and the corners win where they meet
    /// it. The grip never covers the label's tag or a chip above the component.
    @Test func theGripLeavesTheCornersTheTagAndTheChipFree() async throws {
        try await page.draw("restoreWireframe({shapes: [{type: 'button', rect: [500, 400, 30, 20]}], origin: [0, 0]})")
        try await start(tool: "")
        try await page.hover(CGPoint(x: 515, y: 412))
        #expect(try await gripInfo()?.hasPrefix("503,398,24,8,") == true)
        #expect(try await page.run("document.elementFromPoint(529, 401).dataset.corner") as? String == "ne")
        #expect(try await page.run("document.elementFromPoint(515, 402).id") as? String == "tilde-grip")

        // At the top of the screen the tag is inside the component; a long label leaves no room
        // after it, so the grip goes under it.
        try await page.draw("restoreWireframe({shapes: [{type: 'card', rect: [100, 5, 100, 60], label: 'A long label'}], origin: [0, 0]})")
        try await page.hover(CGPoint(x: 150, y: 50))
        #expect(try await gripInfo()?.hasPrefix("138,24,24,8,") == true)

        // At the bottom of the screen the chip is above the component, after the tag.
        try await page.draw("restoreWireframe({shapes: [{type: 'card', rect: [100, 740, 300, 50], label: 'Plan'}], origin: [0, 0]})")
        try await page.hover(CGPoint(x: 250, y: 770))
        let overlap = "(() => { const a = document.getElementById('tilde-grip').getBoundingClientRect(); const b = document.getElementById('tilde-chip').getBoundingClientRect(); return a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top; })()"
        #expect(try await page.run(overlap) as? Bool == false)
        #expect(try await page.run("document.getElementById('tilde-chip').dataset.side") as? String == "above")
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
        try await start(tool: "")
        try await page.drag(from: CGPoint(x: 320, y: 450), to: CGPoint(x: 563, y: 450))
        #expect(try await rects().last == [440, 400, 240, 100])

        // Resized: the corner snaps to the first one's bottom edge, 270.
        try await page.hover(CGPoint(x: 560, y: 450))
        try await page.drag(from: CGPoint(x: 680, y: 500), to: CGPoint(x: 800, y: 273), on: Self.resizer)
        #expect(try await rects().last == [440, 400, 360, 12])
    }

    /// Tilde finds the lines under the pointer after it got there: lines that come while the
    /// pointer rests during a drag snap the component at once, with the guide.
    @Test func linesThatComeWhileThePointerRestsSnapAtOnce() async throws {
        try await start(tool: "card")
        try await page.run("""
            fire('pointermove', 200, 150);
            window.pressed = fire('pointerdown', 200, 150);
            fire('pointermove', 300, 230, {isPressed: true, target: window.pressed});
            fire('pointermove', 403, 304, {isPressed: true, target: window.pressed});
            0
            """)
        try await page.settle()
        try await page.draw("setSnapTargets({rects: [[400, 300, 200, 100]], containers: [], window: null, screen: null})")
        let guide = "(() => [...document.querySelectorAll('div')].filter((element) => element.style.borderTopStyle === 'dashed' && element.style.display === 'block').length)()"
        #expect(try await page.run(guide) as? Int == 1)

        try await page.run("fire('pointerup', 403, 304, {target: window.pressed}); 0")
        try await page.settle()
        #expect(try await rects() == [[200, 150, 200, 150]])
    }

    /// A drag starts where it was pressed, also when new lines to snap to come before its first
    /// move. The page last saw the pointer far away, before it went to the app behind; the
    /// pointer comes back on a component and presses it at once; the lines for that place come
    /// next. The component must not jump towards the old place.
    @Test func linesThatComeAtThePressDoNotMoveAComponentToAnOldPlace() async throws {
        try await drawComponent("card")
        try await start(tool: "")
        try await page.hover(CGPoint(x: 900, y: 600))
        try await page.draw("pointerWentThrough(false)")
        try await page.run("window.pressed = fire('pointerdown', 320, 210); 0")
        try await page.draw("setSnapTargets({rects: [], containers: [], window: null, screen: null})")
        #expect(try await rects() == [[200, 150, 240, 120]])

        try await page.run("fire('pointermove', 330, 220, {isPressed: true, target: window.pressed}); fire('pointerup', 330, 220, {target: window.pressed}); 0")
        try await page.settle()
        #expect(try await rects() == [[210, 160, 240, 120]])
    }

    /// A component being drawn grows from its press, also when new lines come before its first
    /// move: the page last saw the pointer far away, over Tilde's bar, before the press.
    @Test func linesThatComeAtThePressDoNotDrawTowardsAnOldPlace() async throws {
        try await start(tool: "card")
        try await page.hover(CGPoint(x: 900, y: 40))
        try await page.run("window.pressed = fire('pointerdown', 300, 300); 0")
        try await page.draw("setSnapTargets({rects: [], containers: [], window: null, screen: null})")
        #expect(try await rects().allSatisfy { $0[0] == 300 && $0[1] == 300 })
        try await page.run("fire('pointermove', 360, 350, {isPressed: true, target: window.pressed}); 0")
        try await page.settle()
        try await page.run("fire('pointermove', 400, 380, {isPressed: true, target: window.pressed}); fire('pointerup', 400, 380, {target: window.pressed}); 0")
        try await page.settle()
        #expect(try await rects() == [[300, 300, 100, 80]])
    }

    /// The page posts the pointer's place at most 20 times a second, and always the place
    /// where it stopped, so Tilde looks for lines there.
    @Test func theLastPlaceOfAQuickMoveIsPosted() async throws {
        try await start(tool: "card")
        try await page.hover(CGPoint(x: 100, y: 100))
        try await page.run("fire('pointermove', 110, 110); fire('pointermove', 120, 120); 0")
        try await page.wait { self.page.pointers.last == "120,120" }
    }

    /// A moved component snaps by its edges and its centre; ⌘ turns that off.
    @Test func aMovedComponentSnapsToTheLayoutLines() async throws {
        try await page.draw("setSnapTargets({rects: [[600, 400, 300, 200]], containers: [], window: null, screen: null})")
        try await drawComponent("card")
        try await start(tool: "")
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
        try await start(tool: "")
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
        try await page.click(on: Self.bordersButton)
        try await page.click(on: "[data-action=\"border:top\"]")
        #expect(try await page.shapes().map(\.borders) == [["right", "bottom", "left"]])
        try await page.click(on: "[data-action=\"border:left\"]")
        #expect(try await page.shapes().map(\.borders) == [["right", "bottom"]])
        try await page.click(on: "[data-action=\"border:all\"]")
        #expect(try await page.shapes().map(\.borders) == [allBorders])
        try await page.click(on: "[data-action=\"border:all\"]")
        #expect(try await page.shapes().map(\.borders) == [[]])
        try await page.click(on: Self.bordersButton)

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

    /// The chip's Comment button opens a box for that component's comment only. ⌘Return, a
    /// click elsewhere or a second click on the button keeps it, and the report has it; Esc
    /// closes only the box and keeps the comment as it was, and leaves no step for Esc after.
    @Test func theChipsCommentButtonOpensTheComponentsComment() async throws {
        try await drawComponent("card")
        try await drawComponent("table", from: CGPoint(x: 600, y: 400), to: CGPoint(x: 800, y: 600))
        let button = "#tilde-chip [data-menu=\"comment\"]"
        try await page.hover(inside)
        #expect(try await !page.shows("#tilde-comment"))

        try await page.click(on: button)
        #expect(try await page.shows("#tilde-comment"))
        try await typeComment("Use the brand blue")
        #expect(try await page.press("Enter", meta: true))
        #expect(try await !page.shows("#tilde-comment"))
        #expect(try await comments() == ["Use the brand blue", nil])

        try await page.hover(inside)
        try await page.click(on: button)
        #expect(try await page.run("document.getElementById('tilde-comment-field').value") as? String == "Use the brand blue")
        try await typeComment("Another")
        #expect(try await page.press("Escape"))
        #expect(try await !page.shows("#tilde-comment"))
        #expect(try await comments() == ["Use the brand blue", nil])
        // The comment took no step of Esc: the next one reaches Tilde.
        #expect(!page.messages.contains("escape"))
        try await page.press("Escape")
        #expect(page.messages.contains("escape"))

        try await page.hover(inside)
        try await page.click(on: button)
        try await typeComment("Wider")
        try await page.click(CGPoint(x: 1000, y: 100))
        #expect(try await comments() == ["Wider", nil])

        try await page.hover(inside)
        try await page.click(on: button)
        try await typeComment("Narrower")
        try await page.click(on: button)
        #expect(try await !page.shows("#tilde-comment"))
        #expect(try await comments() == ["Narrower", nil])

        let taken = try await page.run("window.tildeDraw.takeNewShapes()") as? String ?? ""
        #expect(taken.contains(#""comment":"Narrower""#))
    }

    private func typeComment(_ text: String) async throws {
        try await page.run("(() => { const field = document.getElementById('tilde-comment-field'); field.value = '\(text)'; return 0; })()")
    }

    private func comments() async throws -> [String?] {
        try await page.rawShapes().map { $0["comment"] as? String }
    }

    // MARK: - Esc

    /// Esc steps back one level at a time: the kinds, then the selection; only with nothing
    /// selected does it reach Tilde, which puts the tool down.
    @Test func escStepsBackBeforeItReachesTilde() async throws {
        try await drawComponent("card")
        try await page.click(inside)
        try await page.click(on: Self.chip)
        #expect(try await page.shows("[data-kind=\"card\"]"))

        #expect(try await page.press("Escape"))
        #expect(try await !page.shows("[data-kind=\"card\"]"))
        #expect(!page.messages.contains("escape"))

        #expect(try await page.press("Escape"))
        #expect(!page.messages.contains("escape"))

        #expect(try await page.press("Escape"))
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
        try await start(tool: "")
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

        try await start(tool: "")
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
        #expect(page.messages.last == "noTool")
        #expect(try await !page.takesPointer(CGPoint(x: 600, y: 400)))
        try await page.drag(from: CGPoint(x: 600, y: 400), to: CGPoint(x: 800, y: 600))
        #expect(try await page.shapes().isEmpty)
        #expect(page.messages.filter { $0 == "shape" }.count == 1)

        try await page.draw("setTool('ellipse')")
        try await page.drag(from: CGPoint(x: 600, y: 400), to: CGPoint(x: 800, y: 600))
        try await page.wait { self.page.messages.filter { $0 == "shape" }.count == 2 }
        #expect(try await page.rawShapes().first?["type"] as? String == "ellipse")
    }

    /// The chip goes just below the component, at its left edge, clear of the label's tag. The
    /// pointer gets from the component to the chip without the chip going.
    @Test func theChipIsBelowTheComponent() async throws {
        try await restore("[{type: 'card', rect: [200, 150, 240, 120], label: 'Plan'}]")
        try await page.hover(inside)
        #expect(try await chipBox() == [200, 276, chipWidth()])

        try await page.hover(CGPoint(x: 210, y: 273))
        #expect(try await page.shows("#tilde-chip"))
        try await page.hover(CGPoint(x: 210, y: 287))
        #expect(try await page.shows("#tilde-chip"))
    }

    /// At the bottom of the screen the chip goes just above the component, after its tag, as the
    /// tag shows: with no label, "Add label" while the pointer is over it.
    @Test func atTheBottomTheChipIsAboveTheComponentAfterTheTag() async throws {
        try await restore("[{type: 'card', rect: [300, 720, 200, 60], label: 'Plan'}, {type: 'card', rect: [700, 720, 200, 60]}]")
        try await page.hover(CGPoint(x: 400, y: 750))
        // The tag "Plan" is 38 wide; the chip is 22 high and 2 above the component.
        #expect(try await chipBox() == [342, 696, chipWidth()])

        try await page.hover(CGPoint(x: 800, y: 750))
        // "Add label" makes the tag 73 wide.
        #expect(try await chipBox() == [777, 696, chipWidth()])
        try await page.hover(CGPoint(x: 790, y: 719))
        #expect(try await page.shows("#tilde-chip"))
    }

    /// The chip stays on the screen at its left and right edges, and is wider than a narrow
    /// component.
    @Test func theChipStaysOnTheScreen() async throws {
        try await restore("[{type: 'card', rect: [-60, 100, 200, 80]}, {type: 'table', rect: [1100, 300, 90, 80]}, {type: 'button', rect: [600, 500, 20, 40]}]")
        try await page.hover(CGPoint(x: 50, y: 140))
        #expect(try await chipBox() == [0, 186, chipWidth()])

        try await page.hover(CGPoint(x: 1150, y: 340))
        let width = try await chipWidth()
        let right = try await chipBox()
        #expect(right == [CanvasPage.size.width - width, 386, width], "\(right), \(width)")

        try await page.hover(CGPoint(x: 610, y: 520))
        #expect(try await chipBox() == [600, 546, chipWidth()])
        #expect(try await chipWidth() > 20)
    }

    /// The Borders button shows the borders that are on, and opens a menu of all borders and
    /// each side, with what is on checked. It stays open while borders change, and closes on a
    /// second click on the button, on Esc and on a click elsewhere. Near the screen's corner it
    /// stays on the screen.
    @Test func theBordersMenuSetsEachSide() async throws {
        try await drawComponent("card")
        try await page.hover(inside)
        #expect(try await page.run("document.querySelectorAll('\(Self.bordersButton) path[stroke-width=\"2.5\"]').length") as? Int == 4)
        #expect(try await !page.shows("#tilde-borders"))

        try await page.click(on: Self.bordersButton)
        #expect(try await page.shows("#tilde-borders"))
        #expect(try await checked() == ["All borders": true, "Top": true, "Right": true, "Bottom": true, "Left": true])
        try await page.click(on: "#tilde-borders [data-action=\"border:top\"]")
        #expect(try await page.shapes().map(\.borders) == [["right", "bottom", "left"]])
        #expect(try await checked() == ["All borders": false, "Top": false, "Right": true, "Bottom": true, "Left": true])
        #expect(try await page.run("document.querySelectorAll('\(Self.bordersButton) path[stroke-width=\"2.5\"]').length") as? Int == 3)
        try await page.click(on: "#tilde-borders [data-action=\"border:all\"]")
        #expect(try await page.shapes().map(\.borders) == [allBorders])
        #expect(try await page.shows("#tilde-borders"))

        try await page.click(on: Self.bordersButton)
        #expect(try await !page.shows("#tilde-borders"))
        try await page.click(on: Self.bordersButton)
        try await page.press("Escape")
        #expect(try await !page.shows("#tilde-borders"))
        #expect(!page.messages.contains("escape"))
        try await page.click(on: Self.bordersButton)
        try await page.click(CGPoint(x: 900, y: 100))
        #expect(try await !page.shows("#tilde-borders"))

        try await restore("[{type: 'card', rect: [1080, 740, 110, 50]}]")
        try await page.hover(CGPoint(x: 1130, y: 760))
        try await page.click(on: Self.bordersButton)
        let menu = try await box(of: "#tilde-borders")
        #expect(menu[0] >= 0 && menu[0] + menu[2] <= CanvasPage.size.width)
        #expect(menu[1] >= 0 && menu[1] + menu[3] <= CanvasPage.size.height)
    }

    private func restore(_ shapes: String) async throws {
        try await start(tool: "card")
        try await page.draw("restoreWireframe({shapes: \(shapes), origin: [0, 0]})")
    }

    /// x, y, width and height of an element of the page.
    private func box(of selector: String) async throws -> [Double] {
        let script = "(() => { const box = document.querySelector('\(selector)').getBoundingClientRect(); return [box.left, box.top, box.width, box.height]; })()"
        return (try await page.run(script) as? [NSNumber] ?? []).map(\.doubleValue)
    }

    /// The chip's left, top and width.
    private func chipBox() async throws -> [Double] {
        let box = try await box(of: "#tilde-chip")
        #expect(box.count == 4 && box[3] == 22)
        return Array(box.prefix(3))
    }

    private func chipWidth() async throws -> Double {
        try await box(of: "#tilde-chip")[2]
    }

    /// Each row of the borders menu, and whether it is checked.
    private func checked() async throws -> [String: Bool] {
        let script = "JSON.stringify(Object.fromEntries([...document.querySelectorAll('#tilde-borders [role=menuitemcheckbox]')].map((row) => [row.textContent.replace('✓', ''), row.getAttribute('aria-checked') === 'true'])))"
        let text = try await page.run(script) as? String ?? "{}"
        return (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Bool]) ?? [:]
    }

    /// The handles of a component: the chip just below it, the square at each corner, and the
    /// grip on its top edge.
    private static let chip = "#tilde-chip"
    private static let bordersButton = "#tilde-chip [data-menu=\"borders\"]"
    private static let resizer = "[data-corner=\"se\"]"
}
