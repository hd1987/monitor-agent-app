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

    func testVersionDisplayIncludesCommitWhenPresent() {
        let info: [String: Any] = [
            "CFBundleShortVersionString": "0.2.14",
            "MonitorAgentGitCommit": "7e7950d"
        ]

        XCTAssertEqual(AppVersion.versionWithCommitDisplay(infoDictionary: info), "0.2.14 (7e7950d)")
    }

    func testVersionDisplayOmitsCommitWhenMissing() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.2.14"]

        XCTAssertEqual(AppVersion.versionWithCommitDisplay(infoDictionary: info), "0.2.14")
    }

    func testReleaseDateFormatsIsoDateForDisplay() {
        let info: [String: Any] = ["MonitorAgentReleaseDate": "2026-06-23"]

        XCTAssertEqual(AppVersion.releaseDateDisplay(infoDictionary: info), "Jun 23, 2026")
    }

    func testReleaseDateDisplayIsNilForMissingOrInvalidDate() {
        XCTAssertNil(AppVersion.releaseDateDisplay(infoDictionary: [:]))
        XCTAssertNil(AppVersion.releaseDateDisplay(infoDictionary: ["MonitorAgentReleaseDate": "Jun 23, 2026"]))
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
