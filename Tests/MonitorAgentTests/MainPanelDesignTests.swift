import AppKit
import SwiftUI
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

    func testHeaderToolButtonsUseCompactHitTarget() {
        XCTAssertEqual(MainPanelDesign.headerControlItemHeight, 24)
    }

    func testRefreshIndicatorUsesThinCornerInsetGeometry() {
        XCTAssertEqual(MainPanelDesign.refreshIndicatorHeight, 2)
        XCTAssertEqual(
            MainPanelDesign.refreshIndicatorHorizontalInset,
            MainPanelDesign.cornerRadius
        )
    }

    func testRefreshIndicatorDoesNotChangeFittingSize() {
        let idleView = NSHostingView(
            rootView: refreshIndicatorTestView(isRefreshing: false)
        )
        let refreshingView = NSHostingView(
            rootView: refreshIndicatorTestView(isRefreshing: true)
        )

        XCTAssertEqual(refreshingView.fittingSize, idleView.fittingSize)
    }

    func testRefreshIndicatorRenderingStaysWithinConfiguredHeight() throws {
        let size = NSSize(width: 120, height: 20)
        let image = try render(
            refreshIndicatorTestView(isRefreshing: true),
            size: size
        )
        let pixelsPerPoint = CGFloat(image.pixelsHigh) / size.height
        let maximumIndicatorRows = Int(
            ceil(MainPanelDesign.refreshIndicatorHeight * pixelsPerPoint)
        )
        let changedRows = rowsDifferentFromWhite(in: image)

        XCTAssertFalse(changedRows.isEmpty, "No rendered indicator pixels were found")
        XCTAssertLessThanOrEqual(
            changedRows.count,
            maximumIndicatorRows,
            "Changed rows: \(changedRows.sorted())"
        )
        XCTAssertTrue(
            changedRows.allSatisfy { $0 < maximumIndicatorRows },
            "Changed rows: \(changedRows.sorted())"
        )
    }

    func testTooltipsShareOneSurfaceStyle() {
        XCTAssertEqual(MainPanelTooltipDesign.cornerRadius, 6)
        XCTAssertEqual(MainPanelTooltipDesign.borderOpacity, 0.12)
        XCTAssertEqual(MainPanelTooltipDesign.shadowOpacity, 0.10)
        XCTAssertEqual(MainPanelTooltipDesign.shadowRadius, 5)
        XCTAssertEqual(MainPanelTooltipDesign.shadowYOffset, 2)
    }

    private func refreshIndicatorTestView(isRefreshing: Bool) -> some View {
        Color.white
            .frame(width: 120, height: 20)
            .mainPanelRefreshProgress(isRefreshing: isRefreshing, tint: .black)
    }

    private func render<V: View>(_ view: V, size: NSSize) throws -> NSBitmapImageRep {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        guard let image = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw RenderingError.bitmapUnavailable
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: image)
        return image
    }

    private func rowsDifferentFromWhite(in image: NSBitmapImageRep) -> Set<Int> {
        var changedRows = Set<Int>()
        for topRow in 0..<image.pixelsHigh {
            for column in 0..<image.pixelsWide {
                guard let color = image.colorAt(x: column, y: topRow)?.usingColorSpace(.deviceRGB)
                else { continue }
                if color.redComponent < 0.98
                    || color.greenComponent < 0.98
                    || color.blueComponent < 0.98 {
                    changedRows.insert(topRow)
                    break
                }
            }
        }
        return changedRows
    }

    private enum RenderingError: Error {
        case bitmapUnavailable
    }
}
