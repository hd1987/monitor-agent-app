import XCTest
@testable import MonitorAgent

final class UsageStatsTests: XCTestCase {
    func testTotalTokensIncludesEveryTokenCategory() {
        let stats = UsageStats(
            inputTokens: 100,
            outputTokens: 40,
            cacheReadTokens: 25,
            cacheCreationTokens: 10
        )

        XCTAssertEqual(stats.totalTokens, 175)
    }
}
