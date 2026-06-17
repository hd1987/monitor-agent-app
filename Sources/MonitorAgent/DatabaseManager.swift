import Foundation
import GRDB

final class DatabaseManager {
    static let shared = DatabaseManager()

    private var dbQueue: DatabaseQueue?

    private init() {
        let dir = NSHomeDirectory() + "/.monitor-agent"
        let path = dir + "/monitor.db"
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            dbQueue = try DatabaseQueue(path: path)
            try setupSchema()
        } catch {
            print("Failed to open db: \(error)")
        }
    }

    // MARK: - Schema

    private func setupSchema() throws {
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
                    last_modified INTEGER NOT NULL,
                    last_synced_at INTEGER NOT NULL
                );
                """)
        }
    }

    // MARK: - Write Methods

    func insertRecords(_ records: [ParsedRecord]) {
        guard let db = dbQueue, !records.isEmpty else { return }
        try? db.write { db in
            for r in records {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO request_logs
                        (request_id, app_type, model, input_tokens, output_tokens,
                         cache_read_tokens, cache_creation_tokens, session_id, created_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [r.requestId, r.appType, r.model,
                                r.inputTokens, r.outputTokens,
                                r.cacheReadTokens, r.cacheCreationTokens,
                                r.sessionId, r.createdAt]
                )
            }
        }
    }

    func getSyncState(for filePath: String) -> SyncState? {
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
                lastSyncedAt: row["last_synced_at"]
            )
        }
    }

    func updateSyncState(_ state: SyncState) {
        guard let db = dbQueue else { return }
        try? db.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO sync_state
                    (file_path, byte_offset, record_count, session_id, model, last_modified, last_synced_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [state.filePath, state.byteOffset, state.recordCount,
                            state.sessionId, state.model, state.lastModified, state.lastSyncedAt]
            )
        }
    }

    // MARK: - Query Helpers

    private func whereClause(app: AppFilter, range: TimeRange) -> (sql: String, args: [any DatabaseValueConvertible]) {
        var conditions: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if let dbValues = app.dbValues {
            let placeholders = dbValues.map { _ in "?" }.joined(separator: ", ")
            conditions.append("app_type IN (\(placeholders))")
            args.append(contentsOf: dbValues)
        }

        if let start = startTimestamp(for: range) {
            conditions.append("created_at >= ?")
            args.append(start)
        }

        let sql = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        return (sql, args)
    }

    private func startTimestamp(for range: TimeRange) -> Int? {
        let cal = Calendar.current
        let now = Date()
        switch range {
        case .today:
            return Int(cal.startOfDay(for: now).timeIntervalSince1970)
        case .last7:
            return Int(cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))!.timeIntervalSince1970)
        case .last30:
            return Int(cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: now))!.timeIntervalSince1970)
        case .allTime:
            return nil
        }
    }

    // MARK: - Queries

    func fetchStats(app: AppFilter, range: TimeRange) -> UsageStats {
        guard let db = dbQueue else { return UsageStats() }
        let w = whereClause(app: app, range: range)

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

    func fetchHeatmap(app: AppFilter, year: Int) -> [DayActivity] {
        guard let db = dbQueue else { return [] }

        let cal = Calendar.current
        let startDate = cal.date(from: DateComponents(year: year, month: 1, day: 1))!
        let endDate = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1))!
        let startTs = Int(startDate.timeIntervalSince1970)
        let endTs = Int(endDate.timeIntervalSince1970)

        var conditions = ["created_at >= ?", "created_at < ?"]
        var args: [any DatabaseValueConvertible] = [startTs, endTs]

        if let dbValues = app.dbValues {
            let placeholders = dbValues.map { _ in "?" }.joined(separator: ", ")
            conditions.append("app_type IN (\(placeholders))")
            args.append(contentsOf: dbValues)
        }

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

    func fetchModelDistribution(app: AppFilter, range: TimeRange) -> [ModelShare] {
        guard let db = dbQueue else { return [] }
        let w = whereClause(app: app, range: range)

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

    func availableYears() -> [Int] {
        guard let db = dbQueue else { return [] }
        return (try? db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT CAST(strftime('%Y', created_at, 'unixepoch', 'localtime') AS INTEGER) AS yr
                FROM request_logs ORDER BY yr DESC
                """)
            return rows.map { $0["yr"] as Int }
        }) ?? []
    }
}
