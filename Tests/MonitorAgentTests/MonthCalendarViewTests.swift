import XCTest
@testable import MonitorAgent

final class MonthCalendarViewTests: XCTestCase {
    func testSharedMonthGridAlignsDatesToCalendarWeekdays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        calendar.firstWeekday = 1
        let month = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))
        )

        let cells = MonthCalendarLayout.cells(for: month, calendar: calendar)

        XCTAssertEqual(cells.prefix(3).compactMap(\.date).count, 0)
        XCTAssertEqual(cells.count, 42)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(cells[3].date)), 1)
        XCTAssertEqual(
            calendar.component(.day, from: try XCTUnwrap(cells.compactMap(\.date).last)),
            31
        )
    }

    func testSharedMonthGridUsesCompactDayGeometry() {
        XCTAssertEqual(MonthCalendarLayout.verticalSpacing, 8)
        XCTAssertEqual(MonthCalendarLayout.gridColumnSpacing, 0)
        XCTAssertEqual(MonthCalendarLayout.gridRowSpacing, 3)
        XCTAssertEqual(MonthCalendarLayout.dayHeight, 32)
        XCTAssertEqual(MonthCalendarLayout.dayCornerRadius, 6)
        XCTAssertEqual(MonthCalendarLayout.monthButtonSize, 28)
    }

    func testWeekdaySymbolsFollowCalendarFirstWeekday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2

        let symbols = MonthCalendarLayout.weekdaySymbols(calendar: calendar)

        XCTAssertEqual(symbols.first, "Mon")
        XCTAssertEqual(symbols.last, "Sun")
    }
}
