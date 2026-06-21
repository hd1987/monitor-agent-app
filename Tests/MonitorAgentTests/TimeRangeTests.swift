import XCTest
@testable import MonitorAgent

final class TimeRangeTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testTodayUsesStartOfTodayAndStartOfTomorrow() {
        let now = date(year: 2026, month: 6, day: 20, hour: 15)

        let bounds = TimeRange.today.bounds(now: now, calendar: calendar)

        XCTAssertEqual(bounds.start, unixSeconds(year: 2026, month: 6, day: 20))
        XCTAssertEqual(bounds.end, unixSeconds(year: 2026, month: 6, day: 21))
    }

    func testLast7DaysIncludesTodayAndPreviousSixDays() {
        let now = date(year: 2026, month: 6, day: 20, hour: 15)

        let bounds = TimeRange.last7.bounds(now: now, calendar: calendar)

        XCTAssertEqual(bounds.start, unixSeconds(year: 2026, month: 6, day: 14))
        XCTAssertEqual(bounds.end, unixSeconds(year: 2026, month: 6, day: 21))
    }

    func testAllTimeHasNoBounds() {
        let now = date(year: 2026, month: 6, day: 20, hour: 15)

        let bounds = TimeRange.allTime.bounds(now: now, calendar: calendar)

        XCTAssertNil(bounds.start)
        XCTAssertNil(bounds.end)
    }

    func testCustomRangeIncludesEntireEndDate() {
        let start = date(year: 2026, month: 6, day: 1, hour: 13)
        let end = date(year: 2026, month: 6, day: 3, hour: 9)

        let bounds = TimeRange.custom(start: start, end: end).bounds(now: end, calendar: calendar)

        XCTAssertEqual(bounds.start, unixSeconds(year: 2026, month: 6, day: 1))
        XCTAssertEqual(bounds.end, unixSeconds(year: 2026, month: 6, day: 4))
    }

    func testCustomSingleDayDisplayTitleShowsOneDate() {
        let day = date(year: 2026, month: 6, day: 20)

        let title = TimeRange.custom(start: day, end: day).displayTitle(formatter: displayFormatter, calendar: calendar)

        XCTAssertEqual(title, "Jun 20")
    }

    func testSingleDayActivityRangeParsesDateString() {
        let range = TimeRange.activityDay("2026-06-20", calendar: calendar)

        XCTAssertEqual(range, .custom(
            start: date(year: 2026, month: 6, day: 20),
            end: date(year: 2026, month: 6, day: 20)
        ))
    }

    func testCustomRangeDisplayTitleShowsStartAndEndDates() {
        let start = date(year: 2026, month: 6, day: 18)
        let end = date(year: 2026, month: 6, day: 20)

        let title = TimeRange.custom(start: start, end: end).displayTitle(formatter: displayFormatter, calendar: calendar)

        XCTAssertEqual(title, "Jun 18 - Jun 20")
    }

    func testTodayDisplayTitleShowsPresetName() {
        let now = date(year: 2026, month: 6, day: 20)

        let title = TimeRange.today.displayTitle(now: now, formatter: displayFormatter, calendar: calendar)

        XCTAssertEqual(title, "Today")
    }

    func testCalendarRangeSelectionUsesSameDayForFirstTap() {
        let day = date(year: 2026, month: 6, day: 20, hour: 12)

        var selection = CalendarRangeSelection()
        selection.select(day, calendar: calendar)

        XCTAssertEqual(selection.start, date(year: 2026, month: 6, day: 20))
        XCTAssertEqual(selection.end, date(year: 2026, month: 6, day: 20))
    }

    func testCalendarRangeSelectionExtendsRangeOnSecondTap() {
        var selection = CalendarRangeSelection()

        selection.select(date(year: 2026, month: 6, day: 20), calendar: calendar)
        selection.select(date(year: 2026, month: 6, day: 24), calendar: calendar)

        XCTAssertEqual(selection.start, date(year: 2026, month: 6, day: 20))
        XCTAssertEqual(selection.end, date(year: 2026, month: 6, day: 24))
    }

    func testCalendarRangeSelectionNormalizesReverseSecondTap() {
        var selection = CalendarRangeSelection()

        selection.select(date(year: 2026, month: 6, day: 20), calendar: calendar)
        selection.select(date(year: 2026, month: 6, day: 18), calendar: calendar)

        XCTAssertEqual(selection.start, date(year: 2026, month: 6, day: 18))
        XCTAssertEqual(selection.end, date(year: 2026, month: 6, day: 20))
    }

    func testCalendarRangeSelectionStartsOverAfterCompletedRange() {
        var selection = CalendarRangeSelection()

        selection.select(date(year: 2026, month: 6, day: 20), calendar: calendar)
        selection.select(date(year: 2026, month: 6, day: 24), calendar: calendar)
        selection.select(date(year: 2026, month: 6, day: 10), calendar: calendar)

        XCTAssertEqual(selection.start, date(year: 2026, month: 6, day: 10))
        XCTAssertEqual(selection.end, date(year: 2026, month: 6, day: 10))
    }

    private func date(year: Int, month: Int, day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func unixSeconds(year: Int, month: Int, day: Int) -> Int {
        Int(date(year: year, month: month, day: day).timeIntervalSince1970)
    }

    private var displayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }
}
