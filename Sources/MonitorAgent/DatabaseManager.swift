import Foundation
import GRDB

enum DatabaseManagerError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "The local usage database is unavailable."
    }
}

final class DatabaseManager {
    static let shared = openOrUnavailable(path: defaultDatabasePath)
    static let defaultDirectory = DatabasePaths.current.directory
    static let defaultDatabasePath = DatabasePaths.current.database
    static let rebuildDatabasePath = DatabasePaths.current.rebuildDatabase

    private var dbQueue: DatabaseQueue?
    private let databasePath: String?
    private let lifecycleLock = NSRecursiveLock()

    var isAvailable: Bool {
        withLifecycleLock { dbQueue != nil }
    }
    var hasExistingDatabaseFile: Bool {
        withLifecycleLock {
            databasePath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        }
    }

    init(inMemory: Bool) {
        databasePath = nil
        do {
            if inMemory {
                dbQueue = try DatabaseQueue()
            } else {
                try FileManager.default.createDirectory(atPath: Self.defaultDirectory, withIntermediateDirectories: true)
                dbQueue = try DatabaseQueue(path: Self.defaultDatabasePath)
            }
            try setupSchema()
        } catch {
            print("Failed to open db: \(error)")
        }
    }

    init(path: String) throws {
        databasePath = path
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        dbQueue = try DatabaseQueue(path: path)
        try setupSchema()
    }

    private init(unavailablePath: String) {
        databasePath = unavailablePath
        dbQueue = nil
    }

    static func openOrUnavailable(
        path: String,
        logError: (String) -> Void = { print($0) }
    ) -> DatabaseManager {
        do {
            return try DatabaseManager(path: path)
        } catch {
            logError("Failed to open database at \(path): \(error)")
            return DatabaseManager(unavailablePath: path)
        }
    }

    // MARK: - Schema

    private func withLifecycleLock<T>(_ operation: () throws -> T) rethrows -> T {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return try operation()
    }

    private func setupSchema() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        try dbQueue?.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS request_logs (
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
                CREATE INDEX IF NOT EXISTS idx_logs_app_created ON request_logs(app_type, created_at DESC);
                CREATE INDEX IF NOT EXISTS idx_logs_session ON request_logs(session_id);
                CREATE INDEX IF NOT EXISTS idx_logs_model ON request_logs(model);

                CREATE TABLE IF NOT EXISTS sync_state (
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

                CREATE TABLE IF NOT EXISTS cursor_spend_snapshots (
                    account_identity TEXT NOT NULL,
                    range_key TEXT NOT NULL,
                    range_start_ms INTEGER,
                    range_end_ms INTEGER,
                    total_cents INTEGER,
                    on_demand_cents INTEGER,
                    total_updated_at INTEGER,
                    on_demand_updated_at INTEGER,
                    last_accessed_at INTEGER NOT NULL,
                    PRIMARY KEY (account_identity, range_key)
                );
                """)
            try addColumnIfMissing(
                db,
                table: "sync_state",
                column: "last_total_input_tokens",
                definition: "INTEGER NOT NULL DEFAULT 0"
            )
            try addColumnIfMissing(
                db,
                table: "sync_state",
                column: "last_total_output_tokens",
                definition: "INTEGER NOT NULL DEFAULT 0"
            )
        }
    }

    private func addColumnIfMissing(_ db: Database, table: String, column: String, definition: String) throws {
        let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { $0["name"] as String }
        guard !columns.contains(column) else { return }
        try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }

    func integrityCheck() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let db = dbQueue else { return false }
        return (try? db.read { db in
            let row = try Row.fetchOne(db, sql: "PRAGMA integrity_check")
            return (row?[0] as String?) == "ok"
        }) ?? false
    }

    func close() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        dbQueue = nil
    }

    func reopen() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let path = databasePath else {
            dbQueue = try DatabaseQueue()
            try setupSchema()
            return
        }

        dbQueue = try DatabaseQueue(path: path)
        try setupSchema()
    }

    func replaceDatabase(with temporaryPath: String) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let destinationPath = databasePath else { return }
        let fm = FileManager.default

        guard fm.fileExists(atPath: temporaryPath) else {
            throw CocoaError(.fileNoSuchFile)
        }

        close()
        do {
            try removeDatabaseSidecars(at: destinationPath)
            if fm.fileExists(atPath: destinationPath) {
                _ = try fm.replaceItemAt(
                    URL(fileURLWithPath: destinationPath),
                    withItemAt: URL(fileURLWithPath: temporaryPath),
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fm.moveItem(atPath: temporaryPath, toPath: destinationPath)
            }
            try removeDatabaseSidecars(at: temporaryPath)
            try reopen()
        } catch {
            try? reopen()
            throw error
        }
    }

    static func cleanUpTemporaryRebuildDatabase() {
        try? removeDatabaseFiles(at: rebuildDatabasePath)
    }

    private static func removeDatabaseFiles(at path: String) throws {
        let fm = FileManager.default
        for candidate in [path, "\(path)-shm", "\(path)-wal"] where fm.fileExists(atPath: candidate) {
            try fm.removeItem(atPath: candidate)
        }
    }

    private static func removeDatabaseSidecars(at path: String) throws {
        let fm = FileManager.default
        for candidate in ["\(path)-shm", "\(path)-wal"] where fm.fileExists(atPath: candidate) {
            try fm.removeItem(atPath: candidate)
        }
    }

    private func removeDatabaseFiles(at path: String) throws {
        try Self.removeDatabaseFiles(at: path)
    }

    private func removeDatabaseSidecars(at path: String) throws {
        try Self.removeDatabaseSidecars(at: path)
    }

    // MARK: - Write Methods

    func commitSync(records: [ParsedRecord], state: SyncState) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let db = dbQueue else { throw DatabaseManagerError.unavailable }
        try db.write { db in
            try insertRecords(records, in: db)
            try upsertSyncState(state, in: db)
        }
    }

    func replaceAppRecords(
        appType: String,
        records: [ParsedRecord],
        state: SyncState
    ) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let db = dbQueue else { throw DatabaseManagerError.unavailable }
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM request_logs WHERE app_type = ?",
                arguments: [appType]
            )
            if appType == AgentID.cursor.appType {
                if let accountIdentity = state.sessionId {
                    try db.execute(
                        sql: "DELETE FROM cursor_spend_snapshots WHERE account_identity <> ?",
                        arguments: [accountIdentity]
                    )
                } else {
                    try db.execute(sql: "DELETE FROM cursor_spend_snapshots")
                }
            }
            try insertRecords(records, in: db)
            try upsertSyncState(state, in: db)
        }
    }

    func fetchCursorSpendSnapshot(range: CursorSpendRange) -> CursorSpendSnapshot? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let db = dbQueue else { return nil }
        return try? db.write { db in
            guard let accountIdentity = try String.fetchOne(
                db,
                sql: "SELECT session_id FROM sync_state WHERE file_path = ? LIMIT 1",
                arguments: [CursorUsageService.syncStateKey]
            ) else {
                return nil
            }
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT total_cents, on_demand_cents,
                           total_updated_at, on_demand_updated_at
                    FROM cursor_spend_snapshots
                    WHERE account_identity = ?
                      AND range_key = ?
                      AND range_start_ms IS ?
                      AND range_end_ms IS ?
                    LIMIT 1
                    """,
                arguments: [
                    accountIdentity,
                    range.key,
                    range.startMilliseconds,
                    range.endMilliseconds,
                ]
            ) else {
                return nil
            }
            let accessedAt = Int(Date().timeIntervalSince1970)
            try db.execute(
                sql: """
                    UPDATE cursor_spend_snapshots
                    SET last_accessed_at = ?
                    WHERE account_identity = ? AND range_key = ?
                    """,
                arguments: [accessedAt, accountIdentity, range.key]
            )
            return cursorSpendSnapshot(
                row: row,
                accountIdentity: accountIdentity,
                range: range
            )
        }
    }

    @discardableResult
    func mergeCursorSpendSnapshot(
        accountIdentity: String,
        range: CursorSpendRange,
        totalCents: Int?,
        onDemandCents: Int?,
        updatedAt: Date
    ) throws -> CursorSpendSnapshot? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let db = dbQueue else { throw DatabaseManagerError.unavailable }
        guard totalCents != nil || onDemandCents != nil else {
            return fetchCursorSpendSnapshot(range: range)
        }
        let timestamp = Int(updatedAt.timeIntervalSince1970)
        return try db.write { db in
            let currentIdentity = try String.fetchOne(
                db,
                sql: "SELECT session_id FROM sync_state WHERE file_path = ? LIMIT 1",
                arguments: [CursorUsageService.syncStateKey]
            )
            guard currentIdentity == accountIdentity else { return nil }

            try db.execute(
                sql: """
                    INSERT INTO cursor_spend_snapshots (
                        account_identity, range_key, range_start_ms, range_end_ms,
                        total_cents, on_demand_cents,
                        total_updated_at, on_demand_updated_at, last_accessed_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_identity, range_key) DO UPDATE SET
                        range_start_ms = excluded.range_start_ms,
                        range_end_ms = excluded.range_end_ms,
                        total_cents = CASE
                            WHEN cursor_spend_snapshots.range_start_ms IS excluded.range_start_ms
                             AND cursor_spend_snapshots.range_end_ms IS excluded.range_end_ms
                            THEN COALESCE(excluded.total_cents, cursor_spend_snapshots.total_cents)
                            ELSE excluded.total_cents
                        END,
                        on_demand_cents = CASE
                            WHEN cursor_spend_snapshots.range_start_ms IS excluded.range_start_ms
                             AND cursor_spend_snapshots.range_end_ms IS excluded.range_end_ms
                            THEN COALESCE(excluded.on_demand_cents, cursor_spend_snapshots.on_demand_cents)
                            ELSE excluded.on_demand_cents
                        END,
                        total_updated_at = CASE
                            WHEN cursor_spend_snapshots.range_start_ms IS excluded.range_start_ms
                             AND cursor_spend_snapshots.range_end_ms IS excluded.range_end_ms
                            THEN COALESCE(excluded.total_updated_at, cursor_spend_snapshots.total_updated_at)
                            ELSE excluded.total_updated_at
                        END,
                        on_demand_updated_at = CASE
                            WHEN cursor_spend_snapshots.range_start_ms IS excluded.range_start_ms
                             AND cursor_spend_snapshots.range_end_ms IS excluded.range_end_ms
                            THEN COALESCE(excluded.on_demand_updated_at, cursor_spend_snapshots.on_demand_updated_at)
                            ELSE excluded.on_demand_updated_at
                        END,
                        last_accessed_at = excluded.last_accessed_at
                    """,
                arguments: [
                    accountIdentity,
                    range.key,
                    range.startMilliseconds,
                    range.endMilliseconds,
                    totalCents,
                    onDemandCents,
                    totalCents == nil ? nil : timestamp,
                    onDemandCents == nil ? nil : timestamp,
                    timestamp,
                ]
            )
            try db.execute(
                sql: """
                    DELETE FROM cursor_spend_snapshots
                    WHERE account_identity = ?
                      AND range_key IN (
                          SELECT range_key FROM cursor_spend_snapshots
                          WHERE account_identity = ?
                          ORDER BY last_accessed_at DESC, range_key DESC
                          LIMIT -1 OFFSET 32
                      )
                    """,
                arguments: [accountIdentity, accountIdentity]
            )
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT total_cents, on_demand_cents,
                           total_updated_at, on_demand_updated_at
                    FROM cursor_spend_snapshots
                    WHERE account_identity = ? AND range_key = ?
                    LIMIT 1
                    """,
                arguments: [accountIdentity, range.key]
            ) else {
                return nil
            }
            return cursorSpendSnapshot(
                row: row,
                accountIdentity: accountIdentity,
                range: range
            )
        }
    }

    func fetchCursorSpendSnapshots(accountIdentity: String) -> [CursorSpendSnapshot] {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let db = dbQueue else { return [] }
        return (try? db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT range_key, range_start_ms, range_end_ms,
                           total_cents, on_demand_cents,
                           total_updated_at, on_demand_updated_at
                    FROM cursor_spend_snapshots
                    WHERE account_identity = ?
                    ORDER BY last_accessed_at DESC
                    """,
                arguments: [accountIdentity]
            )
            return rows.map { row in
                let range = CursorSpendRange(
                    key: row["range_key"],
                    startMilliseconds: row["range_start_ms"],
                    endMilliseconds: row["range_end_ms"]
                )
                return cursorSpendSnapshot(
                    row: row,
                    accountIdentity: accountIdentity,
                    range: range
                )
            }
        }) ?? []
    }

    func restoreCursorSpendSnapshots(_ snapshots: [CursorSpendSnapshot]) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let db = dbQueue else { throw DatabaseManagerError.unavailable }
        guard !snapshots.isEmpty else { return }
        try db.write { db in
            for snapshot in snapshots {
                let currentIdentity = try String.fetchOne(
                    db,
                    sql: "SELECT session_id FROM sync_state WHERE file_path = ? LIMIT 1",
                    arguments: [CursorUsageService.syncStateKey]
                )
                guard currentIdentity == snapshot.accountIdentity else { continue }
                let totalUpdatedAt = snapshot.totalUpdatedAt.map {
                    Int($0.timeIntervalSince1970)
                }
                let onDemandUpdatedAt = snapshot.onDemandUpdatedAt.map {
                    Int($0.timeIntervalSince1970)
                }
                let lastAccessedAt = max(totalUpdatedAt ?? 0, onDemandUpdatedAt ?? 0)
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO cursor_spend_snapshots (
                            account_identity, range_key, range_start_ms, range_end_ms,
                            total_cents, on_demand_cents,
                            total_updated_at, on_demand_updated_at, last_accessed_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        snapshot.accountIdentity,
                        snapshot.range.key,
                        snapshot.range.startMilliseconds,
                        snapshot.range.endMilliseconds,
                        snapshot.totalCents,
                        snapshot.onDemandCents,
                        totalUpdatedAt,
                        onDemandUpdatedAt,
                        lastAccessedAt,
                    ]
                )
            }
        }
    }

    func insertRecords(_ records: [ParsedRecord]) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let db = dbQueue, !records.isEmpty else { return }
        try? db.write { db in
            try insertRecords(records, in: db)
        }
    }

    func insertRecordsThrowing(_ records: [ParsedRecord]) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let db = dbQueue else { throw DatabaseManagerError.unavailable }
        guard !records.isEmpty else { return }
        try db.write { db in
            try insertRecords(records, in: db)
        }
    }

    private func insertRecords(_ records: [ParsedRecord], in db: Database) throws {
        for record in records {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO request_logs
                    (request_id, app_type, model, input_tokens, output_tokens,
                     cache_read_tokens, cache_creation_tokens, session_id, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [record.requestId, record.appType, record.model,
                            record.inputTokens, record.outputTokens,
                            record.cacheReadTokens, record.cacheCreationTokens,
                            record.sessionId, record.createdAt]
            )
        }
    }

    private func cursorSpendSnapshot(
        row: Row,
        accountIdentity: String,
        range: CursorSpendRange
    ) -> CursorSpendSnapshot {
        let storedTotalCents: Int? = row["total_cents"]
        let totalCents: Int? = storedTotalCents.flatMap { $0 >= 0 ? $0 : nil }
        let storedOnDemandCents: Int? = row["on_demand_cents"]
        let onDemandCents: Int? = storedOnDemandCents.flatMap { value in
            guard value >= 0,
                  totalCents.map({ value <= $0 }) != false else {
                return nil
            }
            return value
        }
        let storedTotalUpdatedAt: Int? = row["total_updated_at"]
        let storedOnDemandUpdatedAt: Int? = row["on_demand_updated_at"]
        return CursorSpendSnapshot(
            accountIdentity: accountIdentity,
            range: range,
            totalCents: totalCents,
            onDemandCents: onDemandCents,
            totalUpdatedAt: totalCents == nil ? nil : storedTotalUpdatedAt.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            },
            onDemandUpdatedAt: onDemandCents == nil ? nil : storedOnDemandUpdatedAt.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            }
        )
    }

    func getSyncState(for filePath: String) -> SyncState? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let db = dbQueue else { return nil }
        return try? db.read { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT * FROM sync_state WHERE file_path = ?",
                arguments: [filePath]
            ) else { return nil }
            return SyncState(
                filePath: row["file_path"],
                byteOffset: row["byte_offset"],
                recordCount: row["record_count"],
                sessionId: row["session_id"],
                model: row["model"],
                lastModified: row["last_modified"],
                lastSyncedAt: row["last_synced_at"],
                lastTotalInputTokens: row["last_total_input_tokens"],
                lastTotalOutputTokens: row["last_total_output_tokens"]
            )
        }
    }

    func updateSyncState(_ state: SyncState) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let db = dbQueue else { return }
        try? db.write { db in
            try upsertSyncState(state, in: db)
        }
    }

    private func upsertSyncState(_ state: SyncState, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT OR REPLACE INTO sync_state
                (file_path, byte_offset, record_count, session_id, model,
                 last_modified, last_synced_at, last_total_input_tokens, last_total_output_tokens)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                state.filePath,
                state.byteOffset,
                state.recordCount,
                state.sessionId,
                state.model,
                state.lastModified,
                state.lastSyncedAt,
                state.lastTotalInputTokens,
                state.lastTotalOutputTokens,
            ]
        )
    }

    // MARK: - Query Helpers

    private func appValues(
        for app: AppFilter,
        enabledAgents: Set<AgentID>
    ) -> [String] {
        switch app {
        case .all:
            return AgentID.allCases
                .filter(enabledAgents.contains)
                .map(\.appType)
        case .claude:
            return enabledAgents.contains(.claude) ? [AgentID.claude.appType] : []
        case .codex:
            return enabledAgents.contains(.codex) ? [AgentID.codex.appType] : []
        case .cursor:
            return enabledAgents.contains(.cursor) ? [AgentID.cursor.appType] : []
        }
    }

    private func appendAppCondition(
        app: AppFilter,
        enabledAgents: Set<AgentID>,
        conditions: inout [String],
        args: inout [any DatabaseValueConvertible]
    ) {
        let values = appValues(for: app, enabledAgents: enabledAgents)
        guard !values.isEmpty else {
            conditions.append("0")
            return
        }
        let placeholders = values.map { _ in "?" }.joined(separator: ", ")
        conditions.append("app_type IN (\(placeholders))")
        args.append(contentsOf: values)
    }

    private func whereClause(
        app: AppFilter,
        range: TimeRange,
        enabledAgents: Set<AgentID>,
        bounds: TimeBounds? = nil
    ) -> (sql: String, args: [any DatabaseValueConvertible]) {
        var conditions: [String] = []
        var args: [any DatabaseValueConvertible] = []

        appendAppCondition(
            app: app,
            enabledAgents: enabledAgents,
            conditions: &conditions,
            args: &args
        )

        let resolvedBounds = bounds ?? range.bounds()
        if let start = resolvedBounds.start {
            conditions.append("created_at >= ?")
            args.append(start)
        }
        if let end = resolvedBounds.end {
            conditions.append("created_at < ?")
            args.append(end)
        }

        let sql = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        return (sql, args)
    }

    // MARK: - Queries

    func fetchStats(
        app: AppFilter,
        range: TimeRange,
        enabledAgents: Set<AgentID> = Set(AgentID.allCases)
    ) -> UsageStats {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let db = dbQueue else { return UsageStats() }
        let w = whereClause(app: app, range: range, enabledAgents: enabledAgents)

        return (try? db.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT
                    COUNT(*) AS total_requests,
                    COUNT(DISTINCT session_id) AS total_sessions,
                    COALESCE(SUM(input_tokens), 0) AS input_tokens,
                    COALESCE(SUM(output_tokens), 0) AS output_tokens,
                    COALESCE(SUM(cache_read_tokens), 0) AS cache_read_tokens,
                    COALESCE(SUM(cache_creation_tokens), 0) AS cache_creation_tokens
                FROM request_logs \(w.sql)
                """, arguments: StatementArguments(w.args))

            guard let r = row else { return UsageStats() }
            return UsageStats(
                totalRequests: r["total_requests"],
                totalSessions: r["total_sessions"],
                inputTokens: r["input_tokens"],
                outputTokens: r["output_tokens"],
                cacheReadTokens: r["cache_read_tokens"],
                cacheCreationTokens: r["cache_creation_tokens"]
            )
        }) ?? UsageStats()
    }

    /// Fetch heatmap data for a given date range
    func fetchHeatmap(
        app: AppFilter,
        from startDate: Date,
        to endDate: Date,
        enabledAgents: Set<AgentID> = Set(AgentID.allCases)
    ) -> [DayActivity] {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let db = dbQueue else { return [] }

        let startTs = Int(startDate.timeIntervalSince1970)
        let endTs = Int(endDate.timeIntervalSince1970)

        var conditions = ["created_at >= ?", "created_at < ?"]
        var args: [any DatabaseValueConvertible] = [startTs, endTs]

        appendAppCondition(
            app: app,
            enabledAgents: enabledAgents,
            conditions: &conditions,
            args: &args
        )

        let whereSQL = "WHERE " + conditions.joined(separator: " AND ")

        return (try? db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT date(created_at, 'unixepoch', 'localtime') AS day, COUNT(*) AS cnt
                FROM request_logs \(whereSQL)
                GROUP BY day ORDER BY day
                """, arguments: StatementArguments(args))
            return rows.map { DayActivity(date: $0["day"], count: $0["cnt"]) }
        }) ?? []
    }

    func fetchHourlyTokenUsage(
        app: AppFilter,
        date: String,
        enabledAgents: Set<AgentID> = Set(AgentID.allCases)
    ) -> [HourlyTokenUsage] {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let db = dbQueue else { return [] }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        guard
            let startDate = formatter.date(from: date),
            let endDate = Calendar.current.date(byAdding: .day, value: 1, to: startDate)
        else {
            return []
        }

        var conditions = ["created_at >= ?", "created_at < ?"]
        var args: [any DatabaseValueConvertible] = [
            Int(startDate.timeIntervalSince1970),
            Int(endDate.timeIntervalSince1970),
        ]

        appendAppCondition(
            app: app,
            enabledAgents: enabledAgents,
            conditions: &conditions,
            args: &args
        )

        let whereSQL = "WHERE " + conditions.joined(separator: " AND ")
        var values = (0..<24).map {
            HourlyTokenUsage(hour: $0, requestCount: 0, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)
        }

        guard let rows = try? db.read({ db in
            try Row.fetchAll(db, sql: """
                SELECT
                    CAST(strftime('%H', created_at, 'unixepoch', 'localtime') AS INTEGER) AS hour,
                    COUNT(*) AS request_count,
                    COALESCE(SUM(input_tokens), 0) AS input_tk,
                    COALESCE(SUM(output_tokens), 0) AS output_tk,
                    COALESCE(SUM(cache_read_tokens), 0) AS cache_read_tk,
                    COALESCE(SUM(cache_creation_tokens), 0) AS cache_creation_tk
                FROM request_logs \(whereSQL)
                GROUP BY hour ORDER BY hour
                """, arguments: StatementArguments(args))
        }) else {
            return values
        }

        for row in rows {
            let hour: Int = row["hour"]
            guard values.indices.contains(hour) else { continue }
            values[hour] = HourlyTokenUsage(
                hour: hour,
                requestCount: row["request_count"],
                inputTokens: row["input_tk"],
                outputTokens: row["output_tk"],
                cacheReadTokens: row["cache_read_tk"],
                cacheCreationTokens: row["cache_creation_tk"]
            )
        }

        return values
    }

    func fetchActivityRangeTokenUsage(
        app: AppFilter,
        range: TimeRange,
        enabledAgents: Set<AgentID> = Set(AgentID.allCases),
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ActivityRangeTokenSeries {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let db = dbQueue else { return .empty }

        let bounds = range.bounds(now: now, calendar: calendar)
        let w = whereClause(
            app: app,
            range: range,
            enabledAgents: enabledAgents,
            bounds: bounds
        )

        return (try? db.read { db in
            let limits = try Row.fetchOne(db, sql: """
                SELECT MIN(created_at) AS first_at, MAX(created_at) AS last_at
                FROM request_logs \(w.sql)
                """, arguments: StatementArguments(w.args))
            let firstTimestamp: Int? = limits?["first_at"]
            let lastTimestamp: Int? = limits?["last_at"]

            guard let startDate = bounds.start.map({ Date(timeIntervalSince1970: TimeInterval($0)) })
                ?? firstTimestamp.map({ calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0))) }),
                let exclusiveEnd = bounds.end.map({ Date(timeIntervalSince1970: TimeInterval($0)) })
                    ?? lastTimestamp.flatMap({ timestamp in
                        calendar.date(
                            byAdding: .day,
                            value: 1,
                            to: calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(timestamp)))
                        )
                    }) else {
                return .empty
            }
            let dayCount = max(1, calendar.dateComponents([.day], from: startDate, to: exclusiveEnd).day ?? 1)
            let aggregation = ActivityTokenAggregation.forDayCount(dayCount)

            let localDate = "datetime(created_at, 'unixepoch', 'localtime')"
            let periodExpression: String
            switch aggregation {
            case .hour:
                let startTimestamp = Int(startDate.timeIntervalSince1970)
                periodExpression = "\(startTimestamp) + CAST((created_at - \(startTimestamp)) / 3600 AS INTEGER) * 3600"
            case .day:
                periodExpression = "date(\(localDate))"
            case .week:
                periodExpression = "date(\(localDate), '-' || ((CAST(strftime('%w', \(localDate)) AS INTEGER) + 6) % 7) || ' days')"
            case .month:
                periodExpression = "strftime('%Y-%m-01', \(localDate))"
            }

            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    \(periodExpression) AS period_start,
                    COUNT(*) AS request_count,
                    COALESCE(SUM(input_tokens), 0) AS input_tk,
                    COALESCE(SUM(output_tokens), 0) AS output_tk,
                    COALESCE(SUM(cache_read_tokens), 0) AS cache_read_tk,
                    COALESCE(SUM(cache_creation_tokens), 0) AS cache_creation_tk
                FROM request_logs \(w.sql)
                GROUP BY period_start ORDER BY period_start
                """, arguments: StatementArguments(w.args))

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            let populated = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (Date, ActivityRangeTokenUsage)? in
                let periodStart: Date?
                switch aggregation {
                case .hour:
                    let timestamp: Int = row["period_start"]
                    periodStart = Date(timeIntervalSince1970: TimeInterval(timestamp))
                case .day, .week, .month:
                    let value: String = row["period_start"]
                    periodStart = formatter.date(from: value)
                }
                guard let periodStart else { return nil }
                let usage = ActivityRangeTokenUsage(
                    periodStart: periodStart,
                    requestCount: row["request_count"],
                    inputTokens: row["input_tk"],
                    outputTokens: row["output_tk"],
                    cacheReadTokens: row["cache_read_tk"],
                    cacheCreationTokens: row["cache_creation_tk"]
                )
                return (usage.periodStart, usage)
            })

            var cursor = alignedActivityPeriodStart(startDate, aggregation: aggregation, calendar: calendar)
            let displayExclusiveEnd: Date
            if aggregation == .hour, startDate <= now, now < exclusiveEnd {
                let currentHour = alignedActivityPeriodStart(now, aggregation: .hour, calendar: calendar)
                displayExclusiveEnd = min(
                    exclusiveEnd,
                    nextActivityPeriodStart(currentHour, aggregation: .hour, calendar: calendar)
                )
            } else {
                displayExclusiveEnd = exclusiveEnd
            }
            var usage: [ActivityRangeTokenUsage] = []
            while cursor < displayExclusiveEnd {
                usage.append(populated[cursor] ?? ActivityRangeTokenUsage(
                    periodStart: cursor,
                    requestCount: 0,
                    inputTokens: 0,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheCreationTokens: 0
                ))
                cursor = nextActivityPeriodStart(cursor, aggregation: aggregation, calendar: calendar)
            }

            return ActivityRangeTokenSeries(aggregation: aggregation, usage: usage)
        }) ?? .empty
    }

    private func alignedActivityPeriodStart(
        _ date: Date,
        aggregation: ActivityTokenAggregation,
        calendar: Calendar
    ) -> Date {
        let day = calendar.startOfDay(for: date)
        switch aggregation {
        case .hour:
            let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            return calendar.date(from: components)!
        case .day:
            return day
        case .week:
            let weekday = calendar.component(.weekday, from: day)
            return calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: day)!
        case .month:
            let components = calendar.dateComponents([.year, .month], from: day)
            return calendar.date(from: components)!
        }
    }

    private func nextActivityPeriodStart(
        _ date: Date,
        aggregation: ActivityTokenAggregation,
        calendar: Calendar
    ) -> Date {
        switch aggregation {
        case .hour:
            return calendar.date(byAdding: .hour, value: 1, to: date)!
        case .day:
            return calendar.date(byAdding: .day, value: 1, to: date)!
        case .week:
            return calendar.date(byAdding: .day, value: 7, to: date)!
        case .month:
            return calendar.date(byAdding: .month, value: 1, to: date)!
        }
    }

    func fetchModelDistribution(
        app: AppFilter,
        range: TimeRange,
        enabledAgents: Set<AgentID> = Set(AgentID.allCases)
    ) -> [ModelShare] {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let db = dbQueue else { return [] }
        let w = whereClause(app: app, range: range, enabledAgents: enabledAgents)

        return (try? db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    CASE model
                        WHEN 'anthropic.claude-4-6-opus' THEN 'claude-opus-4-6'
                        WHEN 'anthropic.claude-4-5-haiku' THEN 'claude-haiku-4-5-20251001'
                        ELSE model
                    END AS model,
                    COUNT(*) AS reqs,
                    COALESCE(SUM(input_tokens), 0) AS input_tk,
                    COALESCE(SUM(output_tokens), 0) AS output_tk
                FROM request_logs \(w.sql)
                GROUP BY 1 ORDER BY reqs DESC
                """, arguments: StatementArguments(w.args))
            return rows.map {
                ModelShare(
                    model: $0["model"],
                    requests: $0["reqs"],
                    inputTokens: $0["input_tk"],
                    outputTokens: $0["output_tk"]
                )
            }
        }) ?? []
    }

    func availableYears(
        enabledAgents: Set<AgentID> = Set(AgentID.allCases)
    ) -> [Int] {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let db = dbQueue else { return [] }
        let values = AgentID.allCases
            .filter(enabledAgents.contains)
            .map(\.appType)
        guard !values.isEmpty else { return [] }
        let placeholders = values.map { _ in "?" }.joined(separator: ", ")
        return (try? db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT CAST(strftime('%Y', created_at, 'unixepoch', 'localtime') AS INTEGER) AS yr
                FROM request_logs
                WHERE app_type IN (\(placeholders))
                ORDER BY yr DESC
                """, arguments: StatementArguments(values))
            return rows.map { $0["yr"] as Int }
        }) ?? []
    }
}
