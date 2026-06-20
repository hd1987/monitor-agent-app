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
}
