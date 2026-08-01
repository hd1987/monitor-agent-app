import XCTest
@testable import MonitorAgent

final class DatabaseManagerHourlyActivityTests: XCTestCase {
    func testFetchHourlyTokenUsageAggregatesSelectedDayAndFillsMissingHours() {
        let database = DatabaseManager(inMemory: true)
        let day = localDate(year: 2026, month: 6, day: 20)

        database.insertRecords([
            record(id: "claude-09-a", app: "claude", input: 100, output: 40, cacheRead: 20, cacheCreation: 7, createdAt: day, hour: 9),
            record(id: "claude-09-b", app: "claude", input: 30, output: 10, cacheRead: 5, cacheCreation: 3, createdAt: day, hour: 9),
            record(id: "codex-10-a", app: "codex", input: 80, output: 50, cacheRead: 15, createdAt: day, hour: 10),
            record(id: "claude-next-day", app: "claude", input: 999, output: 999, cacheRead: 999, createdAt: day, dayOffset: 1, hour: 9),
        ])

        let usage = database.fetchHourlyTokenUsage(app: .claude, date: "2026-06-20")

        XCTAssertEqual(usage.count, 24)
        XCTAssertEqual(usage[8], HourlyTokenUsage(hour: 8, requestCount: 0, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0))
        XCTAssertEqual(usage[9], HourlyTokenUsage(hour: 9, requestCount: 2, inputTokens: 130, outputTokens: 50, cacheReadTokens: 25, cacheCreationTokens: 10))
        XCTAssertEqual(usage[10], HourlyTokenUsage(hour: 10, requestCount: 0, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0))
    }

    func testQueriesExcludeCachedRecordsFromDisabledAgents() {
        let database = DatabaseManager(inMemory: true)
        let day = localDate(year: 2026, month: 6, day: 20)
        let olderDay = localDate(year: 2025, month: 6, day: 20)
        database.insertRecords([
            record(id: "claude", app: "claude", input: 10, output: 1, cacheRead: 0, createdAt: day, hour: 9),
            record(id: "codex", app: "codex", input: 20, output: 2, cacheRead: 0, createdAt: olderDay, hour: 10),
            record(id: "cursor", app: "cursor", input: 30, output: 3, cacheRead: 0, createdAt: day, hour: 11),
        ])

        let enabledAgents: Set<AgentID> = [.claude]
        let stats = database.fetchStats(
            app: .all,
            range: .allTime,
            enabledAgents: enabledAgents
        )
        let hourly = database.fetchHourlyTokenUsage(
            app: .all,
            date: "2026-06-20",
            enabledAgents: enabledAgents
        )

        XCTAssertEqual(stats.totalRequests, 1)
        XCTAssertEqual(stats.inputTokens, 10)
        XCTAssertEqual(hourly[9].requestCount, 1)
        XCTAssertEqual(hourly[11].requestCount, 0)
        XCTAssertEqual(database.availableYears(enabledAgents: enabledAgents), [2026])
        XCTAssertEqual(
            database.fetchStats(app: .all, range: .allTime, enabledAgents: []).totalRequests,
            0
        )
    }

    private func record(
        id: String,
        app: String,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheCreation: Int = 0,
        createdAt day: Date,
        dayOffset: Int = 0,
        hour: Int
    ) -> ParsedRecord {
        let calendar = Calendar.current
        let date = calendar.date(byAdding: DateComponents(day: dayOffset, hour: hour), to: day)!
        return ParsedRecord(
            requestId: id,
            appType: app,
            model: "test-model",
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreation,
            sessionId: "session-\(id)",
            createdAt: Int(date.timeIntervalSince1970)
        )
    }

    private func localDate(year: Int, month: Int, day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
