import Foundation
import GRDB
import XCTest
@testable import MonitorAgent

final class CursorAuthenticationTests: XCTestCase {
    private let encryptedToken =
        "cursor-safe-storage:v1:djEwdE8L7nxyrMRcsOhRHXQqKwfLG+7MlPhWkPQz1B3vQ40="

    func testLegacyTokenDoesNotReadKeychain() throws {
        let decoder = CursorStoredTokenDecoder {
            XCTFail("Plaintext sessions must not access Keychain")
            throw CursorUsageError.authenticationUnavailable
        }
        XCTAssertEqual(try decoder.decode("  legacy.token.value\n"), "legacy.token.value")
    }

    func testDecryptsIndependentChromiumFixture() throws {
        // Generated with Python hashlib PBKDF2 and OpenSSL AES-128-CBC.
        let decoder = CursorStoredTokenDecoder {
            Data("test-safe-storage-password".utf8)
        }
        XCTAssertEqual(try decoder.decode(encryptedToken), "header.payload.signature")
    }

    func testRejectsUnsupportedOrMalformedEnvelopesBeforeKeychainAccess() {
        let decoder = CursorStoredTokenDecoder {
            XCTFail("Invalid envelopes must fail before accessing Keychain")
            return Data()
        }
        for value in [
            "cursor-safe-storage:v2:AAAA",
            "cursor-safe-storage:v1:!invalid!",
            "cursor-safe-storage:v1:",
            "cursor-safe-storage:v1:" + Data("v11".utf8).base64EncodedString(),
            "cursor-safe-storage:v1:" + Data("v10".utf8).base64EncodedString(),
            "cursor-safe-storage:v1:" + Data("v10short".utf8).base64EncodedString(),
        ] {
            assertUnavailable { try decoder.decode(value) }
        }
    }

    func testKeychainFailureNeverReturnsCiphertext() {
        let decoder = CursorStoredTokenDecoder {
            throw NSError(domain: "Keychain", code: -25293)
        }
        assertUnavailable { try decoder.decode(encryptedToken) }
        let emptyPasswordDecoder = CursorStoredTokenDecoder { Data() }
        assertUnavailable { try emptyPasswordDecoder.decode(encryptedToken) }
    }

    func testWrongPasswordFailsClosed() {
        let decoder = CursorStoredTokenDecoder { Data("wrong-password".utf8) }
        assertUnavailable { try decoder.decode(encryptedToken) }
    }

    func testInvalidDecryptedCredentialsFailClosed() {
        let decoder = CursorStoredTokenDecoder { Data("test-safe-storage-password".utf8) }
        for payload in [
            "djEwswzhGW0peUr6YTviiYOqpA==",
            "djEwjia4GQKUFgOe1D+jWKnTAQ==",
            "djEwIWlT8iYAlVQAmnlooeYW6Q==",
        ] {
            assertUnavailable { try decoder.decode("cursor-safe-storage:v1:" + payload) }
        }
    }

    func testInvalidPlaintextCredentialsFailClosed() {
        let decoder = CursorStoredTokenDecoder {
            XCTFail("Invalid plaintext must not access Keychain")
            return Data()
        }
        for value in ["", " \n", "token\r\ninjection", "two tokens", "\"token\"", "令牌"] {
            assertUnavailable { try decoder.decode(value) }
        }
    }

    func testDatabaseReaderDecryptsCurrentSessionOnEveryRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state.vscdb").path
        let database = try DatabaseQueue(path: path)
        try database.write { db in
            try db.execute(sql: "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)")
            try db.execute(
                sql: "INSERT INTO ItemTable (key, value) VALUES (?, ?)",
                arguments: ["cursorAuth/accessToken", encryptedToken]
            )
        }
        var passwordReads = 0
        let reader = CursorStateAuthenticationReader(
            databasePath: path,
            tokenDecoder: CursorStoredTokenDecoder {
                passwordReads += 1
                return Data("test-safe-storage-password".utf8)
            }
        )
        XCTAssertEqual(try reader.readAccessToken(), "header.payload.signature")
        XCTAssertEqual(passwordReads, 1)
        try database.write { db in
            try db.execute(
                sql: "UPDATE ItemTable SET value = ? WHERE key = ?",
                arguments: ["new.account.token", "cursorAuth/accessToken"]
            )
        }
        XCTAssertEqual(try reader.readAccessToken(), "new.account.token")
        XCTAssertEqual(passwordReads, 1)
        try database.write { db in
            try db.execute(sql: "DELETE FROM ItemTable WHERE key = ?", arguments: ["cursorAuth/accessToken"])
        }
        assertUnavailable { try reader.readAccessToken() }
    }

    private func assertUnavailable(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> String
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? CursorUsageError, .authenticationUnavailable, file: file, line: line)
        }
    }
}
