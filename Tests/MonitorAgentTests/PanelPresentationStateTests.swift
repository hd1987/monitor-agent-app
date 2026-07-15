import XCTest
@testable import MonitorAgent

final class PanelPresentationStateTests: XCTestCase {
    func testAppFilterCyclesForwardAndBackward() {
        XCTAssertEqual(AppFilter.all.cycled(), .claude)
        XCTAssertEqual(AppFilter.claude.cycled(), .codex)
        XCTAssertEqual(AppFilter.codex.cycled(), .all)
        XCTAssertEqual(AppFilter.all.cycled(reverse: true), .codex)
    }

    func testPinnedPanelRejectsAutomaticDismissalButAllowsExplicitDismissal() {
        let state = PanelPresentationState()

        XCTAssertTrue(state.allowsDismissal(for: .automatic))

        state.togglePin()

        XCTAssertTrue(state.isPinned)
        XCTAssertFalse(state.allowsDismissal(for: .automatic))
        XCTAssertTrue(state.allowsDismissal(for: .explicit))
    }

    func testExplicitDismissalDoesNotResetPin() {
        let state = PanelPresentationState()
        state.togglePin()

        XCTAssertTrue(state.allowsDismissal(for: .explicit))

        XCTAssertTrue(state.isPinned)
        XCTAssertFalse(state.allowsDismissal(for: .automatic))
    }

    func testPinnedPanelIsHighlightedOnlyWhileFocused() {
        let state = PanelPresentationState()
        state.togglePin()

        XCTAssertFalse(state.isPinHighlighted)

        state.setPanelFocused(true)

        XCTAssertTrue(state.isPinHighlighted)

        state.setPanelFocused(false)

        XCTAssertFalse(state.isPinHighlighted)
        XCTAssertTrue(state.isPinned)
    }

    func testAutomaticDismissalCanBeSuppressedOnceWithoutPinning() {
        let state = PanelPresentationState()
        state.suppressNextAutomaticDismissal()

        XCTAssertFalse(state.allowsDismissal(for: .automatic))
        XCTAssertTrue(state.allowsDismissal(for: .automatic))
        XCTAssertFalse(state.isPinned)
    }

    func testCustomPositionPersistsUntilReset() {
        let state = PanelPresentationState()

        state.recordCustomPosition()

        XCTAssertTrue(state.hasCustomPosition)

        state.resetCustomPosition()

        XCTAssertFalse(state.hasCustomPosition)
    }

    func testAnchoredPositionIsCenteredBelowStatusItemAndConstrainedToScreen() {
        let origin = PanelPositioning.anchoredOrigin(
            statusItemFrame: NSRect(x: 880, y: 900, width: 24, height: 24),
            panelSize: NSSize(width: 620, height: 400),
            visibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 900)
        )

        XCTAssertEqual(origin.x, 380)
        XCTAssertEqual(origin.y, 496)
    }

    func testPanelPositionIsConstrainedInsideVisibleFrame() {
        let origin = PanelPositioning.constrainedOrigin(
            NSPoint(x: -100, y: 700),
            panelSize: NSSize(width: 620, height: 400),
            visibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 900)
        )

        XCTAssertEqual(origin.x, 0)
        XCTAssertEqual(origin.y, 500)
    }

    func testEscapeHidesPanelRegardlessOfAutomaticDismissalPolicy() {
        let panel = FloatingPanel()
        var didHide = false
        panel.allowsAutomaticDismissal = { false }
        panel.onHide = { didHide = true }

        panel.cancelOperation(nil)

        XCTAssertTrue(didHide)
    }
}
