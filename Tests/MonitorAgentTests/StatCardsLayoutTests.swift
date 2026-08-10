import XCTest
@testable import MonitorAgent

final class StatCardsLayoutTests: XCTestCase {
    func testVisibleCardsShareAvailableWidthEvenly() {
        let standardWidth = StatCardLayout.equalCardWidth(cardCount: 4)
        let cursorWidth = StatCardLayout.equalCardWidth(cardCount: 5)

        XCTAssertEqual(standardWidth, 141)
        XCTAssertEqual(cursorWidth, 111.2, accuracy: 0.001)
        XCTAssertEqual(
            standardWidth * 4 + StatCardLayout.spacing * 3,
            StatCardLayout.availableWidth
        )
        XCTAssertEqual(
            cursorWidth * 5 + StatCardLayout.spacing * 4,
            StatCardLayout.availableWidth
        )
        XCTAssertEqual(TokenBreakdownTipLayout.itemSpacing, 8)
    }
}
