@testable import TildeUI
import TildeCore
import TildeInstaller
import AppKit
import SwiftUI
import Testing

/// Rules of the annotate UI that do not need pixels: confirmations, keys, capture rects and
/// HUD placement.
@MainActor
@Suite(.serialized)
struct BehaviourTests {
    let controller: AnnotationController

    init() async throws {
        controller = try await Fixtures.controller()
    }

    // MARK: - Confirmations

    @Test func cancelWithoutAnnotationsClosesAtOnce() {
        controller.setStateForTesting(session: Fixtures.session())
        controller.requestCancel()
        #expect(controller.confirmation == nil)
        #expect(controller.mode == .idle)
        #expect(controller.session == nil)
    }

    @Test func cancelWithAnnotationsAsksFirst() {
        controller.setStateForTesting(session: Fixtures.session(), drafts: Fixtures.drafts(2))
        controller.requestCancel()
        #expect(controller.confirmation == .cancelSession)
        #expect(controller.mode == .annotating)

        controller.dismissConfirmation()
        #expect(controller.confirmation == nil)
        #expect(controller.drafts.count == 2)

        controller.requestCancel()
        controller.confirm()
        #expect(controller.mode == .idle)
        #expect(controller.drafts.isEmpty)
    }

    @Test func clearAllAsksAndKeepsTheSession() {
        controller.setStateForTesting(session: Fixtures.session())
        controller.requestClearAll()
        #expect(controller.confirmation == nil)

        controller.setStateForTesting(session: Fixtures.session(), drafts: Fixtures.drafts(3))
        controller.requestClearAll()
        #expect(controller.confirmation == .clearAll)
        controller.confirm()
        #expect(controller.drafts.isEmpty)
        #expect(controller.mode == .annotating)
        #expect(controller.session != nil)
    }

    @Test func escapeDismissesAndReturnConfirms() throws {
        let overlay = OverlayView(controller: controller)
        controller.setStateForTesting(session: Fixtures.session(), drafts: Fixtures.drafts(2), confirmation: .clearAll)

        overlay.keyDown(with: try key(53))
        #expect(controller.confirmation == nil)
        #expect(controller.drafts.count == 2)

        controller.requestClearAll()
        overlay.keyDown(with: try key(36))
        #expect(controller.drafts.isEmpty)
    }

    @Test func deletingOneAnnotationDoesNotAsk() {
        let drafts = Fixtures.drafts(3)
        controller.setStateForTesting(session: Fixtures.session(), drafts: drafts)
        controller.deleteDraft(drafts[1].id)
        #expect(controller.confirmation == nil)
        #expect(controller.drafts.map(\.id) == [drafts[0].id, drafts[2].id])
    }

    // MARK: - Send

    /// A session without an agent says only "Copied", done, also with remote machines; the
    /// images go to them in the background. (The report waits here, so nothing is copied.)
    @Test func aCopySaysOnlyCopied() {
        let unfinished = Task { () -> Captures in
            try? await Task.sleep(for: .seconds(3600))
            return Captures(image: nil, contextImage: nil)
        }
        let draft = Fixtures.drafts(1)[0]
        let drafts = [Draft(annotation: draft.annotation, marker: draft.marker, chip: draft.chip, capture: unfinished)]
        controller.setStateForTesting(session: Fixtures.session(isLocal: true), drafts: drafts)

        controller.send()
        #expect(controller.mode == .sent(confirmation: "Copied"))
        #expect(controller.sentStatus == .done)
    }

    @Test func sendStopsPickingBeforeTheReportIsReady() {
        // A screenshot that is still being taken keeps the report from being made.
        let unfinished = Task { () -> Captures in
            try? await Task.sleep(for: .seconds(3600))
            return Captures(image: nil, contextImage: nil)
        }
        let draft = Fixtures.drafts(1)[0]
        let drafts = [Draft(annotation: draft.annotation, marker: draft.marker, chip: draft.chip, capture: unfinished)]
        controller.setStateForTesting(session: Fixtures.session(), drafts: drafts, hover: Fixtures.hover())

        controller.send()
        #expect(controller.mode == .sent(confirmation: "Sent to Codex"))
        #expect(!controller.overlayTakesInput)
        #expect(controller.hover == nil)

        controller.cancel()
        #expect(controller.session != nil)
    }

    @Test func recordingModeTakesNoInputExceptToChooseAWindow() {
        controller.setStateForTesting(session: Fixtures.session(), hover: Fixtures.hover())
        #expect(controller.overlayTakesInput)

        controller.toggleRecordingMode()
        #expect(controller.mode == .recording(.ready))
        #expect(!controller.overlayTakesInput)
        #expect(controller.hover == nil)

        controller.setStateForTesting(session: Fixtures.session(), mode: .recording(.ready), isPickingWindow: true)
        #expect(controller.overlayTakesInput)
        controller.cancelWindowPick()
        #expect(controller.mode == .recording(.ready))
        #expect(!controller.overlayTakesInput)
    }

    /// A source with no size, as an iPhone reports before it streams, is an error, not the
    /// exception that crashed Tilde; a phone's screen in portrait is fine.
    @Test func aRecordingNeedsASizeItCanWrite() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-writer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(throws: ScreenRecorder.Failure.badSize) {
            _ = try ScreenRecorder.makeWriter(width: 0, height: 0, in: folder)
        }
        let (writer, _) = try ScreenRecorder.makeWriter(width: 1290, height: 2796, in: folder)
        writer.cancelWriting()
    }

    /// The record toggle and Esc go back to annotating; with a clip not stopped they ask first.
    @Test func leavingRecordingModeAsksToDiscardAClipNotStopped() {
        controller.setStateForTesting(session: Fixtures.session(), mode: .recording(.ready))
        controller.escapePressed()
        #expect(controller.mode == .annotating)

        controller.setStateForTesting(session: Fixtures.session(), mode: .recording(.paused(3)))
        controller.toggleRecordingMode()
        #expect(controller.confirmation == .discardRecording)
        #expect(controller.mode == .recording(.paused(3)))
        controller.escapePressed()
        #expect(controller.confirmation == nil)
        #expect(controller.mode == .recording(.paused(3)))

        controller.escapePressed()
        controller.confirm()
        #expect(controller.mode == .annotating)
        #expect(controller.drafts.isEmpty)
    }

    /// Annotating takes only sources Tilde can draw on. A phone chosen for recording goes when
    /// recording mode ends, back to everything on screen.
    @Test func aPhoneIsARecordingSourceOnly() {
        let phone = Phone(id: "phone", name: "iPhone")
        #expect(!RecordingSource.phone(phone).isDrawable)
        #expect(RecordingSource.screen(1).isDrawable)
        #expect(RecordingSource.window(Fixtures.window).isDrawable)

        controller.setStateForTesting(session: Fixtures.session(), isPickingWindow: true)
        controller.choose(.phone(phone))
        #expect(controller.chosenSource == nil)

        controller.setStateForTesting(session: Fixtures.session(), mode: .recording(.ready), isPickingWindow: true)
        controller.choose(.phone(phone))
        #expect(controller.chosenSource == .phone(phone))
        controller.toggleRecordingMode()
        #expect(controller.mode == .annotating)
        #expect(controller.chosenSource == nil)
    }

    @Test func aChosenSourceIsWhatTheNextClipRecords() {
        let phone = Phone(id: "phone", name: "iPhone")
        controller.setStateForTesting(session: Fixtures.session(), mode: .recording(.ready))
        #expect(controller.chosenSource == nil)

        controller.setStateForTesting(session: Fixtures.session(), mode: .recording(.ready), scope: Fixtures.window, isPickingWindow: true)
        #expect(controller.chosenSource == .window(Fixtures.window))

        controller.choose(.phone(phone))
        #expect(controller.chosenSource == .phone(phone))
        #expect(controller.scope == nil)
        #expect(!controller.isPickingWindow)

        // A window limits the session to it, as choosing it on screen does.
        controller.choose(.window(Fixtures.window))
        #expect(controller.scope == Fixtures.window)
        #expect(controller.chosenSource == .window(Fixtures.window))
    }

    /// While a window is being chosen, ⌘↩ does not send; the overlay takes only Esc.
    @Test func choosingAWindowTakesNoOtherKey() throws {
        controller.setStateForTesting(session: Fixtures.session(), drafts: Fixtures.drafts(1), isPickingWindow: true)
        let overlay = OverlayWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200), level: .normal, isWindowSized: true, controller: controller)
        defer { overlay.close() }
        let view = try #require(overlay.contentView)
        let send = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: overlay.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))

        view.keyDown(with: send)

        #expect(controller.mode == .annotating)
        #expect(controller.drafts.count == 1)
    }

    @Test func anOverlayWithoutInputGetsNoPointerEvents() throws {
        let overlay = OverlayWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200), level: .normal, isWindowSized: true, controller: controller)
        defer { overlay.close() }
        let view = try #require(overlay.contentView)
        view.updateTrackingAreas()
        #expect(!view.trackingAreas.isEmpty)

        overlay.takesInput = false
        #expect(overlay.ignoresMouseEvents)
        #expect(!overlay.acceptsMouseMovedEvents)
        #expect(view.trackingAreas.isEmpty)
    }

    // MARK: - Captures

    @Test func closeUpIsTheElementPlusFourPoints() {
        let element = CGRect(x: 100, y: 50, width: 84, height: 22)
        #expect(AnnotationController.closeUpRect(frame: element, outline: element) == CGRect(x: 96, y: 46, width: 92, height: 30))

        let region = CGRect(x: 10, y: 20, width: 300, height: 200)
        #expect(AnnotationController.closeUpRect(frame: region, outline: nil) == region)
    }

    @Test func regionContextNeedsEightyPercentInsideTheWindow() {
        let window = CGRect(x: 0, y: 0, width: 1000, height: 800)
        #expect(AnnotationController.isMostlyInside(CGRect(x: 100, y: 100, width: 200, height: 100), window))
        #expect(AnnotationController.isMostlyInside(CGRect(x: 840, y: 100, width: 200, height: 100), window))
        #expect(!AnnotationController.isMostlyInside(CGRect(x: 900, y: 100, width: 200, height: 100), window))
        #expect(!AnnotationController.isMostlyInside(CGRect(x: 2000, y: 100, width: 200, height: 100), window))
    }

    // MARK: - HUD placement

    /// The pill keeps one width in every mode: the widest title and a two-digit note count fit
    /// in it, and a long subtitle drops words instead of widening it, so changing the mode or
    /// adding notes never moves a button.
    @Test(arguments: [
        AnnotationController.Mode.annotating, .paused([.user]), .recording(.ready), .recording(.recording(since: Date(), before: 0)), .recording(.paused(599)),
    ])
    func everyModeFitsThePillWidth(mode: AnnotationController.Mode) {
        for isPickingWindow in [false, true] {
            controller.setStateForTesting(
                session: Fixtures.session(isLocal: true), drafts: Fixtures.drafts(3), mode: mode, scope: Fixtures.window, isPickingWindow: isPickingWindow
            )
            let width = NSHostingView(rootView: HUDView(controller: controller, isEmbedded: true)).fittingSize.width
            #expect(width <= HUDView.embeddedWidth, "\(mode) needs \(width) pt, the pill has \(HUDView.embeddedWidth)")
            // The floating pill, inside the panel's 16 pt padding.
            let floating = NSHostingView(rootView: HUDView(controller: controller)).fittingSize.width - 32
            #expect(floating == HUDView.width, "\(mode) makes the floating pill \(floating) pt wide")
        }
    }

    /// The preview opens at the size it was last resized to, inside the screen and no smaller
    /// than its minimum; at home it is centred, and a dropped place keeps it on the screen.
    @Test func thePreviewOpensAtItsSavedSize() throws {
        let suite = "tilde-preview-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visible = NSRect(x: 0, y: 25, width: 1800, height: 1100)

        #expect(PreviewPanel.size(on: visible, defaults: defaults) == NSSize(width: 1000, height: 640))

        PreviewPanel.save(NSSize(width: 1400, height: 900), to: defaults)
        let size = PreviewPanel.size(on: visible, defaults: defaults)
        #expect(size == NSSize(width: 1400, height: 900))
        #expect(PreviewPanel.homeTop(of: size, on: visible) == NSPoint(x: 900, y: 1025))
        #expect(PreviewPanel.clamped(NSPoint(x: 1700, y: 1200), size: size, in: visible) == NSPoint(x: 1100, y: 1125))

        PreviewPanel.save(NSSize(width: 3000, height: 100), to: defaults)
        #expect(PreviewPanel.size(on: visible, defaults: defaults) == NSSize(width: 1800, height: PreviewPanel.minSize.height))
    }

    @Test func homeIsTheTopCentreOfTheVisibleArea() {
        let screen = NSRect(x: 1800, y: 0, width: 2560, height: 1440)
        let visible = NSRect(x: 1800, y: 0, width: 2560, height: 1415)
        #expect(HUDPanel.homeTop(screenFrame: screen, visibleFrame: visible) == NSPoint(x: 3080, y: 1419))
    }

    @Test func dragSnapsHomeWithinFortyPoints() {
        let home = NSPoint(x: 900, y: 1134)
        #expect(SnapDrag.snapsHome(NSPoint(x: 930, y: 1110), home: home))
        #expect(!SnapDrag.snapsHome(NSPoint(x: 940, y: 1100), home: home))
    }

    @Test func positionsStayOnScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1800, height: 1130)
        let halfWidth = HUDView.maxWidth / 2 + 16
        #expect(HUDPanel.clamped(NSPoint(x: -500, y: 5000), in: visible) == NSPoint(x: halfWidth, y: 1134))
        #expect(HUDPanel.clamped(NSPoint(x: 5000, y: -10), in: visible) == NSPoint(x: 1800 - halfWidth, y: HUDMetrics.height + 32))
        #expect(HUDPanel.clamped(NSPoint(x: 900, y: 600), in: visible) == NSPoint(x: 900, y: 600))
    }

    @Test func hudContentMapsToTheScreen() {
        let window = NSRect(x: 2800, y: 0, width: 560, height: 1444)
        let content = CGRect(x: 33, y: 0, width: 494, height: 76)
        #expect(HUDPanel.screenRect(ofContent: content, inWindow: window) == NSRect(x: 2833, y: 1368, width: 494, height: 76))
    }

    private func key(_ code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code
        ))
    }

    // MARK: - Shortcuts

    @Test func shortcutsAreSavedClearedResetAndNeverShared() {
        let suite = "tilde-tests-\(UUID().uuidString)"
        let store = ShortcutStore(defaults: UserDefaults(suiteName: suite)!)
        let controlShiftK = Shortcut.keys(KeyCombo(keyCode: 40, modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue, key: "K"))

        #expect(store.set(controlShiftK, for: .startAnnotation) == nil)
        #expect(store.set(controlShiftK, for: .togglePause) == .startAnnotation)
        #expect(store.shortcut(for: .togglePause) == nil)
        #expect(store.set(.doubleTap(.option), for: .togglePause) == nil)
        #expect(store.set(nil, for: .togglePause) == nil)

        let reopened = ShortcutStore(defaults: UserDefaults(suiteName: suite)!)
        #expect(reopened.shortcut(for: .startAnnotation)?.caps == ["⌃", "⇧", "K"])
        #expect(reopened.shortcut(for: .togglePause) == nil)

        reopened.reset(.startAnnotation)
        #expect(ShortcutStore(defaults: UserDefaults(suiteName: suite)!).shortcut(for: .startAnnotation)?.title == "Double-tap ⌃")
    }

    @Test func aDoubleTapIsSavedAndMayBeSharedByStartAndPause() {
        let suite = "tilde-tests-\(UUID().uuidString)"
        let store = ShortcutStore(defaults: UserDefaults(suiteName: suite)!)
        #expect(store.shortcut(for: .startAnnotation) == .doubleTap(.control))
        #expect(store.shortcut(for: .togglePause) == nil)

        #expect(store.set(.doubleTap(.control), for: .togglePause) == nil)
        #expect(store.doubleTapKeys == [.control])

        let reopened = ShortcutStore(defaults: UserDefaults(suiteName: suite)!)
        #expect(reopened.shortcut(for: .startAnnotation) == .doubleTap(.control))
        #expect(reopened.shortcut(for: .startAnnotation)?.caps == ["⌃", "⌃"])
        #expect(reopened.shortcut(for: .startAnnotation)?.combo == nil)
    }

    @Test func combinationsSavedBeforeDoubleTapsStillLoad() throws {
        let saved = Data(#"[{"keyCode":40,"modifiers":262144,"key":"K"}]"#.utf8)
        let shortcuts = try JSONDecoder().decode([Shortcut].self, from: saved)
        #expect(shortcuts.first?.title == "⌃K")
    }

    // MARK: - Window scope

    @Test func scopedSessionsTakeOnlyPointsInTheWindow() {
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)

        #expect(AnnotationController.allows(CGPoint(x: 900, y: 900), scope: nil))
        #expect(AnnotationController.allows(CGPoint(x: 120, y: 380), scope: window))
        #expect(!AnnotationController.allows(CGPoint(x: 99, y: 200), scope: window))
        #expect(!AnnotationController.allows(CGPoint(x: 300, y: 401), scope: window))
    }

    @Test func regionsAreCutToTheScopedWindow() {
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)

        #expect(AnnotationController.clamped(CGRect(x: 50, y: 150, width: 200, height: 100), scope: window) == CGRect(x: 100, y: 150, width: 150, height: 100))
        #expect(AnnotationController.clamped(CGRect(x: 0, y: 0, width: 50, height: 50), scope: window) == nil)
        #expect(AnnotationController.clamped(CGRect(x: 0, y: 0, width: 50, height: 50), scope: nil) == CGRect(x: 0, y: 0, width: 50, height: 50))
    }

    /// The window button picks on screen, with the picker closed to its button; a second click
    /// stops with no change.
    @Test func windowButtonChoosesAgainAndTheScreenTileLiftsTheScope() {
        let elsewhere = CGPoint(x: -5000, y: -5000)
        controller.setStateForTesting(session: Fixtures.session())
        controller.toggleWindowPick()
        #expect(controller.isPickingWindow)
        #expect(!controller.isSourcePickerOpen)
        controller.toggleWindowPick()
        #expect(!controller.isPickingWindow)

        controller.setStateForTesting(session: Fixtures.session(), isPickingWindow: true)
        controller.setScope(Fixtures.window)
        #expect(controller.scope == Fixtures.window)
        #expect(!controller.isPickingWindow)
        #expect(controller.scopeName == "Safari")
        #expect(!controller.allows(elsewhere))

        // Limited to a window, choosing takes the other windows too, and Esc keeps the limit.
        controller.setStateForTesting(session: Fixtures.session(), scope: Fixtures.window, isPickingWindow: true)
        #expect(controller.allows(elsewhere))
        controller.cancelWindowPick()
        #expect(controller.scope == Fixtures.window)
        #expect(!controller.allows(elsewhere))

        controller.setStateForTesting(session: Fixtures.session(), scope: Fixtures.window, isPickingWindow: true)
        controller.choose(.screen(1))
        #expect(controller.scope == nil)
        #expect(!controller.isPickingWindow)
        #expect(controller.chosenSource == .screen(1))
    }

    /// The open picker stops choosing on screen (opening it loads the screens' pictures, so the
    /// test starts in that state). Its cross goes back to choosing on screen; Esc ends both.
    @Test func theOpenPickerTakesNoClicksOnScreen() {
        controller.setStateForTesting(session: Fixtures.session(), isPickingWindow: true, isSourcePickerOpen: true)
        controller.click(at: CGPoint(x: -5000, y: -5000))
        #expect(controller.isPickingWindow)
        #expect(controller.scope == nil)
        #expect(controller.chosenSource == nil)

        controller.closeSourcePicker()
        #expect(controller.isPickingWindow)
        #expect(!controller.isSourcePickerOpen)

        controller.setStateForTesting(session: Fixtures.session(), isPickingWindow: true, isSourcePickerOpen: true)
        controller.cancelWindowPick()
        #expect(!controller.isPickingWindow)
        #expect(!controller.isSourcePickerOpen)
    }

    @Test func scopeEndsWhenTheWindowIsGone() {
        controller.setStateForTesting(session: Fixtures.session())
        controller.setScope(Fixtures.window)

        controller.refreshScope()

        #expect(controller.scope == nil)
        #expect(controller.notice == "Window closed")
    }

    // MARK: - HUD subtitle

    /// Every agent's name and every notice fits the fixed pill in full, so nothing is cut.
    @Test func everySubtitleFitsWithoutTruncating() {
        let icon = Fixtures.appIcon
        let shortcuts: [Shortcut?] = [
            .keys(KeyCombo(keyCode: 35, modifiers: NSEvent.ModifierFlags([.control, .option, .shift, .command]).rawValue, key: "P")),
            .doubleTap(.control), .doubleTap(.command), .doubleTap(.function), nil,
        ]
        let states: [HUDView.SubtitleState] = [.annotating, .choosingWindow, .waitingForWindow, .notice("Window closed"), .holding("⌥")]
            + shortcuts.map { .paused(shortcut: $0) }

        let machine = HUDView.Machine(host: "a-very-long-machine-name.example.com", dot: .green)
        for client in ["Clipboard"] + Harness.allCases.map(\.name) {
            for state in states {
                let part = HUDView.subtitlePart(client: client, clientIcon: icon, machine: machine, state: state)
                #expect(HUDView.width(of: part) <= HUDView.subtitleWidth, "\(client) \(state) is \(HUDView.width(of: part)) pt")
            }
        }
    }

    /// The subtitle says where the report goes in full, in every mode; the window the session is
    /// limited to is on the window button instead.
    @Test func subtitlesSayWhereTheReportGoesInBothStates() {
        let local = HUDView.subtitlePart(client: "Clipboard", clientIcon: nil, machine: nil, state: .annotating)
        #expect(local == HUDView.SubtitlePart(prefix: "for", text: "Clipboard"))

        let paused = HUDView.subtitlePart(client: "Codex", clientIcon: nil, machine: nil, state: .paused(shortcut: .doubleTap(.control)))
        #expect(paused == HUDView.SubtitlePart(prefix: "for", text: "Codex"))
    }

    @Test func aRemoteSubtitleNamesTheMachine() {
        let icon = Fixtures.appIcon
        let machine = HUDView.Machine(host: "mac-mini-ts", dot: .green)
        let part = HUDView.subtitlePart(client: "Claude Code", clientIcon: icon, machine: machine, state: .annotating)

        #expect(part == HUDView.SubtitlePart(prefix: "for", icon: icon, text: "Claude Code", machine: machine))
    }

    @Test func tooltipsStayInsideTheAreaThatDrawsThem() {
        let near = CGRect(x: 10, y: 10, width: 26, height: 26)
        let x = TooltipLayer.centerX(text: "Annotate (Double-tap ⌃)", target: near, width: 528)
        #expect(x > near.midX)
        #expect(TooltipLayer.centerX(text: "Pause", target: CGRect(x: 250, y: 10, width: 26, height: 26), width: 528) == 263)
    }

    // MARK: - Auto-pause

    @Test func scopedSessionsWaitWhileAnotherAppIsInFront() {
        #expect(AnnotationController.autoPauses(frontmost: 42, scopePID: 7, ownPID: 1))
        #expect(!AnnotationController.autoPauses(frontmost: 7, scopePID: 7, ownPID: 1))
        // Tilde in front, such as its HUD or comment box, keeps the session going.
        #expect(!AnnotationController.autoPauses(frontmost: 1, scopePID: 7, ownPID: 1))
        // Sessions on all windows never wait.
        #expect(!AnnotationController.autoPauses(frontmost: 42, scopePID: nil, ownPID: 1))
    }

    @Test func annotateResumesAWindowSessionThatPausedByItself() async throws {
        let controller = try await Fixtures.controller()
        controller.setStateForTesting(session: Fixtures.session(), mode: .paused([.user, .otherApp]))

        controller.togglePause()

        #expect(controller.mode == .annotating)
    }

    // MARK: - Double-tap

    @Test func tappingTheKeyTwiceQuicklyIsADoubleTap() {
        var gesture = DoubleTapGesture()
        #expect(gesture.flagsChanged(key: true, others: false, at: 0) == false)
        #expect(gesture.flagsChanged(key: false, others: false, at: 0.08) == false)
        #expect(gesture.flagsChanged(key: true, others: false, at: 0.25) == false)
        #expect(gesture.flagsChanged(key: false, others: false, at: 0.33) == true)
        // A third tap starts over.
        #expect(gesture.flagsChanged(key: true, others: false, at: 0.4) == false)
        #expect(gesture.flagsChanged(key: false, others: false, at: 0.45) == false)
    }

    @Test func slowOrLongTapsAreNoDoubleTap() {
        var gesture = DoubleTapGesture()
        _ = gesture.flagsChanged(key: true, others: false, at: 0)
        _ = gesture.flagsChanged(key: false, others: false, at: 0.08)
        _ = gesture.flagsChanged(key: true, others: false, at: 0.5)
        #expect(gesture.flagsChanged(key: false, others: false, at: 0.56) == false)

        // Held for a second: no tap, so the next quick tap is a first tap.
        _ = gesture.flagsChanged(key: true, others: false, at: 2)
        _ = gesture.flagsChanged(key: false, others: false, at: 3)
        _ = gesture.flagsChanged(key: true, others: false, at: 3.1)
        #expect(gesture.flagsChanged(key: false, others: false, at: 3.15) == false)
    }

    @Test func chordsAreNoTap() {
        var gesture = DoubleTapGesture()
        // ⌃⌥A between two taps of ⌃.
        _ = gesture.flagsChanged(key: true, others: false, at: 0)
        _ = gesture.flagsChanged(key: false, others: false, at: 0.05)
        _ = gesture.flagsChanged(key: true, others: false, at: 0.1)
        _ = gesture.flagsChanged(key: true, others: true, at: 0.12)
        gesture.otherInput()
        #expect(gesture.flagsChanged(key: false, others: false, at: 0.2) == false)

        // ⌃C right after a tap.
        _ = gesture.flagsChanged(key: true, others: false, at: 1)
        _ = gesture.flagsChanged(key: false, others: false, at: 1.05)
        _ = gesture.flagsChanged(key: true, others: false, at: 1.1)
        gesture.otherInput()
        #expect(gesture.flagsChanged(key: false, others: false, at: 1.15) == false)

        // A key typed between two taps.
        _ = gesture.flagsChanged(key: true, others: false, at: 2)
        _ = gesture.flagsChanged(key: false, others: false, at: 2.05)
        gesture.otherInput()
        _ = gesture.flagsChanged(key: true, others: false, at: 2.1)
        #expect(gesture.flagsChanged(key: false, others: false, at: 2.15) == false)
    }

    @Test func theDetectorFindsWhichModifierWasTappedTwice() {
        var detector = DoubleTapDetector()
        let all = Set(DoubleTapKey.allCases)
        for key in DoubleTapKey.allCases {
            let start = Double(DoubleTapKey.allCases.firstIndex(of: key)!) * 10
            #expect(detector.handle(isFlagsChanged: true, flags: key.flag, at: start, watching: all) == nil)
            #expect(detector.handle(isFlagsChanged: true, flags: [], at: start + 0.05, watching: all) == nil)
            #expect(detector.handle(isFlagsChanged: true, flags: key.flag, at: start + 0.15, watching: all) == nil)
            #expect(detector.handle(isFlagsChanged: true, flags: [], at: start + 0.2, watching: all) == key)
        }
    }

    @Test func theDetectorIgnoresASlowSecondPressAndUnwatchedKeys() {
        var detector = DoubleTapDetector()
        _ = detector.handle(isFlagsChanged: true, flags: .control, at: 0, watching: [.control])
        _ = detector.handle(isFlagsChanged: true, flags: [], at: 0.05, watching: [.control])
        _ = detector.handle(isFlagsChanged: true, flags: .control, at: 0.6, watching: [.control])
        #expect(detector.handle(isFlagsChanged: true, flags: [], at: 0.65, watching: [.control]) == nil)

        _ = detector.handle(isFlagsChanged: true, flags: .option, at: 1, watching: [.control])
        _ = detector.handle(isFlagsChanged: true, flags: [], at: 1.05, watching: [.control])
        _ = detector.handle(isFlagsChanged: true, flags: .option, at: 1.1, watching: [.control])
        #expect(detector.handle(isFlagsChanged: true, flags: [], at: 1.15, watching: [.control]) == nil)
    }

    @Test func theStartKeyBringsAnnotatingUp() {
        let action = AnnotationController.doubleTapAction
        // Arguments: key, start key, pause key, annotating, paused, has a session.
        #expect(action(.control, .control, nil, false, false, false) == .start)
        #expect(action(.control, .control, nil, true, true, true) == .resume)
        // While annotating it does nothing; Esc pauses.
        #expect(action(.control, .control, nil, true, false, true) == nil)
        // The same key for start and pause: it also pauses while annotating.
        #expect(action(.control, .control, .control, true, false, true) == .togglePause)
        // Different keys each do only their own.
        #expect(action(.option, .control, .option, true, false, true) == .togglePause)
        #expect(action(.option, .control, .option, false, false, false) == nil)
        #expect(action(.control, nil, nil, false, false, false) == nil)
    }

    // MARK: - Esc

    @Test func escPausesThenAsksToDiscardThenDismissesTheQuestion() async throws {
        let controller = try await Fixtures.controller()
        controller.setStateForTesting(session: Fixtures.session(), drafts: Fixtures.drafts(2))

        controller.escapePressed()
        #expect(controller.pauses == [.user])
        #expect(controller.confirmation == nil)

        controller.escapePressed()
        #expect(controller.confirmation == .cancelSession)

        controller.escapePressed()
        #expect(controller.confirmation == nil)
        #expect(controller.drafts.count == 2)
    }

    @Test func theQuestionTakesReturnAndEscFromAnyOfTildesWindows() async throws {
        let controller = try await Fixtures.controller()
        controller.setStateForTesting(session: Fixtures.session(), drafts: Fixtures.drafts(2), mode: .paused([.user]), confirmation: .clearAll)

        // Other keys pass on, such as to a focused text field.
        #expect(controller.handleConfirmationKey(0) == false)
        #expect(controller.handleConfirmationKey(53))
        #expect(controller.confirmation == nil)
        #expect(controller.drafts.count == 2)

        // Paused in a popped-out session: Esc asks, ↩ answers.
        controller.escapePressed()
        #expect(controller.confirmation == .cancelSession)
        controller.setStateForTesting(session: Fixtures.session(), drafts: Fixtures.drafts(2), mode: .paused([.user]), confirmation: .clearAll)
        #expect(controller.handleConfirmationKey(36))
        #expect(controller.drafts.isEmpty)
        #expect(controller.handleConfirmationKey(36) == false)
    }

    @Test func escEndsChoosingAWindowFirst() async throws {
        let controller = try await Fixtures.controller()
        controller.setStateForTesting(session: Fixtures.session(), drafts: Fixtures.drafts(1), isPickingWindow: true)

        controller.escapePressed()

        #expect(!controller.isPickingWindow)
        #expect(controller.confirmation == nil)
    }

    @Test func escWhilePausedAlsoAsksToCancel() async throws {
        let controller = try await Fixtures.controller()
        controller.setStateForTesting(session: Fixtures.session(), drafts: Fixtures.drafts(1), mode: .paused([.user]))

        controller.escapePressed()

        #expect(controller.confirmation == .cancelSession)
    }

    // MARK: - Browser window frame

    @Test func browserOpensAtFullHeightAndHalfWidth() {
        let visible = CGRect(x: 0, y: 40, width: 2000, height: 1100)
        let frame = BrowserController.defaultFrame(in: visible)

        #expect(frame.width == 1000)
        #expect(frame.height == 1084)
        #expect(frame.midX == visible.midX)
        #expect(visible.contains(frame))

        // Never narrower than the toolbar with the HUD needs.
        let small = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(BrowserController.defaultFrame(in: small).width == BrowserMetrics.minWindowWidth)
    }

    @Test func savedBrowserFrameMovesOntoAScreen() {
        let screens = [CGRect(x: 0, y: 0, width: 1800, height: 1100)]
        let onScreen = CGRect(x: 100, y: 100, width: 900, height: 800)
        #expect(BrowserController.onScreen(onScreen, screens: screens) == onScreen)

        // Left on a display that is gone, to the right of this one, and taller than this one.
        let lost = CGRect(x: 2500, y: 200, width: 1000, height: 1400)
        let moved = BrowserController.onScreen(lost, screens: screens)
        #expect(moved == CGRect(x: 800, y: 0, width: 1000, height: 1100))
    }
}
