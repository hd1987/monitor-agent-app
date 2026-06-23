import XCTest
@testable import MonitorAgent

final class ActivityTokenChartLayoutTests: XCTestCase {
    func testDrawerUsesStableHeightForSelectedDayDetail() {
        XCTAssertEqual(ActivityTokenChartLayout.drawerHeight, 190)
        XCTAssertEqual(ActivityTokenChartLayout.chartHeight, 128)
    }

    func testTooltipOffsetStaysInsideRightEdge() {
        let offset = ActivityTokenChartLayout.tooltipXOffset(
            anchorX: 588,
            tooltipWidth: 160,
            availableWidth: 588
        )

        XCTAssertLessThanOrEqual(offset + 160, 588)
    }
}
