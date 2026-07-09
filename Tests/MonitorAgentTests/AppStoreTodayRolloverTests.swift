import XCTest
@testable import MonitorAgent

final class AppStoreTodayRolloverTests: XCTestCase {
    func testSelectActivityDateForTodayUsesDynamicTodayPreset() {
        let now = date(year: 2026, month: 7, day: 9, hour: 10)
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            autoStartSync: false,
            currentDateProvider: { now }
        )

        store.selectActivityDate("2026-07-09")

        XCTAssertEqual(store.timeRange, .today)
        XCTAssertEqual(store.selectedActivityDate, "2026-07-09")
    }

    func testReloadAfterDayRolloverResetsAnySelectionToToday() {
        var now = date(year: 2026, month: 7, day: 9, hour: 23)
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            autoStartSync: false,
            currentDateProvider: { now }
        )
        store.timeRange = .custom(
            start: date(year: 2026, month: 7, day: 8),
            end: date(year: 2026, month: 7, day: 8)
        )
        store.selectedActivityDate = "2026-07-08"
        store.hourlyTokenUsage = [
            HourlyTokenUsage(
                hour: 9,
                requestCount: 1,
                inputTokens: 10,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheCreationTokens: 0
            )
        ]

        now = date(year: 2026, month: 7, day: 10, hour: 0)
        let reset = expectation(description: "day rollover resets selection")
        store.reload()
        DispatchQueue.main.async {
            XCTAssertEqual(store.timeRange, .today)
            XCTAssertNil(store.selectedActivityDate)
            XCTAssertTrue(store.hourlyTokenUsage.isEmpty)
            reset.fulfill()
        }

        wait(for: [reset], timeout: 1)
    }

    private func date(year: Int, month: Int, day: Int, hour: Int = 0) -> Date {
        let calendar = Calendar.current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
}
