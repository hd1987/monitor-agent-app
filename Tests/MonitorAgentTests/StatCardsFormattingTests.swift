import XCTest
@testable import MonitorAgent

final class StatCardsFormattingTests: XCTestCase {
    func testFormatCountShowsExactGroupedCounts() {
        XCTAssertEqual(formatCount(999), "999")
        XCTAssertEqual(formatCount(1_000), "1,000")
        XCTAssertEqual(formatCount(1_234_567), "1,234,567")
        XCTAssertEqual(formatCount(1_234_567_890), "1,234,567,890")
    }

    func testTokenFormattersUseTwoDecimalAbbreviations() {
        XCTAssertEqual(formatTokens(999), "999")
        XCTAssertEqual(formatTokens(1_000), "1.00K")
        XCTAssertEqual(formatTokens(999_994), "999.99K")
        XCTAssertEqual(formatTokens(999_995), "1.00M")
        XCTAssertEqual(formatTokens(1_234_567), "1.23M")
        XCTAssertEqual(formatTokens(999_999_999), "1.00B")
        XCTAssertEqual(formatTokens(1_234_567_890), "1.23B")
        XCTAssertEqual(formatTokenDetail(1_234_567), formatTokens(1_234_567))
    }
}
