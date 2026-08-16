import XCTest
@testable import MonitorAgent

final class PanelRefreshCoordinatorTests: XCTestCase {
    func testManualConfigurationDoesNotStartInitialOrPeriodicRefresh() {
        let coordinator = PanelRefreshCoordinator()
        var refreshCount = 0

        coordinator.configureManualRefresh { completion in
            refreshCount += 1
            completion()
        }

        XCTAssertEqual(refreshCount, 0)
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertTrue(coordinator.refreshNow())
        XCTAssertEqual(refreshCount, 1)
    }

    func testManualConfigurationPreservesPendingRefreshAcrossVisibilityTransition() {
        var now = Date(timeIntervalSince1970: 1_000)
        let coordinator = PanelRefreshCoordinator(currentDateProvider: { now })
        var initialCompletion: (() -> Void)?
        var configuredRefreshCount = 0
        let pendingRefreshStarted = expectation(description: "pending refresh starts")

        coordinator.start(interval: .oneMinute) { completion in
            initialCompletion = completion
        }
        now = now.addingTimeInterval(PanelRefreshCoordinator.manualRefreshCooldown)
        XCTAssertTrue(coordinator.refreshNow())

        coordinator.configureManualRefresh { completion in
            configuredRefreshCount += 1
            pendingRefreshStarted.fulfill()
            completion()
        }
        initialCompletion?()

        wait(for: [pendingRefreshStarted], timeout: 1)
        XCTAssertEqual(configuredRefreshCount, 1)
        XCTAssertFalse(coordinator.isRunning)
    }

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

        coordinator.start(
            interval: .never,
            initialRefreshMinimumInterval: RefreshInterval.never.effectiveInterval,
            refresh: refresh
        )
        let firstCompletionProcessed = expectation(description: "first refresh completes")
        DispatchQueue.main.async {
            firstCompletionProcessed.fulfill()
        }
        wait(for: [firstCompletionProcessed], timeout: 1)
        coordinator.stop()
        now = now.addingTimeInterval(RefreshInterval.defaultValue.effectiveInterval - 1)
        coordinator.start(
            interval: .never,
            initialRefreshMinimumInterval: RefreshInterval.never.effectiveInterval,
            refresh: refresh
        )

        XCTAssertEqual(refreshCount, 1)

        coordinator.stop()
        now = now.addingTimeInterval(1)
        coordinator.start(
            interval: .never,
            initialRefreshMinimumInterval: RefreshInterval.never.effectiveInterval,
            refresh: refresh
        )

        XCTAssertEqual(refreshCount, 2)
    }

    func testConfiguredIntervalsThrottlePanelOpenRefreshes() {
        for interval in [RefreshInterval.oneMinute, .twoMinutes, .fiveMinutes] {
            var now = Date(timeIntervalSince1970: 1_000)
            let coordinator = PanelRefreshCoordinator(currentDateProvider: { now })
            var refreshCount = 0
            let refresh: PanelRefreshCoordinator.RefreshAction = { completion in
                refreshCount += 1
                completion()
            }

            coordinator.start(
                interval: interval,
                initialRefreshMinimumInterval: interval.effectiveInterval,
                refresh: refresh
            )
            let firstCompletionProcessed = expectation(
                description: "initial \(interval.displayName) refresh completes"
            )
            DispatchQueue.main.async {
                firstCompletionProcessed.fulfill()
            }
            wait(for: [firstCompletionProcessed], timeout: 1)

            coordinator.stop()
            now = now.addingTimeInterval(interval.effectiveInterval - 1)
            coordinator.start(
                interval: interval,
                initialRefreshMinimumInterval: interval.effectiveInterval,
                refresh: refresh
            )
            XCTAssertEqual(refreshCount, 1, "\(interval.displayName) should throttle panel-open refreshes")

            coordinator.stop()
            now = now.addingTimeInterval(1)
            coordinator.start(
                interval: interval,
                initialRefreshMinimumInterval: interval.effectiveInterval,
                refresh: refresh
            )
            XCTAssertEqual(refreshCount, 2, "\(interval.displayName) should refresh at its interval")
        }
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

    func testManualRefreshStartsNewCycleAndKeepsAutomaticScheduleRunning() {
        var now = Date(timeIntervalSince1970: 1_000)
        let coordinator = PanelRefreshCoordinator(currentDateProvider: { now })
        var completions: [() -> Void] = []

        coordinator.start(interval: .oneMinute) { completion in
            completions.append(completion)
        }
        XCTAssertEqual(completions.count, 1)

        completions[0]()
        let firstCompletionProcessed = expectation(description: "first refresh completes")
        DispatchQueue.main.async {
            firstCompletionProcessed.fulfill()
        }
        wait(for: [firstCompletionProcessed], timeout: 1)
        now = now.addingTimeInterval(PanelRefreshCoordinator.manualRefreshCooldown)

        coordinator.refreshNow()

        XCTAssertEqual(completions.count, 2)
        XCTAssertTrue(coordinator.isRunning)

        coordinator.stop()
        completions[1]()
    }

    func testRepeatedManualRefreshesCoalesceWhileCycleIsInFlight() {
        var now = Date(timeIntervalSince1970: 1_000)
        let coordinator = PanelRefreshCoordinator(currentDateProvider: { now })
        var completions: [() -> Void] = []
        let pendingRefreshStarted = expectation(description: "pending manual refresh starts")

        coordinator.start(interval: .oneMinute) { completion in
            completions.append(completion)
            if completions.count == 2 {
                pendingRefreshStarted.fulfill()
            }
        }
        now = now.addingTimeInterval(PanelRefreshCoordinator.manualRefreshCooldown)

        coordinator.refreshNow()
        coordinator.refreshNow()

        XCTAssertEqual(completions.count, 1)

        completions[0]()
        wait(for: [pendingRefreshStarted], timeout: 1)
        XCTAssertEqual(completions.count, 2)

        coordinator.stop()
        completions[1]()
    }

    func testRefreshStateMarksOnlyManualCycleAsManualAcrossCoalescedCycles() {
        var now = Date(timeIntervalSince1970: 1_000)
        let coordinator = PanelRefreshCoordinator(currentDateProvider: { now })
        var completions: [() -> Void] = []
        var refreshStates: [Bool] = []
        var manualRefreshStates: [Bool] = []
        let pendingRefreshStarted = expectation(description: "pending refresh starts")

        coordinator.setRefreshStateHandler { isRefreshing, isManual in
            refreshStates.append(isRefreshing)
            manualRefreshStates.append(isManual)
        }
        coordinator.start(interval: .oneMinute) { completion in
            completions.append(completion)
            if completions.count == 2 {
                pendingRefreshStarted.fulfill()
            }
        }
        now = now.addingTimeInterval(PanelRefreshCoordinator.manualRefreshCooldown)
        coordinator.refreshNow()

        XCTAssertEqual(refreshStates, [false, true])
        XCTAssertEqual(manualRefreshStates, [false, false])

        completions[0]()
        wait(for: [pendingRefreshStarted], timeout: 1)
        XCTAssertEqual(refreshStates, [false, true, true])
        XCTAssertEqual(manualRefreshStates, [false, false, true])

        completions[1]()
        let finalCompletionProcessed = expectation(description: "final refresh completes")
        DispatchQueue.main.async {
            finalCompletionProcessed.fulfill()
        }
        wait(for: [finalCompletionProcessed], timeout: 1)
        XCTAssertEqual(refreshStates, [false, true, true, false])
        XCTAssertEqual(manualRefreshStates, [false, false, true, false])
    }

    func testManualRefreshWorksForNeverWithoutStartingTimer() {
        var now = Date(timeIntervalSince1970: 1_000)
        let coordinator = PanelRefreshCoordinator(currentDateProvider: { now })
        var refreshCount = 0

        coordinator.start(interval: .never) { completion in
            refreshCount += 1
            completion()
        }
        let firstCompletionProcessed = expectation(description: "first refresh completes")
        DispatchQueue.main.async {
            firstCompletionProcessed.fulfill()
        }
        wait(for: [firstCompletionProcessed], timeout: 1)
        now = now.addingTimeInterval(PanelRefreshCoordinator.manualRefreshCooldown)

        coordinator.refreshNow()

        XCTAssertEqual(refreshCount, 2)
        XCTAssertFalse(coordinator.isRunning)
    }

    func testManualRefreshCooldownRejectsRequestsUntilTenSecondsAfterActualStart() {
        var now = Date(timeIntervalSince1970: 1_000)
        let coordinator = PanelRefreshCoordinator(currentDateProvider: { now })
        var refreshCount = 0

        coordinator.start(interval: .oneMinute) { completion in
            refreshCount += 1
            completion()
        }
        let firstCompletionProcessed = expectation(description: "initial refresh completes")
        DispatchQueue.main.async {
            firstCompletionProcessed.fulfill()
        }
        wait(for: [firstCompletionProcessed], timeout: 1)
        let initialAvailableAt = coordinator.manualRefreshAvailableAt

        XCTAssertFalse(coordinator.refreshNow())
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(
            coordinator.manualRefreshCooldownRemaining(at: now),
            Int(PanelRefreshCoordinator.manualRefreshCooldown)
        )
        XCTAssertEqual(coordinator.manualRefreshAvailableAt, initialAvailableAt)

        now = now.addingTimeInterval(PanelRefreshCoordinator.manualRefreshCooldown - 1)
        XCTAssertFalse(coordinator.refreshNow())
        XCTAssertEqual(coordinator.manualRefreshCooldownRemaining(at: now), 1)

        now = now.addingTimeInterval(1)
        XCTAssertTrue(coordinator.refreshNow())
        XCTAssertEqual(refreshCount, 2)
        XCTAssertEqual(
            coordinator.manualRefreshAvailableAt,
            now.addingTimeInterval(PanelRefreshCoordinator.manualRefreshCooldown)
        )
    }
}
