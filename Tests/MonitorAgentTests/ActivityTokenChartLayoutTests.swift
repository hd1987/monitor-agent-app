import XCTest
@testable import MonitorAgent

final class ActivityTokenChartLayoutTests: XCTestCase {
    func testDrawerUsesStableHeightForSelectedDayDetail() {
        XCTAssertEqual(ActivityTokenChartLayout.drawerHeight, 190)
        XCTAssertEqual(ActivityTokenChartLayout.chartHeight, 128)
    }
}
