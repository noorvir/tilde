import Foundation
import TildeCore
import os

/// A session as saved on disk: who asked, where, its notes and how it ended.
struct SessionRecord: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        /// On screen, or left so by a crash or a quit: unfinished.
        case active
        case sent
        case cancelled
        /// Its notes went into a newer session.
        case restored
    }

    struct Note: Codable, Equatable, Identifiable {
        let id: UUID
        var comment: String
        let target: Target
        /// Quartz screen frame when it was made.
        let frame: CGRect
        let marker: CGPoint
        let chip: String
        let anchor: PageAnchor?

        static func == (lhs: Note, rhs: Note) -> Bool {
            lhs.id == rhs.id && lhs.comment == rhs.comment && lhs.frame == rhs.frame && lhs.chip == rhs.chip && lhs.anchor == rhs.anchor
        }
    }

    let id: String
    let created: Date
    var updated: Date
    /// The agent that asked, or "You".
    let client: String
    /// The machine the agent runs on; nil on this Mac.
    var node: String?
    let isLocal: Bool
    var state: State
    /// The page open in Tilde's browser, for a session there.
    var pageURL: String?
    /// The app of the window the session was limited to.
    var scopeApp: String?
    var notes: [Note]
    /// The inbox folder of the sent report.
    var reportFolder: String?

    /// The page or app, or who asked.
    var title: String {
        if let page = pageURL, let host = URL(string: page)?.host() {
            return host
        }
        if let scopeApp {
            return scopeApp
        }
        if isLocal {
            return "Session"
        }
        return node.map { "Session for \(client) on \($0)" } ?? "Session for \(client)"
    }
}

/// Sessions saved in `~/Library/Application Support/Tilde/Sessions/<id>/`: `session.json`,
/// written atomically, each note's images and its recordings, all only for the owner (0700
/// folders, 0600 files). Writes run on a background queue in order;
/// `flush()` waits for them, such as when Tilde quits.
final class SessionArchive: @unchecked Sendable {
    let root: URL
    private let queue = DispatchQueue(label: "tilde.archive")
    /// The records read so far, each with the time its file was written, so that a read
    /// decodes only the files that changed. Only on `queue`.
    private var readRecords: [String: (written: Date, record: SessionRecord)] = [:]

    /// Kept at least this long, and at least `keptCount` sessions whatever their age.
    static let keptDays = 30
    static let keptCount = 100

    init(root: URL = SessionArchive.defaultRoot) {
        self.root = root
    }

    /// Application Support, or the folder in `TILDE_SESSIONS` (the UX specs use their own).
    static let defaultRoot: URL = {
        if let path = ProcessInfo.processInfo.environment["TILDE_SESSIONS"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Tilde/Sessions", isDirectory: true)
    }()

    // MARK: - Writing

    func save(_ record: SessionRecord) {
        queue.async { [self] in
            write(record)
        }
    }

    /// Saves a session's images not on disk yet, keyed by file name.
    func saveImages(_ images: [String: Data], of id: String) {
        queue.async { [self] in
            let folder = folder(id)
            for (name, data) in images {
                let url = folder.appendingPathComponent(name)
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    continue
                }
                try? createPrivateFolder(folder)
                try? writePrivate(data, to: url)
            }
        }
    }

    /// Removes a note's saved images: its pictures were taken again, and the next save writes
    /// the new ones.
    func forgetImages(of note: UUID, in id: String) {
        queue.async { [self] in
            for name in [Self.imageName(note), Self.contextImageName(note)] {
                try? FileManager.default.removeItem(at: folder(id).appendingPathComponent(name))
            }
        }
    }

    /// Waits for the saves in progress.
    func flush() {
        queue.sync {}
    }

    func delete(_ id: String) {
        queue.async { [self] in
            try? FileManager.default.removeItem(at: folder(id))
        }
    }

    func deleteAll(except kept: String? = nil) {
        queue.async { [self] in
            for record in readAll() where record.id != kept {
                try? FileManager.default.removeItem(at: folder(record.id))
            }
        }
    }

    /// Deletes sessions older than `keptDays`, except the newest `keptCount`, and recordings
    /// that no note has, such as one in progress when Tilde quit. Recordings that older builds
    /// kept in `olderClips` (`~/.tilde/recordings`) go into their sessions first, and that
    /// folder goes once every one is in place.
    func prune(now: Date = Date(), olderClips: URL? = nil) {
        queue.async { [self] in
            if let olderClips, FileManager.default.fileExists(atPath: olderClips.path) {
                moveClips(from: olderClips)
            }
            let limit = now.addingTimeInterval(-Double(Self.keptDays) * 86_400)
            let records = readAll()
            for record in records.dropFirst(Self.keptCount) where record.updated < limit {
                try? FileManager.default.removeItem(at: folder(record.id))
            }
            for record in records.prefix(Self.keptCount) {
                removeClips(of: record)
            }
        }
    }

    /// A session's own name for another session's recording: a hard link in its folder, or a
    /// copy where a link cannot be made.
    func adopt(_ video: URL, into id: String) -> URL {
        let own = newClip(in: id)
        try? linkOrCopy(video, to: own)
        return own
    }

    /// Gives each session its own link (or copy) of the older recordings its notes have, also
    /// when two sessions share one, and saves it. The older folder goes only when all of them
    /// are in place; otherwise it stays, with every original, for the next launch. A session
    /// that cannot be read may have one, so it keeps the folder too.
    private func moveClips(from olderClips: URL) {
        var isComplete = true
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        for folder in folders {
            guard var record = read(folder.lastPathComponent) else {
                isComplete = false
                continue
            }
            var isChanged = false
            record.notes = record.notes.map { note in
                guard case .recording(let video, let seconds, let source) = note.target,
                      video.deletingLastPathComponent().standardizedFileURL == olderClips.standardizedFileURL,
                      FileManager.default.fileExists(atPath: video.path)
                else {
                    return note
                }
                let own = newClip(in: record.id)
                do {
                    try linkOrCopy(video, to: own)
                } catch {
                    isComplete = false
                    return note
                }
                isChanged = true
                let target = Target.recording(video: own, seconds: seconds, source: source)
                return SessionRecord.Note(id: note.id, comment: note.comment, target: target, frame: note.frame, marker: note.marker, chip: note.chip, anchor: note.anchor)
            }
            if isChanged, !write(record) {
                isComplete = false
            }
        }
        if isComplete {
            try? FileManager.default.removeItem(at: olderClips)
        }
    }

    private func removeClips(of record: SessionRecord) {
        let kept = Set(record.notes.compactMap { note -> String? in
            if case .recording(let video, _, _) = note.target {
                return video.lastPathComponent
            }
            return nil
        })
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(record.id), includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "mp4" && !kept.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Reading

    /// Every saved session, newest first.
    func all() -> [SessionRecord] {
        queue.sync { readAll() }
    }

    func record(_ id: String) -> SessionRecord? {
        queue.sync { read(id) }
    }

    /// A note's close-up and context image.
    func images(of note: SessionRecord.Note, in id: String) -> (image: Data?, contextImage: Data?) {
        let contextImage = try? Data(contentsOf: folder(id).appendingPathComponent(Self.contextImageName(note.id)))
        return (closeUp(of: note, in: id), contextImage)
    }

    /// A note's close-up alone, such as for its thumbnail.
    func closeUp(of note: SessionRecord.Note, in id: String) -> Data? {
        try? Data(contentsOf: folder(id).appendingPathComponent(Self.imageName(note.id)))
    }

    func folder(_ id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    /// A new file for a session's recording, in its folder, so that deleting the session or
    /// pruning History deletes it too.
    func newClip(in id: String) -> URL {
        let folder = folder(id)
        try? createPrivateFolder(root)
        try? createPrivateFolder(folder)
        return folder.appendingPathComponent("clip-\(UUID().uuidString).mp4")
    }

    static func imageName(_ id: UUID) -> String {
        "\(id.uuidString).png"
    }

    static func contextImageName(_ id: UUID) -> String {
        "\(id.uuidString)-context.png"
    }

    // MARK: - Files

    /// Saves a session's record; false when it could not.
    @discardableResult
    private func write(_ record: SessionRecord) -> Bool {
        let folder = folder(record.id)
        readRecords[record.id] = nil
        do {
            try createPrivateFolder(root)
            try createPrivateFolder(folder)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            // Atomic: a crash mid-write leaves the previous file.
            try writePrivate(encoder.encode(record), to: folder.appendingPathComponent("session.json"))
            return true
        } catch {
            Logger(subsystem: "dev.tilde.app", category: "archive").error("could not save session \(record.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func read(_ id: String) -> SessionRecord? {
        let file = folder(id).appendingPathComponent("session.json")
        guard let written = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
            readRecords[id] = nil
            return nil
        }
        if let read = readRecords[id], read.written == written {
            return read.record
        }
        readRecords[id] = nil
        guard let data = try? Data(contentsOf: file) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(SessionRecord.self, from: data) else {
            return nil
        }
        readRecords[id] = (written, record)
        return record
    }

    private func readAll() -> [SessionRecord] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let ids = folders.map(\.lastPathComponent)
        // A session that is deleted, also in the Finder, is not kept.
        let kept = Set(ids)
        readRecords = readRecords.filter { kept.contains($0.key) }
        return ids.compactMap(read).sorted { $0.updated > $1.updated }
    }
}
