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
        let controlShiftK = Shortcut(keyCode: 40, modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue, key: "K")

        #expect(store.set(controlShiftK, for: .startAnnotation) == nil)
        #expect(store.set(controlShiftK, for: .togglePause) == .startAnnotation)
        #expect(store.shortcut(for: .togglePause) == ShortcutStore.Action.togglePause.defaultShortcut)
        #expect(store.set(nil, for: .togglePause) == nil)

        let reopened = ShortcutStore(defaults: UserDefaults(suiteName: suite)!)
        #expect(reopened.shortcut(for: .startAnnotation)?.caps == ["⌃", "⇧", "K"])
        #expect(reopened.shortcut(for: .togglePause) == nil)

        reopened.reset(.togglePause)
        #expect(ShortcutStore(defaults: UserDefaults(suiteName: suite)!).shortcut(for: .togglePause)?.title == "⌃⌥P")
    }
}
