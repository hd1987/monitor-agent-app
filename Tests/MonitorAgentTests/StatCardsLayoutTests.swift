import XCTest
@testable import MonitorAgent

final class StatCardsLayoutTests: XCTestCase {
    func testMetricCardsUseSharedWidth() {
        XCTAssertEqual(StatCardLayout.metricWidth, 128)
        XCTAssertEqual(StatCardLayout.requestsWidth, StatCardLayout.metricWidth)
        XCTAssertEqual(StatCardLayout.sessionsWidth, StatCardLayout.metricWidth)
        XCTAssertEqual(StatCardLayout.cacheHitWidth, StatCardLayout.metricWidth)
        XCTAssertGreaterThan(StatCardLayout.tokensWidth, StatCardLayout.metricWidth)
    }
}
