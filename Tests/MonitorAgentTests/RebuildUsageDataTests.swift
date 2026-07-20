import XCTest
@testable import MonitorAgent

final class RebuildUsageDataTests: XCTestCase {
    func testRebuildLineFilterSkipsUnrelatedEventsWithoutMissingUsageEvents() {
        let claudeUsage = Data(#"{"type" : "assistant", "message" : {"usage" : {}}}"#.utf8)
        let claudeUnrelated = Data(#"{"type":"user","message":{"content":"large payload"}}"#.utf8)
        let codexSession = Data(#"{"type" : "session_meta", "payload" : {}}"#.utf8)
        let codexContext = Data(#"{"type":"turn_context","payload":{}}"#.utf8)
        let codexUsage = Data(#"{"type":"event_msg","payload":{"type":"token_count"}}"#.utf8)
        let codexUnrelated = Data(#"{"type":"response_item","payload":{"type":"message"}}"#.utf8)

        XCTAssertTrue(SessionLogLineFilter.shouldParseClaude(claudeUsage))
        XCTAssertFalse(SessionLogLineFilter.shouldParseClaude(claudeUnrelated))
        XCTAssertTrue(SessionLogLineFilter.shouldParseCodex(codexSession))
        XCTAssertTrue(SessionLogLineFilter.shouldParseCodex(codexContext))
        XCTAssertTrue(SessionLogLineFilter.shouldParseCodex(codexUsage))
        XCTAssertFalse(SessionLogLineFilter.shouldParseCodex(codexUnrelated))

        let combined = claudeUnrelated + claudeUsage
        let usageRange = claudeUnrelated.count..<combined.count
        let unrelatedRange = combined.startIndex..<claudeUnrelated.count
        XCTAssertTrue(SessionLogLineFilter.shouldParseClaude(combined, in: usageRange))
        XCTAssertFalse(SessionLogLineFilter.shouldParseClaude(combined, in: unrelatedRange))
    }

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

    func testReplaceDatabasePreservesSyncOffsetAndAvoidsFullFileRescan() throws {
        let directory = try makeTemporaryDirectory()
        let activePath = directory.appendingPathComponent("monitor.db").path
        let temporaryPath = directory.appendingPathComponent("monitor-rebuild.tmp.db").path
        let claudeRoot = directory.appendingPathComponent("claude-projects")
        let codexRoot = directory.appendingPathComponent("codex-sessions")
        let codexArchiveRoot = directory.appendingPathComponent("codex-archive")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexArchiveRoot, withIntermediateDirectories: true)
        let sourceFile = claudeRoot.appendingPathComponent("session.jsonl")
        let sourceContent = claudeAssistantLine()
        try sourceContent.write(to: sourceFile, atomically: true, encoding: .utf8)
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceFile.path)
        let modifiedAt = Int((attributes[.modificationDate] as! Date).timeIntervalSince1970)

        let activeDatabase = try DatabaseManager(path: activePath)
        activeDatabase.insertRecords([record(id: "old", input: 10)])
        let temporaryDatabase = try DatabaseManager(path: temporaryPath)
        try temporaryDatabase.commitSync(
            records: [record(id: "rebuilt", input: 120)],
            state: SyncState(
                filePath: sourceFile.path,
                byteOffset: Int64(sourceContent.utf8.count),
                recordCount: 1,
                sessionId: nil,
                model: nil,
                lastModified: modifiedAt,
                lastSyncedAt: modifiedAt
            )
        )
        temporaryDatabase.close()

        try activeDatabase.replaceDatabase(with: temporaryPath)
        let syncManager = SessionSyncManager(
            database: activeDatabase,
            claudeProjectsPath: claudeRoot.path,
            codexSessionsPath: codexRoot.path,
            codexArchivedSessionsPath: codexArchiveRoot.path
        )

        XCTAssertEqual(syncManager.syncAllOnce(), SessionSyncResult())
        XCTAssertEqual(activeDatabase.getSyncState(for: sourceFile.path)?.byteOffset, Int64(sourceContent.utf8.count))
    }

    func testRebuildSummaryFormatsCountsForDisplay() {
        let summary = UsageDataRebuildSummary(filesSynced: 3, recordsSynced: 42, totalRequests: 42, totalSessions: 7)

        XCTAssertEqual(summary.displayText, "Rebuilt 42 requests across 7 sessions from 3 files.")
    }

    func testRebuildSummaryReportsPendingLatestActivity() {
        let summary = UsageDataRebuildSummary(
            filesSynced: 3,
            recordsSynced: 42,
            totalRequests: 42,
            totalSessions: 7,
            latestActivityPending: true
        )

        XCTAssertTrue(summary.displayText.contains("Latest activity will be added during the next sync."))
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

        XCTAssertEqual(progressEvents.first?.phase, .scanning)
        XCTAssertEqual(progressEvents.last?.phase, .syncingLatest)
        let rebuildEvents = progressEvents.filter { $0.phase == .rebuildingClaude }
        XCTAssertEqual(rebuildEvents.first?.processedBytes, 0)
        XCTAssertEqual(rebuildEvents.last?.fractionCompleted, 1)
        XCTAssertEqual(rebuildEvents.last?.recordsSynced, 1)
        XCTAssertTrue(progressEvents.contains { $0.phase == .catchingUp })
        XCTAssertTrue(progressEvents.contains { $0.phase == .validating })
        XCTAssertTrue(progressEvents.contains { $0.phase == .replacing })
    }

    func testUsageDataRebuilderCatchesUpActivityAppendedDuringRebuild() throws {
        let directory = try makeTemporaryDirectory()
        let activePath = directory.appendingPathComponent("monitor.db").path
        let temporaryPath = directory.appendingPathComponent("monitor-rebuild.tmp.db").path
        let claudeRoot = directory.appendingPathComponent("claude-projects")
        let codexRoot = directory.appendingPathComponent("codex-sessions")
        let codexArchiveRoot = directory.appendingPathComponent("codex-archive")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexArchiveRoot, withIntermediateDirectories: true)
        let sourceFile = claudeRoot.appendingPathComponent("session.jsonl")
        try claudeAssistantLine(messageId: "msg-1").write(to: sourceFile, atomically: true, encoding: .utf8)

        let activeDatabase = try DatabaseManager(path: activePath)
        let rebuilder = UsageDataRebuilder(
            activeDatabase: activeDatabase,
            temporaryDatabasePath: temporaryPath,
            claudeProjectsPath: claudeRoot.path,
            codexSessionsPath: codexRoot.path,
            codexArchivedSessionsPath: codexArchiveRoot.path
        )
        var didAppend = false
        var appendError: Error?

        let summary = try rebuilder.rebuild { progress in
            guard progress.phase == .rebuildingClaude,
                  progress.completedFiles == 1,
                  !didAppend else { return }
            didAppend = true
            do {
                let handle = try FileHandle(forWritingTo: sourceFile)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(self.claudeAssistantLine(messageId: "msg-2").utf8))
                try handle.close()
            } catch {
                appendError = error
            }
        }

        XCTAssertNil(appendError)
        XCTAssertTrue(didAppend)
        XCTAssertEqual(summary.totalRequests, 2)
        XCTAssertEqual(activeDatabase.fetchStats(app: .all, range: .allTime).totalRequests, 2)
    }

    func testUsageDataRebuilderCancelsWithoutReplacingActiveDatabase() throws {
        let directory = try makeTemporaryDirectory()
        let activePath = directory.appendingPathComponent("monitor.db").path
        let temporaryPath = directory.appendingPathComponent("monitor-rebuild.tmp.db").path
        let claudeRoot = directory.appendingPathComponent("claude-projects")
        let codexRoot = directory.appendingPathComponent("codex-sessions")
        let codexArchiveRoot = directory.appendingPathComponent("codex-archive")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexArchiveRoot, withIntermediateDirectories: true)
        try claudeAssistantLine().write(
            to: claudeRoot.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let activeDatabase = try DatabaseManager(path: activePath)
        activeDatabase.insertRecords([record(id: "old", input: 10)])
        let cancellation = UsageDataRebuildCancellation()
        let rebuilder = UsageDataRebuilder(
            activeDatabase: activeDatabase,
            temporaryDatabasePath: temporaryPath,
            claudeProjectsPath: claudeRoot.path,
            codexSessionsPath: codexRoot.path,
            codexArchivedSessionsPath: codexArchiveRoot.path
        )

        XCTAssertThrowsError(try rebuilder.rebuild(cancellation: cancellation) { progress in
            if progress.processedBytes > 0 {
                cancellation.cancel()
            }
        }) { error in
            XCTAssertEqual(error as? StrictSessionSyncError, .cancelled)
        }
        XCTAssertEqual(activeDatabase.fetchStats(app: .all, range: .allTime).inputTokens, 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryPath))
    }

    func testUsageDataRebuilderRejectsSourceReplacementDuringRebuild() throws {
        let directory = try makeTemporaryDirectory()
        let activePath = directory.appendingPathComponent("monitor.db").path
        let temporaryPath = directory.appendingPathComponent("monitor-rebuild.tmp.db").path
        let claudeRoot = directory.appendingPathComponent("claude-projects")
        let codexRoot = directory.appendingPathComponent("codex-sessions")
        let codexArchiveRoot = directory.appendingPathComponent("codex-archive")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexArchiveRoot, withIntermediateDirectories: true)
        let sourceFile = claudeRoot.appendingPathComponent("session.jsonl")
        try claudeAssistantLine().write(to: sourceFile, atomically: true, encoding: .utf8)

        let activeDatabase = try DatabaseManager(path: activePath)
        activeDatabase.insertRecords([record(id: "old", input: 10)])
        let rebuilder = UsageDataRebuilder(
            activeDatabase: activeDatabase,
            temporaryDatabasePath: temporaryPath,
            claudeProjectsPath: claudeRoot.path,
            codexSessionsPath: codexRoot.path,
            codexArchivedSessionsPath: codexArchiveRoot.path
        )
        var didReplace = false

        XCTAssertThrowsError(try rebuilder.rebuild { progress in
            guard progress.processedBytes > 0, !didReplace else { return }
            didReplace = true
            try? "{}\n".write(to: sourceFile, atomically: true, encoding: .utf8)
        }) { error in
            guard let syncError = error as? StrictSessionSyncError,
                  case .sourceFileChanged = syncError else {
                return XCTFail("Expected sourceFileChanged, got \(error)")
            }
        }
        XCTAssertTrue(didReplace)
        XCTAssertEqual(activeDatabase.fetchStats(app: .all, range: .allTime).inputTokens, 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryPath))
    }

    func testUsageDataRebuilderRejectsEmptyResultWhenActiveDatabaseHasRequests() throws {
        let directory = try makeTemporaryDirectory()
        let activePath = directory.appendingPathComponent("monitor.db").path
        let temporaryPath = directory.appendingPathComponent("monitor-rebuild.tmp.db").path
        let claudeRoot = directory.appendingPathComponent("claude-projects")
        let codexRoot = directory.appendingPathComponent("codex-sessions")
        let codexArchiveRoot = directory.appendingPathComponent("codex-archive")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexArchiveRoot, withIntermediateDirectories: true)
        try "{}\n".write(
            to: claudeRoot.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let activeDatabase = try DatabaseManager(path: activePath)
        activeDatabase.insertRecords([record(id: "old", input: 10)])
        let rebuilder = UsageDataRebuilder(
            activeDatabase: activeDatabase,
            temporaryDatabasePath: temporaryPath,
            claudeProjectsPath: claudeRoot.path,
            codexSessionsPath: codexRoot.path,
            codexArchivedSessionsPath: codexArchiveRoot.path
        )

        XCTAssertThrowsError(try rebuilder.rebuild()) { error in
            XCTAssertEqual(error as? UsageDataRebuildError, .suspiciousEmptyResult)
        }
        XCTAssertEqual(activeDatabase.fetchStats(app: .all, range: .allTime).inputTokens, 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryPath))
    }

    func testUsageDataRebuilderStreamsLinesAcrossReadChunkBoundaries() throws {
        let directory = try makeTemporaryDirectory()
        let activePath = directory.appendingPathComponent("monitor.db").path
        let temporaryPath = directory.appendingPathComponent("monitor-rebuild.tmp.db").path
        let claudeRoot = directory.appendingPathComponent("claude-projects")
        let codexRoot = directory.appendingPathComponent("codex-sessions")
        let codexArchiveRoot = directory.appendingPathComponent("codex-archive")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexArchiveRoot, withIntermediateDirectories: true)
        try claudeAssistantLine(paddingCount: 1_100_000).write(
            to: claudeRoot.appendingPathComponent("large-session.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let activeDatabase = try DatabaseManager(path: activePath)
        let rebuilder = UsageDataRebuilder(
            activeDatabase: activeDatabase,
            temporaryDatabasePath: temporaryPath,
            claudeProjectsPath: claudeRoot.path,
            codexSessionsPath: codexRoot.path,
            codexArchivedSessionsPath: codexArchiveRoot.path
        )
        var byteProgress: [Int64] = []

        let summary = try rebuilder.rebuild { progress in
            if progress.phase == .rebuildingClaude {
                byteProgress.append(progress.processedBytes)
            }
        }

        XCTAssertEqual(summary.totalRequests, 1)
        XCTAssertGreaterThan(byteProgress.count, 2)
        XCTAssertEqual(byteProgress, byteProgress.sorted())
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

    func testUsageDataRebuilderKeepsUnavailableExistingDatabaseWhenSourcesProduceNoRequests() throws {
        let directory = try makeTemporaryDirectory()
        let activeURL = directory.appendingPathComponent("monitor.db")
        let temporaryPath = directory.appendingPathComponent("monitor-rebuild.tmp.db").path
        let claudeRoot = directory.appendingPathComponent("claude-projects")
        let codexRoot = directory.appendingPathComponent("codex-sessions")
        let codexArchiveRoot = directory.appendingPathComponent("codex-archive")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexArchiveRoot, withIntermediateDirectories: true)
        try "{}\n".write(
            to: claudeRoot.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let originalData = Data("not-a-sqlite-database".utf8)
        try originalData.write(to: activeURL)
        let activeDatabase = DatabaseManager.openOrUnavailable(
            path: activeURL.path,
            logError: { _ in }
        )
        let rebuilder = UsageDataRebuilder(
            activeDatabase: activeDatabase,
            temporaryDatabasePath: temporaryPath,
            claudeProjectsPath: claudeRoot.path,
            codexSessionsPath: codexRoot.path,
            codexArchivedSessionsPath: codexArchiveRoot.path
        )

        XCTAssertThrowsError(try rebuilder.rebuild()) { error in
            XCTAssertEqual(error as? UsageDataRebuildError, .suspiciousEmptyResult)
        }
        XCTAssertEqual(try Data(contentsOf: activeURL), originalData)
        XCTAssertFalse(activeDatabase.isAvailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryPath))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MonitorAgentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func claudeAssistantLine(
        messageId: String = "msg-1",
        paddingCount: Int = 0
    ) -> String {
        let padding = paddingCount > 0
            ? ",\"padding\":\"\(String(repeating: "x", count: paddingCount))\""
            : ""
        return """
        {"type":"assistant","sessionId":"session-1","timestamp":"2026-07-05T06:00:00.000Z","message":{"id":"\(messageId)","model":"claude-test"\(padding),"usage":{"input_tokens":120,"output_tokens":30,"cache_read_input_tokens":40,"cache_creation_input_tokens":0}}}

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
