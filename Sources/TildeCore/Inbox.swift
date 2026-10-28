import Foundation

/// Writes a sent feedback batch to `~/.tilde/inbox/<time>_<session>/` as
/// `feedback.md` plus the close-up and context PNGs of each annotation, and returns the folder.
public func saveToInbox(_ feedback: Feedback, sessionID: String, root: URL = inboxRoot) throws -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

    let folder = root.appendingPathComponent("\(formatter.string(from: Date()))_\(sessionID)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    for (index, annotation) in feedback.annotations.enumerated() {
        if let image = annotation.image {
            try image.write(to: folder.appendingPathComponent(imageName(index + 1)))
        }
        if let contextImage = annotation.contextImage {
            try contextImage.write(to: folder.appendingPathComponent(contextImageName(index + 1)))
        }
    }

    let report = reportText(for: feedback, folder: folder)
    try report.write(to: folder.appendingPathComponent("feedback.md"), atomically: true, encoding: .utf8)
    return folder
}

/// `~/.tilde/inbox`, or the folder in `TILDE_INBOX` (the e2e harness uses its own).
public let inboxRoot: URL = {
    if let path = ProcessInfo.processInfo.environment["TILDE_INBOX"], !path.isEmpty {
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tilde/inbox", isDirectory: true)
}()

/// The newest batch folder in the inbox, or nil when nothing was sent yet.
public func latestInboxFolder(root: URL = inboxRoot) -> URL? {
    recentInboxFolders(root: root, limit: 1).first
}

/// Sent batch folders, newest first.
public func recentInboxFolders(root: URL = inboxRoot, limit: Int) -> [URL] {
    let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    // Folder names start with the time, so the newest sorts first in reverse order.
    return Array(
        folders
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("feedback.md").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)
    )
}
