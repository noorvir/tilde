@testable import TildeUI
import TildeCore
import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing

/// The mode a session starts in, and the mode that is kept for the next session.
struct StartModeTests {
    typealias Open = SessionFlow.Open
    typealias StartMode = SessionFlow.StartMode

    /// A session starts in the mode that was on last, in annotation mode until one is saved.
    /// In Tilde's browser it starts with no mode, so the user can type an address first.
    @Test func aSessionStartsInTheModeThatWasOnLast() {
        #expect(StartMode(saved: nil, inBrowser: false) == .annotating)
        #expect(StartMode(saved: "annotating", inBrowser: false) == .annotating)
        #expect(StartMode(saved: "none", inBrowser: false) == .noMode)
        #expect(StartMode(saved: "draw", inBrowser: false) == .draw)
        #expect(StartMode(saved: "wireframe", inBrowser: false) == .wireframe)
        #expect(StartMode(saved: "recording", inBrowser: false) == .annotating)
        for saved in [nil, "annotating", "none", "draw", "wireframe"] {
            #expect(StartMode(saved: saved, inBrowser: true) == .noMode)
        }
    }

    /// A session begins with no mode; the start mode's event then turns that mode on, and that
    /// mode is the one to keep.
    @Test(arguments: [StartMode.annotating, .noMode, .draw, .wireframe])
    func aStartModesEventTurnsTheModeOn(mode: StartMode) {
        var flow = SessionFlow(mode: .idle)
        _ = flow.handle(.begin, SessionFlow.Facts())
        #expect(flow.startMode == .noMode)

        if let event = mode.event {
            _ = flow.handle(event, SessionFlow.Facts())
        }
        #expect(flow.startMode == mode)
        #expect(flow.isAnnotating == (mode == .annotating))
        #expect(flow.isWireframe == (mode == .wireframe))
        #expect(flow.session?.isDrawing == (mode == .draw || mode == .wireframe))
    }

    /// The mode on screen is kept, also through a pause of Draw or Wireframe. Recording mode
    /// counts as no mode. A state that is no mode of the user's choice keeps nothing: choosing,
    /// the hold key, another app in front, sending, no session.
    @Test func theModeOnScreenIsTheModeToKeep() {
        func kept(_ open: Open) -> StartMode? {
            SessionFlow(mode: .open(open)).startMode
        }
        #expect(kept(Open()) == .annotating)
        #expect(kept(Open(pauses: [.user])) == .noMode)
        #expect(kept(Open(pauses: [.user, .otherApp])) == .noMode)
        #expect(kept(Open(canvas: .draw)) == .draw)
        #expect(kept(Open(pauses: [.user], canvas: .draw)) == .draw)
        #expect(kept(Open(canvas: .wireframe)) == .wireframe)
        #expect(kept(Open(pauses: [.hold], canvas: .wireframe)) == .wireframe)
        #expect(kept(Open(activity: .recording(.ready))) == .noMode)
        #expect(kept(Open(activity: .recording(.recording))) == .noMode)

        #expect(kept(Open(activity: .picking(isPickerOpen: false))) == nil)
        #expect(kept(Open(pauses: [.hold])) == nil)
        #expect(kept(Open(pauses: [.otherApp])) == nil)
        #expect(SessionFlow(mode: .sending(operation: 1, returnTo: Open())).startMode == nil)
        #expect(SessionFlow(mode: .idle).startMode == nil)
    }
}

/// Wireframe mode and Draw's tool, without the canvas's window: the controller, the parts and
/// the keys. The canvas's page has its own tests.
@MainActor
@Suite(.serialized)
struct WireframeTests {
    typealias Open = SessionFlow.Open
    let controller: AnnotationController

    init() async throws {
        controller = try await Fixtures.controller()
    }

    private func open(_ open: Open, drafts: [Draft] = []) {
        controller.setStateForTesting(session: Fixtures.session(), drafts: drafts, mode: .open(open))
    }

    /// A key as the keyboard gives it: its character, its key code and its modifiers.
    private func key(_ characters: String, code: Int = 0, modifiers: NSEvent.ModifierFlags = [], isRepeat: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: UInt16(code)
        ))
    }

    // MARK: - Tools

    /// Wireframe mode starts with the card; a tool's button or letter chooses the tool, in
    /// upper case too, and the mode stays.
    @Test func aToolsLetterChoosesTheWireframeTool() throws {
        open(Open(canvas: .draw))
        controller.dispatch(.startWireframe)
        #expect(controller.isWireframe)
        #expect(controller.wireframe.tool == "card")

        for (tool, _, letter, _) in WireframeMode.tools {
            #expect(controller.handleKey(try key(letter), in: .canvas))
            #expect(controller.wireframe.tool == tool)
        }
        #expect(controller.handleKey(try key("G", modifiers: .shift), in: .overlay(hoveredNote: nil)))
        #expect(controller.wireframe.tool == "table")
        controller.setWireframeTool("button")
        #expect(controller.wireframe.tool == "button")
        #expect(controller.isWireframe)
    }

    /// In wireframe mode the other letters and the digits are taken and do nothing: no tool or
    /// colour of Draw, and no other mode. A key with ⌘ is not one of them.
    @Test func otherLettersAndDigitsDoNothingInWireframeMode() throws {
        open(Open(canvas: .wireframe))
        controller.setWireframeTool("list")
        let drawTool = controller.drawing.tool
        let color = controller.drawing.color

        for letter in ["a", "p", "w", "q", "1", "6"] {
            #expect(controller.handleKey(try key(letter), in: .canvas), "\(letter) was not taken")
        }
        #expect(controller.wireframe.tool == "list")
        #expect(controller.drawing.tool == drawTool)
        #expect(controller.drawing.color == color)
        #expect(controller.isWireframe)
        #expect(controller.pauses.isEmpty)

        // ⌘Z undoes the canvas's last change.
        #expect(controller.handleKey(try key("z", code: kVK_ANSI_Z, modifiers: .command), in: .canvas))
        #expect(controller.isWireframe)
    }

    /// The wireframe tools' letters are Draw's and the modes' letters outside wireframe mode.
    @Test func aWireframeToolsLetterIsNoWireframeKeyOutsideTheMode() throws {
        open(Open(canvas: .draw))
        #expect(controller.handleKey(try key("r", code: kVK_ANSI_R), in: .canvas))
        #expect(controller.drawing.tool == "rectangle")
        #expect(controller.wireframe.tool == "card")
        #expect(!controller.isWireframe)
    }

    // MARK: - The draft

    /// A switch to Annotate or to Draw while a wireframe is drawn keeps it in the list as a
    /// draft, with the picture of its components: never one with no picture.
    @Test func aSwitchOfModeKeepsTheWireframeAsADraftWithItsPicture() async throws {
        for event in [SessionFlow.Event.toggleAnnotating, .startDrawing] {
            open(Open(canvas: .wireframe))
            // The canvas has one card that no note has taken, and the screen gives its picture.
            controller.wireframe.newShapes = { done in
                let card = Fixtures.wireframeShapes[0]
                done(DrawingPanel.Drawing(shapes: [card], ids: ["a"], bounds: DrawingShapes.bounds(of: [card])))
            }
            controller.wireframe.scope = { Fixtures.window }
            controller.wireframe.pictures = { _ in Captures(image: Fixtures.closeUp(0), contextImage: Fixtures.context(0)) }

            // The canvas's window is not opened here.
            controller.dispatch(event, with: [.showCanvas: {}])
            #expect(!controller.isWireframe)
            try await until { controller.drafts.first?.annotation.image != nil }

            let draft = try #require(controller.drafts.first)
            #expect(controller.drafts.count == 1)
            #expect(draft.isWireframe)
            #expect(draft.isUnfinished)
            #expect(draft.annotation.image == Fixtures.closeUp(0))
            #expect(draft.annotation.contextImage == Fixtures.context(0))
            #expect(WireframeMode.Saved(draft)?.shapes.count == 1)
        }
    }

    /// The draft of the wireframe that is drawn has no label while its components are on the
    /// canvas: a press on its top-right corner, where the label would be, finds none, so it is
    /// for the corner's handle and opens no preview. The label is back when the mode ends.
    @Test func theDraftOfTheWireframeOnTheCanvasHasNoLabel() async throws {
        open(Open(canvas: .wireframe))
        let card = Fixtures.wireframeShapes[0]
        let bounds = DrawingShapes.bounds(of: [card])
        controller.wireframe.newShapes = { done in
            done(DrawingPanel.Drawing(shapes: [card], ids: ["a"], bounds: bounds))
        }
        controller.wireframe.scope = { Fixtures.window }
        controller.wireframe.pictures = { _ in Captures(image: Fixtures.closeUp(0), contextImage: Fixtures.context(0)) }

        // A change on the canvas saves the draft.
        controller.drawing.panel.onCanvasChanged()
        try await until { controller.wireframe.shownNote != nil }
        let draft = try #require(controller.drafts.first)
        let corner = CGPoint(x: bounds.maxX, y: bounds.minY)
        #expect(draft.marker == corner)
        #expect(controller.tracker.label(at: corner) == nil)

        controller.dispatch(.toggleAnnotating, with: [.showCanvas: {}])
        try await until { controller.tracker.label(at: corner) == draft.id }
    }

    /// The draft that a change saves takes no pictures: to make them takes the processor from
    /// the canvas while the user moves the components or their window. The mode's end makes
    /// them, and until then a note that is drawn again keeps the pictures it has.
    @Test func theDraftSavedWhileTheWireframeChangesTakesNoPictures() async throws {
        open(Open(canvas: .wireframe))
        let card = Fixtures.wireframeShapes[0]
        controller.wireframe.newShapes = { done in
            done(DrawingPanel.Drawing(shapes: [card], ids: ["a"], bounds: DrawingShapes.bounds(of: [card])))
        }
        controller.wireframe.scope = { Fixtures.window }
        var taken = 0
        controller.wireframe.pictures = { _ in
            taken += 1
            return Captures(image: Fixtures.closeUp(0), contextImage: Fixtures.context(0))
        }

        controller.drawing.panel.onCanvasChanged()
        try await until { controller.wireframe.shownNote != nil }
        #expect(taken == 0)
        #expect(controller.drafts.first?.annotation.image == nil)

        controller.dispatch(.toggleAnnotating, with: [.showCanvas: {}])
        try await until { controller.drafts.first?.annotation.image != nil }
        #expect(taken == 1)
        #expect(controller.drafts.count == 1)
    }

    // MARK: - Esc

    /// Esc in wireframe mode puts the tool down: no tool is on, the mode stays and nothing
    /// pauses, so the components can still be selected and changed, and the pointer goes
    /// through to the apps behind elsewhere. A tool draws again.
    @Test func escPutsTheWireframeToolDown() throws {
        open(Open(canvas: .wireframe))
        controller.setWireframeTool("table")
        #expect(!controller.isToolDown)

        controller.escapePressed()
        #expect(controller.wireframe.tool == nil)
        #expect(controller.isToolDown)
        #expect(controller.isWireframe)
        #expect(controller.pauses.isEmpty)
        // Esc again changes nothing: it never ends the mode or the session.
        controller.escapePressed()
        #expect(controller.wireframe.tool == nil)
        #expect(controller.isWireframe)
        #expect(controller.session != nil)

        #expect(controller.handleKey(try key("b"), in: .canvas))
        #expect(controller.wireframe.tool == "button")
        #expect(!controller.isToolDown)
    }

    /// The session holds the keyboard, and with it Esc system-wide, in every mode and after Esc
    /// paused it. A pause by the user gives the keyboard to the app in front until the session
    /// goes on; another app in front that pauses the session keeps it too.
    @Test func theSessionHoldsTheKeyboardUntilTheUserPauses() {
        let controller = AnnotationController(store: SessionStore(), browser: BrowserController(), archive: Fixtures.archive(), defaults: MemoryDefaults())
        controller.setStateForTesting(session: Fixtures.session(), mode: .open(Open(pauses: [.user])))
        controller.dispatch(.toggleAnnotating)
        #expect(controller.holdsKeyboard)

        controller.dispatch(.togglePause)
        #expect(!controller.holdsKeyboard)
        controller.dispatch(.togglePause)
        #expect(controller.holdsKeyboard)

        controller.escapePressed()
        #expect(controller.pauses == [.user])
        #expect(controller.holdsKeyboard)

        // The canvas's window is not opened here.
        controller.dispatch(.startDrawing, with: [.showCanvas: {}])
        #expect(controller.holdsKeyboard)
        controller.dispatch(.togglePause)
        #expect(!controller.holdsKeyboard)
        controller.dispatch(.togglePause)
        controller.dispatch(.toggleAnnotating)
        #expect(controller.holdsKeyboard)

        controller.dispatch(.otherAppInFront)
        #expect(!controller.holdsKeyboard)
        controller.dispatch(.scopeAppInFront)
        #expect(controller.holdsKeyboard)

        controller.dispatch(.requestCancel)
        #expect(controller.session == nil)
        #expect(!controller.holdsKeyboard)
    }

    /// Esc in Draw puts Draw's tool down, and its tool is kept for the next time; a tool's
    /// button or key takes a tool up again.
    @Test func escPutsDrawsToolDown() {
        open(Open(canvas: .draw))
        controller.setDrawingTool("ellipse")
        #expect(!controller.drawing.isToolDown)

        controller.escapePressed()
        #expect(controller.drawing.isToolDown)
        #expect(controller.isToolDown)
        #expect(controller.drawing.tool == "ellipse")
        #expect(controller.isDrawing)
        #expect(controller.pauses.isEmpty)
        #expect(controller.wireframe.tool == "card")

        controller.setDrawingTool("arrow")
        #expect(!controller.drawing.isToolDown)
        #expect(!controller.isToolDown)
        #expect(controller.drawing.tool == "arrow")
    }

    /// A new wireframe has a tool again after Esc put the last one's tool down.
    @Test func aNewWireframeStartsWithTheCard() {
        open(Open(canvas: .wireframe))
        controller.escapePressed()
        #expect(controller.wireframe.tool == nil)

        controller.dispatch(.toggleAnnotating)
        #expect(!controller.isWireframe)
        open(Open(canvas: .draw))
        controller.dispatch(.startWireframe)
        #expect(controller.wireframe.tool == "card")
    }

    // MARK: - Done, pause and the hold key

    /// ⌘↩ on the canvas and on the overlay is Done in wireframe mode, not Send: with nothing
    /// drawn, the mode ends in no mode and the notes stay.
    @Test(arguments: [true, false])
    func commandReturnIsDoneInWireframeMode(onCanvas: Bool) async throws {
        let controller = self.controller
        open(Open(canvas: .wireframe), drafts: Fixtures.drafts(2))
        let surface: KeySurface = onCanvas ? .canvas : .overlay(hoveredNote: nil)

        #expect(controller.handleKey(try key("\r", code: kVK_Return, modifiers: .command), in: surface))
        try await until { !controller.isWireframe }
        #expect(!controller.isDrawing)
        #expect(controller.pauses == [.user])
        #expect(controller.mode == .open(Open(pauses: [.user])))
        #expect(controller.drafts.count == 2)
    }

    /// The pause keeps wireframe mode and its tool; W resumes it, and no tool's letter acts
    /// meanwhile.
    @Test func aPauseKeepsWireframeModeAndWResumesIt() throws {
        open(Open(canvas: .wireframe))
        controller.setWireframeTool("list")
        controller.dispatch(.togglePause)
        #expect(controller.isWireframe)
        #expect(controller.isDrawingPaused)

        _ = controller.handleKey(try key("t"), in: .overlay(hoveredNote: nil))
        #expect(controller.wireframe.tool == "list")
        #expect(controller.isDrawingPaused)

        #expect(controller.handleKey(try key("w"), in: .overlay(hoveredNote: nil)))
        #expect(!controller.isDrawingPaused)
        #expect(controller.isWireframe)
        #expect(controller.wireframe.tool == "list")
    }

    /// The mode on screen goes to the defaults when it changes, for the next session.
    @Test func theModeOnScreenIsSavedForTheNextSession() throws {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: WireframeSwitch.key)
        let controller = AnnotationController(store: SessionStore(), browser: BrowserController(), archive: Fixtures.archive(), defaults: defaults)
        controller.setStateForTesting(session: Fixtures.session(), mode: .open(Open(pauses: [.user])))
        #expect(defaults.string(forKey: "LastMode") == nil)

        controller.dispatch(.toggleAnnotating)
        #expect(defaults.string(forKey: "LastMode") == "annotating")
        controller.dispatch(.togglePause)
        #expect(defaults.string(forKey: "LastMode") == "none")
        // The canvas's window is not opened here.
        controller.dispatch(.startDrawing, with: [.showCanvas: {}])
        #expect(defaults.string(forKey: "LastMode") == "draw")
        controller.dispatch(.startWireframe)
        #expect(defaults.string(forKey: "LastMode") == "wireframe")
        // The hold key and the session's end are no modes to keep.
        controller.dispatch(.toggleAnnotating)
        controller.dispatch(.holdBegan)
        #expect(defaults.string(forKey: "LastMode") == "annotating")
        controller.dispatch(.holdEnded)
        controller.dispatch(.requestCancel)
        #expect(controller.session == nil)
        #expect(defaults.string(forKey: "LastMode") == "annotating")
    }

    /// The sessions in a row that used neither Draw nor Wireframe are counted, for the choice
    /// to load the canvas ahead; a session that used one starts the count again.
    @Test func sessionsWithoutACanvasAreCounted() throws {
        let defaults = MemoryDefaults()
        let controller = AnnotationController(store: SessionStore(), browser: BrowserController(), archive: Fixtures.archive(), defaults: defaults)
        for count in 1...2 {
            controller.setStateForTesting(session: Fixtures.session(), mode: .open(Open(pauses: [.user])))
            controller.dispatch(.requestCancel)
            #expect(controller.session == nil)
            #expect(defaults.integer(forKey: "SessionsWithoutCanvas") == count)
        }

        controller.setStateForTesting(session: Fixtures.session(), mode: .open(Open(pauses: [.user])))
        // The canvas's window is not opened here.
        controller.dispatch(.startDrawing, with: [.showCanvas: {}])
        controller.dispatch(.requestCancel)
        #expect(controller.session == nil)
        #expect(defaults.integer(forKey: "SessionsWithoutCanvas") == 0)
    }

    /// The tool chosen last stays: after Esc put it down and the mode started again, and in
    /// the next session, from the defaults.
    @Test func wireframeModeStartsWithTheToolChosenLast() throws {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: WireframeSwitch.key)
        let controller = AnnotationController(store: SessionStore(), browser: BrowserController(), archive: Fixtures.archive(), defaults: defaults)
        controller.setStateForTesting(session: Fixtures.session(), mode: .open(Open()))
        controller.dispatch(.startWireframe)
        #expect(controller.wireframe.tool == "card")
        controller.setWireframeTool("table")
        controller.escapePressed()
        #expect(controller.wireframe.tool == nil)
        controller.dispatch(.toggleAnnotating)
        controller.dispatch(.startWireframe)
        #expect(controller.wireframe.tool == "table")

        let next = AnnotationController(store: SessionStore(), browser: BrowserController(), archive: Fixtures.archive(), defaults: defaults)
        #expect(next.wireframe.tool == "table")
    }

    /// The bar's Adjust popover closes first, then its style mode: on Esc, and on a press on
    /// the canvas, which does nothing more; the tool stays.
    @Test func escAndAPressCloseTheStyleControlsFirst() {
        open(Open(canvas: .wireframe))
        controller.wireframe.bar = WireframeBar(isStyling: true, isAdjusting: true)
        controller.escapePressed()
        #expect(controller.wireframe.bar == WireframeBar(isStyling: true, isAdjusting: false))
        controller.escapePressed()
        #expect(controller.wireframe.bar == WireframeBar())
        #expect(controller.wireframe.tool == "card")

        controller.wireframe.bar = WireframeBar(isStyling: true)
        #expect(controller.canvasPressed(at: CGPoint(x: 400, y: 300)))
        #expect(controller.wireframe.bar == WireframeBar())
        #expect(controller.isWireframe)
    }

    /// A session that ends in wireframe mode, such as by Cancel, ends the mode too: the canvas
    /// stays for the next session, whose bar shows the tools.
    @Test func aSessionThatEndsInWireframeModeEndsTheMode() {
        open(Open(canvas: .wireframe))
        controller.wireframe.bar = WireframeBar(isStyling: true, isAdjusting: true)
        controller.dispatch(.requestCancel)
        #expect(controller.session == nil)
        #expect(controller.wireframe.bar == WireframeBar())
    }

    /// A change from the bar goes to the defaults, which the canvas and Settings follow; a
    /// strength keeps to its range and steps.
    @Test func aChangeFromTheBarIsSaved() {
        let defaults = MemoryDefaults()
        let controller = AnnotationController(store: SessionStore(), browser: BrowserController(), archive: Fixtures.archive(), defaults: defaults)
        controller.wireframe.change(.style(.blueprint))
        controller.wireframe.change(.colours(.oneColour))
        controller.wireframe.change(.strength(.blur, 3.3))
        controller.wireframe.change(.strength(.fade, 2))

        let look = WireframeLook.saved(in: defaults)
        #expect(look.style == .blueprint)
        #expect(look.colours == .oneColour)
        #expect(look.blur == 3.5)
        #expect(look.fade == WireframeLook.fadeRange.upperBound)
        #expect(look.fill == WireframeLook().fill)
        #expect(defaults.object(forKey: WireframeLook.Key.fill) == nil)
    }

    // MARK: - The note and the report

    /// The report of a wireframe has its components from the top left of their window (or of
    /// the screen), with kind, label, borders and rows, without the canvas's ids, and says
    /// what the two pictures show.
    @Test func theReportHasTheComponentsFromTheirWindow() throws {
        let window = Fixtures.window.frame
        let text = WireframeMode.report(of: Fixtures.wireframeShapes, origin: window.origin, isOnWindow: true)
        let report = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])

        #expect(report["origin"] as? [Double] == [100, 100])
        #expect(report["originIs"] as? String == "window")
        #expect((report["wireframe"] as? String)?.contains("the image shows it drawn over the screen, the context image the screen under it") == true)
        let shapes = try #require(report["shapes"] as? [[String: Any]])
        #expect(shapes.count == 2)
        #expect(shapes[0]["type"] as? String == "card")
        #expect(shapes[0]["label"] as? String == "Plan")
        #expect(shapes[0]["rect"] as? [Double] == [40, 60, 240, 120])
        #expect(shapes[0]["borders"] as? [String] == ["top", "right", "bottom", "left"])
        #expect(shapes[0]["id"] == nil)
        #expect(shapes[0]["color"] == nil)
        #expect(shapes[1]["type"] as? String == "table")
        #expect(shapes[1]["rows"] as? Int == 3)
        #expect(shapes[1]["columns"] as? Int == 2)
        #expect(shapes[1]["rect"] as? [Double] == [40, 200, 400, 160])

        let onScreen = WireframeMode.report(of: Fixtures.wireframeShapes, origin: .zero, isOnWindow: false)
        #expect(onScreen.contains("\"originIs\":\"screen\""))
    }

    /// The agent gets a wireframe as a drawing: the components and what the pictures are, in
    /// the feedback's text.
    @Test func theFeedbackTextDescribesTheWireframe() {
        let draft = Fixtures.wireframe()
        let text = reportText(for: Feedback(annotations: [draft.annotation]), folder: nil)
        #expect(text.contains("Add a plan card"))
        #expect(text.contains("Drawing on the screen"))
        #expect(text.contains("\"type\":\"card\""))
        #expect(text.contains("\"label\":\"Plan\""))
        #expect(text.contains("A wireframe of the change"))
    }

    /// A wireframe's note gives its components back as they were drawn; another note gives none.
    @Test func aWireframeNoteGivesItsComponentsBack() throws {
        let draft = Fixtures.wireframe()
        #expect(draft.isWireframe)
        let saved = try #require(WireframeMode.Saved(draft))
        #expect(saved.origin == Fixtures.window.frame.origin)
        #expect(saved.isOnWindow)
        #expect(saved.shapes.map { $0["type"] as? String } == ["card", "table"])
        #expect(saved.shapes[0]["rect"] as? [Double] == [40, 60, 240, 120])

        for other in Fixtures.drafts(3) {
            #expect(!other.isWireframe)
            #expect(WireframeMode.Saved(other) == nil)
        }
        // A drawing of Draw mode is no wireframe.
        let drawing = Target.drawing(shapes: DrawingShapes.encode(Fixtures.wireframeShapes, origin: .zero, element: nil))
        let annotation = Annotation(comment: "", target: drawing, frame: .zero, image: nil, contextImage: nil)
        #expect(WireframeMode.Saved(Draft(annotation: annotation, marker: .zero, chip: "Drawing", capture: Task { Captures(image: nil, contextImage: nil) })) == nil)
    }

    /// A wireframe drawn again keeps its note: the same id, comment and chip, with the new
    /// components, frame, label place, window and pictures.
    @Test func aWireframeDrawnAgainKeepsItsNoteAndComment() async {
        let old = Fixtures.wireframe()
        let moved = Fixtures.wireframeShapes.map { DrawingShapes.moved($0, by: CGVector(dx: 50, dy: 20)) }
        let frame = DrawingShapes.bounds(of: moved)
        let window = ElementPicker.WindowInfo(number: 77, pid: 12, app: "Notes", title: nil, frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let pictures = Captures(image: Data([1]), contextImage: Data([2]))
        let note = NewNote(
            target: .drawing(shapes: WireframeMode.report(of: moved, origin: .zero, isOnWindow: true)), frame: frame,
            marker: CGPoint(x: frame.maxX, y: frame.minY), chip: WireframeMode.chip, window: window, captures: pictures, drawingIDs: ["a", "b"]
        )

        let redrawn = old.redrawn(as: note)
        #expect(redrawn.id == old.id)
        #expect(redrawn.annotation.comment == "Add a plan card")
        #expect(redrawn.chip == WireframeMode.chip)
        #expect(redrawn.annotation.frame == frame)
        #expect(redrawn.marker == CGPoint(x: frame.maxX, y: frame.minY))
        #expect(redrawn.annotation.image == Data([1]))
        #expect(redrawn.annotation.contextImage == Data([2]))
        #expect(redrawn.sourceWindow == 77)
        #expect(redrawn.sourcePID == 12)
        #expect(WireframeMode.Saved(redrawn)?.shapes.first?["rect"] as? [Double] == [190, 180, 240, 120])
        let captures = await redrawn.capture.value
        #expect(captures.image == Data([1]))
    }

    /// Edit Wireframe on a wireframe's note starts wireframe mode with the preview closed;
    /// on another note, or in wireframe mode, it does nothing.
    @Test func editWireframeStartsWireframeModeOnlyForAWireframeNote() {
        let wireframe = Fixtures.wireframe()
        let drafts = Fixtures.drafts(1) + [wireframe]
        controller.setStateForTesting(session: Fixtures.session(), drafts: drafts, mode: .open(Open(canvas: .draw, panel: .preview)), previewID: wireframe.id)

        controller.editWireframe(drafts[0].id)
        #expect(!controller.isWireframe)
        #expect(controller.previewCard.id == wireframe.id)

        controller.editWireframe(wireframe.id)
        #expect(controller.isWireframe)
        #expect(controller.previewCard.id == nil)
        #expect(controller.wireframe.tool == "card")
        #expect(controller.drafts.count == 2)
    }

    // MARK: - The HUD

    /// The pill keeps its width in Draw and Wireframe, paused or not: the two modes add no
    /// button and move none.
    @Test(arguments: [SessionFlow.Canvas.draw, .wireframe])
    func theCanvasModesKeepThePillWidth(canvas: SessionFlow.Canvas) {
        for pauses in [[], [SessionFlow.PauseReason.user]] as [Set<SessionFlow.PauseReason>] {
            controller.setStateForTesting(session: Fixtures.session(isLocal: true), drafts: Fixtures.drafts(10), mode: .open(Open(pauses: pauses, canvas: canvas)))
            let embedded = NSHostingView(rootView: HUDView(controller: controller, isEmbedded: true)).fittingSize.width
            #expect(embedded <= HUDView.embeddedWidth)
        }
    }

    /// The wireframe's tool and Draw's tool redraw only the views that observe their parts.
    @Test func aToolDoesNotRedrawTheControllersViews() {
        open(Open(canvas: .wireframe))
        var changes = 0
        let subscription = controller.objectWillChange.sink { changes += 1 }
        var toolChanges = 0
        let tools = controller.wireframe.objectWillChange.sink { toolChanges += 1 }

        controller.setWireframeTool("table")
        controller.wireframe.putToolDown()
        controller.drawing.putToolDown()
        #expect(changes == 0)
        #expect(toolChanges == 2)
        subscription.cancel()
        tools.cancel()
    }
}
