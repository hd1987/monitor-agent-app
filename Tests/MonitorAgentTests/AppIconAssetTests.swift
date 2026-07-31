import XCTest
@testable import MonitorAgent

final class AppIconAssetTests: XCTestCase {
    func testInstalledResourceBundleUsesContentsResourcesDirectory() {
        let resourceDirectory = URL(fileURLWithPath: "/Applications/MonitorAgent.app/Contents/Resources")

        XCTAssertEqual(
            AppIconAsset.installedResourceBundleURL(resourceDirectory: resourceDirectory)?.path,
            "/Applications/MonitorAgent.app/Contents/Resources/MonitorAgent_MonitorAgent.bundle"
        )
    }

    func testDevelopmentIconLoadsFromSwiftPackageBundle() {
        XCTAssertNotNil(AppIconAsset.data(for: .all))
    }
}
