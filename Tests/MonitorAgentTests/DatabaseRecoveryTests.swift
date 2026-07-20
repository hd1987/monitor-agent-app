import XCTest
@testable import MonitorAgent

final class DatabaseRecoveryTests: XCTestCase {
    func testOpenOrUnavailableKeepsManagerUsableWhenDatabaseCannotOpen() throws {
        let directory = try makeTemporaryDirectory()
        let blockingFile = directory.appendingPathComponent("blocking-file")
        try Data("block".utf8).write(to: blockingFile)

        let database = DatabaseManager.openOrUnavailable(
            path: blockingFile.appendingPathComponent("monitor.db").path,
            logError: { _ in }
        )

        XCTAssertFalse(database.isAvailable)
        XCTAssertFalse(database.integrityCheck())
    }

    func testCommitSyncPersistsRecordsAndStateTogether() throws {
        let database = DatabaseManager()
        let state = SyncState(
            filePath: "/tmp/session.jsonl",
            byteOffset: 128,
            recordCount: 1,
            sessionId: "session-1",
            model: "test-model",
            lastModified: 1,
            lastSyncedAt: 2
        )

        try database.commitSync(records: [record(id: "request-1")], state: state)

        XCTAssertEqual(database.fetchStats(app: .all, range: .allTime).totalRequests, 1)
        XCTAssertEqual(database.getSyncState(for: state.filePath)?.byteOffset, 128)
    }

    func testCommitSyncReportsUnavailableDatabase() {
        let database = DatabaseManager()
        database.close()
        let state = SyncState(
            filePath: "/tmp/session.jsonl",
            byteOffset: 128,
            recordCount: 1,
            sessionId: nil,
            model: nil,
            lastModified: 1,
            lastSyncedAt: 2
        )

        XCTAssertThrowsError(try database.commitSync(records: [record(id: "request-1")], state: state))
        XCTAssertNil(database.getSyncState(for: state.filePath))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MonitorAgentDatabaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func record(id: String) -> ParsedRecord {
        ParsedRecord(
            requestId: id,
            appType: "claude",
            model: "test-model",
            inputTokens: 10,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            sessionId: "session-1",
            createdAt: 1_783_238_400
        )
    }
}
