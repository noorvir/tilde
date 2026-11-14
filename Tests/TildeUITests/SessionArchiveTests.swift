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

    /// The archive keeps the sessions it has read, and reads a session again when its file is
    /// another one: saved again, written by something else, or deleted.
    @Test func aSavedSessionIsReadAgainWhenItsFileChanges() throws {
        let archive = Fixtures.archive()
        var record = Fixtures.record(notes: 1)
        archive.save(record)
        #expect(archive.all() == [record])

        record.state = .sent
        archive.save(record)
        #expect(archive.all().map(\.state) == [.sent])

        let file = archive.folder(record.id).appendingPathComponent("session.json")
        let text = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "\"sent\"", with: "\"cancelled\"")
        try text.write(to: file, atomically: true, encoding: .utf8)
        #expect(archive.all().map(\.state) == [.cancelled])
        #expect(archive.record(record.id)?.state == .cancelled)

        try FileManager.default.removeItem(at: archive.folder(record.id))
        #expect(archive.all().isEmpty)
        #expect(archive.record(record.id) == nil)
    }

    /// History reads the saved sessions away from the main thread, after a delete in progress.
    @Test func historyShowsTheSessionsThatAreLeft() async throws {
        let archive = Fixtures.archive()
        let kept = Fixtures.record(id: "a1b2c3d4", notes: 1)
        let deleted = Fixtures.record(id: "b1b2c3d4", notes: 1, updated: Date(timeIntervalSince1970: 1_792_000_000))
        archive.save(kept)
        archive.save(deleted)
        let history = HistoryModel(archive: archive)

        history.reload()
        #expect(!history.hasRead)
        try await until { history.records == [kept, deleted] }
        #expect(history.hasRead)

        history.delete(deleted)
        try await until { history.records == [kept] }
    }

    /// A note whose pictures were taken again, such as a wireframe drawn again, has the new
    /// ones: an image on disk is otherwise never written again.
    @Test func aNoteWhosePicturesWereTakenAgainHasTheNewOnes() throws {
        let archive = Fixtures.archive()
        let record = Fixtures.record(isLocal: true, notes: 1, pageURL: nil)
        let note = try #require(record.notes.first)
        archive.save(record)
        archive.saveImages([SessionArchive.imageName(note.id): Data([7])], of: record.id)
        archive.forgetImages(of: note.id, in: record.id)
        archive.saveImages([SessionArchive.imageName(note.id): Data([9])], of: record.id)
        archive.flush()

        #expect(archive.closeUp(of: note, in: record.id) == Data([9]))
    }

    @Test func restoredNotesHaveTheirSavedImages() async throws {
        let archive = Fixtures.archive()
        let record = Fixtures.record(isLocal: true, notes: 1, pageURL: nil)
        let note = try #require(record.notes.first)
        archive.save(record)
        archive.saveImages([SessionArchive.imageName(note.id): Data([7]), SessionArchive.contextImageName(note.id): Data([8])], of: record.id)
        archive.flush()

        let drafts = SessionSaver.drafts(from: record, archive: archive, into: record.id)

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
        let controller = AnnotationController(store: SessionStore(), browser: BrowserController(), archive: archive, defaults: MemoryDefaults())
        await Fixtures.storeUpdated()
        let session = Fixtures.session()
        controller.setStateForTesting(session: session, drafts: Fixtures.drafts(2))

        // Debounced: not at once, but soon after.
        archive.flush()
        #expect(archive.record(session.id) == nil)
        try await until {
            archive.flush()
            return archive.record(session.id) != nil
        }

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
        let controller = AnnotationController(store: SessionStore(), browser: BrowserController(), archive: archive, defaults: MemoryDefaults())
        await Fixtures.storeUpdated()
        #expect(archive.all().filter { $0.state == .active }.map(\.id) == [record.id])

        controller.restore(record)
        try await until { controller.drafts.count == 3 }

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
        let controller = AnnotationController(store: SessionStore(), browser: BrowserController(), archive: archive, defaults: MemoryDefaults())
        await Fixtures.storeUpdated()
        #expect(HistoryModel(archive: archive).canRestore(record))

        controller.restore(record)
        try await until { controller.drafts.count == 2 }

        archive.flush()
        #expect(archive.record(record.id)?.state == .sent)
    }

    @Test func restoringOverNotesOnScreenAsksThenReplacesThem() async throws {
        let archive = Fixtures.archive()
        let record = Fixtures.record(state: .cancelled, notes: 3, pageURL: nil)
        archive.save(record)
        archive.flush()
        let controller = AnnotationController(store: SessionStore(), browser: BrowserController(), archive: archive, defaults: MemoryDefaults())
        await Fixtures.storeUpdated()
        controller.setStateForTesting(session: Fixtures.session(), drafts: Array(Fixtures.drafts(1)))

        controller.restore(record)
        #expect(controller.confirmation == .restore)
        #expect(controller.restoreRecord == record)
        #expect(controller.drafts.count == 1)

        controller.dispatch(.confirm)
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
        let controller = AnnotationController(store: store, browser: BrowserController(), archive: archive, defaults: MemoryDefaults())
        store.reattach = { id, node in controller.reattach(id, node: node) }
        await Fixtures.storeUpdated()

        // Not for an agent on another machine.
        #expect(await store.wait(for: record.id, node: "box", seconds: 0) == nil)

        let state = await store.wait(for: record.id, node: nil, seconds: 0)
        #expect(state != nil)
        #expect(store.session(record.id)?.client == "Codex")
        #expect(store.session(record.id)?.isLocal == false)
        try await until { controller.drafts.count == 2 }
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

        let drafts = SessionSaver.drafts(from: record, archive: archive, into: "0e0e0e0e")
        let video = try #require(drafts.first.flatMap(Fixtures.video))
        #expect(video.deletingLastPathComponent() == archive.folder("0e0e0e0e"))
        #expect(FileManager.default.fileExists(atPath: video.path))

        try FileManager.default.removeItem(at: try #require(Fixtures.video(of: clip)))
        #expect(SessionSaver.drafts(from: record, archive: archive, into: record.id).isEmpty)
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

    /// Recordings an older Tilde kept in ~/.tilde/recordings move into their sessions, and
    /// that folder goes.
    @Test func olderRecordingsMoveIntoTheirSessions() throws {
        let archive = Fixtures.archive()
        let older = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-recordings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        let clip = try Fixtures.clip(in: older.appendingPathComponent("old.mp4"))
        var record = Fixtures.record(notes: 0, pageURL: nil)
        record.notes = [SessionRecord.Note(id: clip.id, comment: "", target: clip.annotation.target, frame: .zero, marker: .zero, chip: clip.chip, anchor: nil)]
        archive.save(record)
        archive.flush()

        archive.prune(olderClips: older)
        archive.flush()

        let moved = try #require(archive.record(record.id)?.notes.first)
        guard case .recording(let video, _, _) = moved.target else {
            Issue.record("not a recording")
            return
        }
        #expect(video.deletingLastPathComponent() == archive.folder(record.id))
        #expect(FileManager.default.fileExists(atPath: video.path))
        #expect(!FileManager.default.fileExists(atPath: older.path))
    }

    /// Two sessions that share an older recording each get their own; the older folder goes
    /// only then.
    @Test func sessionsSharingAnOlderRecordingEachGetIt() throws {
        let archive = Fixtures.archive()
        let older = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-recordings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        let clip = try Fixtures.clip(in: older.appendingPathComponent("old.mp4"))
        let note = SessionRecord.Note(id: clip.id, comment: "", target: clip.annotation.target, frame: .zero, marker: .zero, chip: clip.chip, anchor: nil)
        let ids = ["a1b2c3d4", "b1b2c3d4"]
        for id in ids {
            var record = Fixtures.record(id: id, notes: 0, pageURL: nil)
            record.notes = [note]
            archive.save(record)
        }
        archive.flush()

        archive.prune(olderClips: older)
        archive.flush()

        for id in ids {
            let target = try #require(archive.record(id)?.notes.first?.target)
            guard case .recording(let video, _, _) = target else {
                Issue.record("not a recording")
                return
            }
            #expect(video.deletingLastPathComponent() == archive.folder(id))
            #expect(FileManager.default.fileExists(atPath: video.path))
        }
        #expect(!FileManager.default.fileExists(atPath: older.path))
    }

    /// When a session cannot get its own recording, the older one stays where it was, and so
    /// does the folder, for the next launch.
    @Test func anOlderRecordingThatCannotMoveStays() throws {
        let archive = Fixtures.archive()
        let older = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-recordings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        let clip = try Fixtures.clip(in: older.appendingPathComponent("old.mp4"))
        var record = Fixtures.record(notes: 0, pageURL: nil)
        record.notes = [SessionRecord.Note(id: clip.id, comment: "", target: clip.annotation.target, frame: .zero, marker: .zero, chip: clip.chip, anchor: nil)]
        archive.save(record)
        archive.flush()
        // A session folder that cannot take a file, as on a full disk.
        let folder = archive.folder(record.id)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: folder.path) }

        archive.prune(olderClips: older)
        archive.flush()

        let target = try #require(archive.record(record.id)?.notes.first?.target)
        guard case .recording(let video, _, _) = target else {
            Issue.record("not a recording")
            return
        }
        #expect(video == older.appendingPathComponent("old.mp4"))
        #expect(FileManager.default.fileExists(atPath: video.path))
    }

    /// A session that cannot be read may have an older recording: the older folder stays.
    @Test func anUnreadableSessionKeepsTheOlderRecordings() throws {
        let archive = Fixtures.archive()
        let older = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-recordings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        _ = try Fixtures.clip(in: older.appendingPathComponent("old.mp4"))
        let record = Fixtures.record(notes: 0, pageURL: nil)
        archive.save(record)
        archive.flush()
        try Data("{".utf8).write(to: archive.folder(record.id).appendingPathComponent("session.json"))

        archive.prune(olderClips: older)
        archive.flush()

        #expect(FileManager.default.fileExists(atPath: older.appendingPathComponent("old.mp4").path))
    }

    /// History's Copy Report of a sent session is the report it was sent with, whose image
    /// numbers match its folder's files.
    @Test func copyReportReusesTheSentReport() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("# The sent report".utf8).write(to: folder.appendingPathComponent("feedback.md"))
        var record = Fixtures.record(notes: 2, pageURL: nil)
        record.reportFolder = folder.path

        #expect(HistoryModel.report(of: record, archive: Fixtures.archive()) == "# The sent report")
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
}

@MainActor
struct CommentTypingTests {
    @Test func typingDoesNotRedrawTheHUDOrTheOverlay() {
        let controller = AnnotationController(store: SessionStore(), browser: BrowserController(), archive: Fixtures.archive(), defaults: MemoryDefaults())
        var changes = 0
        let subscription = controller.objectWillChange.sink { changes += 1 }
        controller.commentBox.text = "typed"
        #expect(changes == 0)
        #expect(controller.commentBox.text == "typed")
        subscription.cancel()
    }

    /// A view observes the controller for the flow, the session and the notes, and each part it
    /// shows: a change of a part redraws only the views that observe that part.
    @Test func aPartDoesNotRedrawTheViewsOfTheOtherParts() {
        let controller = AnnotationController(store: SessionStore(), browser: BrowserController(), archive: Fixtures.archive(), defaults: MemoryDefaults())
        var changes = 0
        let subscription = controller.objectWillChange.sink { changes += 1 }
        controller.previewCard.expandedImage = .context
        controller.hud.showsList = true
        controller.notices.show(.windowClosed)
        #expect(changes == 0)
        subscription.cancel()
    }
}
