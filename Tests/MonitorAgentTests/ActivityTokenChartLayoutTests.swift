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

    func testTooltipOffsetStaysInsideRightEdge() {
        let offset = ActivityTokenChartLayout.tooltipXOffset(
            anchorX: 588,
            tooltipWidth: 160,
            availableWidth: 588
        )

        XCTAssertLessThanOrEqual(offset + 160, 588)
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
}
