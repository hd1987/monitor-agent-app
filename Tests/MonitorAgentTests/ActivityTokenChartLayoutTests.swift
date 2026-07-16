import XCTest
@testable import MonitorAgent

final class ActivityTokenChartLayoutTests: XCTestCase {
    func testDrawerUsesStableHeightForSelectedDayDetail() {
        XCTAssertEqual(ActivityTokenChartLayout.drawerHeight, 190)
        XCTAssertEqual(ActivityTokenChartLayout.chartHeight, 128)
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

    func testTooltipOffsetStaysInsideRightEdge() {
        let offset = ActivityTokenChartLayout.tooltipXOffset(
            anchorX: 588,
            tooltipWidth: 160,
            availableWidth: 588
        )

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

    func testCurrentHourPositionIncludesMinutesForToday() {
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
            10.5
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
