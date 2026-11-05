import Foundation
import TildeCore

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

    /// Kept at least this long, and at least `keptCount` sessions whatever their age.
    static let keptDays = 30
    static let keptCount = 100

    init(root: URL = SessionArchive.defaultRoot) {
        self.root = root
    }

    /// Application Support, or the folder in `TILDE_SESSIONS` (tests and the e2e use their own).
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
    /// that no note has, such as one in progress when Tilde quit.
    func prune(now: Date = Date()) {
        queue.async { [self] in
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
        let folder = folder(id)
        let image = try? Data(contentsOf: folder.appendingPathComponent(Self.imageName(note.id)))
        let contextImage = try? Data(contentsOf: folder.appendingPathComponent(Self.contextImageName(note.id)))
        return (image, contextImage)
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

    private func write(_ record: SessionRecord) {
        let folder = folder(record.id)
        do {
            try createPrivateFolder(root)
            try createPrivateFolder(folder)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            // Atomic: a crash mid-write leaves the previous file.
            try writePrivate(encoder.encode(record), to: folder.appendingPathComponent("session.json"))
        } catch {
            NSLog("Tilde could not save session \(record.id): \(error.localizedDescription)")
        }
    }

    private func read(_ id: String) -> SessionRecord? {
        guard let data = try? Data(contentsOf: folder(id).appendingPathComponent("session.json")) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SessionRecord.self, from: data)
    }

    private func readAll() -> [SessionRecord] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { read($0.lastPathComponent) }.sorted { $0.updated > $1.updated }
    }
}
