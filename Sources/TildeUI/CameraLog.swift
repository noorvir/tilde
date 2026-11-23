import Foundation
import OSLog

/// The camera's log: the unified log, category `camera`, at notice and above, which release
/// builds keep, and the same lines in `~/Library/Logs/Tilde/camera.log` for a test without
/// the `log` tool. Read the first with
/// `/usr/bin/log show --last 30m --predicate 'subsystem == "dev.tilde.app" AND category == "camera"'`;
/// in zsh a bare `log` is the shell's own command.
enum CameraLog {
    private static let log = Logger(subsystem: "dev.tilde.app", category: "camera")
    private static let queue = DispatchQueue(label: "dev.tilde.camera.log", qos: .utility)
    /// Only the app writes the file: tests and tools do not.
    private static let file: URL? = {
        guard Bundle.main.bundleIdentifier == "dev.tilde.app" else {
            return nil
        }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Tilde", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("camera.log")
    }()
    private static let maxFileSize = 1_000_000

    static func note(_ message: String) {
        log.notice("\(message, privacy: .public)")
        write(message)
    }

    static func error(_ message: String) {
        log.error("\(message, privacy: .public)")
        write("error: \(message)")
    }

    private static func write(_ message: String) {
        guard let file else {
            return
        }
        let now = Date()
        queue.async {
            let line = "\(now.formatted(.iso8601.time(includingFractionalSeconds: true))) \(message)\n"
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            // Starts over when it is large: the newest lines are the ones a test needs.
            if size > maxFileSize || size == 0 {
                try? Data(line.utf8).write(to: file)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: file) else {
                return
            }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}
