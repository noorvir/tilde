import Foundation
import Security

/// The token that agents on this Mac send to Tilde's MCP listener. Any process can reach
/// 127.0.0.1, also other users' and sandboxed ones, but only the owner can read this file:
/// `~/.tilde/local-token`, 0600 in a 0700 folder.
public enum LocalToken {
    public static func file(home: URL) -> URL {
        home.appendingPathComponent(".tilde/local-token")
    }

    /// The token, made the first time.
    public static func load(home: URL) -> String {
        let file = file(home: home)
        if let token = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return token
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let folder = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Private from the start, then renamed into place, so no one sees a partial file.
        let temporary = folder.appendingPathComponent(".local-token-\(UUID().uuidString)")
        if FileManager.default.createFile(atPath: temporary.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) {
            rename(temporary.path, file.path)
        }
        return token
    }

    /// The `Authorization` header with the token.
    public static func authorization(home: URL) -> String {
        "Bearer \(load(home: home))"
    }
}
