import XCTest
@testable import MonitorAgent

final class RebuildUsageDataTests: XCTestCase {
    func testFullSyncIntoTemporaryDatabaseStartsFromZeroAndWritesSyncState() throws {
        let directory = try makeTemporaryDirectory()
        let claudeRoot = directory.appendingPathComponent("claude-projects")
        let codexRoot = directory.appendingPathComponent("codex-sessions")
        let codexArchiveRoot = directory.appendingPathComponent("codex-archive")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexArchiveRoot, withIntermediateDirectories: true)

        let claudeFile = claudeRoot.appendingPathComponent("session.jsonl")
        try claudeAssistantLine().write(to: claudeFile, atomically: true, encoding: .utf8)

        let database = try DatabaseManager(path: directory.appendingPathComponent("monitor-rebuild.tmp.db").path)
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: claudeRoot.path,
            codexSessionsPath: codexRoot.path,
            codexArchivedSessionsPath: codexArchiveRoot.path
        )

        let result = syncManager.syncAllOnce()

        let stats = database.fetchStats(app: .all, range: .allTime)
        XCTAssertEqual(stats.totalRequests, 1)
        XCTAssertEqual(stats.inputTokens, 120)
        XCTAssertEqual(database.getSyncState(for: claudeFile.path)?.byteOffset, Int64(claudeAssistantLine().utf8.count))
        XCTAssertEqual(result.recordsSynced, 1)
        XCTAssertEqual(result.filesSynced, 1)
    }

    func testFullSyncReportsFileLevelProgress() throws {
        let directory = try makeTemporaryDirectory()
        let claudeRoot = directory.appendingPathComponent("claude-projects")
        let codexRoot = directory.appendingPathComponent("codex-sessions")
        let codexArchiveRoot = directory.appendingPathComponent("codex-archive")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexArchiveRoot, withIntermediateDirectories: true)

        try claudeAssistantLine(messageId: "msg-1").write(
            to: claudeRoot.appendingPathComponent("session-a.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try claudeAssistantLine(messageId: "msg-2").write(
            to: claudeRoot.appendingPathComponent("session-b.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let database = try DatabaseManager(path: directory.appendingPathComponent("monitor-rebuild.tmp.db").path)
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: claudeRoot.path,
            codexSessionsPath: codexRoot.path,
            codexArchivedSessionsPath: codexArchiveRoot.path
        )
        var progressEvents: [SessionSyncProgress] = []

        _ = syncManager.syncAllOnce { progress in
            progressEvents.append(progress)
        }

        XCTAssertEqual(progressEvents, [
            SessionSyncProgress(completedFiles: 0, totalFiles: 2, recordsSynced: 0),
            SessionSyncProgress(completedFiles: 1, totalFiles: 2, recordsSynced: 1),
            SessionSyncProgress(completedFiles: 2, totalFiles: 2, recordsSynced: 2),
        ])
    }

    func testExclusiveSyncOperationsRunSerially() {
        let database = DatabaseManager(inMemory: true)
        let syncManager = SessionSyncManager(database: database)
        let firstEntered = expectation(description: "first operation entered")
        let secondEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            syncManager.performExclusive {
                firstEntered.fulfill()
                releaseFirst.wait()
            }
        }
        wait(for: [firstEntered], timeout: 1)

        DispatchQueue.global().async {
            syncManager.performExclusive {
                _ = secondEntered.signal()
            }
        }
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 0.05), .timedOut)

        releaseFirst.signal()
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 1), .success)
    }

    func testIncrementalSyncRestartsFromBeginningAfterFileTruncation() throws {
        let directory = try makeTemporaryDirectory()
        let claudeRoot = directory.appendingPathComponent("claude-projects")
        let codexRoot = directory.appendingPathComponent("codex-sessions")
        let codexArchiveRoot = directory.appendingPathComponent("codex-archive")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexArchiveRoot, withIntermediateDirectories: true)

        let claudeFile = claudeRoot.appendingPathComponent("session.jsonl")
        let initialContent = claudeAssistantLine(messageId: "long-message-1")
            + claudeAssistantLine(messageId: "long-message-2")
        try initialContent.write(to: claudeFile, atomically: true, encoding: .utf8)

        let database = try DatabaseManager(path: directory.appendingPathComponent("monitor.db").path)
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: claudeRoot.path,
            codexSessionsPath: codexRoot.path,
            codexArchivedSessionsPath: codexArchiveRoot.path
        )
        _ = syncManager.syncAllOnce()

        let replacementContent = claudeAssistantLine(messageId: "new")
        XCTAssertLessThan(replacementContent.utf8.count, initialContent.utf8.count)
        try replacementContent.write(to: claudeFile, atomically: true, encoding: .utf8)
        _ = syncManager.syncAllOnce()

        XCTAssertEqual(database.fetchStats(app: .all, range: .allTime).totalRequests, 3)
        XCTAssertEqual(
            database.getSyncState(for: claudeFile.path)?.byteOffset,
            Int64(replacementContent.utf8.count)
        )
    }

    func testReplaceDatabaseWithTemporaryDatabaseSwapsQueryableData() throws {
        let directory = try makeTemporaryDirectory()
        let activePath = directory.appendingPathComponent("monitor.db").path
        let temporaryPath = directory.appendingPathComponent("monitor-rebuild.tmp.db").path

        let activeDatabase = try DatabaseManager(path: activePath)
        activeDatabase.insertRecords([record(id: "old", input: 10)])

        let temporaryDatabase = try DatabaseManager(path: temporaryPath)
        temporaryDatabase.insertRecords([record(id: "new", input: 99)])
        temporaryDatabase.close()

        try activeDatabase.replaceDatabase(with: temporaryPath)

        let stats = activeDatabase.fetchStats(app: .all, range: .allTime)
        XCTAssertEqual(stats.totalRequests, 1)
        XCTAssertEqual(stats.inputTokens, 99)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryPath))
    }

    func testReplaceDatabaseKeepsActiveDatabaseWhenTemporaryDatabaseIsMissing() throws {
        let directory = try makeTemporaryDirectory()
        let activePath = directory.appendingPathComponent("monitor.db").path
        let missingTemporaryPath = directory.appendingPathComponent("missing-rebuild.tmp.db").path

        let activeDatabase = try DatabaseManager(path: activePath)
        activeDatabase.insertRecords([record(id: "old", input: 10)])

        XCTAssertThrowsError(try activeDatabase.replaceDatabase(with: missingTemporaryPath))

        let stats = activeDatabase.fetchStats(app: .all, range: .allTime)
        XCTAssertEqual(stats.totalRequests, 1)
        XCTAssertEqual(stats.inputTokens, 10)
    }

    func testRebuildSummaryFormatsCountsForDisplay() {
        let summary = UsageDataRebuildSummary(filesSynced: 3, recordsSynced: 42, totalRequests: 42, totalSessions: 7)

        XCTAssertEqual(summary.displayText, "Rebuilt 42 requests across 7 sessions from 3 files.")
    }

    func testUsageDataRebuilderReturnsSummaryAfterSuccessfulReplacement() throws {
        let directory = try makeTemporaryDirectory()
        let activePath = directory.appendingPathComponent("monitor.db").path
        let temporaryPath = directory.appendingPathComponent("monitor-rebuild.tmp.db").path
        let claudeRoot = directory.appendingPathComponent("claude-projects")
        let codexRoot = directory.appendingPathComponent("codex-sessions")
        let codexArchiveRoot = directory.appendingPathComponent("codex-archive")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexArchiveRoot, withIntermediateDirectories: true)
        try claudeAssistantLine().write(to: claudeRoot.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        let activeDatabase = try DatabaseManager(path: activePath)
        activeDatabase.insertRecords([record(id: "old", input: 10)])

        let rebuilder = UsageDataRebuilder(
            activeDatabase: activeDatabase,
            temporaryDatabasePath: temporaryPath,
            claudeProjectsPath: claudeRoot.path,
            codexSessionsPath: codexRoot.path,
            codexArchivedSessionsPath: codexArchiveRoot.path
        )

        let summary = try rebuilder.rebuild()

        XCTAssertEqual(summary.filesSynced, 1)
        XCTAssertEqual(summary.recordsSynced, 1)
        XCTAssertEqual(summary.totalRequests, 1)
        XCTAssertEqual(summary.totalSessions, 1)
        XCTAssertEqual(activeDatabase.fetchStats(app: .all, range: .allTime).inputTokens, 120)
    }

    func testUsageDataRebuilderForwardsProgressEvents() throws {
        let directory = try makeTemporaryDirectory()
        let activePath = directory.appendingPathComponent("monitor.db").path
        let temporaryPath = directory.appendingPathComponent("monitor-rebuild.tmp.db").path
        let claudeRoot = directory.appendingPathComponent("claude-projects")
        let codexRoot = directory.appendingPathComponent("codex-sessions")
        let codexArchiveRoot = directory.appendingPathComponent("codex-archive")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexArchiveRoot, withIntermediateDirectories: true)
        try claudeAssistantLine().write(to: claudeRoot.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        let activeDatabase = try DatabaseManager(path: activePath)
        let rebuilder = UsageDataRebuilder(
            activeDatabase: activeDatabase,
            temporaryDatabasePath: temporaryPath,
            claudeProjectsPath: claudeRoot.path,
            codexSessionsPath: codexRoot.path,
            codexArchivedSessionsPath: codexArchiveRoot.path
        )
        var progressEvents: [SessionSyncProgress] = []

        _ = try rebuilder.rebuild { progress in
            progressEvents.append(progress)
        }

        XCTAssertEqual(progressEvents, [
            SessionSyncProgress(completedFiles: 0, totalFiles: 1, recordsSynced: 0),
            SessionSyncProgress(completedFiles: 1, totalFiles: 1, recordsSynced: 1),
        ])
    }

    func testUsageDataRebuilderKeepsActiveDatabaseWhenValidationFails() throws {
        let directory = try makeTemporaryDirectory()
        let activePath = directory.appendingPathComponent("monitor.db").path
        let temporaryPath = directory.appendingPathComponent("monitor-rebuild.tmp.db").path

        let activeDatabase = try DatabaseManager(path: activePath)
        activeDatabase.insertRecords([record(id: "old", input: 10)])

        let rebuilder = UsageDataRebuilder(
            activeDatabase: activeDatabase,
            temporaryDatabasePath: temporaryPath,
            claudeProjectsPath: directory.appendingPathComponent("missing-claude").path,
            codexSessionsPath: directory.appendingPathComponent("missing-codex").path,
            codexArchivedSessionsPath: directory.appendingPathComponent("missing-archive").path,
            validateTemporaryDatabase: { _ in false }
        )

        XCTAssertThrowsError(try rebuilder.rebuild())
        XCTAssertEqual(activeDatabase.fetchStats(app: .all, range: .allTime).inputTokens, 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryPath))
    }

    func testUsageDataRebuilderKeepsActiveDatabaseWhenNoSourceFilesAreReadable() throws {
        let directory = try makeTemporaryDirectory()
        let activePath = directory.appendingPathComponent("monitor.db").path
        let temporaryPath = directory.appendingPathComponent("monitor-rebuild.tmp.db").path
        let activeDatabase = try DatabaseManager(path: activePath)
        activeDatabase.insertRecords([record(id: "old", input: 10)])

        let rebuilder = UsageDataRebuilder(
            activeDatabase: activeDatabase,
            temporaryDatabasePath: temporaryPath,
            claudeProjectsPath: directory.appendingPathComponent("missing-claude").path,
            codexSessionsPath: directory.appendingPathComponent("missing-codex").path,
            codexArchivedSessionsPath: directory.appendingPathComponent("missing-archive").path
        )

        XCTAssertThrowsError(try rebuilder.rebuild()) { error in
            XCTAssertEqual(error as? UsageDataRebuildError, .noSourceFiles)
        }
        XCTAssertEqual(activeDatabase.fetchStats(app: .all, range: .allTime).inputTokens, 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryPath))
    }

    func testUsageDataRebuilderKeepsUnavailableExistingDatabaseWhenNoSourcesAreReadable() throws {
        let directory = try makeTemporaryDirectory()
        let activeURL = directory.appendingPathComponent("monitor.db")
        let temporaryPath = directory.appendingPathComponent("monitor-rebuild.tmp.db").path
        let originalData = Data("not-a-sqlite-database".utf8)
        try originalData.write(to: activeURL)
        let activeDatabase = DatabaseManager.openOrUnavailable(
            path: activeURL.path,
            logError: { _ in }
        )
        XCTAssertFalse(activeDatabase.isAvailable)

        let rebuilder = UsageDataRebuilder(
            activeDatabase: activeDatabase,
            temporaryDatabasePath: temporaryPath,
            claudeProjectsPath: directory.appendingPathComponent("missing-claude").path,
            codexSessionsPath: directory.appendingPathComponent("missing-codex").path,
            codexArchivedSessionsPath: directory.appendingPathComponent("missing-archive").path
        )

        XCTAssertThrowsError(try rebuilder.rebuild()) { error in
            XCTAssertEqual(error as? UsageDataRebuildError, .noSourceFiles)
        }
        XCTAssertEqual(try Data(contentsOf: activeURL), originalData)
        XCTAssertFalse(activeDatabase.isAvailable)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MonitorAgentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func claudeAssistantLine(messageId: String = "msg-1") -> String {
        """
        {"type":"assistant","sessionId":"session-1","timestamp":"2026-07-05T06:00:00.000Z","message":{"id":"\(messageId)","model":"claude-test","usage":{"input_tokens":120,"output_tokens":30,"cache_read_input_tokens":40,"cache_creation_input_tokens":0}}}

        """
    }

    private func record(id: String, input: Int) -> ParsedRecord {
        ParsedRecord(
            requestId: id,
            appType: "claude",
            model: "test-model",
            inputTokens: input,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            sessionId: "session-\(id)",
            createdAt: 1_783_238_400
        )
    }
}
