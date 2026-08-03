import XCTest
@testable import MonitorAgent

final class ActivityTokenChartLayoutTests: XCTestCase {
    func testDrawerUsesStableHeightForSelectedDayDetail() {
        XCTAssertEqual(ActivityTokenChartLayout.drawerHeight, 190)
        XCTAssertEqual(ActivityTokenChartLayout.chartHeight, 128)
        XCTAssertEqual(ActivityTokenChartLayout.rangeChartTooltipWidth, 170)
        XCTAssertLessThanOrEqual(
            ActivityTokenChartLayout.requiredDrawerHeight,
            ActivityTokenChartLayout.drawerHeight
        )
    }

    func testUnifiedChartDataNormalizesHourlyUsage() {
        let data = ActivityChartData.hourly(
            date: "2026-07-08",
            usage: hourlyUsage()
        )

        XCTAssertEqual(data.usage.map(\.index), Array(0...23))
        XCTAssertEqual(data.chartDomainEnd, 23)
        XCTAssertEqual(data.xAxisMarks, ActivityTokenChartLayout.hourAxisMarks)
        XCTAssertEqual(data.axisLabel(for: 3), "3h")
        XCTAssertEqual(data.periodLabel(for: data.usage[13]), "13:00-14:00")
        XCTAssertEqual(data.tooltipWidth, ActivityTokenChartLayout.chartTooltipWidth)
    }

    func testUnifiedChartDataNormalizesRangeUsage() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 7, day: 2))!
        let series = ActivityRangeTokenSeries(
            aggregation: .day,
            usage: [start, end].enumerated().map { index, date in
                ActivityRangeTokenUsage(
                    periodStart: date,
                    requestCount: index + 1,
                    inputTokens: Int64(index + 10),
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheCreationTokens: 0
                )
            }
        )
        let data = ActivityChartData.range(
            range: .custom(start: start, end: end),
            series: series
        )

        XCTAssertEqual(data.usage.map(\.index), [0, 1])
        XCTAssertEqual(data.usage.map(\.requestCount), [1, 2])
        XCTAssertEqual(data.chartDomainEnd, 1)
        XCTAssertEqual(data.xAxisMarks, [0, 1])
        XCTAssertEqual(data.granularityLabel(isLoading: false), "Day")
        XCTAssertNil(data.granularityLabel(isLoading: true))
        XCTAssertEqual(data.tooltipWidth, ActivityTokenChartLayout.rangeChartTooltipWidth)
    }

    func testHourAxisMarksUseThreeHourCadence() {
        XCTAssertEqual(ActivityTokenChartLayout.hourAxisMarks.first, 0)
        XCTAssertEqual(ActivityTokenChartLayout.hourAxisMarks.last, ActivityTokenChartLayout.lastHourAxisMark)
        let intervals = zip(
            ActivityTokenChartLayout.hourAxisMarks,
            ActivityTokenChartLayout.hourAxisMarks.dropFirst()
        ).map { current, next in
            next - current
        }
        XCTAssertTrue(intervals.allSatisfy { $0 == ActivityTokenChartLayout.hourAxisMarkInterval })
    }

    func testHourAxisLabelsUseHourSuffix() {
        XCTAssertEqual(ActivityTokenChartLayout.hourAxisLabel(for: 0), "0h")
        XCTAssertEqual(ActivityTokenChartLayout.hourAxisLabel(for: ActivityTokenChartLayout.lastHourAxisMark), "21h")
    }

    func testMultiDayHourlyAxisLabelsShowOnlyHour() {
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 30,
            hour: 20
        ))!

        XCTAssertEqual(
            ActivityTokenChartLayout.rangeHourAxisLabel(for: date, calendar: calendar),
            "20h"
        )
    }

    func testTokenAxisLabelsUseWholeNumberAbbreviations() {
        XCTAssertEqual(ActivityTokenChartLayout.tokenAxisLabel(for: 0), "0")
        XCTAssertEqual(ActivityTokenChartLayout.tokenAxisLabel(for: 1_500), "2K")
        XCTAssertEqual(ActivityTokenChartLayout.tokenAxisLabel(for: 20_400_000), "20M")
        XCTAssertEqual(ActivityTokenChartLayout.tokenAxisLabel(for: 1_600_000_000), "2B")
    }

    func testHourRangeLabelsUseStartInclusiveOneHourWindow() {
        XCTAssertEqual(ActivityTokenChartLayout.hourRangeLabel(for: 13), "13:00-14:00")
        XCTAssertEqual(ActivityTokenChartLayout.hourRangeLabel(for: 23), "23:00-00:00")
    }

    func testMultiDayHourRangeLabelDoesNotRepeatEndDate() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 31,
            hour: 18
        ))!

        XCTAssertEqual(
            ActivityTokenChartLayout.rangeHourLabel(for: start, calendar: calendar),
            "Jul 31, 2026 18:00 - 19:00"
        )
    }

    func testWeeklyLabelBoundsClampPartialWeeksToSelectedRange() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let rangeStart = calendar.date(from: DateComponents(year: 2026, month: 6, day: 3))!
        let rangeEnd = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30))!
        let firstWeekStart = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        let lastWeekStart = calendar.date(from: DateComponents(year: 2026, month: 9, day: 28))!
        let range = TimeRange.custom(start: rangeStart, end: rangeEnd)

        let firstBounds = ActivityTokenChartLayout.weekLabelBounds(
            for: firstWeekStart,
            range: range,
            calendar: calendar
        )
        let lastBounds = ActivityTokenChartLayout.weekLabelBounds(
            for: lastWeekStart,
            range: range,
            calendar: calendar
        )

        XCTAssertEqual(firstBounds.start, rangeStart)
        XCTAssertEqual(
            firstBounds.end,
            calendar.date(from: DateComponents(year: 2026, month: 6, day: 7))
        )
        XCTAssertEqual(lastBounds.start, lastWeekStart)
        XCTAssertEqual(lastBounds.end, rangeEnd)
    }

    func testTooltipFlipsToRightOfGuideNearLeftEdge() {
        let offset = ActivityTokenChartLayout.tooltipXOffset(
            anchorX: 100,
            tooltipWidth: 150,
            availableWidth: 588
        )

        XCTAssertEqual(offset, 108)
    }

    func testTooltipAppearsToLeftOfGuideWhenSpaceAllows() {
        let offset = ActivityTokenChartLayout.tooltipXOffset(
            anchorX: 588,
            tooltipWidth: 160,
            availableWidth: 588
        )

        XCTAssertEqual(offset, 420)
        XCTAssertLessThanOrEqual(offset + 160, 588)
    }

    func testMonthLabelUsesGridColumnOffset() {
        let offset = ActivityTokenChartLayout.monthLabelXOffset(
            column: 4,
            cellSize: 8,
            cellSpacing: 3,
            availableWidth: 588
        )

        XCTAssertEqual(offset, 44)
    }

    func testFinalMonthLabelStaysInsideRightEdge() {
        let offset = ActivityTokenChartLayout.monthLabelXOffset(
            column: 52,
            cellSize: 8,
            cellSpacing: 3,
            availableWidth: 588
        )

        XCTAssertEqual(offset, 564)
        XCTAssertLessThanOrEqual(offset + ActivityTokenChartLayout.monthLabelWidth, 588)
    }

    func testHoveredHourRoundsToNearestHourInsideChartDomain() {
        XCTAssertEqual(ActivityTokenChartLayout.hoveredHour(forChartXValue: 0.2), 0)
        XCTAssertEqual(ActivityTokenChartLayout.hoveredHour(forChartXValue: 8.6), 9)
        XCTAssertEqual(ActivityTokenChartLayout.hoveredHour(forChartXValue: 22.6), 23)
    }

    func testHoveredHourClampsOutsideChartDomain() {
        XCTAssertEqual(ActivityTokenChartLayout.hoveredHour(forChartXValue: -1.4), 0)
        XCTAssertEqual(ActivityTokenChartLayout.hoveredHour(forChartXValue: 24.2), 23)
    }

    func testRangeAxisMarksIncludeFirstAndLastBucketsWithoutCrowding() {
        XCTAssertEqual(ActivityTokenChartLayout.rangeAxisMarks(count: 0), [])
        XCTAssertEqual(ActivityTokenChartLayout.rangeAxisMarks(count: 1), [0])
        XCTAssertEqual(ActivityTokenChartLayout.rangeAxisMarks(count: 7), [0, 1, 2, 3, 4, 5, 6])

        let marks = ActivityTokenChartLayout.rangeAxisMarks(count: 30)
        XCTAssertEqual(marks.first, 0)
        XCTAssertEqual(marks.last, 29)
        XCTAssertEqual(marks, [0, 4, 7, 11, 15, 18, 22, 25, 29])
        XCTAssertEqual(marks.count, 9)
        XCTAssertEqual(ActivityTokenChartLayout.rangeAxisMarks(count: 9), Array(0...8))
    }

    func testTwoDayHourlyAxisUsesSixHourCadenceAndEndBoundary() {
        XCTAssertEqual(
            ActivityTokenChartLayout.rangeHourAxisMarks(
                bucketCount: 48,
                dayCount: 2,
                includesEndBoundary: true
            ),
            [0, 6, 12, 18, 24, 30, 36, 42, 48]
        )
    }

    func testThreeDayHourlyAxisUsesEightHourCadenceAndEndBoundary() {
        XCTAssertEqual(
            ActivityTokenChartLayout.rangeHourAxisMarks(
                bucketCount: 72,
                dayCount: 3,
                includesEndBoundary: true
            ),
            [0, 8, 16, 24, 32, 40, 48, 56, 64, 72]
        )
    }

    func testIncompleteMultiDayHourlyAxisOmitsFutureEndBoundary() {
        XCTAssertEqual(
            ActivityTokenChartLayout.rangeHourAxisMarks(
                bucketCount: 59,
                dayCount: 3,
                includesEndBoundary: false
            ),
            [0, 8, 16, 24, 32, 40, 48, 56]
        )
    }

    func testActivityRangeAggregationUsesPointDensityBoundaries() {
        XCTAssertEqual(ActivityTokenAggregation.forDayCount(1), .hour)
        XCTAssertEqual(ActivityTokenAggregation.forDayCount(3), .hour)
        XCTAssertEqual(ActivityTokenAggregation.forDayCount(4), .day)
        XCTAssertEqual(ActivityTokenAggregation.forDayCount(90), .day)
        XCTAssertEqual(ActivityTokenAggregation.forDayCount(91), .week)
        XCTAssertEqual(ActivityTokenAggregation.forDayCount(540), .week)
        XCTAssertEqual(ActivityTokenAggregation.forDayCount(541), .month)
    }

    func testVisibleUsageForTodayStopsAtCurrentHour() {
        let calendar = Calendar(identifier: .gregorian)
        let usage = hourlyUsage()
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 9, hour: 10, minute: 30))!

        let visible = ActivityTokenChartLayout.visibleUsage(
            usage,
            for: "2026-07-09",
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(visible.map(\.hour), Array(0...10))
    }

    func testVisibleUsageForPastDateKeepsFullDay() {
        let calendar = Calendar(identifier: .gregorian)
        let usage = hourlyUsage()
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 9, hour: 10, minute: 30))!

        let visible = ActivityTokenChartLayout.visibleUsage(
            usage,
            for: "2026-07-08",
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(visible.map(\.hour), Array(0...23))
    }

    func testCurrentHourPositionAlignsWithFinalHourlyBucketForToday() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 9,
            hour: 10,
            minute: 30
        ))!

        XCTAssertEqual(
            ActivityTokenChartLayout.currentHourPosition(
                for: "2026-07-09",
                now: now,
                calendar: calendar
            ),
            10
        )
        XCTAssertNil(
            ActivityTokenChartLayout.currentHourPosition(
                for: "2026-07-08",
                now: now,
                calendar: calendar
            )
        )
    }

    func testHeatmapThresholdsCreateFiveRelativeIntensityLevels() {
        let thresholds = ActivityTokenChartLayout.heatmapThresholds(
            for: [0, 10, 20, 30, 40, 50]
        )

        XCTAssertEqual(thresholds, [20, 30, 30, 40])
        XCTAssertEqual(ActivityTokenChartLayout.heatmapIntensity(for: 0, thresholds: thresholds), 0)
        XCTAssertEqual(ActivityTokenChartLayout.heatmapIntensity(for: 10, thresholds: thresholds), 0.20)
        XCTAssertEqual(ActivityTokenChartLayout.heatmapIntensity(for: 50, thresholds: thresholds), 1.0)
    }

    private func hourlyUsage() -> [HourlyTokenUsage] {
        (0...23).map {
            HourlyTokenUsage(
                hour: $0,
                requestCount: $0 == 10 ? 1 : 0,
                inputTokens: $0 == 10 ? 100 : 0,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheCreationTokens: 0
            )
        }
    }
}
