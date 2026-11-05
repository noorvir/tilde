import Foundation
import Security

/// The token that agents on this Mac send to Tilde's MCP listener. Any process can reach
/// 127.0.0.1, also other users' and sandboxed ones, but only the owner can read this file:
/// `~/.tilde/local-token`, 0600 in a 0700 folder.
public enum LocalToken {
    public enum Failure: Error, CustomStringConvertible {
        case noRandomBytes
        case notSaved(String)

        public var description: String {
            switch self {
            case .noRandomBytes: "macOS gave no random bytes for Tilde's token"
            case .notSaved(let reason): "Could not save Tilde's token in ~/.tilde/local-token: \(reason)"
            }
        }
    }

    public static func file(home: URL) -> URL {
        home.appendingPathComponent(".tilde/local-token")
    }

    /// The token, made the first time. Made only once, also when two processes start at the
    /// same moment: the first one's file stays, and the other reads it.
    public static func load(home: URL) throws -> String {
        let file = file(home: home)
        if let token = read(file) {
            return token
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw Failure.noRandomBytes
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let folder = file.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw Failure.notSaved(error.localizedDescription)
        }
        // Private and whole from the start, then linked into place: a link never replaces a
        // file, so a token already there wins.
        let temporary = folder.appendingPathComponent(".local-token-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw Failure.notSaved("cannot write in \(folder.path)")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        if link(temporary.path, file.path) != 0, errno != EEXIST {
            throw Failure.notSaved(String(cString: strerror(errno)))
        }
        guard let saved = read(file) else {
            throw Failure.notSaved("cannot read it back")
        }
        return saved
    }

    /// The `Authorization` header with the token.
    public static func authorization(home: URL) throws -> String {
        "Bearer \(try load(home: home))"
    }

    private static func read(_ file: URL) -> String? {
        let token = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }
}
