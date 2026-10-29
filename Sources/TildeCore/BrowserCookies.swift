import CommonCrypto
import CryptoKit
import Foundation
import Security
import SQLite3

/// A Chromium browser whose logins Tilde's browser can import.
public enum ChromiumBrowser: String, CaseIterable, Sendable {
    case chrome
    case arc
    case brave
    case edge

    public var name: String {
        switch self {
        case .chrome: "Chrome"
        case .arc: "Arc"
        case .brave: "Brave"
        case .edge: "Edge"
        }
    }

    /// The folder with the browser's `Local State` and profile folders, inside the home folder.
    var userData: String {
        switch self {
        case .chrome: "Library/Application Support/Google/Chrome"
        case .arc: "Library/Application Support/Arc/User Data"
        case .brave: "Library/Application Support/BraveSoftware/Brave-Browser"
        case .edge: "Library/Application Support/Microsoft Edge"
        }
    }

    /// The Keychain item that holds the cookie encryption password.
    var keychain: (service: String, account: String) {
        switch self {
        case .chrome: ("Chrome Safe Storage", "Chrome")
        case .arc: ("Arc Safe Storage", "Arc")
        case .brave: ("Brave Safe Storage", "Brave")
        case .edge: ("Microsoft Edge Safe Storage", "Microsoft Edge")
        }
    }
}

/// One profile of a Chromium browser, such as Chrome's "Work".
public struct ChromiumProfile: Hashable, Sendable {
    public let browser: ChromiumBrowser
    /// The profile's folder name, such as "Default" or "Profile 1".
    public let folder: String
    public let name: String
    let cookies: URL

    public var title: String {
        "\(browser.name) · \(name)"
    }
}

/// Reads the cookies of a Chromium browser profile, for Tilde's browser to use the same logins.
/// Nothing leaves the Mac. Reading needs the browser's Keychain password, so macOS asks the
/// user the first time.
public enum BrowserCookies {
    public enum Failure: Error, CustomStringConvertible {
        case keychain(OSStatus)
        case database(String)

        public var description: String {
            switch self {
            case .keychain(let status) where status == errSecUserCanceled || status == errSecAuthFailed:
                return "Keychain access was not allowed"
            case .keychain(let status):
                return "the Keychain password is not available (\(status))"
            case .database(let message):
                return "could not read the cookies (\(message))"
            }
        }
    }

    /// The profiles of the installed Chromium browsers that have cookies.
    public static func profiles(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ChromiumProfile] {
        ChromiumBrowser.allCases.flatMap { browser -> [ChromiumProfile] in
            let root = home.appendingPathComponent(browser.userData)
            let names = profileNames(localState: root.appendingPathComponent("Local State"))
            let folders = names.keys.isEmpty ? ["Default"] : names.keys.sorted()
            return folders.compactMap { folder in
                let directory = root.appendingPathComponent(folder)
                // Chrome moved the file into Network/ in version 96.
                let cookies = [directory.appendingPathComponent("Network/Cookies"), directory.appendingPathComponent("Cookies")]
                    .first { FileManager.default.fileExists(atPath: $0.path) }
                return cookies.map { ChromiumProfile(browser: browser, folder: folder, name: names[folder] ?? folder, cookies: $0) }
            }
        }
    }

    /// The profile's cookies that Tilde can use, and how many it had to skip.
    public static func cookies(of profile: ChromiumProfile) throws -> (cookies: [HTTPCookie], skipped: Int) {
        let password = try keychainPassword(for: profile.browser)
        return try cookies(database: profile.cookies, password: password)
    }

    /// Reads a copy of the cookie database, so a running browser's lock does not matter, and
    /// deletes the copy afterwards.
    static func cookies(database: URL, password: String) throws -> (cookies: [HTTPCookie], skipped: Int) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-cookies-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("Cookies")
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: database.path + suffix)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            throw Failure.database("open failed")
        }
        defer { sqlite3_close(db) }

        // From version 24 each value starts with the SHA-256 of its host.
        let version = Int(scalar(db, "SELECT value FROM meta WHERE key = 'version'") ?? "") ?? 0
        let key = derivedKey(password: password)

        var statement: OpaquePointer?
        let query = "SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite FROM cookies"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw Failure.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var cookies: [HTTPCookie] = []
        var skipped = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            let host = text(statement, 0)
            var value = text(statement, 2)
            if value.isEmpty {
                let encrypted = blob(statement, 3)
                guard let decrypted = decrypt(encrypted, key: key, host: host, hasHostHash: version >= 24) else {
                    skipped += 1
                    continue
                }
                value = decrypted
            }

            var properties: [HTTPCookiePropertyKey: Any] = [
                .domain: host, .name: text(statement, 1), .value: value, .path: text(statement, 4),
            ]
            let expires = sqlite3_column_int64(statement, 5)
            if expires > 0 {
                properties[.expires] = date(chromiumTime: expires)
            }
            if sqlite3_column_int(statement, 6) == 1 {
                properties[.secure] = "TRUE"
            }
            if sqlite3_column_int(statement, 7) == 1 {
                properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
            }
            switch sqlite3_column_int(statement, 8) {
            case 1: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax
            case 2: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict
            default: break
            }

            if let cookie = HTTPCookie(properties: properties) {
                cookies.append(cookie)
            } else {
                skipped += 1
            }
        }
        return (cookies, skipped)
    }

    // MARK: - Decryption

    /// Chromium on macOS: PBKDF2-HMAC-SHA1 of the Keychain password, salt "saltysalt",
    /// 1003 rounds, 16 bytes.
    static func derivedKey(password: String) -> Data {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        let passwordBytes = Array(password.utf8)
        _ = key.withUnsafeMutableBytes { keyBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.map { CChar(bitPattern: $0) }, passwordBytes.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                    keyBytes.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES128
                )
            }
        }
        return key
    }

    /// A "v10" value: AES-128-CBC with an IV of 16 spaces. Returns nil for other versions or
    /// values that do not decrypt.
    static func decrypt(_ encrypted: Data, key: Data, host: String, hasHostHash: Bool) -> String? {
        guard encrypted.starts(with: Data("v10".utf8)) else {
            return nil
        }
        guard var plain = crypt(CCOperation(kCCDecrypt), Data(encrypted.dropFirst(3)), key: key) else {
            return nil
        }
        let hostHash = Data(SHA256.hash(data: Data(host.utf8)))
        if hasHostHash, plain.starts(with: hostHash) {
            plain = Data(plain.dropFirst(hostHash.count))
        }
        return String(data: plain, encoding: .utf8)
    }

    static func crypt(_ operation: CCOperation, _ input: Data, key: Data) -> Data? {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var length = 0
        let outputCount = output.count
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                            inBytes.baseAddress, input.count, out.baseAddress, outputCount, &length
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            return nil
        }
        return output.prefix(length)
    }

    // MARK: - Helpers

    /// Microseconds since 1601-01-01, as Chromium stores times.
    static func date(chromiumTime: Int64) -> Date {
        Date(timeIntervalSince1970: Double(chromiumTime) / 1_000_000 - 11_644_473_600)
    }

    private static func keychainPassword(for browser: ChromiumBrowser) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: browser.keychain.service,
            kSecAttrAccount as String: browser.keychain.account,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw Failure.keychain(status)
        }
        return password
    }

    /// Profile folder names and their display names, from the browser's `Local State`.
    private static func profileNames(localState: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: localState),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any]
        else {
            return [:]
        }
        return cache.reduce(into: [:]) { names, entry in
            names[entry.key] = (entry.value as? [String: Any])?["name"] as? String ?? entry.key
        }
    }

    private static func scalar(_ db: OpaquePointer, _ query: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? text(statement, 0) : nil
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private static func blob(_ statement: OpaquePointer?, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else {
            return Data()
        }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}
