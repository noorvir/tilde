import Foundation

/// Writes a sent feedback batch to `~/.tilde/inbox/<time>_<session>/` as
/// `feedback.md` plus the close-up and context PNGs of each annotation and the video of each
/// recording, and returns the folder. Only the owner can open it. A report for an agent on
/// another machine names that machine in `.node`, so that only it lists the report.
public func saveToInbox(_ feedback: Feedback, sessionID: String, node: String? = nil, root: URL = inboxRoot) throws -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

    let folder = root.appendingPathComponent("\(formatter.string(from: Date()))_\(sessionID)", isDirectory: true)
    try createPrivateFolder(root)
    try createPrivateFolder(folder)

    for (index, annotation) in feedback.annotations.enumerated() {
        if let image = annotation.image {
            try writePrivate(image, to: folder.appendingPathComponent(imageName(index + 1)))
        }
        if let contextImage = annotation.contextImage {
            try writePrivate(contextImage, to: folder.appendingPathComponent(contextImageName(index + 1)))
        }
        if case .recording(let video, _, _) = annotation.target {
            try linkOrCopy(video, to: folder.appendingPathComponent(videoName(index + 1)))
        }
    }
    if let node {
        try writePrivate(Data(node.utf8), to: folder.appendingPathComponent(".node"))
    }

    let report = reportText(for: feedback, folder: folder)
    try writePrivate(Data(report.utf8), to: folder.appendingPathComponent("feedback.md"))
    return folder
}

/// Deletes reports older than `keptDays`, except the newest `keptCount`, as History keeps
/// sessions. Folder names start with the time, so they sort newest last.
public func pruneInbox(root: URL = inboxRoot, now: Date = Date(), keptDays: Int = 30, keptCount: Int = 100) {
    let limit = now.addingTimeInterval(-Double(keptDays) * 86_400)
    let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    for folder in folders.filter({ isReportID($0.lastPathComponent) }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(keptCount) {
        let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
        if modified < limit {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

/// The same on another machine, in its `~/.tilde/inbox`, as a shell command.
public let pruneInboxCommand = """
    cd ~/.tilde/inbox 2>/dev/null && ls -1 | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}_[0-9a-f]{8}$' | sort -r | tail -n +101 | \
    while IFS= read -r folder; do [ -n "$(find "$folder" -maxdepth 0 -mtime +30)" ] && rm -rf -- "$folder"; done; true
    """

/// Makes a folder, the folders in it and their files for the owner only, such as reports
/// saved by an older Tilde with the default 0755 and 0644.
public func makePrivate(tree root: URL) {
    guard FileManager.default.fileExists(atPath: root.path) else {
        return
    }
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
    while let item = items?.nextObject() as? URL {
        let isFolder = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        try? FileManager.default.setAttributes([.posixPermissions: isFolder ? 0o700 : 0o600], ofItemAtPath: item.path)
    }
}

/// The machine whose agent a report was for, or nil for this Mac.
public func reportNode(_ folder: URL) -> String? {
    try? String(contentsOf: folder.appendingPathComponent(".node"), encoding: .utf8)
}

/// Whether a name has the form of a report folder that Tilde makes, such as
/// `2026-11-04_00-13-48_14d2dc23`, and so cannot lead out of the inbox.
public func isReportID(_ name: String) -> Bool {
    name.wholeMatch(of: #/\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_[0-9a-f]{8}/#) != nil
}

/// Creates a folder, with its missing parents, that only its owner can open; an existing one
/// is made so too.
public func createPrivateFolder(_ folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
}

/// Writes a file, atomically, that only its owner can read.
public func writePrivate(_ data: Data, to file: URL) throws {
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
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

/// A second name for a file, so a report holds a video without a second copy on disk; a copy
/// where a link cannot be made, such as across volumes.
public func linkOrCopy(_ file: URL, to destination: URL) throws {
    do {
        try FileManager.default.linkItem(at: file, to: destination)
    } catch {
        try FileManager.default.copyItem(at: file, to: destination)
    }
}
