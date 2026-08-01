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

    func testFetchActivityRangeTokenUsageAggregatesByDayAndFillsMissingDays() {
        let database = DatabaseManager(inMemory: true)
        let start = localDate(year: 2026, month: 6, day: 1)
        let end = localDate(year: 2026, month: 6, day: 4)
        database.insertRecords([
            record(id: "first", app: "claude", input: 100, output: 10, cacheRead: 5, createdAt: start, hour: 9),
            record(id: "last", app: "claude", input: 300, output: 30, cacheRead: 15, createdAt: end, hour: 11),
        ])

        let series = database.fetchActivityRangeTokenUsage(
            app: .claude,
            range: .custom(start: start, end: end)
        )

        XCTAssertEqual(series.aggregation, .day)
        XCTAssertEqual(dateStrings(series.usage.map(\.periodStart)), ["2026-06-01", "2026-06-02", "2026-06-03", "2026-06-04"])
        XCTAssertEqual(series.usage.map(\.requestCount), [1, 0, 0, 1])
        XCTAssertEqual(series.usage.map(\.inputTokens), [100, 0, 0, 300])
    }

    func testFetchActivityRangeTokenUsageKeepsBoundedEmptyDaysVisible() {
        let database = DatabaseManager(inMemory: true)
        let start = localDate(year: 2026, month: 6, day: 1)
        let end = localDate(year: 2026, month: 6, day: 4)

        let series = database.fetchActivityRangeTokenUsage(
            app: .claude,
            range: .custom(start: start, end: end)
        )

        XCTAssertEqual(series.aggregation, .day)
        XCTAssertEqual(dateStrings(series.usage.map(\.periodStart)), ["2026-06-01", "2026-06-02", "2026-06-03", "2026-06-04"])
        XCTAssertTrue(series.usage.allSatisfy { $0.requestCount == 0 && $0.inputTokens == 0 })
    }

    func testFetchActivityRangeTokenUsageUsesContinuousHoursForThreeDays() {
        let database = DatabaseManager(inMemory: true)
        let start = localDate(year: 2026, month: 6, day: 1)
        let end = localDate(year: 2026, month: 6, day: 3)
        database.insertRecords([
            record(id: "first", app: "claude", input: 100, output: 10, cacheRead: 5, createdAt: start, hour: 9),
            record(id: "last", app: "claude", input: 300, output: 30, cacheRead: 15, createdAt: end, hour: 23),
        ])

        let series = database.fetchActivityRangeTokenUsage(
            app: .claude,
            range: .custom(start: start, end: end)
        )

        XCTAssertEqual(series.aggregation, .hour)
        XCTAssertEqual(series.usage.count, 72)
        XCTAssertEqual(series.usage[9].inputTokens, 100)
        XCTAssertEqual(series.usage[71].inputTokens, 300)
    }

    func testMultiDayHourlyUsageStopsAfterCurrentHour() {
        let database = DatabaseManager(inMemory: true)
        let start = localDate(year: 2026, month: 6, day: 1)
        let end = localDate(year: 2026, month: 6, day: 3)
        let now = Calendar.current.date(byAdding: DateComponents(day: 2, hour: 10, minute: 30), to: start)!

        let series = database.fetchActivityRangeTokenUsage(
            app: .claude,
            range: .custom(start: start, end: end),
            now: now
        )

        XCTAssertEqual(series.aggregation, .hour)
        XCTAssertEqual(series.usage.count, 59)
        XCTAssertEqual(Calendar.current.component(.hour, from: series.usage.last!.periodStart), 10)
    }

    func testActivityRangeQueryUsesInjectedNowForFilteringAndBuckets() {
        let database = DatabaseManager(inMemory: true)
        let calendar = Calendar.current
        let now = localDate(year: 2001, month: 6, day: 20)
        let rangeStart = calendar.date(byAdding: .day, value: -6, to: now)!
        database.insertRecords([
            record(id: "first", app: "claude", input: 100, output: 10, cacheRead: 5, createdAt: rangeStart, hour: 9),
        ])

        let series = database.fetchActivityRangeTokenUsage(
            app: .claude,
            range: .last7,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(series.aggregation, .day)
        XCTAssertEqual(series.usage.count, 7)
        XCTAssertEqual(series.usage.first?.requestCount, 1)
        XCTAssertEqual(series.usage.first?.inputTokens, 100)
    }

    func testFetchActivityRangeTokenUsageChoosesWeekAndMonthForLongRanges() {
        let database = DatabaseManager(inMemory: true)
        let first = localDate(year: 2024, month: 1, day: 1)
        let last = localDate(year: 2026, month: 2, day: 1)
        database.insertRecords([
            record(id: "first", app: "claude", input: 100, output: 10, cacheRead: 5, createdAt: first, hour: 9),
            record(id: "last", app: "claude", input: 300, output: 30, cacheRead: 15, createdAt: last, hour: 11),
        ])

        let weekly = database.fetchActivityRangeTokenUsage(
            app: .claude,
            range: .custom(
                start: first,
                end: Calendar.current.date(byAdding: .day, value: 120, to: first)!
            )
        )
        let monthly = database.fetchActivityRangeTokenUsage(app: .claude, range: .allTime)

        XCTAssertEqual(weekly.aggregation, .week)
        XCTAssertFalse(weekly.usage.isEmpty)
        XCTAssertEqual(monthly.aggregation, .month)
        XCTAssertEqual(monthly.usage.first.map { dateStrings([$0.periodStart])[0] }, "2024-01-01")
        XCTAssertEqual(monthly.usage.last.map { dateStrings([$0.periodStart])[0] }, "2026-02-01")
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

    private func dateStrings(_ dates: [Date]) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return dates.map(formatter.string(from:))
    }
}
