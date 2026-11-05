import CryptoKit
import Foundation

/// `tilde-proxy`, the pipe from a node's agents to Tilde: they start it as a stdio MCP server,
/// and it connects to the socket that Tilde's ssh link forwards to the node. Tilde takes each
/// node's file from the GitHub release of `version` and copies it there only when it has the
/// hash built in here, the same as `proxy/SHA256SUMS`.
public enum TildeProxy {
    public static let version = "1.0.0"

    /// A node type that has a file.
    public enum Target: String, CaseIterable, Sendable {
        case darwinArm64 = "darwin-arm64"
        case darwinAmd64 = "darwin-amd64"
        case linuxAmd64 = "linux-amd64"
        case linuxArm64 = "linux-arm64"

        /// The type from `uname -sm`, such as "Linux aarch64"; nil for one with no file, such as
        /// FreeBSD.
        public init?(uname: String) {
            let words = uname.split(whereSeparator: \.isWhitespace)
            guard words.count == 2 else {
                return nil
            }

            switch (words[0], words[1]) {
            case ("Darwin", "arm64"): self = .darwinArm64
            case ("Darwin", "x86_64"): self = .darwinAmd64
            case ("Linux", "x86_64"), ("Linux", "amd64"): self = .linuxAmd64
            case ("Linux", "aarch64"), ("Linux", "arm64"): self = .linuxArm64
            default: return nil
            }
        }

        public var fileName: String {
            "tilde-proxy-\(rawValue)"
        }

        public var sha256: String {
            switch self {
            case .darwinArm64: "fbc2696db5e3b33308dbe986be4c9d37ecdea335e8f73cfff5e28cfe252ca92e"
            case .darwinAmd64: "f7187e62fc963e705b5709a343863dd357e21afd87ffef0a2c502285c9661a0d"
            case .linuxAmd64: "5cc15c81274c977beadd4f7558c190cb39f2c396e6fd4951a691258a6f92edbd"
            case .linuxArm64: "ceb84ca1586b56b67d53216c96fb283d17a74c823538b6f8216976a27a59bdb5"
            }
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case download(String)
        case wrongHash(String)

        public var description: String {
            switch self {
            case .download(let reason): "Could not download tilde-proxy: \(reason)"
            case .wrongHash(let name): "The downloaded \(name) is not the one Tilde expects, so it was not used"
            }
        }
    }

    /// The release's files. `TILDE_PROXY_DOWNLOAD_URL` replaces it for tests only.
    public static var downloadBase: URL {
        if let base = ProcessInfo.processInfo.environment["TILDE_PROXY_DOWNLOAD_URL"], let url = URL(string: base) {
            return url
        }
        return URL(string: "https://github.com/noorvir/tilde/releases/download/tilde-proxy-v\(version)")!
    }

    public static var defaultCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("dev.tilde.app/tilde-proxy-\(version)")
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The node type's file on this Mac, with its built-in hash: from the cache, or else
    /// downloaded, checked and then cached. A file with another hash is never returned.
    public static func file(for target: Target, cache: URL = defaultCache, base: URL = downloadBase) async throws -> URL {
        let file = cache.appendingPathComponent(target.fileName)
        if let data = try? Data(contentsOf: file), sha256(data) == target.sha256 {
            return file
        }

        let data: Data
        do {
            let (body, response) = try await URLSession.shared.data(from: base.appendingPathComponent(target.fileName))
            if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                throw Failure.download("the server answered \(status)")
            }
            data = body
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.download(error.localizedDescription)
        }
        guard sha256(data) == target.sha256 else {
            throw Failure.wrongHash(target.fileName)
        }

        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return file
    }
}
