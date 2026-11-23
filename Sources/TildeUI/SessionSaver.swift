import AppKit
import TildeCore

/// Keeps the saved record of the session on screen current: it saves half a second after a
/// change, every 10 seconds, and before the Mac sleeps. It also turns a saved session back
/// into notes.
@MainActor
final class SessionSaver {
    /// The session on screen as it is now.
    struct Snapshot {
        let session: SessionStore.Session
        let drafts: [Draft]
        /// The page open in Tilde's browser, for a session there.
        let pageURL: String?
        /// The app of the window the session is limited to.
        let scopeApp: String?
        /// Work that is not a note yet, saved as unfinished notes so that a crash keeps it: the
        /// open comment with its typed text, and Draw's shapes with no comment yet.
        var unfinished: [Unfinished] = []
    }

    struct Unfinished {
        let note: SessionRecord.Note
        let capture: Task<Captures, Never>?
    }

    let archive: SessionArchive
    /// What to save; nil with no session on screen.
    var snapshot: () -> Snapshot? = { nil }
    /// While the comment box is open, the save every 10 seconds waits.
    var isHeld = false

    /// When the session on screen started.
    private var created = Date()
    private let saveTime = Countdown()
    private var checkpointTimer: Timer?
    private var sleepObserver: NSObjectProtocol?

    init(archive: SessionArchive) {
        self.archive = archive
    }

    /// Saves a session that started at `created` from now on, until `stop()`.
    func start(created: Date) {
        self.created = created
        checkpointTimer?.invalidate()
        checkpointTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isHeld else {
                    return
                }
                self.save()
            }
        }
        if sleepObserver == nil {
            sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.save()
                }
            }
        }
    }

    func stop() {
        checkpointTimer?.invalidate()
        checkpointTimer = nil
        saveTime.cancel()
    }

    /// Saves half a second after the last change, so a burst of changes is one write.
    func saveSoon() {
        guard snapshot() != nil else {
            return
        }
        saveTime.start(0.5) { [weak self] in
            self?.save()
        }
    }

    /// Saves the session on screen with its notes; images follow once their captures are done.
    func save(state: SessionRecord.State = .active, reportFolder: URL? = nil) {
        guard let snapshot = snapshot() else {
            return
        }
        let record = record(of: snapshot, state: state, reportFolder: reportFolder)
        archive.save(record)
        let archive = self.archive
        Task {
            var images: [String: Data] = [:]
            for draft in snapshot.drafts {
                let captures = await draft.capture.value
                images[SessionArchive.imageName(draft.id)] = captures.image
                images[SessionArchive.contextImageName(draft.id)] = captures.contextImage
            }
            for unfinished in snapshot.unfinished {
                guard let captures = await unfinished.capture?.value else {
                    continue
                }
                images[SessionArchive.imageName(unfinished.note.id)] = captures.image
                images[SessionArchive.contextImageName(unfinished.note.id)] = captures.contextImage
            }
            archive.saveImages(images, of: record.id, notes: record.notes.map(\.id))
        }
    }

    /// Saves what is on screen at once, without images still being captured, such as when
    /// Tilde quits.
    func saveBeforeQuitting() {
        if let snapshot = snapshot() {
            archive.save(record(of: snapshot, state: .active, reportFolder: nil))
        }
        archive.flush()
    }

    private func record(of snapshot: Snapshot, state: SessionRecord.State, reportFolder: URL?) -> SessionRecord {
        let session = snapshot.session
        let notes = snapshot.drafts.map { draft in
            SessionRecord.Note(
                id: draft.id, comment: draft.annotation.comment, target: draft.annotation.target, frame: draft.annotation.frame,
                marker: draft.marker, chip: draft.chip, anchor: draft.anchor, isUnfinished: draft.isUnfinished ? true : nil
            )
        } + snapshot.unfinished.map(\.note)
        return SessionRecord(
            id: session.id, created: created, updated: Date(), client: session.client, node: session.node, isLocal: session.isLocal, state: state,
            pageURL: snapshot.pageURL, scopeApp: snapshot.scopeApp, notes: notes, reportFolder: reportFolder?.path
        )
    }

    // MARK: - Saved sessions

    /// Notes of a saved session as drafts, with their saved images.
    /// A recording comes too while its file is there; into another session, the file is
    /// linked into that session's folder, so that each session owns its recordings.
    static func drafts(from record: SessionRecord, archive: SessionArchive, into id: String) -> [Draft] {
        record.notes.compactMap { note in
            var target = note.target
            if case .recording(let video, let seconds, let source) = note.target {
                guard FileManager.default.fileExists(atPath: video.path) else {
                    return nil
                }
                if record.id != id {
                    target = .recording(video: archive.adopt(video, into: id), seconds: seconds, source: source)
                }
            }
            let images = archive.images(of: note, in: record.id)
            let captures = Captures(image: images.image, contextImage: images.contextImage)
            // The preview and the list show the annotation's own images.
            let annotation = Annotation(
                id: note.id, comment: note.comment, target: target, frame: note.frame, image: images.image, contextImage: images.contextImage
            )
            var draft = Draft(annotation: annotation, marker: note.marker, chip: note.chip, capture: Task { captures }, anchor: note.anchor)
            draft.isRestored = true
            // A comment written before a crash finishes its note, as in the preview; a
            // wireframe only Done finishes.
            let hasComment = !note.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            draft.isUnfinished = note.isUnfinished == true && (draft.isWireframe || !hasComment)
            return draft
        }
    }

    /// Marks an unfinished or cancelled session as restored, so it is not offered again; a
    /// sent one stays sent.
    func markRestored(_ record: SessionRecord) {
        guard record.state != .sent else {
            return
        }
        var old = record
        old.state = .restored
        old.updated = Date()
        archive.save(old)
    }

    /// Keeps an unfinished session in the history as cancelled.
    func discard(_ record: SessionRecord) {
        var old = record
        old.state = .cancelled
        old.updated = Date()
        archive.save(old)
    }
}
