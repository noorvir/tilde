@testable import TildeUI
import TildeCore
import AppKit
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
        #expect(controller.phase == .idle)
        #expect(controller.session == nil)
    }

    @Test func cancelWithAnnotationsAsksFirst() {
        controller.setStateForTesting(session: Fixtures.session(), drafts: Fixtures.drafts(2))
        controller.requestCancel()
        #expect(controller.confirmation == .cancelSession)
        #expect(controller.phase == .annotating)

        controller.dismissConfirmation()
        #expect(controller.confirmation == nil)
        #expect(controller.drafts.count == 2)

        controller.requestCancel()
        controller.confirm()
        #expect(controller.phase == .idle)
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
        #expect(controller.phase == .annotating)
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

    @Test func homeIsTheTopCentreOfTheVisibleArea() {
        let screen = NSRect(x: 1800, y: 0, width: 2560, height: 1440)
        let visible = NSRect(x: 1800, y: 0, width: 2560, height: 1415)
        #expect(HUDPanel.homeTop(screenFrame: screen, visibleFrame: visible) == NSPoint(x: 3080, y: 1419))
    }

    @Test func dragSnapsHomeWithinFortyPoints() {
        let home = NSPoint(x: 900, y: 1134)
        #expect(HUDPanel.snapsHome(NSPoint(x: 930, y: 1110), home: home))
        #expect(!HUDPanel.snapsHome(NSPoint(x: 940, y: 1100), home: home))
    }

    @Test func positionsStayOnScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1800, height: 1130)
        let halfWidth = HUDView.width / 2 + 16
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

    @Test func windowButtonChoosesAndClearsTheScope() {
        controller.setStateForTesting(session: Fixtures.session())

        controller.toggleWindowScope()
        #expect(controller.isPickingWindow)
        controller.cancelWindowPick()
        #expect(!controller.isPickingWindow)

        controller.toggleWindowScope()
        controller.setScope(Fixtures.window)
        #expect(controller.scope == Fixtures.window)
        #expect(!controller.isPickingWindow)
        #expect(controller.scopeName == "Safari")

        controller.toggleWindowScope()
        #expect(controller.scope == nil)
        #expect(!controller.isPickingWindow)
    }

    @Test func scopeEndsWhenTheWindowIsGone() {
        controller.setStateForTesting(session: Fixtures.session())
        controller.setScope(Fixtures.window)

        controller.refreshScope()

        #expect(controller.scope == nil)
        #expect(controller.notice == "Window closed")
    }

    // MARK: - HUD subtitle

    /// Every subtitle has a candidate that fits the fixed pill, so it never truncates.
    @Test func everySubtitleFitsWithoutTruncating() {
        let icon = Fixtures.appIcon
        let variants: [(client: String?, scope: String?, notes: Int, state: HUDView.SubtitleState)] = [
            (nil, nil, 0, .annotating),
            (nil, nil, 12, .annotating),
            ("Codex", nil, 3, .annotating),
            ("Claude Code", "Google Chrome", 0, .annotating),
            ("Claude Code", "Google Chrome", 128, .annotating),
            (nil, "Tilde Browser", 2, .annotating),
            ("Windsurf", nil, 0, .choosingWindow),
            (nil, nil, 1, .paused(shortcut: .keys(KeyCombo(keyCode: 35, modifiers: NSEvent.ModifierFlags([.control, .option, .shift, .command]).rawValue, key: "P")))),
            (nil, nil, 1, .paused(shortcut: nil)),
            (nil, nil, 0, .notice("Window closed")),
            (nil, "Google Chrome", 2, .waitingForWindow),
            (nil, nil, 1, .paused(shortcut: .doubleTap(.control))),
            (nil, nil, 1, .paused(shortcut: .doubleTap(.command))),
            (nil, nil, 1, .paused(shortcut: .doubleTap(.function))),
        ]

        for variant in variants {
            let candidates = HUDView.subtitleCandidates(
                client: variant.client, clientIcon: icon, scopeName: variant.scope, scopeIcon: icon, notes: variant.notes, state: variant.state
            )
            let shortest = try! #require(candidates.last)
            #expect(HUDView.width(of: shortest) <= HUDView.subtitleWidth, "\(variant) is \(HUDView.width(of: shortest)) pt")
        }
    }

    @Test func localSubtitlesLeaveOutTheClient() {
        let candidates = HUDView.subtitleCandidates(client: nil, clientIcon: nil, scopeName: "Google Chrome", scopeIcon: nil, notes: 0, state: .annotating)

        #expect(candidates.first == [HUDView.SubtitlePart(prefix: "in", text: "Google Chrome"), HUDView.SubtitlePart(text: "click or drag")])
        #expect(candidates.contains([HUDView.SubtitlePart(prefix: "in", text: "Google Chrome")]))
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
        controller.setStateForTesting(session: Fixtures.session(), isPaused: true, isAutoPaused: true)

        controller.togglePause()

        #expect(!controller.isEffectivelyPaused)
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
        #expect(controller.isPaused)
        #expect(controller.confirmation == nil)

        controller.escapePressed()
        #expect(controller.confirmation == .cancelSession)

        controller.escapePressed()
        #expect(controller.confirmation == nil)
        #expect(controller.drafts.count == 2)
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
        controller.setStateForTesting(session: Fixtures.session(), drafts: Fixtures.drafts(1), isPaused: true)

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
