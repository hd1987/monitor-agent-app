import XCTest
@testable import MonitorAgent

final class PanelPresentationStateTests: XCTestCase {
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

    func testAutomaticDismissalCanBeSuppressedOnceWithoutPinning() {
        let state = PanelPresentationState()
        state.suppressNextAutomaticDismissal()

        XCTAssertFalse(state.allowsDismissal(for: .automatic))
        XCTAssertTrue(state.allowsDismissal(for: .automatic))
        XCTAssertFalse(state.isPinned)
    }
}
