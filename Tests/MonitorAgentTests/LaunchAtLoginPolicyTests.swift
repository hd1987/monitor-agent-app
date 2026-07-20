import XCTest
@testable import MonitorAgent

final class LaunchAtLoginPolicyTests: XCTestCase {
    func testCanRegisterLaunchAtLoginRequiresAppBundle() {
        XCTAssertTrue(
            SyncSettings.canRegisterLaunchAtLogin(
                bundlePath: "/Applications/MonitorAgent.app",
                bundleIdentifier: "com.hd1987.monitor-agent"
            )
        )

        XCTAssertFalse(
            SyncSettings.canRegisterLaunchAtLogin(
                allowedByRuntime: false,
                bundlePath: "/Applications/MonitorAgent.app",
                bundleIdentifier: "com.hd1987.monitor-agent"
            )
        )

        XCTAssertFalse(
            SyncSettings.canRegisterLaunchAtLogin(
                bundlePath: "/Users/adi/Work/monitor-agent-app/.build/arm64-apple-macosx/debug/MonitorAgent",
                bundleIdentifier: nil
            )
        )
    }
}
