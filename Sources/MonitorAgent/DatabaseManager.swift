import Foundation
import GRDB

final class DatabaseManager {
    static let shared = DatabaseManager()

    private var dbQueue: DatabaseQueue?

    private init() {
        let path = NSHomeDirectory() + "/.cc-switch/cc-switch.db"
        do {
            var config = Configuration()
            config.readonly = true
            dbQueue = try DatabaseQueue(path: path, configuration: config)
        } catch {
            print("Failed to open db: \(error)")
        }
    }

    // MARK: - Helpers

    /// Build WHERE clause fragments for app filter and time range
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
                FROM proxy_request_logs \(w.sql)
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
                SELECT date(created_at, 'unixepoch') AS day, COUNT(*) AS cnt
                FROM proxy_request_logs \(whereSQL)
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
                SELECT model,
                    COUNT(*) AS reqs,
                    COALESCE(SUM(input_tokens), 0) AS input_tk,
                    COALESCE(SUM(output_tokens), 0) AS output_tk
                FROM proxy_request_logs \(w.sql)
                GROUP BY model ORDER BY reqs DESC
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

    /// Return the years that have data
    func availableYears() -> [Int] {
        guard let db = dbQueue else { return [] }
        return (try? db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT CAST(strftime('%Y', created_at, 'unixepoch') AS INTEGER) AS yr
                FROM proxy_request_logs ORDER BY yr DESC
                """)
            return rows.map { $0["yr"] as Int }
        }) ?? []
    }
}
