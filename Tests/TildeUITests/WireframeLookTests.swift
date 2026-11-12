@testable import TildeUI
import AppKit
import Testing

/// The look of wireframe components on the drawing canvas's page: each style's marks, the fill
/// and the fade of Settings, the label tag, and the shapes that Tilde blurs the screen under.
/// The page is the real one, in no window; each test has its own.
@MainActor
struct WireframeLookTests {
    let page: CanvasPage

    init() async throws {
        page = CanvasPage()
        try await page.load()
    }

    private func setLook(_ style: String, fill: Double = 0.22, fade: Double = 0.45) async throws {
        try await page.draw("setWireframeLook({style: '\(style)', fill: \(fill), fade: \(fade)})")
    }

    /// Components as a note's report has them, from the top left of the page.
    private func restore(_ shapes: String) async throws {
        try await page.draw("restoreWireframe({shapes: \(shapes), origin: [0, 0]})")
    }

    /// How many elements of the look match a CSS selector.
    private func count(_ selector: String) async throws -> Int {
        try await page.run("document.querySelectorAll('#tilde-look \(selector)').length") as? Int ?? -1
    }

    /// The shapes in the page's last message to blur under.
    private func under() throws -> String? {
        page.messages.last { $0.hasPrefix("under:") }.map { String($0.dropFirst("under:".count)) }
    }

    /// A style change redraws the components already drawn, at once, with the marks of the
    /// style: Technical's offset edge, Hatched's lines, Construction's dashes and ticks,
    /// Blueprint's lines past the corners.
    @Test func eachStyleRedrawsTheComponentsAtOnce() async throws {
        try await page.draw("setWireframe({tool: 'card', icons: {}})")
        try await page.drag(from: CGPoint(x: 200, y: 150), to: CGPoint(x: 440, y: 270))
        let offsetEdge = ##"path[stroke="#1D5BD8"][stroke-width="3"]"##
        let hatching = ##"[fill="url(#tilde-hatch)"]"##
        let dashes = ##"[stroke-dasharray="5 4"]"##
        // The top and the bottom border, 7 pt longer at each end.
        let pastTheCorners = ##"line[x1="193"][x2="447"]"##

        #expect(try await count(offsetEdge) == 1)
        #expect(try await count(##"rect[fill="none"][stroke-width="2"]"##) == 1)
        #expect(try await count(hatching) == 0)

        try await setLook("hatched")
        #expect(try await count(hatching) == 1)
        #expect(try await count(offsetEdge) == 0)

        try await setLook("construction")
        #expect(try await count(dashes) == 1)
        #expect(try await count(##"path[stroke-width="1.5"]"##) == 4)
        #expect(try await count(hatching) == 0)

        try await setLook("blueprint")
        #expect(try await count(pastTheCorners) == 2)
        #expect(try await count(dashes) == 0)

        try await setLook("technical")
        #expect(try await count(offsetEdge) == 1)
        #expect(try await count(pastTheCorners) == 0)
    }

    /// Fill sets the opacity of the blue in each component, and of a button's inside; Fade sets
    /// the white over the screen under each one.
    @Test func fillAndFadeSetTheBlueAndTheWhite() async throws {
        try await restore("[{type: 'card', rect: [100, 100, 200, 80]}, {type: 'button', rect: [400, 100, 100, 40]}]")
        #expect(try await count(##"rect[fill="#2F7BF6"][fill-opacity="0.22"]"##) == 2)
        #expect(try await count(##"rect[fill="#FFFFFF"][fill-opacity="0.45"]"##) == 2)

        try await setLook("technical", fill: 0.4, fade: 0)
        #expect(try await count(##"rect[fill="#2F7BF6"][fill-opacity="0.4"]"##) == 2)
        #expect(try await count(##"rect[fill="#2F7BF6"][fill-opacity="1"]"##) == 1)
        #expect(try await count(##"rect[fill="#FFFFFF"][fill-opacity="0"]"##) == 2)
    }

    /// The page tells Tilde the shapes to blur the screen under: each component with a fill,
    /// where it is now. An outline has no fill; a circle is an ellipse.
    @Test func theBlurFollowsTheComponentsWithAFill() async throws {
        try await page.draw("setWireframe({tool: 'card', icons: {}})")
        try await restore("[{type: 'card', rect: [10, 10, 100, 50]}, {type: 'rectangle', rect: [200, 10, 100, 50], filled: false}, {type: 'ellipse', rect: [400, 10, 60, 60], filled: true}]")
        #expect(try under() == "[[10,10,100,50,0],[400,10,60,60,1]]")
        // An outline has no white under it either.
        #expect(try await count(##"rect[fill="#FFFFFF"]"##) == 1)

        try await page.draw("setWireframe({tool: '', icons: {}})")
        try await page.drag(from: CGPoint(x: 60, y: 35), to: CGPoint(x: 60, y: 135))
        #expect(try under() == "[[10,110,100,50,0],[400,10,60,60,1]]")

        try await page.draw("clear()")
        #expect(try under() == "[]")
    }

    /// The label is a tag on the component's top left edge, or inside it at the top of the
    /// screen; a double-click types it in place, on the tag.
    @Test func theLabelIsATagAtTheTopLeft() async throws {
        try await page.draw("setWireframe({tool: 'card', icons: {}})")
        try await restore("[{type: 'card', rect: [200, 150, 240, 120], label: 'Plan'}, {type: 'list', rect: [500, 5, 100, 200], label: 'Tags'}]")
        #expect(try await page.run("[...document.querySelectorAll('#tilde-look text')].map((text) => text.textContent).join()") as? String == "Plan,Tags")
        #expect(try await count(##"rect[x="200"][y="133"][width="38"][height="15"]"##) == 1)
        #expect(try await count(##"rect[x="500"][y="7"]"##) == 1)

        try await page.click(CGPoint(x: 320, y: 210))
        try await page.click(CGPoint(x: 320, y: 210))
        #expect(try await page.shows("#tilde-label"))
        #expect(try await page.run("[getComputedStyle(document.getElementById('tilde-label')).left, getComputedStyle(document.getElementById('tilde-label')).top].join()") as? String == "200px,133px")
        // While it is typed, the tag shows only in the field.
        #expect(try await count("text") == 1)
    }

    /// While a component is drawn, it shows in the look of its tool, as it will be.
    @Test func theComponentBeingDrawnShowsAsItWillBe() async throws {
        try await page.draw("setWireframe({tool: 'list', icons: {}})")
        try await page.run("fire('pointermove', 200, 150); window.pressed = fire('pointerdown', 200, 150); fire('pointermove', 300, 270, {isPressed: true, target: window.pressed}); 0")
        try await page.settle()
        // The lines between its rows, and no content.
        #expect(try await count(##"line[stroke="#2F7BF6"]"##) >= 2)
        #expect(try await count(##"rect[height="6"]"##) == 0)
        #expect(try await count(##"path[stroke="#1D5BD8"][stroke-width="3"]"##) == 1)

        try await page.run("fire('pointerup', 300, 270, {target: window.pressed}); 0")
        try await page.settle()
        #expect(try await page.shapes().map(\.type) == ["list"])
        #expect(try await count(##"line[stroke="#2F7BF6"]"##) >= 2)
    }

    /// No component shows content, which is not known: a card, a section, a rectangle and a
    /// circle each have one darker block a padding in (less in a small one), a dropdown one in
    /// its value's place. A table, a list and a button keep only the lines and the fill of
    /// their kind. An outline has no block.
    @Test func eachComponentHasOneInnerBlockInPlaceOfContent() async throws {
        try await restore(
            "[{type: 'card', rect: [100, 100, 240, 120]}, {type: 'card', rect: [400, 100, 60, 30]}, {type: 'dropdown', rect: [500, 100, 160, 30]}, "
                + "{type: 'ellipse', rect: [700, 100, 100, 80], filled: true}, {type: 'rectangle', rect: [850, 100, 100, 80], filled: false}, "
                + "{type: 'table', rect: [100, 300, 240, 120]}, {type: 'list', rect: [400, 300, 100, 120]}, {type: 'button', rect: [550, 300, 80, 30]}]"
        )
        let block = ##"[fill="#1D5BD8"][fill-opacity="0.132"]"##
        #expect(try await count(block) == 4)
        #expect(try await count(##"rect[x="112"][y="112"][width="216"][height="96"]"## + block) == 1)
        // 30 high: a padding of 6.
        #expect(try await count(##"rect[x="406"][y="106"][width="48"][height="18"]"## + block) == 1)
        #expect(try await count(##"rect[x="506"][y="106"][width="114"][height="18"]"## + block) == 1)
        #expect(try await count("ellipse" + block) == 1)
        #expect(try await count(##"rect[height="6"]"##) == 0)
    }

    /// Every component has a tag, also with no label: a short empty one. With the pointer over
    /// the component, or over its tag, the tag is active and says "Add label"; then empty again.
    @Test func anEmptyTagSaysAddLabelUnderThePointer() async throws {
        try await page.draw("setWireframe({tool: 'card', icons: {}})")
        try await restore("[{type: 'card', rect: [200, 150, 240, 120]}]")
        let emptyTag = ##"rect[x="200"][y="133"][width="28"][height="15"][fill="#2F7BF6"]"##
        #expect(try await count(emptyTag) == 1)
        #expect(try await count("text") == 0)

        try await page.hover(CGPoint(x: 320, y: 210))
        #expect(try await count(##"rect[x="200"][y="133"][width="73"][fill="#1D5BD8"]"##) == 1)
        #expect(try await texts() == "Add label")
        try await page.hover(CGPoint(x: 260, y: 140))
        #expect(try await texts() == "Add label")

        try await page.hover(CGPoint(x: 800, y: 600))
        #expect(try await count(emptyTag) == 1)
        #expect(try await count("text") == 0)
    }

    /// Done takes the components for the agent's pictures: an empty tag goes, a label stays.
    @Test func doneLeavesNoEmptyTagInThePictures() async throws {
        try await page.draw("setWireframe({tool: 'card', icons: {}})")
        try await restore("[{type: 'card', rect: [200, 150, 240, 120]}, {type: 'card', rect: [600, 150, 240, 120], label: 'Plan'}]")
        #expect(try await count(##"rect[height="15"]"##) == 2)

        _ = try await page.takeShapes()
        #expect(try await count(##"rect[height="15"]"##) == 1)
        #expect(try await texts() == "Plan")
    }

    /// A click on a tag types the label in place, on the tag, which grows with the text. Return
    /// or a click elsewhere keeps it; Esc keeps the label as it was.
    @Test func aClickOnTheTagEditsTheLabel() async throws {
        try await page.draw("setWireframe({tool: 'card', icons: {}})")
        try await restore("[{type: 'card', rect: [200, 150, 240, 120]}]")
        try await page.click(CGPoint(x: 210, y: 140))
        #expect(try await page.shows("#tilde-label"))
        let place = "[getComputedStyle(document.getElementById('tilde-label')).left, getComputedStyle(document.getElementById('tilde-label')).top].join()"
        #expect(try await page.run(place) as? String == "200px,133px")
        try await page.typeLabel("Pricing plans")
        #expect(try await page.run("document.getElementById('tilde-label').style.width") as? String == "101px")
        try await page.press("Enter")
        #expect(try await page.shapes().map(\.label) == ["Pricing plans"])
        #expect(try await page.shapes().map(\.rect) == [[200, 150, 240, 120]])

        try await page.click(CGPoint(x: 210, y: 140))
        try await page.typeLabel("Plans")
        try await page.press("Escape")
        #expect(try await page.shapes().map(\.label) == ["Pricing plans"])

        try await page.click(CGPoint(x: 210, y: 140))
        try await page.typeLabel("Plans")
        try await page.click(CGPoint(x: 800, y: 600))
        #expect(try await page.shapes().map(\.label) == ["Plans"])
        #expect(try await texts() == "Plans")
    }

    /// The texts of the look, joined with commas.
    private func texts() async throws -> String? {
        try await page.run("[...document.querySelectorAll('#tilde-look text')].map((text) => text.textContent).join()") as? String
    }

    /// Wireframe mode draws with no colour of Excalidraw's own; Draw, after it, draws in its
    /// colour again.
    @Test func drawKeepsItsColourAfterWireframeMode() async throws {
        try await page.draw("setColor('#FF3B30')")
        try await page.draw("setWireframe({tool: 'card', icons: {}})")
        try await page.draw("setWireframe(null)")
        try await page.draw("setTool('arrow')")
        try await page.drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 200))
        let shapes = try await page.rawShapes()
        #expect(shapes.map { $0["color"] as? String } == ["#FF3B30"])
    }

    /// The look is the default until Settings change it; a value out of its range is kept to it.
    @Test func theSavedLookStaysInItsRanges() throws {
        let name = "WireframeLookTests"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(WireframeLook.saved(in: defaults) == WireframeLook())

        defaults.set("hatched", forKey: WireframeLook.Key.style)
        defaults.set(0.9, forKey: WireframeLook.Key.fill)
        defaults.set(-1.0, forKey: WireframeLook.Key.blur)
        defaults.set(0.5, forKey: WireframeLook.Key.fade)
        #expect(WireframeLook.saved(in: defaults) == WireframeLook(style: .hatched, fill: 0.6, blur: 0, fade: 0.5))
    }
}

/// The pictures of the Appearance page: the canvas's own page draws a tile for each style and
/// the component in each state, and draws nothing again for the same look.
@MainActor
struct WireframePreviewsTests {
    @Test func eachStyleAndStateIsDrawnOnceForALook() async throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/TildeUI/DrawingWeb")
        let previews = WireframePreviews(html: { DrawingCanvas.page(in: folder) })
        let look = WireframeLook(style: .hatched, fill: 0.3, blur: 2, fade: 0.5)
        try await previews.draw(look)
        #expect(Set(previews.tiles.keys) == Set(WireframeLook.Style.allCases))
        #expect(Set(previews.states.keys) == Set(WireframePreviews.State.allCases))
        #expect(previews.tiles.values.allSatisfy { $0.size == WireframePreviews.tileSize })

        let tiles = previews.tiles
        previews.show(look)
        #expect(previews.tiles == tiles)
        #expect(!previews.isDrawing)
        previews.stop()
    }
}
