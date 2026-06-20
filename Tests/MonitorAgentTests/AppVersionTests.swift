import XCTest
@testable import MonitorAgent

final class AppVersionTests: XCTestCase {
    func testDisplayVersionUsesBundleShortVersion() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.2.2"]

        XCTAssertEqual(AppVersion.displayVersion(infoDictionary: info), "0.2.2")
    }

    func testDisplayVersionFallsBackToDevelopmentWhenBundleVersionIsMissing() {
        XCTAssertEqual(AppVersion.displayVersion(infoDictionary: [:]), "Development")
    }

    func testComparableVersionIsNilWhenBundleVersionIsMissing() {
        XCTAssertNil(AppVersion.comparableVersion(infoDictionary: [:]))
    }

    func testVersionComparisonRequiresComparableCurrentVersion() {
        XCTAssertFalse(VersionComparison.isRemoteVersionNewer("0.2.2", than: nil))
        XCTAssertFalse(VersionComparison.isRemoteVersionNewer("0.2.2", than: "0.2.2"))
        XCTAssertTrue(VersionComparison.isRemoteVersionNewer("0.2.3", than: "0.2.2"))
    }

    func testRestartCommandLaunchesDetachedNewInstance() {
        let command = RestartLauncher.makeCommand(
            appURL: URL(fileURLWithPath: "/Applications/MonitorAgent.app"),
            delay: 0.5
        )

        XCTAssertEqual(command.executablePath, "/bin/sh")
        XCTAssertEqual(command.arguments.first, "-c")
        XCTAssertTrue(command.arguments[1].contains("/usr/bin/nohup"))
        XCTAssertFalse(command.arguments[1].contains("/bin/kill -0"))
        XCTAssertTrue(command.arguments[1].contains("/usr/bin/open -n"))
        XCTAssertTrue(command.arguments[1].contains("/Applications/MonitorAgent.app"))
    }
}
