@testable import TildeUI
import TildeCore
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct SessionArchiveTests {
    @Test func aSavedSessionLoadsBackWithItsImages() throws {
        let archive = Fixtures.archive()
        let record = Fixtures.record()
        let note = try #require(record.notes.first)

        archive.save(record)
        archive.saveImages([SessionArchive.imageName(note.id): Data([1, 2, 3])], of: record.id)
        archive.flush()

        #expect(archive.record(record.id) == record)
        #expect(archive.all() == [record])
        #expect(archive.images(of: note, in: record.id).image == Data([1, 2, 3]))
        #expect(archive.images(of: note, in: record.id).contextImage == nil)
    }

    @Test func restoredNotesHaveTheirSavedImages() async throws {
        let archive = Fixtures.archive()
        let record = Fixtures.record(isLocal: true, notes: 1, pageURL: nil)
        let note = try #require(record.notes.first)
        archive.save(record)
        archive.saveImages([SessionArchive.imageName(note.id): Data([7]), SessionArchive.contextImageName(note.id): Data([8])], of: record.id)
        archive.flush()

        let drafts = AnnotationController.drafts(from: record, archive: archive, into: record.id)

        // The preview and the list read the annotation's images; the report reads the captures.
        #expect(drafts.first?.annotation.image == Data([7]))
        #expect(drafts.first?.annotation.contextImage == Data([8]))
        let captures = await drafts.first?.capture.value
        #expect(captures?.image == Data([7]))
    }

    @Test func savingReplacesTheFileWholeAndLeavesNoTemporaryFiles() throws {
        let archive = Fixtures.archive()
        var record = Fixtures.record()
        archive.save(record)
        record.notes[0].comment = "Changed"
        record.state = .sent
        archive.save(record)
        archive.flush()

        #expect(archive.record(record.id)?.notes[0].comment == "Changed")
        #expect(archive.record(record.id)?.state == .sent)
        let files = try FileManager.default.contentsOfDirectory(atPath: archive.folder(record.id).path)
        #expect(files == ["session.json"])
    }

    @Test func pruningKeepsThirtyDaysAndTheLastHundred() {
        let archive = Fixtures.archive()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // 105 old sessions and 2 recent ones.
        for index in 0..<105 {
            archive.save(Fixtures.record(id: "old\(index)", updated: now.addingTimeInterval(-40 * 86_400 - Double(index))))
        }
        archive.save(Fixtures.record(id: "new1", updated: now.addingTimeInterval(-60)))
        archive.save(Fixtures.record(id: "new2", updated: now.addingTimeInterval(-86_400)))
        archive.prune(now: now)
        archive.flush()

        let kept = archive.all()
        #expect(kept.count == SessionArchive.keptCount)
        #expect(kept.prefix(2).map(\.id) == ["new1", "new2"])
        #expect(kept.last?.id == "old97")
    }

    @Test func aSessionIsSavedSoonAfterAChange() async throws {
        let archive = Fixtures.archive()
        let controller = AnnotationController(store: SessionStore(), browser: BrowserController(), archive: archive)
        try await Task.sleep(for: .milliseconds(20))
        let session = Fixtures.session()
        controller.setStateForTesting(session: session, drafts: Fixtures.drafts(2))

        // Debounced: not at once, but within about a second.
        archive.flush()
        #expect(archive.record(session.id) == nil)
        try await Task.sleep(for: .milliseconds(1300))
        archive.flush()

        let record = try #require(archive.record(session.id))
        #expect(record.state == .active)
        #expect(record.notes.map(\.comment) == Fixtures.drafts(2).map(\.annotation.comment))
    }

    @Test func anUnfinishedSessionCanBeRestoredAfterARestart() async throws {
        let archive = Fixtures.archive()
        let record = Fixtures.record(isLocal: true, notes: 3, pageURL: nil)
        archive.save(record)
        archive.flush()

        // Tilde starts again: the session is still marked active, so it is unfinished.
        let controller = AnnotationController(store: SessionStore(), browser: BrowserController(), archive: archive)
        try await Task.sleep(for: .milliseconds(20))
        #expect(archive.all().filter { $0.state == .active }.map(\.id) == [record.id])

        controller.restore(record)
        try await waitUntil { controller.drafts.count == 3 }

        #expect(controller.drafts.map(\.annotation.comment) == record.notes.map(\.comment))
        #expect(controller.session?.isLocal == true)
        archive.flush()
        #expect(archive.record(record.id)?.state == .restored)
    }

    @Test func aSentSessionCanBeOpenedAgainAndStaysSent() async throws {
        let archive = Fixtures.archive()
        let record = Fixtures.record(state: .sent, notes: 2, pageURL: nil)
        archive.save(record)
        archive.flush()
        let controller = AnnotationController(store: SessionStore(), browser: BrowserController(), archive: archive)
        try await Task.sleep(for: .milliseconds(20))
        #expect(HistoryModel(archive: archive).canRestore(record))

        controller.restore(record)
        try await waitUntil { controller.drafts.count == 2 }

        archive.flush()
        #expect(archive.record(record.id)?.state == .sent)
    }

    @Test func restoringOverNotesOnScreenAsksThenReplacesThem() async throws {
        let archive = Fixtures.archive()
        let record = Fixtures.record(state: .cancelled, notes: 3, pageURL: nil)
        archive.save(record)
        archive.flush()
        let controller = AnnotationController(store: SessionStore(), browser: BrowserController(), archive: archive)
        try await Task.sleep(for: .milliseconds(20))
        controller.setStateForTesting(session: Fixtures.session(), drafts: Array(Fixtures.drafts(1)))

        controller.restore(record)
        #expect(controller.confirmation == .restore)
        #expect(controller.restoreRecord == record)
        #expect(controller.drafts.count == 1)

        controller.confirm()
        #expect(controller.drafts.map(\.annotation.comment) == record.notes.map(\.comment))
        archive.flush()
        #expect(archive.record(record.id)?.state == .restored)
    }

    @Test func anAgentWaitingForItsSessionGetsItBackWithItsNotes() async throws {
        let archive = Fixtures.archive()
        let record = Fixtures.record(client: "Codex", notes: 2, pageURL: nil)
        archive.save(record)
        archive.flush()

        let store = SessionStore()
        let controller = AnnotationController(store: store, browser: BrowserController(), archive: archive)
        store.reattach = { id, node in controller.reattach(id, node: node) }
        try await Task.sleep(for: .milliseconds(20))

        // Not for an agent on another machine.
        #expect(await store.wait(for: record.id, node: "box", seconds: 0) == nil)

        let state = await store.wait(for: record.id, node: nil, seconds: 0)
        #expect(state != nil)
        #expect(store.session(record.id)?.client == "Codex")
        #expect(store.session(record.id)?.isLocal == false)
        try await waitUntil { controller.drafts.count == 2 }
        #expect(controller.session?.id == record.id)

        // Unknown ids, and ids that are not Tilde's, find nothing.
        #expect(await store.wait(for: "0badc0de", node: nil, seconds: 0) == nil)
        #expect(await store.wait(for: "../x", node: nil, seconds: 0) == nil)
    }

    /// A session owns its recordings: restored into another session, a clip is linked into
    /// that session's folder; one gone with its session is left out.
    @Test func aRestoredRecordingBelongsToTheNewSession() throws {
        let archive = Fixtures.archive()
        let clip = try Fixtures.clip(in: archive.newClip(in: "a1b2c3d4"))
        var record = Fixtures.record(notes: 0, pageURL: nil)
        record.notes = [SessionRecord.Note(
            id: clip.id, comment: "", target: clip.annotation.target, frame: clip.annotation.frame, marker: .zero, chip: clip.chip, anchor: nil
        )]

        let drafts = AnnotationController.drafts(from: record, archive: archive, into: "0e0e0e0e")
        let video = try #require(drafts.first.flatMap(Fixtures.video))
        #expect(video.deletingLastPathComponent() == archive.folder("0e0e0e0e"))
        #expect(FileManager.default.fileExists(atPath: video.path))

        try FileManager.default.removeItem(at: try #require(Fixtures.video(of: clip)))
        #expect(AnnotationController.drafts(from: record, archive: archive, into: record.id).isEmpty)
    }

    /// Recordings no note has, such as one in progress when Tilde quit, go at launch.
    @Test func pruningDeletesRecordingsNoNoteHas() throws {
        let archive = Fixtures.archive()
        let record = Fixtures.record(notes: 1, pageURL: nil)
        archive.save(record)
        archive.flush()
        let orphan = archive.newClip(in: record.id)
        try Data([1]).write(to: orphan)

        archive.prune()
        archive.flush()

        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(archive.record(record.id) != nil)
    }

    /// Only the owner can open a saved session.
    @Test func savedSessionsArePrivate() throws {
        let archive = Fixtures.archive()
        let record = Fixtures.record(notes: 1, pageURL: nil)
        archive.save(record)
        archive.flush()

        let folder = try FileManager.default.attributesOfItem(atPath: archive.folder(record.id).path)
        let file = try FileManager.default.attributesOfItem(atPath: archive.folder(record.id).appendingPathComponent("session.json").path)
        #expect(folder[.posixPermissions] as? Int == 0o700)
        #expect(file[.posixPermissions] as? Int == 0o600)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }
}

@MainActor
struct CommentTypingTests {
    @Test func typingDoesNotRedrawTheHUDOrTheOverlay() {
        let controller = AnnotationController(store: SessionStore(), browser: BrowserController())
        var changes = 0
        let subscription = controller.objectWillChange.sink { changes += 1 }
        controller.commentText = "typed"
        #expect(changes == 0)
        #expect(controller.commentText == "typed")
        subscription.cancel()
    }
}
