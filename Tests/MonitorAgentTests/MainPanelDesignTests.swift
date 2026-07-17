import XCTest
@testable import MonitorAgent

final class MainPanelDesignTests: XCTestCase {
    func testGroupedSurfacesMatchGeneralContrastLevels() {
        XCTAssertEqual(MainPanelDesign.lightGroupedSurfaceOpacity, 0.032)
        XCTAssertEqual(MainPanelDesign.darkGroupedSurfaceOpacity, 0.075)
    }

    func testSelectedHeaderControlsUseProminentActivityBlue() {
        XCTAssertEqual(MainPanelSelectionPalette.tabBackgroundOpacity, 0.38)
    }

    func testHeaderToolsUseRestrainedColorAndOpenSpacing() {
        XCTAssertEqual(MainPanelDesign.headerToolOpacity, 0.46)
        XCTAssertEqual(MainPanelDesign.headerToolSpacing, 4)
    }
}
