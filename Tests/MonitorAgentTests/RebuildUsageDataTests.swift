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

    func testRoutineSyncSkipsDisabledLocalSources() throws {
        let directory = try makeTemporaryDirectory()
        let claudeRoot = directory.appendingPathComponent("claude-projects")
        let codexRoot = directory.appendingPathComponent("codex-sessions")
        let codexArchiveRoot = directory.appendingPathComponent("codex-archive")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexArchiveRoot, withIntermediateDirectories: true)
        let claudeFile = claudeRoot.appendingPathComponent("session.jsonl")
        try claudeAssistantLine().write(to: claudeFile, atomically: true, encoding: .utf8)
        let database = DatabaseManager(inMemory: true)
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: claudeRoot.path,
            codexSessionsPath: codexRoot.path,
            codexArchivedSessionsPath: codexArchiveRoot.path
        )

        let result = syncManager.syncAllOnce(enabledAgents: [.codex])

        XCTAssertEqual(result, SessionSyncResult())
        XCTAssertNil(database.getSyncState(for: claudeFile.path))
    }

    func testRoutineSyncDoesNotInvokeDisabledCursorSource() {
        let cursorSyncer = CountingCursorUsageSyncer()
        let syncManager = SessionSyncManager(
            database: DatabaseManager(inMemory: true),
            claudeProjectsPath: "/missing-claude-\(UUID().uuidString)",
            codexSessionsPath: "/missing-codex-\(UUID().uuidString)",
            codexArchivedSessionsPath: "/missing-archive-\(UUID().uuidString)",
            cursorUsageSyncer: cursorSyncer
        )

        _ = syncManager.syncAllOnce(enabledAgents: [.claude, .codex])

        XCTAssertEqual(cursorSyncer.syncCount, 0)
    }

    func testCursorSyncPublishesTypedAuthenticationFailureOutcome() {
        let syncManager = SessionSyncManager(
            database: DatabaseManager(inMemory: true),
            cursorUsageSyncer: FailingCursorUsageSyncer()
        )
        let completed = expectation(description: "Cursor failure outcome is published")
        var outcome: CursorUsageSyncOutcome?

        syncManager.syncCursorOnce(
            expectedIdentity: "cursor-account:test",
            onSuccess: {},
            onOutcome: {
                outcome = $0
                completed.fulfill()
            },
            completion: {}
        )

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(outcome, .failure(.authentication))
    }

    func testCursorSyncPublishesTypedRequestFailureOutcome() {
        let syncManager = SessionSyncManager(
            database: DatabaseManager(inMemory: true),
            cursorUsageSyncer: RequestFailingCursorUsageSyncer()
        )
        let completed = expectation(description: "Cursor request failure is published")
        var outcome: CursorUsageSyncOutcome?

        syncManager.syncCursorOnce(
            expectedIdentity: "cursor-account:test",
            onSuccess: {},
            onOutcome: {
                outcome = $0
                completed.fulfill()
            },
            completion: {}
        )

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(outcome, .failure(.request))
    }

    func testCursorSyncPublishesSuccessAndCancellationOutcomes() {
        let database = DatabaseManager(inMemory: true)
        let identity = "cursor-account:test"
        let syncManager = SessionSyncManager(
            database: database,
            cursorUsageSyncer: SuccessfulCursorUsageSyncer(
                database: database,
                identity: identity
            )
        )
        let completed = expectation(description: "Cursor outcomes are published")
        completed.expectedFulfillmentCount = 2
        var outcomes: [CursorUsageSyncOutcome] = []

        syncManager.syncCursorOnce(
            expectedIdentity: identity,
            onSuccess: {},
            onOutcome: {
                outcomes.append($0)
                completed.fulfill()
            },
            completion: {}
        )
        syncManager.syncCursorOnce(
            expectedIdentity: identity,
            cancellation: AgentSyncCancellation(enabledAgents: []),
            onSuccess: {},
            onOutcome: {
                outcomes.append($0)
                completed.fulfill()
            },
            completion: {}
        )

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertTrue(outcomes.contains(.success))
        XCTAssertTrue(outcomes.contains(.cancelled))
    }

    func testRoutineSyncStreamsLineAcrossReadChunkBoundary() throws {
        let directory = try makeTemporaryDirectory()
        let claudeRoot = directory.appendingPathComponent("claude-projects")
        let codexRoot = directory.appendingPathComponent("codex-sessions")
        let codexArchiveRoot = directory.appendingPathComponent("codex-archive")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexArchiveRoot, withIntermediateDirectories: true)
        let sourceFile = claudeRoot.appendingPathComponent("large-line.jsonl")
        let line = String(repeating: " ", count: 1_048_576) + claudeAssistantLine()
        try line.write(to: sourceFile, atomically: true, encoding: .utf8)
        let database = DatabaseManager(inMemory: true)
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: claudeRoot.path,
            codexSessionsPath: codexRoot.path,
            codexArchivedSessionsPath: codexArchiveRoot.path
        )

        let result = syncManager.syncAllOnce(enabledAgents: [.claude])

        XCTAssertEqual(result.recordsSynced, 1)
        XCTAssertEqual(database.fetchStats(app: .claude, range: .allTime).totalRequests, 1)
        XCTAssertEqual(
            database.getSyncState(for: sourceFile.path)?.byteOffset,
            Int64(line.utf8.count)
        )
    }

    func testExclusiveSyncOperationsRunSerially() {
        let database = DatabaseManager(inMemory: true)
        let syncManager = SessionSyncManager(database: database)
        let firstEntered = expectation(description: "first operation entered")
        let secondEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            try! syncManager.performExclusive {
                firstEntered.fulfill()
                releaseFirst.wait()
            }
        }
        wait(for: [firstEntered], timeout: 1)

        DispatchQueue.global().async {
            try! syncManager.performExclusive {
                _ = secondEntered.signal()
            }
        }
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 0.05), .timedOut)

        releaseFirst.signal()
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 1), .success)
    }

    func testLocalSyncCompletionDoesNotWaitForCursorNetworkSync() {
        let database = DatabaseManager(inMemory: true)
        let cursorSyncer = BlockingCursorUsageSyncer()
        let callback = DispatchSemaphore(value: 0)
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: "/missing-claude-\(UUID().uuidString)",
            codexSessionsPath: "/missing-codex-\(UUID().uuidString)",
            codexArchivedSessionsPath: "/missing-archive-\(UUID().uuidString)",
            cursorUsageSyncer: cursorSyncer
        )

        syncManager.syncOnce(
            onLocalComplete: { callback.signal() },
            onCursorComplete: { callback.signal() },
            completion: {}
        )

        XCTAssertEqual(callback.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(cursorSyncer.entered.wait(timeout: .now() + 1), .success)

        syncManager.syncOnce(
            onLocalComplete: { callback.signal() },
            onCursorComplete: { callback.signal() },
            completion: {}
        )
        XCTAssertEqual(callback.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(cursorSyncer.entered.wait(timeout: .now() + 0.05), .timedOut)

        cursorSyncer.release.signal()
        XCTAssertEqual(callback.wait(timeout: .now() + 1), .success)
    }

    func testCursorSyncQueuesDifferentExpectedAccountIdentity() {
        let database = DatabaseManager(inMemory: true)
        let firstIdentity = "cursor-account:first"
        let secondIdentity = "cursor-account:second"
        let cursorSyncer = SequencedIdentityCursorUsageSyncer(
            database: database,
            identities: [firstIdentity, secondIdentity]
        )
        let syncManager = SessionSyncManager(
            database: database,
            cursorUsageSyncer: cursorSyncer
        )
        let firstSuccess = expectation(description: "First account sync succeeds")
        let secondSuccess = expectation(description: "Second account sync succeeds")

        syncManager.syncCursorOnce(
            expectedIdentity: firstIdentity,
            onSuccess: { firstSuccess.fulfill() },
            completion: {}
        )
        XCTAssertEqual(cursorSyncer.firstStarted.wait(timeout: .now() + 1), .success)
        syncManager.syncCursorOnce(
            expectedIdentity: secondIdentity,
            onSuccess: { secondSuccess.fulfill() },
            completion: {}
        )
        XCTAssertEqual(cursorSyncer.syncCount, 1)

        cursorSyncer.releaseFirst.signal()
        wait(for: [firstSuccess, secondSuccess], timeout: 1)
        XCTAssertEqual(cursorSyncer.syncCount, 2)
        XCTAssertEqual(
            database.getSyncState(for: CursorUsageService.syncStateKey)?.sessionId,
            secondIdentity
        )
    }

    func testQueuedCursorSyncRetainsManagerUntilCompletion() {
        let cursorQueue = DispatchQueue(label: "test.cursor-sync-retention")
        cursorQueue.suspend()
        var syncManager: SessionSyncManager? = SessionSyncManager(
            database: DatabaseManager(inMemory: true),
            cursorUsageSyncer: CountingCursorUsageSyncer(),
            cursorQueue: cursorQueue
        )
        weak let retainedManager = syncManager
        let completed = expectation(description: "Queued Cursor request completes")

        syncManager?.syncCursorOnce(
            expectedIdentity: "cursor-account:first",
            onSuccess: {},
            completion: { completed.fulfill() }
        )
        syncManager = nil

        XCTAssertNotNil(retainedManager)
        cursorQueue.resume()
        wait(for: [completed], timeout: 1)
    }

    func testCursorPresentationPublicationBlocksAccountReplacement() throws {
        let database = DatabaseManager(inMemory: true)
        let firstIdentity = "cursor-account:first"
        let secondIdentity = "cursor-account:second"
        let firstState = SyncState(
            filePath: CursorUsageService.syncStateKey,
            byteOffset: 1,
            recordCount: 0,
            sessionId: firstIdentity,
            model: nil,
            lastModified: 1,
            lastSyncedAt: 1
        )
        let secondState = SyncState(
            filePath: CursorUsageService.syncStateKey,
            byteOffset: 2,
            recordCount: 0,
            sessionId: secondIdentity,
            model: nil,
            lastModified: 2,
            lastSyncedAt: 2
        )
        try database.replaceAppRecords(
            appType: AgentID.cursor.appType,
            records: [],
            state: firstState
        )
        let token = try XCTUnwrap(
            database.cursorDataPresentationToken(matching: firstIdentity)
        )
        let publicationEntered = DispatchSemaphore(value: 0)
        let releasePublication = DispatchSemaphore(value: 0)
        let replacementAttempted = DispatchSemaphore(value: 0)
        let replacementCompleted = DispatchSemaphore(value: 0)
        let publicationCompleted = expectation(description: "Atomic publication completes")

        DispatchQueue.global().async {
            let didPublish = database.performIfCursorDataPresentationTokenCurrent(token) {
                publicationEntered.signal()
                _ = releasePublication.wait(timeout: .now() + 2)
            }
            XCTAssertTrue(didPublish)
            publicationCompleted.fulfill()
        }
        XCTAssertEqual(publicationEntered.wait(timeout: .now() + 1), .success)

        DispatchQueue.global().async {
            replacementAttempted.signal()
            try! database.replaceAppRecords(
                appType: AgentID.cursor.appType,
                records: [],
                state: secondState
            )
            replacementCompleted.signal()
        }
        XCTAssertEqual(replacementAttempted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(replacementCompleted.wait(timeout: .now() + 0.05), .timedOut)

        releasePublication.signal()
        wait(for: [publicationCompleted], timeout: 1)
        XCTAssertEqual(replacementCompleted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            database.getSyncState(for: CursorUsageService.syncStateKey)?.sessionId,
            secondIdentity
        )
    }

    func testCursorSyncPreservesAccountGenerationOrderAcrossRepeatedIdentity() {
        let database = DatabaseManager(inMemory: true)
        let firstIdentity = "cursor-account:first"
        let secondIdentity = "cursor-account:second"
        let cursorSyncer = SequencedIdentityCursorUsageSyncer(
            database: database,
            identities: [firstIdentity, secondIdentity, firstIdentity]
        )
        let syncManager = SessionSyncManager(
            database: database,
            cursorUsageSyncer: cursorSyncer
        )
        let successes = expectation(description: "Every account generation succeeds")
        successes.expectedFulfillmentCount = 3

        syncManager.syncCursorOnce(
            expectedIdentity: firstIdentity,
            onSuccess: { successes.fulfill() },
            completion: {}
        )
        XCTAssertEqual(cursorSyncer.firstStarted.wait(timeout: .now() + 1), .success)
        syncManager.syncCursorOnce(
            expectedIdentity: secondIdentity,
            onSuccess: { successes.fulfill() },
            completion: {}
        )
        syncManager.syncCursorOnce(
            expectedIdentity: firstIdentity,
            onSuccess: { successes.fulfill() },
            completion: {}
        )

        cursorSyncer.releaseFirst.signal()
        wait(for: [successes], timeout: 1)
        XCTAssertEqual(cursorSyncer.syncCount, 3)
        XCTAssertEqual(
            database.getSyncState(for: CursorUsageService.syncStateKey)?.sessionId,
            firstIdentity
        )
    }

    func testExclusiveOperationWaitsForPendingCursorGenerations() {
        let database = DatabaseManager(inMemory: true)
        let firstIdentity = "cursor-account:first"
        let secondIdentity = "cursor-account:second"
        let cursorSyncer = SequencedIdentityCursorUsageSyncer(
            database: database,
            identities: [firstIdentity, secondIdentity]
        )
        let syncManager = SessionSyncManager(
            database: database,
            cursorUsageSyncer: cursorSyncer
        )
        let syncsCompleted = expectation(description: "Cursor generations complete")
        syncsCompleted.expectedFulfillmentCount = 2
        let exclusiveAttempted = DispatchSemaphore(value: 0)
        let exclusiveEntered = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var syncCountAtExclusiveEntry: Int?

        syncManager.syncCursorOnce(
            expectedIdentity: firstIdentity,
            onSuccess: { syncsCompleted.fulfill() },
            completion: {}
        )
        XCTAssertEqual(cursorSyncer.firstStarted.wait(timeout: .now() + 1), .success)
        syncManager.syncCursorOnce(
            expectedIdentity: secondIdentity,
            onSuccess: { syncsCompleted.fulfill() },
            completion: {}
        )
        DispatchQueue.global().async {
            exclusiveAttempted.signal()
            try! syncManager.performExclusive {
                resultLock.lock()
                syncCountAtExclusiveEntry = cursorSyncer.syncCount
                resultLock.unlock()
                exclusiveEntered.signal()
            }
        }
        XCTAssertEqual(exclusiveAttempted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(exclusiveEntered.wait(timeout: .now() + 0.05), .timedOut)

        cursorSyncer.releaseFirst.signal()
        wait(for: [syncsCompleted], timeout: 1)
        XCTAssertEqual(exclusiveEntered.wait(timeout: .now() + 1), .success)
        resultLock.lock()
        let capturedSyncCount = syncCountAtExclusiveEntry
        resultLock.unlock()
        XCTAssertEqual(capturedSyncCount, 2)
        XCTAssertEqual(
            database.getSyncState(for: CursorUsageService.syncStateKey)?.sessionId,
            secondIdentity
        )
    }

    func testExclusiveOperationCannotOvertakePublishedCursorDrain() {
        let database = DatabaseManager(inMemory: true)
        let identity = "cursor-account:first"
        let beforeSubmission = DispatchSemaphore(value: 0)
        let allowSubmission = DispatchSemaphore(value: 0)
        let cursorSyncer = SequencedIdentityCursorUsageSyncer(
            database: database,
            identities: [identity]
        )
        let syncManager = SessionSyncManager(
            database: database,
            cursorUsageSyncer: cursorSyncer,
            beforeCursorDrainSubmission: {
                beforeSubmission.signal()
                _ = allowSubmission.wait(timeout: .now() + 2)
            }
        )
        let syncCompleted = expectation(description: "Published Cursor drain completes")
        let exclusiveAttempted = DispatchSemaphore(value: 0)
        let exclusiveEntered = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            syncManager.syncCursorOnce(
                expectedIdentity: identity,
                onSuccess: { syncCompleted.fulfill() },
                completion: {}
            )
        }
        XCTAssertEqual(beforeSubmission.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async {
            exclusiveAttempted.signal()
            _ = try! syncManager.performExclusive {
                exclusiveEntered.signal()
            }
        }
        XCTAssertEqual(exclusiveAttempted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(exclusiveEntered.wait(timeout: .now() + 0.05), .timedOut)

        allowSubmission.signal()
        XCTAssertEqual(cursorSyncer.firstStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(exclusiveEntered.wait(timeout: .now() + 0.05), .timedOut)
        cursorSyncer.releaseFirst.signal()
        wait(for: [syncCompleted], timeout: 1)
        XCTAssertEqual(exclusiveEntered.wait(timeout: .now() + 1), .success)
    }

    func testCursorRequestSubmittedAfterExclusiveOperationRunsAfterBarrier() {
        let database = DatabaseManager(inMemory: true)
        let firstIdentity = "cursor-account:first"
        let secondIdentity = "cursor-account:second"
        let operationPublished = DispatchSemaphore(value: 0)
        let cursorSyncer = SequencedIdentityCursorUsageSyncer(
            database: database,
            identities: [firstIdentity, secondIdentity]
        )
        let syncManager = SessionSyncManager(
            database: database,
            cursorUsageSyncer: cursorSyncer,
            beforeCursorOperationSubmission: {
                operationPublished.signal()
            }
        )
        let firstCompleted = expectation(description: "First Cursor request completes")
        let secondCompleted = expectation(description: "Second Cursor request completes")
        let resultLock = NSLock()
        var syncCountAtExclusiveEntry: Int?

        syncManager.syncCursorOnce(
            expectedIdentity: firstIdentity,
            onSuccess: { firstCompleted.fulfill() },
            completion: {}
        )
        XCTAssertEqual(cursorSyncer.firstStarted.wait(timeout: .now() + 1), .success)

        DispatchQueue.global().async {
            _ = try! syncManager.performExclusive {
                resultLock.lock()
                syncCountAtExclusiveEntry = cursorSyncer.syncCount
                resultLock.unlock()
            }
        }
        XCTAssertEqual(operationPublished.wait(timeout: .now() + 1), .success)

        syncManager.syncCursorOnce(
            expectedIdentity: secondIdentity,
            onSuccess: { secondCompleted.fulfill() },
            completion: {}
        )
        cursorSyncer.releaseFirst.signal()

        wait(for: [firstCompleted, secondCompleted], timeout: 1)
        resultLock.lock()
        let capturedSyncCount = syncCountAtExclusiveEntry
        resultLock.unlock()
        XCTAssertEqual(capturedSyncCount, 1)
        XCTAssertEqual(
            database.getSyncState(for: CursorUsageService.syncStateKey)?.sessionId,
            secondIdentity
        )
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

    func testUsageDataRebuilderCancelsDuringCursorUsageWithoutReplacingActiveDatabase() throws {
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
        let cursorUsageSyncer = BlockingCancellableCursorUsageSyncer()
        let rebuilder = UsageDataRebuilder(
            activeDatabase: activeDatabase,
            temporaryDatabasePath: temporaryPath,
            claudeProjectsPath: claudeRoot.path,
            codexSessionsPath: codexRoot.path,
            codexArchivedSessionsPath: codexArchiveRoot.path,
            cursorUsageServiceFactory: { _ in cursorUsageSyncer }
        )
        let finished = expectation(description: "Rebuild stops during Cursor usage")
        var rebuildError: Error?

        DispatchQueue.global(qos: .utility).async {
            do {
                _ = try rebuilder.rebuild(cancellation: cancellation)
            } catch {
                rebuildError = error
            }
            finished.fulfill()
        }
        XCTAssertEqual(cursorUsageSyncer.started.wait(timeout: .now() + 1), .success)
        cancellation.cancel()
        wait(for: [finished], timeout: 2)

        XCTAssertEqual(rebuildError as? StrictSessionSyncError, .cancelled)
        XCTAssertEqual(activeDatabase.fetchStats(app: .all, range: .allTime).inputTokens, 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryPath))
    }

    func testUsageDataRebuilderCancelsDuringCursorSpendWithoutReplacingActiveDatabase() throws {
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
        let identity = "cursor-account:test"
        _ = try SuccessfulCursorUsageSyncer(
            database: activeDatabase,
            identity: identity
        ).sync()
        let activeSpendArchive = CursorDailySpendArchive(
            accountIdentity: identity,
            days: [CursorDailySpend(dayMilliseconds: 0, totalCents: 700)],
            syncedThroughMilliseconds: 86_400_000,
            lastSyncedAt: Date(timeIntervalSince1970: 20)
        )
        try activeDatabase.restoreCursorDailySpendArchive(activeSpendArchive)
        let cancellation = UsageDataRebuildCancellation()
        let cursorSpendSyncer = BlockingCancellableCursorSpendSyncer()
        let rebuilder = UsageDataRebuilder(
            activeDatabase: activeDatabase,
            temporaryDatabasePath: temporaryPath,
            claudeProjectsPath: claudeRoot.path,
            codexSessionsPath: codexRoot.path,
            codexArchivedSessionsPath: codexArchiveRoot.path,
            cursorUsageServiceFactory: {
                SuccessfulCursorUsageSyncer(database: $0, identity: identity)
            },
            cursorSpendServiceFactory: { _ in cursorSpendSyncer }
        )
        let finished = expectation(description: "Rebuild stops during Cursor spend")
        var rebuildError: Error?

        DispatchQueue.global(qos: .utility).async {
            do {
                _ = try rebuilder.rebuild(cancellation: cancellation)
            } catch {
                rebuildError = error
            }
            finished.fulfill()
        }
        XCTAssertEqual(cursorSpendSyncer.started.wait(timeout: .now() + 1), .success)
        cancellation.cancel()
        wait(for: [finished], timeout: 2)

        XCTAssertEqual(rebuildError as? StrictSessionSyncError, .cancelled)
        XCTAssertEqual(activeDatabase.fetchStats(app: .all, range: .allTime).inputTokens, 11)
        XCTAssertEqual(
            activeDatabase.fetchCursorDailySpendArchive(accountIdentity: identity),
            activeSpendArchive
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryPath))
    }

    func testUsageDataRebuildReplacementBoundaryHasSingleWinner() {
        let cancelledFirst = UsageDataRebuildCancellation()
        cancelledFirst.cancel()
        XCTAssertFalse(cancelledFirst.beginReplacement())

        let replacementFirst = UsageDataRebuildCancellation()
        XCTAssertTrue(replacementFirst.beginReplacement())
        replacementFirst.cancel()
        XCTAssertFalse(replacementFirst.isCancelled)
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

    func testUsageDataRebuilderPreservesCachedCursorDataWhenRefreshFails() throws {
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
        activeDatabase.insertRecords([ParsedRecord(
            requestId: "cursor:cached",
            appType: "cursor",
            model: "cursor-model",
            inputTokens: 10,
            outputTokens: 20,
            cacheReadTokens: 30,
            cacheCreationTokens: 40,
            sessionId: "cursor-session",
            createdAt: 1_783_238_400
        )])
        let rebuilder = UsageDataRebuilder(
            activeDatabase: activeDatabase,
            temporaryDatabasePath: temporaryPath,
            claudeProjectsPath: claudeRoot.path,
            codexSessionsPath: codexRoot.path,
            codexArchivedSessionsPath: codexArchiveRoot.path,
            cursorUsageServiceFactory: { _ in FailingCursorUsageSyncer() }
        )

        XCTAssertThrowsError(try rebuilder.rebuild()) { error in
            XCTAssertEqual(error as? UsageDataRebuildError, .cursorRefreshFailed)
        }
        XCTAssertEqual(activeDatabase.fetchStats(app: .cursor, range: .allTime).totalRequests, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryPath))
    }

    func testUsageDataRebuilderPreservesCachedCursorDataOnSuccessfulEmptyRefresh() throws {
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
        activeDatabase.insertRecords([ParsedRecord(
            requestId: "cursor:cached",
            appType: "cursor",
            model: "cursor-model",
            inputTokens: 10,
            outputTokens: 20,
            cacheReadTokens: 30,
            cacheCreationTokens: 40,
            sessionId: "cursor-session",
            createdAt: 1_783_238_400
        )])
        let rebuilder = UsageDataRebuilder(
            activeDatabase: activeDatabase,
            temporaryDatabasePath: temporaryPath,
            claudeProjectsPath: claudeRoot.path,
            codexSessionsPath: codexRoot.path,
            codexArchivedSessionsPath: codexArchiveRoot.path,
            cursorUsageServiceFactory: { _ in EmptyCursorUsageSyncer() }
        )

        XCTAssertThrowsError(try rebuilder.rebuild()) { error in
            XCTAssertEqual(error as? UsageDataRebuildError, .cursorRefreshFailed)
        }
        XCTAssertEqual(activeDatabase.fetchStats(app: .cursor, range: .allTime).totalRequests, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryPath))
    }

    func testUsageDataRebuilderRestoresSameAccountCursorSpendData() throws {
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

        let identity = "cursor-account:test"
        let range = CursorSpendRange(
            key: "today",
            startMilliseconds: 0,
            endMilliseconds: 86_400_000
        )
        let activeDatabase = try DatabaseManager(path: activePath)
        _ = try SuccessfulCursorUsageSyncer(
            database: activeDatabase,
            identity: identity
        ).sync()
        _ = try activeDatabase.mergeCursorSpendSnapshot(
            accountIdentity: identity,
            range: range,
            totalCents: 500,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        try activeDatabase.replaceCursorDailySpend(
            accountIdentity: identity,
            days: [CursorDailySpend(dayMilliseconds: 0, totalCents: 700)],
            replacementStartMilliseconds: nil,
            replacementEndMilliseconds: nil,
            syncedThroughMilliseconds: 86_400_000,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let rebuilder = UsageDataRebuilder(
            activeDatabase: activeDatabase,
            temporaryDatabasePath: temporaryPath,
            claudeProjectsPath: claudeRoot.path,
            codexSessionsPath: codexRoot.path,
            codexArchivedSessionsPath: codexArchiveRoot.path,
            cursorUsageServiceFactory: {
                SuccessfulCursorUsageSyncer(database: $0, identity: identity)
            }
        )

        _ = try rebuilder.rebuild()
        let restored = try XCTUnwrap(activeDatabase.fetchCursorSpendSnapshot(
            accountIdentity: identity,
            range: range
        ))

        XCTAssertEqual(restored.totalCents, 700)
        XCTAssertEqual(
            activeDatabase.fetchCursorSpendSnapshots(accountIdentity: identity).first?.totalCents,
            500
        )
    }

    func testUsageDataRebuilderRecalibratesCompleteCursorSpendHistory() throws {
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
        let identity = "cursor-account:test"
        let activeDatabase = try DatabaseManager(path: activePath)
        _ = try SuccessfulCursorUsageSyncer(
            database: activeDatabase,
            identity: identity
        ).sync()
        try activeDatabase.replaceCursorDailySpend(
            accountIdentity: identity,
            days: [CursorDailySpend(dayMilliseconds: 0, totalCents: 700)],
            replacementStartMilliseconds: nil,
            replacementEndMilliseconds: nil,
            syncedThroughMilliseconds: 86_400_000,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let rebuilder = UsageDataRebuilder(
            activeDatabase: activeDatabase,
            temporaryDatabasePath: temporaryPath,
            claudeProjectsPath: claudeRoot.path,
            codexSessionsPath: codexRoot.path,
            codexArchivedSessionsPath: codexArchiveRoot.path,
            cursorUsageServiceFactory: {
                SuccessfulCursorUsageSyncer(database: $0, identity: identity)
            },
            cursorSpendServiceFactory: {
                RecalibratingCursorSpendSyncer(database: $0, identity: identity)
            }
        )

        _ = try rebuilder.rebuild()
        let archive = try XCTUnwrap(
            activeDatabase.fetchCursorDailySpendArchive(accountIdentity: identity)
        )

        XCTAssertEqual(
            archive.days,
            [CursorDailySpend(dayMilliseconds: 86_400_000, totalCents: 900)]
        )
        XCTAssertEqual(archive.syncedThroughMilliseconds, 172_800_000)
    }

    func testUsageDataRebuilderPreservesActiveDataWhenSpendCalibrationFails() throws {
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
        let identity = "cursor-account:test"
        let activeDatabase = try DatabaseManager(path: activePath)
        _ = try SuccessfulCursorUsageSyncer(
            database: activeDatabase,
            identity: identity
        ).sync()
        let archive = CursorDailySpendArchive(
            accountIdentity: identity,
            days: [CursorDailySpend(dayMilliseconds: 0, totalCents: 700)],
            syncedThroughMilliseconds: 86_400_000,
            lastSyncedAt: Date(timeIntervalSince1970: 20)
        )
        try activeDatabase.restoreCursorDailySpendArchive(archive)
        let rebuilder = UsageDataRebuilder(
            activeDatabase: activeDatabase,
            temporaryDatabasePath: temporaryPath,
            claudeProjectsPath: claudeRoot.path,
            codexSessionsPath: codexRoot.path,
            codexArchivedSessionsPath: codexArchiveRoot.path,
            cursorUsageServiceFactory: {
                SuccessfulCursorUsageSyncer(database: $0, identity: identity)
            },
            cursorSpendServiceFactory: { _ in FailingCursorSpendSyncer() }
        )

        XCTAssertThrowsError(try rebuilder.rebuild()) { error in
            XCTAssertEqual(error as? UsageDataRebuildError, .cursorRefreshFailed)
        }
        XCTAssertEqual(
            activeDatabase.fetchCursorDailySpendArchive(accountIdentity: identity),
            archive
        )
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

private struct FailingCursorUsageSyncer: CursorUsageSyncing {
    func sync() throws -> SessionSyncResult {
        throw CursorUsageError.authenticationRejected
    }
}

private struct RequestFailingCursorUsageSyncer: CursorUsageSyncing {
    func sync() throws -> SessionSyncResult {
        throw CursorUsageError.requestFailed
    }
}

private struct EmptyCursorUsageSyncer: CursorUsageSyncing {
    func sync() throws -> SessionSyncResult {
        SessionSyncResult(filesSynced: 1, recordsSynced: 0)
    }
}

private struct SuccessfulCursorUsageSyncer: CursorUsageSyncing {
    let database: DatabaseManager
    let identity: String

    func sync() throws -> SessionSyncResult {
        let record = ParsedRecord(
            requestId: "cursor:rebuilt",
            appType: AgentID.cursor.appType,
            model: "cursor-model",
            inputTokens: 1,
            outputTokens: 2,
            cacheReadTokens: 3,
            cacheCreationTokens: 4,
            sessionId: "cursor-session",
            createdAt: 1_783_238_400
        )
        let state = SyncState(
            filePath: CursorUsageService.syncStateKey,
            byteOffset: 1,
            recordCount: 1,
            sessionId: identity,
            model: nil,
            lastModified: 1,
            lastSyncedAt: 1
        )
        try database.replaceAppRecords(
            appType: AgentID.cursor.appType,
            records: [record],
            state: state
        )
        return SessionSyncResult(filesSynced: 1, recordsSynced: 1)
    }
}

private final class RecalibratingCursorSpendSyncer: CursorSpendHistorySyncing {
    private let database: DatabaseManager
    private let identity: String

    init(database: DatabaseManager, identity: String) {
        self.database = database
        self.identity = identity
    }

    func refreshFullHistory(
        cancellation: CursorOperationCancellation?
    ) throws -> CursorSpendSnapshot? {
        try database.replaceCursorDailySpend(
            accountIdentity: identity,
            days: [CursorDailySpend(dayMilliseconds: 86_400_000, totalCents: 900)],
            replacementStartMilliseconds: nil,
            replacementEndMilliseconds: nil,
            syncedThroughMilliseconds: 172_800_000,
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        return database.fetchCursorSpendSnapshot(
            accountIdentity: identity,
            range: CursorSpendRange(
                key: TimeRange.allTime.id,
                startMilliseconds: nil,
                endMilliseconds: nil
            )
        )
    }
}

private final class FailingCursorSpendSyncer: CursorSpendHistorySyncing {
    func refreshFullHistory(
        cancellation: CursorOperationCancellation?
    ) throws -> CursorSpendSnapshot? {
        throw CursorUsageError.requestFailed
    }
}

private final class BlockingCancellableCursorUsageSyncer: CancellableCursorUsageSyncing {
    let started = DispatchSemaphore(value: 0)

    func sync() throws -> SessionSyncResult {
        XCTFail("Rebuild Cursor usage must receive its cancellation token")
        return SessionSyncResult()
    }

    func sync(cancellation: CursorOperationCancellation?) throws -> SessionSyncResult {
        started.signal()
        while cancellation?.isCursorCancelled != true {
            Thread.sleep(forTimeInterval: 0.001)
        }
        throw CursorUsageError.cancelled
    }
}

private final class BlockingCancellableCursorSpendSyncer: CursorSpendHistorySyncing {
    let started = DispatchSemaphore(value: 0)

    func refreshFullHistory(
        cancellation: CursorOperationCancellation?
    ) throws -> CursorSpendSnapshot? {
        started.signal()
        while cancellation?.isCursorCancelled != true {
            Thread.sleep(forTimeInterval: 0.001)
        }
        throw CursorUsageError.cancelled
    }
}

private final class BlockingCursorUsageSyncer: CursorUsageSyncing {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func sync() throws -> SessionSyncResult {
        entered.signal()
        release.wait()
        return SessionSyncResult(filesSynced: 1, recordsSynced: 0)
    }
}

private final class CountingCursorUsageSyncer: CursorUsageSyncing {
    private(set) var syncCount = 0

    func sync() throws -> SessionSyncResult {
        syncCount += 1
        return SessionSyncResult(filesSynced: 1, recordsSynced: 0)
    }
}

private final class SequencedIdentityCursorUsageSyncer: CursorUsageSyncing {
    let firstStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    private let database: DatabaseManager
    private let identities: [String]
    private let lock = NSLock()
    private var storedSyncCount = 0

    var syncCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedSyncCount
    }

    init(database: DatabaseManager, identities: [String]) {
        self.database = database
        self.identities = identities
    }

    func sync() throws -> SessionSyncResult {
        lock.lock()
        let index = storedSyncCount
        storedSyncCount += 1
        lock.unlock()
        guard identities.indices.contains(index) else {
            throw CursorUsageError.invalidResponse
        }
        if index == 0 {
            firstStarted.signal()
            _ = releaseFirst.wait(timeout: .now() + 2)
        }
        let state = SyncState(
            filePath: CursorUsageService.syncStateKey,
            byteOffset: Int64(index + 1),
            recordCount: 0,
            sessionId: identities[index],
            model: nil,
            lastModified: index + 1,
            lastSyncedAt: index + 1
        )
        try database.replaceAppRecords(
            appType: AgentID.cursor.appType,
            records: [],
            state: state
        )
        return SessionSyncResult(filesSynced: 1, recordsSynced: 0)
    }
}
