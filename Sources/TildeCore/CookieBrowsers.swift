import Foundation
import SQLite3

/// A browser on this Mac whose logins Tilde's browser can import, with its profiles.
public struct CookieBrowser: Hashable, Sendable, Identifiable {
    public let name: String
    /// To tell whether the app is installed, and for its icon.
    public let bundleID: String
    public let profiles: [CookieProfile]
    /// Safari's cookies need Full Disk Access for Tilde.
    public let needsFullDiskAccess: Bool

    public var id: String { bundleID }
}

/// One profile of a browser, such as Chrome's "Work".
public struct CookieProfile: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        case chromium(ChromiumProfile)
        /// Firefox's `cookies.sqlite`.
        case firefox(URL)
        /// Safari's `Cookies.binarycookies`.
        case safari(URL)
    }

    public let source: Source
    public let browser: String
    public let name: String

    public var title: String {
        "\(browser) · \(name)"
    }
}

extension BrowserCookies {
    /// The browsers with cookie data on this Mac, each with its profiles, in a fixed order.
    /// Safari is listed while Tilde cannot read its cookies, to ask for Full Disk Access.
    public static func browsers(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [CookieBrowser] {
        let chromium = profiles(home: home)
        let chromiumBundleIDs: [ChromiumBrowser: String] = [
            .chrome: "com.google.Chrome", .arc: "company.thebrowser.Browser", .brave: "com.brave.Browser", .edge: "com.microsoft.edgemac",
        ]
        var browsers: [CookieBrowser] = ChromiumBrowser.allCases.compactMap { browser in
            let profiles = chromium.filter { $0.browser == browser }.map { CookieProfile(source: .chromium($0), browser: browser.name, name: $0.name) }
            guard !profiles.isEmpty, let bundleID = chromiumBundleIDs[browser] else {
                return nil
            }
            return CookieBrowser(name: browser.name, bundleID: bundleID, profiles: profiles, needsFullDiskAccess: false)
        }

        let safari = [
            "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies", "Library/Cookies/Cookies.binarycookies",
        ].map { home.appendingPathComponent($0) }
        let readable = safari.first { file in
            guard let handle = try? FileHandle(forReadingFrom: file) else {
                return false
            }
            try? handle.close()
            return true
        }
        browsers.append(CookieBrowser(
            name: "Safari", bundleID: "com.apple.Safari",
            profiles: [CookieProfile(source: .safari(readable ?? safari[0]), browser: "Safari", name: "Default")], needsFullDiskAccess: readable == nil
        ))

        let firefox = firefoxProfiles(root: home.appendingPathComponent("Library/Application Support/Firefox"))
        if !firefox.isEmpty {
            browsers.append(CookieBrowser(name: "Firefox", bundleID: "org.mozilla.firefox", profiles: firefox, needsFullDiskAccess: false))
        }
        return browsers
    }

    /// The profile's cookies that Tilde can use, and how many it had to skip.
    public static func cookies(of profile: CookieProfile) throws -> (cookies: [HTTPCookie], skipped: Int) {
        switch profile.source {
        case .chromium(let chromium):
            return try cookies(of: chromium)
        case .firefox(let database):
            return try firefoxCookies(database: database)
        case .safari(let file):
            guard let data = try? Data(contentsOf: file) else {
                throw Failure.database("Tilde needs Full Disk Access to read Safari's cookies")
            }
            return try safariCookies(data)
        }
    }

    // MARK: - Firefox

    /// Profiles from `profiles.ini` that have a cookie database.
    static func firefoxProfiles(root: URL) -> [CookieProfile] {
        guard let ini = try? String(contentsOf: root.appendingPathComponent("profiles.ini"), encoding: .utf8) else {
            return []
        }
        var sections: [[String: String]] = []
        for line in ini.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("[") {
                sections.append([:])
            } else if let equals = line.firstIndex(of: "="), !sections.isEmpty {
                sections[sections.count - 1][String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
        }
        return sections.compactMap { section in
            guard let path = section["Path"] else {
                return nil
            }
            let folder = section["IsRelative"] == "0" ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
            let database = folder.appendingPathComponent("cookies.sqlite")
            guard FileManager.default.fileExists(atPath: database.path) else {
                return nil
            }
            return CookieProfile(source: .firefox(database), browser: "Firefox", name: section["Name"] ?? folder.lastPathComponent)
        }
    }

    /// Firefox keeps its cookies unencrypted. Reads a copy, as a running Firefox locks the file.
    static func firefoxCookies(database: URL) throws -> (cookies: [HTTPCookie], skipped: Int) {
        try withCopy(of: database) { db in
            var statement: OpaquePointer?
            let query = "SELECT host, name, value, path, expiry, isSecure, isHttpOnly, sameSite FROM moz_cookies"
            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
                throw Failure.database(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            var cookies: [HTTPCookie] = []
            var skipped = 0
            while sqlite3_step(statement) == SQLITE_ROW {
                var properties: [HTTPCookiePropertyKey: Any] = [
                    .domain: column(statement, 0), .name: column(statement, 1), .value: column(statement, 2), .path: column(statement, 3),
                ]
                let expiry = Double(sqlite3_column_int64(statement, 4))
                if expiry > 0 {
                    // Newer versions count milliseconds.
                    properties[.expires] = Date(timeIntervalSince1970: expiry > 1e11 ? expiry / 1000 : expiry)
                }
                if sqlite3_column_int(statement, 5) == 1 {
                    properties[.secure] = "TRUE"
                }
                if sqlite3_column_int(statement, 6) == 1 {
                    properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
                }
                switch sqlite3_column_int(statement, 7) {
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
    }

    // MARK: - Safari

    /// Safari's `Cookies.binarycookies`: "cook", the page count and sizes (big-endian), then
    /// pages of cookies (little-endian), each with its strings at offsets from its start.
    static func safariCookies(_ data: Data) throws -> (cookies: [HTTPCookie], skipped: Int) {
        let bytes = [UInt8](data)
        func big(_ at: Int) -> Int? {
            at + 4 <= bytes.count ? Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3]) : nil
        }
        func little(_ at: Int) -> Int? {
            at + 4 <= bytes.count ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 : nil
        }
        func double(_ at: Int) -> Double? {
            guard at + 8 <= bytes.count else {
                return nil
            }
            let raw = (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[at + $1]) << (8 * UInt64($1)) }
            return Double(bitPattern: raw)
        }
        func string(_ at: Int) -> String? {
            guard at < bytes.count, let end = bytes[at...].firstIndex(of: 0) else {
                return nil
            }
            return String(decoding: bytes[at..<end], as: UTF8.self)
        }

        guard bytes.count >= 8, String(decoding: bytes[0..<4], as: UTF8.self) == "cook", let pageCount = big(4) else {
            throw Failure.database("not a Safari cookie file")
        }
        var pageStart = 8 + 4 * pageCount
        var cookies: [HTTPCookie] = []
        var skipped = 0
        for page in 0..<pageCount {
            guard let pageSize = big(8 + 4 * page), let count = little(pageStart + 4) else {
                throw Failure.database("a Safari cookie page is cut short")
            }
            for index in 0..<count {
                guard let offset = little(pageStart + 8 + 4 * index) else {
                    skipped += 1
                    continue
                }
                let start = pageStart + offset
                guard let flags = little(start + 8), let domainAt = little(start + 16), let nameAt = little(start + 20),
                      let pathAt = little(start + 24), let valueAt = little(start + 28), let expiry = double(start + 40),
                      let domain = string(start + domainAt), let name = string(start + nameAt), let path = string(start + pathAt),
                      let value = string(start + valueAt)
                else {
                    skipped += 1
                    continue
                }
                var properties: [HTTPCookiePropertyKey: Any] = [.domain: domain, .name: name, .value: value, .path: path]
                // Seconds since 2001.
                properties[.expires] = Date(timeIntervalSinceReferenceDate: expiry)
                if flags & 1 != 0 {
                    properties[.secure] = "TRUE"
                }
                if flags & 4 != 0 {
                    properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
                }
                if let cookie = HTTPCookie(properties: properties) {
                    cookies.append(cookie)
                } else {
                    skipped += 1
                }
            }
            pageStart += pageSize
        }
        return (cookies, skipped)
    }

    // MARK: - SQLite

    /// Opens a copy of a database, with its journal, and deletes the copy afterwards.
    private static func withCopy<T>(of database: URL, _ read: (OpaquePointer) throws -> T) throws -> T {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-cookies-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(database.lastPathComponent)
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
        return try read(db)
    }

    private static func column(_ statement: OpaquePointer?, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }
}
