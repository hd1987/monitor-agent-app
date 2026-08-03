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

    func testLineChartIconLoadsAsTemplateImage() {
        let image = MainPanelIconAsset.lineChartImage

        XCTAssertNotNil(AppIconAsset.data(named: "linechart"))
        XCTAssertTrue(image.isTemplate)
    }
}
