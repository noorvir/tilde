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

    /// A session on screen in a mode; `question` and `clip` as in the flow.
    private func open(
        drafts: [Draft] = [], pauses: Set<SessionFlow.PauseReason> = [], activity: SessionFlow.Activity = .annotating,
        question: SessionFlow.Question? = nil, session: SessionStore.Session? = nil, source: RecordingSource? = nil
    ) {
        controller.setStateForTesting(
            session: session ?? Fixtures.session(), drafts: drafts, mode: .open(SessionFlow.Open(activity: activity, pauses: pauses, question: question)), source: source
        )
    }

    // MARK: - Confirmations

    @Test func cancelWithoutAnnotationsClosesAtOnce() {
        open()
        controller.requestCancel()
        #expect(controller.confirmation == nil)
        #expect(controller.session == nil)
    }

    @Test func cancelWithAnnotationsAsksFirst() {
        open(drafts: Fixtures.drafts(2))
        controller.requestCancel()
        #expect(controller.confirmation == .cancelSession)

        controller.dismissConfirmation()
        #expect(controller.confirmation == nil)
        #expect(controller.drafts.count == 2)

        controller.requestCancel()
        controller.confirm()
        #expect(controller.session == nil)
        #expect(controller.drafts.isEmpty)
    }

    /// A clip that is not stopped is lost on cancel like a note, so × asks for it too.
    @Test func cancelAsksForAClipInProgress() {
        open(activity: .recording(.recording))
        controller.requestCancel()
        #expect(controller.confirmation == .cancelSession)
    }

    @Test func clearAllAsksAndKeepsTheSession() {
        open()
        controller.requestClearAll()
        #expect(controller.confirmation == nil)

        open(drafts: Fixtures.drafts(3))
        controller.requestClearAll()
        #expect(controller.confirmation == .clearAll)
        controller.confirm()
        #expect(controller.drafts.isEmpty)
        #expect(controller.session != nil)
    }

    @Test func escapeDismissesAndReturnConfirms() throws {
        let overlay = OverlayView(controller: controller)
        open(drafts: Fixtures.drafts(2), question: .clearAll)

        overlay.keyDown(with: try key(53))
        #expect(controller.confirmation == nil)
        #expect(controller.drafts.count == 2)

        controller.requestClearAll()
        overlay.keyDown(with: try key(36))
        #expect(controller.drafts.isEmpty)
    }

    @Test func deletingOneAnnotationDoesNotAsk() {
        let drafts = Fixtures.drafts(3)
        open(drafts: drafts)
        controller.deleteDraft(drafts[1].id)
        #expect(controller.confirmation == nil)
        #expect(controller.drafts.map(\.id) == [drafts[0].id, drafts[2].id])
    }

    // MARK: - Recordings on disk

    @Test func deletingARecordingDeletesItsVideo() throws {
        let clip = try Fixtures.clip(in: controller.archive.newClip(in: "a1b2c3d4"))
        open(drafts: [clip])
        controller.deleteDraft(clip.id)
        #expect(!FileManager.default.fileExists(atPath: try #require(Fixtures.video(of: clip)).path))
    }

    /// A cancelled session keeps its stopped recordings in History, like its notes, and a
    /// restore of it plays them again.
    @Test func cancellingKeepsStoppedRecordings() throws {
        let session = Fixtures.session()
        let clip = try Fixtures.clip(in: controller.archive.newClip(in: session.id))
        open(drafts: [clip] + Fixtures.drafts(1), session: session)

        controller.requestCancel()
        controller.confirm()
        controller.archive.flush()

        let video = try #require(Fixtures.video(of: clip))
        #expect(FileManager.default.fileExists(atPath: video.path))
        let record = try #require(controller.archive.record(session.id))
        #expect(record.notes.count == 2)
        let restored = AnnotationController.drafts(from: record, archive: controller.archive, into: "0f0f0f0f")
        #expect(restored.compactMap(Fixtures.video).count == 1)
    }

    // MARK: - Regressions of round 2

    /// The first comment saved enables Send at once, and deleting the last note disables it.
    @Test func sendFollowsTheNotes() throws {
        let pending = Pending(
            target: .region, frame: CGRect(x: 10, y: 10, width: 80, height: 40), marker: .zero, chip: "Region",
            capture: Task { Captures(image: nil, contextImage: nil) }
        )
        controller.setStateForTesting(
            session: Fixtures.session(), mode: .open(SessionFlow.Open(panel: .comment)), composer: .new(pending)
        )
        controller.submitComment(thenSend: false)
        #expect(controller.drafts.count == 1)
        #expect(controller.flow.canSend)

        controller.deleteDraft(try #require(controller.drafts.first).id)
        #expect(!controller.flow.canSend)
    }

    /// Choosing in recording mode offers a phone, and the HUD stays in recording mode.
    @Test func choosingInRecordingModeOffersAPhone() {
        let (screens, apps) = Fixtures.sources()
        controller.sourcePicker.injected = (screens, apps, .done)

        open(activity: .recording(.ready))
        controller.toggleWindowPick()
        controller.openSourcePicker()
        #expect(controller.isRecordMode)
        #expect(controller.sourcePicker.screens.contains { $0.source == .phone(Fixtures.phone) })

        open()
        controller.toggleWindowPick()
        controller.openSourcePicker()
        #expect(!controller.isRecordMode)
        #expect(!controller.sourcePicker.screens.contains { $0.source == .phone(Fixtures.phone) })
    }

    /// Clear History keeps the session on screen, whose notes and recordings are in use.
    @Test func clearHistoryKeepsTheSessionOnScreen() {
        let archive = Fixtures.archive()
        archive.save(Fixtures.record(id: "a1b2c3d4", notes: 1))
        archive.save(Fixtures.record(id: "b1b2c3d4", notes: 1))
        archive.flush()
        let history = HistoryModel(archive: archive, currentID: { "a1b2c3d4" })

        history.clear()

        #expect(archive.record("a1b2c3d4") != nil)
        #expect(archive.record("b1b2c3d4") == nil)
    }

    /// ⌘↩ is Send: it never answers a question, and Send waits under it.
    @Test func commandReturnNeverAnswersAQuestion() throws {
        let overlay = OverlayWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200), level: .normal, isWindowSized: true, controller: controller)
        defer { overlay.close() }
        let view = try #require(overlay.contentView)
        let commandReturn = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: overlay.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
        open(drafts: Fixtures.drafts(2), question: .cancelSession)

        view.keyDown(with: commandReturn)
        #expect(!controller.handleConfirmationKey(36, modifiers: .command))
        #expect(controller.confirmation == .cancelSession)
        #expect(controller.session != nil)
        #expect(HUDView.status(of: controller).title == "Annotating")
    }

    /// A restore and Open Browser wait while a clip records, as the window button does.
    @Test func aClipKeepsItsNotesAndSource() {
        open(drafts: Fixtures.drafts(1), activity: .recording(.recording))
        controller.restore(Fixtures.record(notes: 3))
        controller.annotateInBrowser()
        #expect(controller.drafts.count == 1)
        #expect(controller.confirmation == nil)
        #expect(controller.scope == nil)
    }

    /// While the report is made, notes are neither deleted nor edited.
    @Test func notesStayAsTheyAreWhileSending() {
        let unfinished = Task { () -> Captures in
            try? await Task.sleep(for: .seconds(3600))
            return Captures(image: nil, contextImage: nil)
        }
        let draft = Fixtures.drafts(1)[0]
        open(drafts: [Draft(annotation: draft.annotation, marker: draft.marker, chip: draft.chip, capture: unfinished)] + Fixtures.drafts(2).dropFirst())
        controller.send()

        controller.deleteDraft(draft.id)
        controller.updateComment(draft.id, "changed")
        #expect(controller.drafts.count == 2)
        #expect(controller.drafts.first?.annotation.comment == draft.annotation.comment)
    }

    // MARK: - Send

    /// "Copied" shows only once the report is saved and on the clipboard; while a screenshot
    /// is still being taken, the HUD says "Sending" and nothing is copied yet.
    @Test func copiedShowsOnlyAfterTheCopy() async throws {
        let unfinished = Task { () -> Captures in
            try? await Task.sleep(for: .seconds(3600))
            return Captures(image: nil, contextImage: nil)
        }
        let draft = Fixtures.drafts(1)[0]
        open(drafts: [Draft(annotation: draft.annotation, marker: draft.marker, chip: draft.chip, capture: unfinished)], session: Fixtures.session(isLocal: true))

        controller.send()
        #expect(HUDView.status(of: controller).title == "Sending")
        #expect(controller.sentConfirmation == nil)
        #expect(controller.pasteboard.string(forType: .string) == nil)

        open(drafts: Fixtures.drafts(1), session: Fixtures.session(isLocal: true))
        controller.send()
        try await until { controller.sentConfirmation != nil }
        #expect(controller.sentConfirmation == "Copied")
        #expect(controller.pasteboard.string(forType: .string)?.contains("Avatar and name are not vertically centered") == true)
    }

    /// While the report is made, the overlay takes nothing and × and Esc do nothing, so the
    /// report cannot be sent twice or lost.
    @Test func whileSendingNothingElseActs() {
        let unfinished = Task { () -> Captures in
            try? await Task.sleep(for: .seconds(3600))
            return Captures(image: nil, contextImage: nil)
        }
        let draft = Fixtures.drafts(1)[0]
        open(drafts: [Draft(annotation: draft.annotation, marker: draft.marker, chip: draft.chip, capture: unfinished)])
        controller.hover = Fixtures.hover()

        controller.send()
        #expect(controller.hover == nil)
        controller.requestCancel()
        controller.escapePressed()
        controller.send()
        #expect(controller.session != nil)
        #expect(controller.confirmation == nil)
        #expect(HUDView.status(of: controller).title == "Sending")
    }

    /// ⌘↩ follows the Send button: it sends while paused too, and not while choosing a window.
    @Test func commandReturnSendsWheneverSendIsEnabled() throws {
        let overlay = OverlayWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200), level: .normal, isWindowSized: true, controller: controller)
        defer { overlay.close() }
        let view = try #require(overlay.contentView)
        let send = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: overlay.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))

        open(drafts: Fixtures.drafts(1), activity: .picking(isRecordMode: false, isPickerOpen: false))
        view.keyDown(with: send)
        #expect(controller.isPickingWindow)

        open(drafts: Fixtures.drafts(1), pauses: [.user])
        view.keyDown(with: send)
        #expect(HUDView.status(of: controller).title == "Sending")
    }

    /// A source with no size, as an iPhone reports before it streams, is an error, not the
    /// exception that crashed Tilde; a phone's screen in portrait is fine.
    @Test func aRecordingNeedsASizeItCanWrite() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(throws: ScreenRecorder.Failure.badSize) {
            _ = try ScreenRecorder.makeWriter(width: 0, height: 0, to: folder.appendingPathComponent("a.mp4"))
        }
        let (writer, _) = try ScreenRecorder.makeWriter(width: 1290, height: 2796, to: folder.appendingPathComponent("b.mp4"))
        writer.cancelWriting()
    }

    /// A 5K screen records at 2560 px on its long side, in proportion; a phone is not scaled.
    @Test func videosAreAtMost2560PixelsLong() {
        #expect(ScreenRecorder.videoSize(of: CGSize(width: 5120, height: 2880)) == (2560, 1440))
        #expect(ScreenRecorder.videoSize(of: CGSize(width: 1170, height: 2532)) == (1170, 2532))
        #expect(ScreenRecorder.videoSize(of: CGSize(width: 3455, height: 2235)) == (2560, 1656))
    }

    /// Annotating takes only sources Tilde can draw on. A phone chosen for recording goes when
    /// recording mode ends, back to everything on screen.
    @Test func aPhoneIsARecordingSourceOnly() {
        let phone = Phone(id: "phone", name: "iPhone")
        open(activity: .picking(isRecordMode: false, isPickerOpen: false))
        controller.choose(.phone(phone))
        #expect(controller.source == nil)
        #expect(controller.isPickingWindow)

        open(activity: .picking(isRecordMode: true, isPickerOpen: false))
        controller.choose(.phone(phone))
        #expect(controller.source == .phone(phone))
        controller.toggleRecordingMode()
        #expect(controller.recording == nil)
        #expect(controller.source == nil)
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
        SessionFlow.Activity.annotating, .recording(.ready), .recording(.starting(operation: 0)), .recording(.recording),
        .recording(.paused), .recording(.finishing(operation: 0, thenSend: false)), .picking(isRecordMode: true, isPickerOpen: false),
    ])
    func everyModeFitsThePillWidth(activity: SessionFlow.Activity) {
        for pauses in [[], [SessionFlow.PauseReason.user]] as [Set<SessionFlow.PauseReason>] {
            let open = SessionFlow.Open(activity: activity, pauses: pauses)
            for mode in [SessionFlow.Mode.open(open), .sending(operation: 0, returnTo: open)] {
                controller.setStateForTesting(
                    session: Fixtures.session(isLocal: true), drafts: Fixtures.drafts(10), mode: mode, source: .window(Fixtures.window),
                    clipClock: (Date(), 3599)
                )
                let width = NSHostingView(rootView: HUDView(controller: controller, isEmbedded: true)).fittingSize.width
                #expect(width <= HUDView.embeddedWidth, "\(mode) needs \(width) pt, the pill has \(HUDView.embeddedWidth)")
                // The floating pill, inside the panel's 16 pt padding.
                let floating = NSHostingView(rootView: HUDView(controller: controller)).fittingSize.width - 32
                #expect(floating == HUDView.width, "\(mode) makes the floating pill \(floating) pt wide")
            }
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

    private func until(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(condition())
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
    /// stops with no change. A choice is taken only while choosing.
    @Test func windowButtonChoosesAgainAndTheScreenTileLiftsTheScope() {
        let elsewhere = CGPoint(x: -5000, y: -5000)
        open()
        controller.toggleWindowPick()
        #expect(controller.isPickingWindow)
        #expect(!controller.isSourcePickerOpen)
        controller.toggleWindowPick()
        #expect(!controller.isPickingWindow)

        controller.choose(.window(Fixtures.window))
        #expect(controller.scope == nil)

        controller.toggleWindowPick()
        controller.choose(.window(Fixtures.window))
        #expect(controller.scope == Fixtures.window)
        #expect(!controller.isPickingWindow)
        #expect(controller.scopeName == "Safari")
        #expect(!controller.allows(elsewhere))

        // Limited to a window, choosing takes the other windows too, and Esc keeps the limit.
        open(activity: .picking(isRecordMode: false, isPickerOpen: false), source: .window(Fixtures.window))
        #expect(controller.allows(elsewhere))
        controller.escapePressed()
        #expect(controller.scope == Fixtures.window)
        #expect(!controller.allows(elsewhere))

        open(activity: .picking(isRecordMode: false, isPickerOpen: false), source: .window(Fixtures.window))
        controller.choose(.screen(1))
        #expect(controller.scope == nil)
        #expect(!controller.isPickingWindow)
        #expect(controller.source == .screen(1))
    }

    /// The window button does nothing while a clip is in progress: a clip keeps its source.
    @Test func aClipKeepsItsSource() {
        for clip in [SessionFlow.Clip.starting(operation: 1), .recording, .paused, .finishing(operation: 1, thenSend: false)] {
            open(activity: .recording(clip))
            controller.toggleWindowPick()
            #expect(!controller.isPickingWindow, "\(clip)")
        }
    }

    /// The open picker takes no clicks on screen. "‹ Back" and Esc step back one level: an
    /// app's windows, then the picker, then choosing.
    @Test func theOpenPickerStepsBackOneLevelAtATime() {
        open(activity: .picking(isRecordMode: false, isPickerOpen: true))
        controller.click(at: CGPoint(x: -5000, y: -5000))
        #expect(controller.isSourcePickerOpen)
        #expect(controller.source == nil)

        controller.sourcePicker.openApp = Fixtures.window.pid
        controller.stepBackInSourcePicker()
        #expect(controller.sourcePicker.openApp == nil)
        #expect(controller.isSourcePickerOpen)

        controller.escapePressed()
        #expect(controller.isPickingWindow)
        #expect(!controller.isSourcePickerOpen)

        controller.escapePressed()
        #expect(!controller.isPickingWindow)
    }

    @Test func scopeEndsWhenTheWindowIsGone() {
        controller.setStateForTesting(session: Fixtures.session())
        controller.setScope(Fixtures.window)

        controller.refreshScope()

        #expect(controller.scope == nil)
        #expect(controller.notice?.rawValue == "Window closed")
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
        controller.setStateForTesting(session: Fixtures.session(), mode: .open(SessionFlow.Open(pauses: [.user, .otherApp])))

        controller.togglePause()

        #expect(controller.pauses.isEmpty)
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
        // Arguments: key, start key, pause key, paused, has a session.
        #expect(action(.control, .control, nil, false, false) == .start)
        #expect(action(.control, .control, nil, true, true) == .resume)
        // While annotating it does nothing; Esc pauses.
        #expect(action(.control, .control, nil, false, true) == nil)
        // The same key for start and pause: it also pauses while annotating.
        #expect(action(.control, .control, .control, false, true) == .togglePause)
        // Different keys each do only their own; the pause key is the pause command of the
        // mode, such as for the clip in recording mode.
        #expect(action(.option, .control, .option, false, true) == .togglePause)
        #expect(action(.option, .control, .option, false, false) == nil)
        #expect(action(.control, nil, nil, false, false) == nil)
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
        open(drafts: Fixtures.drafts(2), pauses: [.user], question: .clearAll)

        // Other keys pass on, such as to a focused text field.
        #expect(controller.handleConfirmationKey(0) == false)
        #expect(controller.handleConfirmationKey(53))
        #expect(controller.confirmation == nil)
        #expect(controller.drafts.count == 2)

        // Paused in a popped-out session: Esc asks, ↩ answers.
        controller.escapePressed()
        #expect(controller.confirmation == .cancelSession)
        open(drafts: Fixtures.drafts(2), pauses: [.user], question: .clearAll)
        #expect(controller.handleConfirmationKey(36))
        #expect(controller.drafts.isEmpty)
        #expect(controller.handleConfirmationKey(36) == false)
    }

    @Test func escEndsChoosingAWindowFirst() async throws {
        open(drafts: Fixtures.drafts(1), activity: .picking(isRecordMode: false, isPickerOpen: false))

        controller.escapePressed()

        #expect(!controller.isPickingWindow)
        #expect(controller.confirmation == nil)
    }

    @Test func escWhilePausedAlsoAsksToCancel() async throws {
        open(drafts: Fixtures.drafts(1), pauses: [.user])

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
