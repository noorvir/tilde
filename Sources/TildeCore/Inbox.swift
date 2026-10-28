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

public let inboxRoot = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tilde/inbox", isDirectory: true)
