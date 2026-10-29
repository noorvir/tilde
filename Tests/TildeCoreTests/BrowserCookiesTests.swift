@testable import TildeCore
import CommonCrypto
import CryptoKit
import Foundation
import SQLite3
import Testing

/// Reads a cookie database made here, in Chromium's format, encrypted with a test password.
struct BrowserCookiesTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-cookie-test-\(UUID().uuidString)")
    let password = "test-password"

    @Test func readsPlainEncryptedAndExpiringCookies() throws {
        // Foundation caps expiry at 400 days, so the test date stays within that.
        let expiry = (Date().timeIntervalSince1970 + 30 * 86_400).rounded()
        let key = BrowserCookies.derivedKey(password: password)
        let database = try makeDatabase(version: 24, rows: [
            Row(host: ".example.com", name: "plain", value: "one", encrypted: Data(), expires: 0, secure: false, httpOnly: false, sameSite: -1),
            Row(host: "app.example.com", name: "session", value: "", encrypted: encrypt("secret", host: "app.example.com", key: key), expires: chromiumTime(expiry), secure: true, httpOnly: true, sameSite: 1),
            Row(host: ".example.com", name: "future", value: "", encrypted: Data("v11unknown".utf8), expires: 0, secure: false, httpOnly: false, sameSite: 2),
        ])

        let result = try BrowserCookies.cookies(database: database, password: password)
        let cookies = Dictionary(uniqueKeysWithValues: result.cookies.map { ($0.name, $0) })

        #expect(result.skipped == 1)
        #expect(cookies["plain"]?.value == "one")
        #expect(cookies["plain"]?.domain == ".example.com")
        #expect(cookies["plain"]?.expiresDate == nil)
        #expect(cookies["session"]?.value == "secret")
        #expect(cookies["session"]?.isSecure == true)
        #expect(cookies["session"]?.isHTTPOnly == true)
        #expect(cookies["session"]?.sameSitePolicy == .sameSiteLax)
        #expect(abs((cookies["session"]?.expiresDate?.timeIntervalSince1970 ?? 0) - expiry) < 1)
    }

    @Test func olderDatabasesHaveNoHostHash() throws {
        let key = BrowserCookies.derivedKey(password: password)
        let plain = try #require(BrowserCookies.crypt(CCOperation(kCCEncrypt), Data("token".utf8), key: key))
        let database = try makeDatabase(version: 18, rows: [
            Row(host: ".example.com", name: "old", value: "", encrypted: Data("v10".utf8) + plain, expires: 0, secure: false, httpOnly: false, sameSite: -1),
        ])

        let result = try BrowserCookies.cookies(database: database, password: password)

        #expect(result.cookies.first?.value == "token")
    }

    @Test func aWrongPasswordSkipsEncryptedCookies() throws {
        let key = BrowserCookies.derivedKey(password: password)
        let database = try makeDatabase(version: 24, rows: [
            Row(host: ".example.com", name: "session", value: "", encrypted: encrypt("secret", host: ".example.com", key: key), expires: 0, secure: false, httpOnly: false, sameSite: -1),
        ])

        let result = try BrowserCookies.cookies(database: database, password: "other")

        #expect(result.cookies.first?.value != "secret")
    }

    @Test func findsProfilesFromLocalState() throws {
        let home = folder.appendingPathComponent("home")
        let chrome = home.appendingPathComponent("Library/Application Support/Google/Chrome")
        for profile in ["Default", "Profile 1"] {
            let network = chrome.appendingPathComponent("\(profile)/Network")
            try FileManager.default.createDirectory(at: network, withIntermediateDirectories: true)
            try Data().write(to: network.appendingPathComponent("Cookies"))
        }
        let localState = #"{ "profile": { "info_cache": { "Default": { "name": "Personal" }, "Profile 1": { "name": "Work" } } } }"#
        try Data(localState.utf8).write(to: chrome.appendingPathComponent("Local State"))

        let profiles = BrowserCookies.profiles(home: home)

        #expect(profiles.map(\.title) == ["Chrome · Personal", "Chrome · Work"])
    }

    // MARK: - Fixture

    struct Row {
        let host: String
        let name: String
        let value: String
        let encrypted: Data
        let expires: Int64
        let secure: Bool
        let httpOnly: Bool
        let sameSite: Int32
    }

    private func encrypt(_ value: String, host: String, key: Data) -> Data {
        let plain = Data(SHA256.hash(data: Data(host.utf8))) + Data(value.utf8)
        return Data("v10".utf8) + BrowserCookies.crypt(CCOperation(kCCEncrypt), plain, key: key)!
    }

    private func chromiumTime(_ unixSeconds: Double) -> Int64 {
        Int64((unixSeconds + 11_644_473_600) * 1_000_000)
    }

    private func makeDatabase(version: Int, rows: [Row]) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Cookies")
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        let db = try #require(handle)
        defer { sqlite3_close(db) }

        let schema = """
            CREATE TABLE meta (key TEXT, value TEXT);
            CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, path TEXT,
                                  expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, samesite INTEGER);
            INSERT INTO meta VALUES ('version', '\(version)');
            """
        #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)

        for row in rows {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO cookies VALUES (?, ?, ?, ?, '/', ?, ?, ?, ?)", -1, &statement, nil)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, row.host, -1, transient)
            sqlite3_bind_text(statement, 2, row.name, -1, transient)
            sqlite3_bind_text(statement, 3, row.value, -1, transient)
            _ = row.encrypted.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(row.encrypted.count), transient) }
            sqlite3_bind_int64(statement, 5, row.expires)
            sqlite3_bind_int(statement, 6, row.secure ? 1 : 0)
            sqlite3_bind_int(statement, 7, row.httpOnly ? 1 : 0)
            sqlite3_bind_int(statement, 8, row.sameSite)
            #expect(sqlite3_step(statement) == SQLITE_DONE)
            sqlite3_finalize(statement)
        }
        return url
    }
}
