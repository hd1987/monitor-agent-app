import XCTest
@testable import MonitorAgent

final class PanelRefreshCoordinatorTests: XCTestCase {
    func testNeverRunsOneImmediateCycleWithoutStartingTimer() {
        let coordinator = PanelRefreshCoordinator()
        var refreshCount = 0

        coordinator.start(interval: .never) { completion in
            refreshCount += 1
            completion()
        }

        XCTAssertEqual(refreshCount, 1)
        XCTAssertFalse(coordinator.isRunning)
    }

    func testNeverUsesDefaultIntervalForPanelOpenRefreshes() {
        var now = Date(timeIntervalSince1970: 1_000)
        let coordinator = PanelRefreshCoordinator(currentDateProvider: { now })
        var refreshCount = 0
        let refresh: PanelRefreshCoordinator.RefreshAction = { completion in
            refreshCount += 1
            completion()
        }

        coordinator.start(interval: .never, refresh: refresh)
        let firstCompletionProcessed = expectation(description: "first refresh completes")
        DispatchQueue.main.async {
            firstCompletionProcessed.fulfill()
        }
        wait(for: [firstCompletionProcessed], timeout: 1)
        coordinator.stop()
        now = now.addingTimeInterval(RefreshInterval.defaultValue.effectiveInterval - 1)
        coordinator.start(interval: .never, refresh: refresh)

        XCTAssertEqual(refreshCount, 1)

        coordinator.stop()
        now = now.addingTimeInterval(1)
        coordinator.start(interval: .never, refresh: refresh)

        XCTAssertEqual(refreshCount, 2)
    }

    func testRestartCoalescesUntilInFlightCycleCompletes() {
        let coordinator = PanelRefreshCoordinator()
        var completions: [() -> Void] = []
        var refreshCount = 0
        let restarted = expectation(description: "pending refresh starts")

        let refresh: PanelRefreshCoordinator.RefreshAction = { completion in
            refreshCount += 1
            completions.append(completion)
            if refreshCount == 2 {
                restarted.fulfill()
            }
        }

        coordinator.start(interval: .oneMinute, refresh: refresh)
        coordinator.start(interval: .fiveMinutes, refresh: refresh)

        XCTAssertEqual(refreshCount, 1)
        XCTAssertTrue(coordinator.isRunning)

        completions[0]()
        wait(for: [restarted], timeout: 1)
        XCTAssertEqual(refreshCount, 2)

        coordinator.stop()
        completions[1]()
    }
}
