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

    func testBarChartIconLoadsAsTemplateImage() {
        let image = MainPanelIconAsset.barChartImage

        XCTAssertNotNil(AppIconAsset.data(named: "barchart"))
        XCTAssertTrue(image.isValid)
        XCTAssertTrue(image.isTemplate)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }
}
