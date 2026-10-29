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
        return isLocal ? "Session" : "Session for \(client)"
    }
}

/// Sessions saved in `~/Library/Application Support/Tilde/Sessions/<id>/`: `session.json`,
/// written atomically, and each note's images. Writes run on a background queue in order;
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
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
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

    func deleteAll() {
        queue.async { [self] in
            for record in readAll() {
                try? FileManager.default.removeItem(at: folder(record.id))
            }
        }
    }

    /// Deletes sessions older than `keptDays`, except the newest `keptCount`.
    func prune(now: Date = Date()) {
        queue.async { [self] in
            let limit = now.addingTimeInterval(-Double(Self.keptDays) * 86_400)
            for record in readAll().dropFirst(Self.keptCount) where record.updated < limit {
                try? FileManager.default.removeItem(at: folder(record.id))
            }
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
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            // Atomic: a crash mid-write leaves the previous file.
            try encoder.encode(record).write(to: folder.appendingPathComponent("session.json"), options: .atomic)
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
