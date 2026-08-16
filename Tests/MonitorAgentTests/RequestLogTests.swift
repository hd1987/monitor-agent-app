import GRDB
import XCTest
@testable import MonitorAgent

final class RequestLogTests: XCTestCase {
    func testRequestsWindowUsesRequestedInitialContentSize() {
        XCTAssertEqual(RequestsWindowLayout.initialSize.width, 860)
        XCTAssertEqual(RequestsWindowLayout.initialSize.height, 750)
    }

    func testCursorDetailSummaryIsUnavailableWhenPresentationExcludesCursor() {
        let unavailableContext = RequestPresentationContext(
            enabledAgents: [.claude, .codex],
            cursorDataPresentationToken: nil,
            cursorSpendAccountIdentity: nil
        )
        let model = RequestsViewModel(
            database: DatabaseManager(inMemory: true),
            provider: .cursor,
            timeRange: .today,
            enabledAgents: Set(AgentID.allCases),
            presentationContext: unavailableContext
        )

        XCTAssertFalse(model.isSummaryAvailable)

        model.updateEnabledAgents(
            Set(AgentID.allCases),
            presentationContext: RequestPresentationContext(
                enabledAgents: Set(AgentID.allCases),
                cursorDataPresentationToken: nil,
                cursorSpendAccountIdentity: nil
            )
        )

        XCTAssertTrue(model.isSummaryAvailable)
    }

    func testDetailTotalUsageUsesCursorSpendSnapshotForAllAndCursor() throws {
        let database = DatabaseManager(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_786_435_200)
        let identity = "cursor-account:test"
        try database.replaceAppRecords(
            appType: AgentID.cursor.appType,
            records: [],
            state: SyncState(
                filePath: CursorUsageService.syncStateKey,
                byteOffset: 0,
                recordCount: 0,
                sessionId: identity,
                model: nil,
                lastModified: 0,
                lastSyncedAt: 0
            )
        )
        _ = try database.mergeCursorSpendSnapshot(
            accountIdentity: identity,
            range: CursorSpendRange(timeRange: .today, now: now),
            totalCents: 3_039,
            updatedAt: now
        )

        XCTAssertEqual(
            RequestDetailTotalUsageResolver.totalUsageMicros(
                database: database,
                provider: .all,
                range: .today,
                enabledAgents: Set(AgentID.allCases),
                accountIdentity: identity,
                now: now
            ),
            30_390_000
        )
        XCTAssertEqual(
            RequestDetailTotalUsageResolver.totalUsageMicros(
                database: database,
                provider: .cursor,
                range: .today,
                enabledAgents: Set(AgentID.allCases),
                accountIdentity: identity,
                now: now
            ),
            30_390_000
        )
        XCTAssertNil(
            RequestDetailTotalUsageResolver.totalUsageMicros(
                database: database,
                provider: .codex,
                range: .today,
                enabledAgents: Set(AgentID.allCases),
                accountIdentity: identity,
                now: now
            )
        )
    }

    func testCostSchemaMigrationPreservesUsageWatermarkAndCreatesBackfillState() throws {
        let databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MonitorAgent-Requests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let legacyDatabase = try DatabaseQueue(path: databaseURL.path)
        try legacyDatabase.write { db in
            try db.execute(sql: """
                CREATE TABLE request_logs (
                    request_id TEXT PRIMARY KEY,
                    app_type TEXT NOT NULL,
                    model TEXT NOT NULL,
                    input_tokens INTEGER NOT NULL DEFAULT 0,
                    output_tokens INTEGER NOT NULL DEFAULT 0,
                    cache_read_tokens INTEGER NOT NULL DEFAULT 0,
                    cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
                    session_id TEXT,
                    created_at INTEGER NOT NULL
                );
                CREATE TABLE sync_state (
                    file_path TEXT PRIMARY KEY,
                    byte_offset INTEGER NOT NULL DEFAULT 0,
                    record_count INTEGER NOT NULL DEFAULT 0,
                    session_id TEXT,
                    model TEXT,
                    last_total_input_tokens INTEGER NOT NULL DEFAULT 0,
                    last_total_output_tokens INTEGER NOT NULL DEFAULT 0,
                    last_modified INTEGER NOT NULL,
                    last_synced_at INTEGER NOT NULL
                );
                INSERT INTO sync_state VALUES (
                    'cursor://usage-events', 1800000000000, 1,
                    'cursor-account:identity', NULL, 0, 0, 10, 10
                );
                INSERT INTO request_logs VALUES (
                    'cursor:legacy', 'cursor', 'cursor-model', 1, 2, 3, 4,
                    'cursor-session', 1790000000
                );
                """)
        }

        let database = try DatabaseManager(path: databaseURL.path)
        let state = try XCTUnwrap(database.getSyncState(for: CursorUsageService.syncStateKey))
        let backfill = try XCTUnwrap(database.cursorUsageCostBackfillState(
            accountIdentity: "cursor-account:identity"
        ))
        let migratedDatabase = try DatabaseQueue(path: databaseURL.path)
        let columns = try migratedDatabase.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(request_logs)")
                .map { $0["name"] as String }
        }

        XCTAssertEqual(state.sessionId, "cursor-account:identity")
        XCTAssertEqual(state.byteOffset, 1_800_000_000_000)
        XCTAssertEqual(backfill.nextStartMilliseconds, 1_790_000_000_000)
        XCTAssertEqual(backfill.targetEndMilliseconds, 1_799_996_400_000)
        XCTAssertTrue(columns.contains("charged_cost_micros"))
        XCTAssertTrue(columns.contains("list_cost_micros"))
        XCTAssertTrue(columns.contains("discount_percent"))
        XCTAssertTrue(columns.contains("is_free_request"))
    }

    func testLatestRequestQuerySchedulerSkipsSupersededQueuedWork() {
        let scheduler = LatestRequestQueryScheduler(label: "requests-query-test")
        let blockerStarted = expectation(description: "blocker started")
        let latestFinished = expectation(description: "latest finished")
        let releaseBlocker = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var executed: [String] = []

        scheduler.submit { _ in
            blockerStarted.fulfill()
            releaseBlocker.wait()
        }
        wait(for: [blockerStarted], timeout: 1)
        scheduler.submit { _ in
            lock.lock()
            executed.append("obsolete")
            lock.unlock()
        }
        scheduler.submit { _ in
            lock.lock()
            executed.append("latest")
            lock.unlock()
            latestFinished.fulfill()
        }
        releaseBlocker.signal()

        wait(for: [latestFinished], timeout: 1)
        lock.lock()
        let result = executed
        lock.unlock()
        XCTAssertEqual(result, ["latest"])
    }

    func testRequestPresentationPublicationBlocksCursorReplacement() throws {
        let database = DatabaseManager(inMemory: true)
        let firstIdentity = "cursor-account:first"
        try database.replaceAppRecords(
            appType: AgentID.cursor.appType,
            records: [],
            state: SyncState(
                filePath: CursorUsageService.syncStateKey,
                byteOffset: 1,
                recordCount: 0,
                sessionId: firstIdentity,
                model: nil,
                lastModified: 1,
                lastSyncedAt: 1
            )
        )
        let context = RequestPresentationContext(
            enabledAgents: Set(AgentID.allCases),
            cursorDataPresentationToken: try XCTUnwrap(
                database.cursorDataPresentationToken(matching: firstIdentity)
            ),
            cursorSpendAccountIdentity: firstIdentity
        )
        let publicationStarted = DispatchSemaphore(value: 0)
        let releasePublication = DispatchSemaphore(value: 0)
        let publicationFinished = DispatchSemaphore(value: 0)
        let replacementFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            context.performIfCurrent(in: database) {
                publicationStarted.signal()
                releasePublication.wait()
            }
            publicationFinished.signal()
        }
        XCTAssertEqual(publicationStarted.wait(timeout: .now() + 1), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            try? database.replaceAppRecords(
                appType: AgentID.cursor.appType,
                records: [],
                state: SyncState(
                    filePath: CursorUsageService.syncStateKey,
                    byteOffset: 2,
                    recordCount: 0,
                    sessionId: "cursor-account:second",
                    model: nil,
                    lastModified: 2,
                    lastSyncedAt: 2
                )
            )
            replacementFinished.signal()
        }
        XCTAssertEqual(replacementFinished.wait(timeout: .now() + 0.05), .timedOut)

        releasePublication.signal()
        XCTAssertEqual(publicationFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(replacementFinished.wait(timeout: .now() + 1), .success)
        XCTAssertNil(database.cursorDataPresentationToken(matching: firstIdentity))
    }

    func testRequestPagesUseStableKeysetOrderWithoutDuplicates() {
        let database = DatabaseManager(inMemory: true)
        database.insertRecords((0..<205).map { index in
            ParsedRecord(
                requestId: String(format: "codex:request:%03d", index),
                appType: AgentID.codex.appType,
                model: "gpt-test",
                inputTokens: index,
                outputTokens: 1,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                sessionId: "session",
                createdAt: 1_800_000_000 + index / 3
            )
        })

        let first = database.fetchRequestLogPage(app: .codex, range: .allTime, limit: 100)
        let second = database.fetchRequestLogPage(
            app: .codex,
            range: .allTime,
            after: first.nextCursor,
            limit: 100
        )
        let third = database.fetchRequestLogPage(
            app: .codex,
            range: .allTime,
            after: second.nextCursor,
            limit: 100
        )
        let items = first.items + second.items + third.items

        XCTAssertEqual(first.items.count, 100)
        XCTAssertEqual(second.items.count, 100)
        XCTAssertEqual(third.items.count, 5)
        XCTAssertNil(third.nextCursor)
        XCTAssertEqual(Set(items.map(\.requestId)).count, 205)
        let sortedItems = items.sorted {
            $0.createdAt == $1.createdAt
                ? $0.requestId > $1.requestId
                : $0.createdAt > $1.createdAt
        }
        XCTAssertEqual(items.map(\.requestId), sortedItems.map(\.requestId))
    }

    func testRequestSummaryAggregatesUsageWithoutEstimatingTotalSpend() {
        let database = DatabaseManager(inMemory: true)
        database.insertRecords([
            ParsedRecord(
                requestId: "codex:one",
                appType: AgentID.codex.appType,
                model: "gpt-test",
                inputTokens: 10,
                outputTokens: 20,
                cacheReadTokens: 30,
                cacheCreationTokens: 0,
                sessionId: "codex-session",
                createdAt: 1_800_000_000
            ),
            ParsedRecord(
                requestId: "cursor:one",
                appType: AgentID.cursor.appType,
                model: "cursor-test",
                inputTokens: 40,
                outputTokens: 50,
                cacheReadTokens: 60,
                cacheCreationTokens: 70,
                sessionId: "cursor-session",
                createdAt: 1_800_000_001,
                chargedCostMicros: 350_000,
                listCostMicros: 700_000,
                discountPercent: 50
            ),
        ])

        let all = database.fetchRequestLogSummary(app: .all, range: .allTime)
        let codex = database.fetchRequestLogSummary(app: .codex, range: .allTime)
        let disabledCursor = database.fetchRequestLogSummary(
            app: .all,
            range: .allTime,
            enabledAgents: [.codex]
        )

        XCTAssertEqual(all.totalRequests, 2)
        XCTAssertEqual(all.totalSessions, 2)
        XCTAssertEqual(all.totalTokens, 280)
        XCTAssertEqual(all.inputTokens, 50)
        XCTAssertEqual(all.outputTokens, 70)
        XCTAssertEqual(all.cacheReadTokens, 90)
        XCTAssertEqual(all.cacheCreationTokens, 70)
        XCTAssertEqual(all.cacheHitRate, 90.0 / 210.0, accuracy: 0.0001)
        XCTAssertEqual(all.totalUsageMicros, nil)
        XCTAssertEqual(codex.totalSessions, 1)
        XCTAssertEqual(codex.totalUsageMicros, nil)
        XCTAssertEqual(disabledCursor.totalRequests, 1)
        XCTAssertEqual(disabledCursor.totalUsageMicros, nil)
    }

    func testDetailTotalUsageIsUnavailableWithoutCursorSpendSnapshot() throws {
        let database = DatabaseManager(inMemory: true)
        try database.replaceAppRecords(
            appType: AgentID.cursor.appType,
            records: [],
            state: SyncState(
                filePath: CursorUsageService.syncStateKey,
                byteOffset: 0,
                recordCount: 0,
                sessionId: "cursor-account:test",
                model: nil,
                lastModified: 0,
                lastSyncedAt: 0
            ),
        )

        XCTAssertNil(
            RequestDetailTotalUsageResolver.totalUsageMicros(
                database: database,
                provider: .cursor,
                range: .allTime,
                enabledAgents: Set(AgentID.allCases),
                accountIdentity: "cursor-account:test"
            )
        )
    }

    func testRequestListColumnsConsumeOnlyAvailableWidth() {
        let columns = RequestListColumns(totalWidth: 1_000)

        XCTAssertEqual(
            columns.date + columns.provider + columns.model + columns.tokens + columns.cost,
            1_000,
            accuracy: 0.001
        )
        XCTAssertEqual(columns.tokens, 140, accuracy: 0.001)
        XCTAssertEqual(columns.cost, 200, accuracy: 0.001)
    }

    func testRequestListReservesTrailingSpaceForOverlayScroller() {
        XCTAssertGreaterThan(RequestListLayout.scrollbarReservation, 0)
        XCTAssertEqual(
            RequestListLayout.horizontalInsets,
            RequestListLayout.contentInset * 2 + RequestListLayout.scrollbarReservation
        )
    }

    func testRequestListPaginationPrefetchesBeforeLastRow() {
        XCTAssertFalse(
            RequestListPagination.shouldPrefetch(appearingIndex: 79, itemCount: 100)
        )
        XCTAssertTrue(
            RequestListPagination.shouldPrefetch(appearingIndex: 80, itemCount: 100)
        )
        XCTAssertTrue(
            RequestListPagination.shouldPrefetch(appearingIndex: 99, itemCount: 100)
        )
        XCTAssertTrue(
            RequestListPagination.shouldPrefetch(appearingIndex: 0, itemCount: 10)
        )
        XCTAssertFalse(
            RequestListPagination.shouldPrefetch(appearingIndex: -1, itemCount: 100)
        )
        XCTAssertFalse(
            RequestListPagination.shouldPrefetch(appearingIndex: 100, itemCount: 100)
        )
    }
}
