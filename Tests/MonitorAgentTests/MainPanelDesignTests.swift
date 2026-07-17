import XCTest
@testable import MonitorAgent

final class MainPanelDesignTests: XCTestCase {
    func testGroupedSurfacesMatchGeneralContrastLevels() {
        XCTAssertEqual(MainPanelDesign.lightGroupedSurfaceOpacity, 0.032)
        XCTAssertEqual(MainPanelDesign.darkGroupedSurfaceOpacity, 0.075)
    }
}
