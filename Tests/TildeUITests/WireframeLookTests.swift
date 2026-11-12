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
    /// style: Technical's offset edge, Hatched's lines, Construction's dashes, ticks and image
    /// cross, Blueprint's lines past the corners.
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
        #expect(try await count(dashes) >= 4)
        #expect(try await count(##"path[stroke-width="1.5"]"##) == 4)
        #expect(try await count(##"rect[x="390"][width="38"]"##) == 1)
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
        #expect(try await count(##"rect[fill="#1D5BD8"]"##) == 3)
        #expect(try await count(##"path[stroke="#1D5BD8"][stroke-width="3"]"##) == 1)

        try await page.run("fire('pointerup', 300, 270, {target: window.pressed}); 0")
        try await page.settle()
        #expect(try await page.shapes().map(\.type) == ["list"])
        #expect(try await count(##"rect[fill="#1D5BD8"]"##) == 3)
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
