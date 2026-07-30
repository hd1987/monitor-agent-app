import XCTest
@testable import MonitorAgent

final class LaunchAtLoginPolicyTests: XCTestCase {
    func testCanRegisterLaunchAtLoginRequiresAppBundle() {
        XCTAssertTrue(
            LaunchAtLoginController.canRegisterLaunchAtLogin(
                bundlePath: "/Applications/MonitorAgent.app",
                bundleIdentifier: "com.hd1987.monitor-agent"
            )
        )

        XCTAssertFalse(
            LaunchAtLoginController.canRegisterLaunchAtLogin(
                bundlePath: "/Users/adi/Work/monitor-agent-app/.build/arm64-apple-macosx/debug/MonitorAgent",
                bundleIdentifier: nil
            )
        )
    }
}
