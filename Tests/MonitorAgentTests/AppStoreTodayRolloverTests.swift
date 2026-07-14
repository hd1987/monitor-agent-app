import XCTest
@testable import MonitorAgent

final class AppStoreTodayRolloverTests: XCTestCase {
    func testPanelVisibilityTracksSyncLifecycle() {
        let suiteName = "AppStoreTodayRolloverTests.syncLifecycle"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(SyncInterval.ten.rawValue, forKey: "syncInterval")
        let syncSettings = SyncSettings(defaults: defaults)
        let syncManager = SessionSyncManager(
            database: DatabaseManager(inMemory: true),
            claudeProjectsPath: "/nonexistent/claude",
            codexSessionsPath: "/nonexistent/codex",
            codexArchivedSessionsPath: "/nonexistent/codex-archive"
        )
        let quotaDefaults = UserDefaults(suiteName: "\(suiteName).quota")!
        quotaDefaults.removePersistentDomain(forName: "\(suiteName).quota")
        let quotaSettings = QuotaSettings(defaults: quotaDefaults)
        let quotaService = RecordingQuotaService()
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            syncManager: syncManager,
            syncSettings: syncSettings,
            quotaService: quotaService,
            quotaSettings: quotaSettings
        )

        XCTAssertFalse(store.isPanelVisible)
        XCTAssertFalse(store.isPeriodicSyncActive)
        XCTAssertFalse(store.isPeriodicQuotaRefreshActive)

        store.panelDidOpen()
        XCTAssertTrue(store.isPanelVisible)
        XCTAssertTrue(store.isPeriodicSyncActive)
        XCTAssertTrue(store.isPeriodicQuotaRefreshActive)
        XCTAssertEqual(quotaService.providers, [.claude, .codex])
        XCTAssertEqual(quotaService.minimumIntervals, [120, 120])

        store.panelDidClose()
        XCTAssertFalse(store.isPanelVisible)
        XCTAssertFalse(store.isPeriodicSyncActive)
        XCTAssertFalse(store.isPeriodicQuotaRefreshActive)

        defaults.removePersistentDomain(forName: suiteName)
        quotaDefaults.removePersistentDomain(forName: "\(suiteName).quota")
    }

    func testAppFilterDoesNotTriggerQuotaRefresh() {
        let quotaService = RecordingQuotaService()
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            quotaService: quotaService,
            observeSyncIntervalChanges: false
        )

        store.appFilter = .claude
        store.appFilter = .codex

        XCTAssertTrue(quotaService.providers.isEmpty)
    }

    func testPanelOpenRefreshesAllEnabledQuotaProvidersRegardlessOfFilter() {
        let quotaService = RecordingQuotaService()
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            quotaService: quotaService,
            observeSyncIntervalChanges: false
        )
        store.appFilter = .claude

        store.panelDidOpen()

        XCTAssertEqual(quotaService.providers, [.claude, .codex])
        store.panelDidClose()
    }

    func testQuotaSettingsChangeRestartsVisiblePanelWithNewInterval() {
        let suiteName = "AppStoreTodayRolloverTests.quotaInterval"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let quotaSettings = QuotaSettings(defaults: defaults)
        let quotaService = RecordingQuotaService()
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            quotaService: quotaService,
            quotaSettings: quotaSettings,
            observeSyncIntervalChanges: false
        )
        store.panelDidOpen()

        quotaSettings.refreshInterval = .fiveMinutes
        store.quotaSettingsDidChange()

        XCTAssertTrue(store.isPeriodicQuotaRefreshActive)
        XCTAssertEqual(quotaService.minimumIntervals, [120, 120, 300, 300])
        store.panelDidClose()
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testNeverQuotaIntervalRefreshesOnOpenWithoutStartingTimer() {
        let suiteName = "AppStoreTodayRolloverTests.neverQuotaInterval"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let quotaSettings = QuotaSettings(defaults: defaults)
        quotaSettings.refreshInterval = .never
        let quotaService = RecordingQuotaService()
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            quotaService: quotaService,
            quotaSettings: quotaSettings,
            observeSyncIntervalChanges: false
        )

        store.panelDidOpen()

        XCTAssertFalse(store.isPeriodicQuotaRefreshActive)
        XCTAssertEqual(quotaService.providers, [.claude, .codex])
        XCTAssertEqual(quotaService.minimumIntervals, [120, 120])
        store.panelDidClose()
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testSelectActivityDateForTodayUsesDynamicTodayPreset() {
        let now = date(year: 2026, month: 7, day: 9, hour: 10)
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            observeSyncIntervalChanges: false,
            currentDateProvider: { now }
        )

        store.selectActivityDate("2026-07-09")

        XCTAssertEqual(store.timeRange, .today)
        XCTAssertEqual(store.selectedActivityDate, "2026-07-09")
    }

    func testSelectZeroActivityDateKeepsSelectionAndLoadsZeroHourlyUsage() {
        let now = date(year: 2026, month: 7, day: 9, hour: 10)
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            observeSyncIntervalChanges: false,
            currentDateProvider: { now }
        )

        store.selectActivityDate("2026-07-08")

        let loaded = expectation(description: "zero hourly usage loads")
        waitUntil(attemptsRemaining: 50) {
            store.hourlyTokenUsage.count == 24
        } completion: {
            XCTAssertEqual(store.selectedActivityDate, "2026-07-08")
            XCTAssertTrue(store.hourlyTokenUsage.allSatisfy { !$0.hasTokenUsage && $0.requestCount == 0 })
            loaded.fulfill()
        }

        wait(for: [loaded], timeout: 1)
    }

    func testReloadAfterDayRolloverResetsAnySelectionToToday() {
        var now = date(year: 2026, month: 7, day: 9, hour: 23)
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            observeSyncIntervalChanges: false,
            currentDateProvider: { now }
        )
        store.timeRange = .custom(
            start: date(year: 2026, month: 7, day: 8),
            end: date(year: 2026, month: 7, day: 8)
        )
        store.selectedActivityDate = "2026-07-08"
        store.hourlyTokenUsage = [
            HourlyTokenUsage(
                hour: 9,
                requestCount: 1,
                inputTokens: 10,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheCreationTokens: 0
            )
        ]

        now = date(year: 2026, month: 7, day: 10, hour: 0)
        let reset = expectation(description: "day rollover resets selection")
        store.reload()
        DispatchQueue.main.async {
            XCTAssertEqual(store.timeRange, .today)
            XCTAssertNil(store.selectedActivityDate)
            XCTAssertTrue(store.hourlyTokenUsage.isEmpty)
            reset.fulfill()
        }

        wait(for: [reset], timeout: 1)
    }

    func testReloadClearsUnavailableYearsAndResetsYearMode() {
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            observeSyncIntervalChanges: false
        )
        store.availableYears = [2025]
        store.heatmapMode = .year(2025)

        let cleared = expectation(description: "empty database clears stale years")
        store.reload()
        waitUntil(attemptsRemaining: 50) {
            store.availableYears.isEmpty && store.heatmapMode == .trailing
        } completion: {
            cleared.fulfill()
        }

        wait(for: [cleared], timeout: 1)
    }

    private func waitUntil(
        attemptsRemaining: Int,
        condition: @escaping () -> Bool,
        completion: @escaping () -> Void
    ) {
        if condition() {
            completion()
            return
        }
        guard attemptsRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            self.waitUntil(
                attemptsRemaining: attemptsRemaining - 1,
                condition: condition,
                completion: completion
            )
        }
    }

    private func date(year: Int, month: Int, day: Int, hour: Int = 0) -> Date {
        let calendar = Calendar.current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
}

private final class RecordingQuotaService: QuotaRefreshing {
    private(set) var providers: [QuotaProviderID] = []
    private(set) var minimumIntervals: [TimeInterval] = []

    func refresh(
        provider: QuotaProviderID,
        minimumInterval: TimeInterval,
        force: Bool,
        now: Date,
        completion: @escaping (QuotaSnapshot) -> Void
    ) {
        providers.append(provider)
        minimumIntervals.append(minimumInterval)
    }
}
