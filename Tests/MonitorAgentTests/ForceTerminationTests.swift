import XCTest
@testable import MonitorAgent

final class ForceTerminationTests: XCTestCase {
    func testFallbackExitUsesShortDelayAndZeroExitCode() {
        var scheduledDelay: TimeInterval?
        var scheduledBlock: (() -> Void)?
        var exitCode: Int32?

        ForceTermination.scheduleFallbackExit(
            scheduler: { delay, block in
                scheduledDelay = delay
                scheduledBlock = block
            },
            exit: { code in
                exitCode = code
            }
        )

        XCTAssertEqual(scheduledDelay, 0.2)
        XCTAssertNil(exitCode)

        scheduledBlock?()

        XCTAssertEqual(exitCode, 0)
    }
}
