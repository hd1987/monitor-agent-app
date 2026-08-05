import Combine
import SwiftUI
import XCTest
@testable import MonitorAgent

final class AppStoreTodayRolloverTests: XCTestCase {
    func testPanelVisibilityTracksSyncLifecycle() {
        let suiteName = "AppStoreTodayRolloverTests.syncLifecycle"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(RefreshInterval.oneMinute.rawValue, forKey: "refreshInterval")
        let refreshSettings = RefreshSettings(defaults: defaults)
        let syncManager = SessionSyncManager(
            database: DatabaseManager(inMemory: true),
            claudeProjectsPath: "/nonexistent/claude",
            codexSessionsPath: "/nonexistent/codex",
            codexArchivedSessionsPath: "/nonexistent/codex-archive"
        )
        let quotaDefaults = UserDefaults(suiteName: "\(suiteName).quota")!
        quotaDefaults.removePersistentDomain(forName: "\(suiteName).quota")
        let quotaSettings = QuotaSettings(defaults: quotaDefaults)
        enableAllProviders(quotaSettings)
        let quotaService = RecordingQuotaService()
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            syncManager: syncManager,
            refreshSettings: refreshSettings,
            quotaService: quotaService,
            quotaSettings: quotaSettings
        )

        XCTAssertFalse(store.isPanelVisible)
        XCTAssertFalse(store.isPeriodicRefreshActive)

        store.panelDidOpen()
        XCTAssertTrue(store.isPanelVisible)
        XCTAssertTrue(store.isPeriodicRefreshActive)
        XCTAssertEqual(quotaService.providers, [.claude, .codex])

        store.panelDidClose()
        XCTAssertFalse(store.isPanelVisible)
        XCTAssertFalse(store.isPeriodicRefreshActive)

        defaults.removePersistentDomain(forName: suiteName)
        quotaDefaults.removePersistentDomain(forName: "\(suiteName).quota")
    }

    func testAppFilterDoesNotTriggerQuotaRefresh() {
        let quotaService = RecordingQuotaService()
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            quotaService: quotaService,
            observeRefreshIntervalChanges: false
        )

        store.appFilter = .claude
        store.appFilter = .codex

        XCTAssertTrue(quotaService.providers.isEmpty)
    }

    func testPanelOpenRefreshesAllEnabledQuotaProvidersRegardlessOfFilter() {
        let suiteName = "AppStoreTodayRolloverTests.refreshAllProviders"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let quotaSettings = QuotaSettings(defaults: defaults)
        enableAllProviders(quotaSettings)
        let quotaService = RecordingQuotaService()
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            quotaService: quotaService,
            quotaSettings: quotaSettings,
            observeRefreshIntervalChanges: false
        )
        store.appFilter = .claude

        store.panelDidOpen()

        XCTAssertEqual(quotaService.providers, [.claude, .codex])
        store.panelDidClose()
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testMonitoringSelectionLimitsFiltersAndQuotaRefresh() {
        let suiteName = "AppStoreTodayRolloverTests.monitoringSelection"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let monitoringSettings = AgentMonitoringSettings(defaults: defaults)
        monitoringSettings.enabledAgents = [.claude]
        let quotaSettings = QuotaSettings(defaults: defaults)
        enableAllProviders(quotaSettings)
        let quotaService = RecordingQuotaService()
        let database = DatabaseManager(inMemory: true)
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: "/nonexistent/claude",
            codexSessionsPath: "/nonexistent/codex",
            codexArchivedSessionsPath: "/nonexistent/codex-archive"
        )
        let store = AppStore(
            database: database,
            syncManager: syncManager,
            monitoringSettings: monitoringSettings,
            quotaService: quotaService,
            quotaSettings: quotaSettings,
            observeRefreshIntervalChanges: false
        )

        store.panelDidOpen()

        XCTAssertEqual(store.availableAppFilters, [.all, .claude])
        XCTAssertEqual(store.visibleQuotaProviders, [.claude])
        XCTAssertEqual(quotaService.providers, [.claude])
        store.panelDidClose()
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testNoMonitoredAgentsStopsPanelRefreshLifecycle() {
        let suiteName = "AppStoreTodayRolloverTests.noMonitoredAgents"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let monitoringSettings = AgentMonitoringSettings(defaults: defaults)
        monitoringSettings.enabledAgents = []
        let quotaSettings = QuotaSettings(defaults: defaults)
        enableAllProviders(quotaSettings)
        let quotaService = RecordingQuotaService()
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            monitoringSettings: monitoringSettings,
            quotaService: quotaService,
            quotaSettings: quotaSettings,
            observeRefreshIntervalChanges: false
        )

        store.panelDidOpen()
        store.refreshNow()

        XCTAssertFalse(store.hasEnabledAgents)
        XCTAssertEqual(store.availableAppFilters, [.all])
        XCTAssertFalse(store.isPeriodicRefreshActive)
        XCTAssertTrue(quotaService.providers.isEmpty)
        XCTAssertEqual(store.manualRefreshCooldownRemaining(at: Date()), 0)
        store.panelDidClose()
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDisablingSelectedAgentResetsFilterAndSelectedActivity() {
        let suiteName = "AppStoreTodayRolloverTests.disableSelectedAgent"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let monitoringSettings = AgentMonitoringSettings(defaults: defaults)
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            monitoringSettings: monitoringSettings,
            observeRefreshIntervalChanges: false
        )
        store.appFilter = .codex
        store.selectActivityDate("2026-07-09")

        monitoringSettings.enabledAgents = [.claude, .cursor]

        XCTAssertEqual(store.appFilter, .all)
        XCTAssertNil(store.selectedActivityDate)
        XCTAssertEqual(store.availableAppFilters, [.all, .claude, .cursor])
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDisablingAllAgentsClosesActivityDetail() {
        let suiteName = "AppStoreTodayRolloverTests.disableAllAgents"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let monitoringSettings = AgentMonitoringSettings(defaults: defaults)
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            monitoringSettings: monitoringSettings,
            observeRefreshIntervalChanges: false
        )
        store.toggleActivityDetail()

        XCTAssertTrue(store.isActivityDetailPresented)

        monitoringSettings.enabledAgents = []

        XCTAssertEqual(store.activityDetailState, .closed)
        XCTAssertFalse(store.isActivityDetailPresented)
        XCTAssertNil(store.activityChartData)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDisablingAgentCancelsItsInFlightRoutineSync() {
        let suiteName = "AppStoreTodayRolloverTests.cancelDisabledAgent"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let monitoringSettings = AgentMonitoringSettings(defaults: defaults)
        let cursorSyncer = CancellableCursorUsageSyncerProbe()
        let database = DatabaseManager(inMemory: true)
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: "/nonexistent/claude",
            codexSessionsPath: "/nonexistent/codex",
            codexArchivedSessionsPath: "/nonexistent/codex-archive",
            cursorUsageSyncer: cursorSyncer
        )
        let store = AppStore(
            database: database,
            syncManager: syncManager,
            monitoringSettings: monitoringSettings,
            quotaService: RecordingQuotaService(),
            quotaSettings: QuotaSettings(defaults: defaults),
            observeRefreshIntervalChanges: false
        )

        store.panelDidOpen()
        wait(for: [cursorSyncer.started], timeout: 1)
        monitoringSettings.enabledAgents = [.claude, .codex]

        wait(for: [cursorSyncer.cancelled], timeout: 1)
        store.panelDidClose()
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDisabledQuotaDoesNotBlockReplacementRefreshCycle() {
        let suiteName = "AppStoreTodayRolloverTests.cancelDisabledQuota"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let monitoringSettings = AgentMonitoringSettings(defaults: defaults)
        let quotaSettings = QuotaSettings(defaults: defaults)
        quotaSettings.claudeExpirationDate = Date(timeIntervalSinceNow: 30 * 24 * 60 * 60)
        let quotaService = BlockingQuotaService()
        let database = DatabaseManager(inMemory: true)
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: "/nonexistent/claude",
            codexSessionsPath: "/nonexistent/codex",
            codexArchivedSessionsPath: "/nonexistent/codex-archive"
        )
        let store = AppStore(
            database: database,
            syncManager: syncManager,
            monitoringSettings: monitoringSettings,
            quotaService: quotaService,
            quotaSettings: quotaSettings,
            observeRefreshIntervalChanges: false
        )

        store.panelDidOpen()
        wait(for: [quotaService.started], timeout: 1)
        monitoringSettings.enabledAgents = [.cursor]

        let replacementCycleFinished = expectation(description: "Replacement refresh cycle finishes")
        waitUntil(attemptsRemaining: 100) {
            !store.isRefreshInProgress
        } completion: {
            replacementCycleFinished.fulfill()
        }
        wait(for: [replacementCycleFinished], timeout: 2)

        quotaService.finish()
        let completionDrained = expectation(description: "Cancelled quota completion drains")
        DispatchQueue.main.async {
            completionDrained.fulfill()
        }
        wait(for: [completionDrained], timeout: 1)
        store.panelDidClose()
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testMonitoringSelectionPublishesThroughAppStore() {
        let suiteName = "AppStoreTodayRolloverTests.publishedMonitoringSelection"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let monitoringSettings = AgentMonitoringSettings(defaults: defaults)
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            monitoringSettings: monitoringSettings,
            observeRefreshIntervalChanges: false
        )
        let published = expectation(description: "AppStore publishes enabled Agents")
        var observation: AnyCancellable?
        observation = store.$enabledAgents.dropFirst().sink { enabledAgents in
            XCTAssertEqual(enabledAgents, [.claude])
            published.fulfill()
        }

        store.updateEnabledAgents([.claude])

        wait(for: [published], timeout: 1)
        withExtendedLifetime(observation) {}
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testRefreshIntervalChangeRestartsUnifiedVisiblePanelTimer() {
        let suiteName = "AppStoreTodayRolloverTests.quotaInterval"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let refreshSettings = RefreshSettings(defaults: defaults)
        let quotaSettings = QuotaSettings(defaults: defaults)
        enableAllProviders(quotaSettings)
        let quotaService = RecordingQuotaService()
        let database = DatabaseManager(inMemory: true)
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: "/nonexistent/claude",
            codexSessionsPath: "/nonexistent/codex",
            codexArchivedSessionsPath: "/nonexistent/codex-archive"
        )
        let store = AppStore(
            database: database,
            syncManager: syncManager,
            refreshSettings: refreshSettings,
            quotaService: quotaService,
            quotaSettings: quotaSettings
        )
        store.panelDidOpen()

        refreshSettings.interval = .fiveMinutes

        XCTAssertTrue(store.isPeriodicRefreshActive)
        let restarted = expectation(description: "unified refresh restarts")
        waitUntil(attemptsRemaining: 50) {
            quotaService.providers.count == 4
        } completion: {
            XCTAssertEqual(quotaService.providers, [.claude, .codex, .claude, .codex])
            restarted.fulfill()
        }
        wait(for: [restarted], timeout: 1)
        store.panelDidClose()
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testNeverRefreshIntervalRunsOnceOnOpenWithoutStartingTimer() {
        let suiteName = "AppStoreTodayRolloverTests.neverQuotaInterval"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let refreshSettings = RefreshSettings(defaults: defaults)
        refreshSettings.interval = .never
        let quotaSettings = QuotaSettings(defaults: defaults)
        enableAllProviders(quotaSettings)
        let quotaService = RecordingQuotaService()
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            refreshSettings: refreshSettings,
            quotaService: quotaService,
            quotaSettings: quotaSettings
        )

        store.panelDidOpen()

        XCTAssertFalse(store.isPeriodicRefreshActive)
        XCTAssertEqual(quotaService.providers, [.claude, .codex])
        store.panelDidClose()
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testManualRefreshRunsUnifiedCycleForEveryEnabledProvider() {
        let suiteName = "AppStoreTodayRolloverTests.manualRefresh"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let refreshSettings = RefreshSettings(defaults: defaults)
        let quotaSettings = QuotaSettings(defaults: defaults)
        enableAllProviders(quotaSettings)
        let quotaService = RecordingQuotaService()
        let database = DatabaseManager(inMemory: true)
        var now = Date(timeIntervalSince1970: 1_000)
        let refreshCoordinator = PanelRefreshCoordinator(currentDateProvider: { now })
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: "/nonexistent/claude",
            codexSessionsPath: "/nonexistent/codex",
            codexArchivedSessionsPath: "/nonexistent/codex-archive"
        )
        let store = AppStore(
            database: database,
            syncManager: syncManager,
            refreshSettings: refreshSettings,
            quotaService: quotaService,
            quotaSettings: quotaSettings,
            refreshCoordinator: refreshCoordinator
        )

        store.panelDidOpen()
        XCTAssertEqual(
            store.manualRefreshCooldownRemaining(at: now),
            Int(PanelRefreshCoordinator.manualRefreshCooldown)
        )
        now = now.addingTimeInterval(PanelRefreshCoordinator.manualRefreshCooldown)
        store.refreshNow()

        let refreshed = expectation(description: "manual unified refresh completes")
        waitUntil(attemptsRemaining: 50) {
            quotaService.providers.count == 4
        } completion: {
            XCTAssertEqual(quotaService.providers, [.claude, .codex, .claude, .codex])
            XCTAssertTrue(store.isPeriodicRefreshActive)
            refreshed.fulfill()
        }
        wait(for: [refreshed], timeout: 1)

        store.panelDidClose()
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testSelectActivityDateForTodayUsesDynamicTodayPreset() {
        let now = date(year: 2026, month: 7, day: 9, hour: 10)
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            observeRefreshIntervalChanges: false,
            currentDateProvider: { now }
        )

        store.selectActivityDate("2026-07-09")

        XCTAssertEqual(store.timeRange, .today)
        XCTAssertEqual(store.selectedActivityDate, "2026-07-09")
    }

    func testHeatmapModeChangeKeepsActivityDetailPresented() {
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            observeRefreshIntervalChanges: false
        )
        store.selectActivityDate("2026-07-08")
        let hostingView = NSHostingView(
            rootView: HeatmapView()
                .environmentObject(store)
                .environmentObject(ThemeManager.shared)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: MainPanelDesign.width, height: 500)
        hostingView.layoutSubtreeIfNeeded()

        store.heatmapMode = .year(2025)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(store.isActivityDetailPresented)
        XCTAssertEqual(store.selectedActivityDate, "2026-07-08")
    }

    func testClosingActivityDetailPreservesCurrentFilters() {
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            observeRefreshIntervalChanges: false
        )
        store.appFilter = .codex
        store.selectActivityDate("2026-07-08")
        let selectedRange = store.timeRange

        store.closeActivityDetail()

        XCTAssertFalse(store.isActivityDetailPresented)
        XCTAssertNil(store.selectedActivityDate)
        XCTAssertEqual(store.timeRange, selectedRange)
        XCTAssertEqual(store.appFilter, .codex)
    }

    func testToggleActivityDetailShowsAndHidesCurrentSingleDayRange() {
        let now = date(year: 2026, month: 7, day: 9, hour: 10)
        let expectedUsage = [hourlyUsage(hour: 10, inputTokens: 100)]
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            observeRefreshIntervalChanges: false,
            currentDateProvider: { now },
            hourlyTokenUsageLoader: { _, _, _, date in
                XCTAssertEqual(date, "2026-07-09")
                return expectedUsage
            }
        )

        store.toggleActivityDetail()

        let loaded = expectation(description: "top chart button loads current day")
        waitUntil(attemptsRemaining: 50) {
            store.hourlyTokenUsage == expectedUsage && !store.isHourlyTokenUsageLoading
        } completion: {
            XCTAssertTrue(store.isActivityDetailPresented)
            XCTAssertEqual(store.selectedActivityDate, "2026-07-09")
            XCTAssertEqual(store.timeRange, .today)
            XCTAssertEqual(
                store.activityDetailState,
                .hourly(date: "2026-07-09", usage: expectedUsage, isLoading: false)
            )
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 1)

        store.toggleActivityDetail()

        XCTAssertEqual(store.activityDetailState, .closed)
        XCTAssertFalse(store.isActivityDetailPresented)
        XCTAssertEqual(store.timeRange, .today)
    }

    func testToggleActivityDetailShowsCurrentMultiDayRange() {
        let loadCountLock = NSLock()
        var loadCount = 0
        let expectedSeries = ActivityRangeTokenSeries(
            aggregation: .day,
            usage: [ActivityRangeTokenUsage(
                periodStart: date(year: 2026, month: 7, day: 3),
                requestCount: 1,
                inputTokens: 100,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheCreationTokens: 0
            )]
        )
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            observeRefreshIntervalChanges: false,
            activityRangeTokenUsageLoader: { _, _, _, range in
                XCTAssertEqual(range, .last7)
                loadCountLock.lock()
                loadCount += 1
                loadCountLock.unlock()
                return expectedSeries
            }
        )
        store.setTimeRangeFromFilter(.last7)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        store.toggleActivityDetail()

        let loaded = expectation(description: "top chart button loads current range")
        waitUntil(attemptsRemaining: 50) {
            store.activityRangeTokenSeries == expectedSeries
                && !store.isActivityRangeTokenUsageLoading
        } completion: {
            XCTAssertTrue(store.isActivityDetailPresented)
            XCTAssertNil(store.selectedActivityDate)
            XCTAssertEqual(store.activityDetailRange, .last7)
            XCTAssertEqual(store.timeRange, .last7)
            XCTAssertEqual(
                store.activityDetailState,
                .range(range: .last7, series: expectedSeries, isLoading: false)
            )
            loadCountLock.lock()
            let finalLoadCount = loadCount
            loadCountLock.unlock()
            XCTAssertEqual(finalLoadCount, 1)
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 1)
    }

    func testSelectingMultiDayFilterPresentsAggregatedActivityDetail() {
        let expectedSeries = ActivityRangeTokenSeries(
            aggregation: .day,
            usage: [
                ActivityRangeTokenUsage(
                    periodStart: date(year: 2026, month: 7, day: 3),
                    requestCount: 2,
                    inputTokens: 100,
                    outputTokens: 20,
                    cacheReadTokens: 10,
                    cacheCreationTokens: 5
                )
            ]
        )
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            observeRefreshIntervalChanges: false,
            activityRangeTokenUsageLoader: { _, _, _, range in
                XCTAssertEqual(range, .last7)
                return expectedSeries
            }
        )

        store.selectActivityDate("2026-07-08")
        store.setTimeRangeFromFilter(.last7)

        let loaded = expectation(description: "multi-day Activity usage loads")
        waitUntil(attemptsRemaining: 50) {
            store.activityRangeTokenSeries == expectedSeries && !store.isActivityRangeTokenUsageLoading
        } completion: {
            XCTAssertEqual(store.timeRange, .last7)
            XCTAssertEqual(store.activityDetailRange, .last7)
            XCTAssertNil(store.selectedActivityDate)
            XCTAssertTrue(store.isActivityDetailPresented)
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 1)
    }

    func testSelectingMultiDayFilterLoadsActivityDetailOnce() {
        let loadCountLock = NSLock()
        var loadCount = 0
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            observeRefreshIntervalChanges: false,
            activityRangeTokenUsageLoader: { _, _, _, _ in
                loadCountLock.lock()
                loadCount += 1
                loadCountLock.unlock()
                return .empty
            }
        )

        store.selectActivityDate("2026-07-08")
        store.setTimeRangeFromFilter(.last7)

        let reloadSettled = expectation(description: "debounced Activity detail reload settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            loadCountLock.lock()
            let finalLoadCount = loadCount
            loadCountLock.unlock()
            XCTAssertEqual(finalLoadCount, 1)
            reloadSettled.fulfill()
        }
        wait(for: [reloadSettled], timeout: 1)
    }

    func testSelectingDateFilterKeepsClosedActivityDetailClosed() {
        let rangeLoadStarted = expectation(description: "range detail should not load")
        rangeLoadStarted.isInverted = true
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            observeRefreshIntervalChanges: false,
            activityRangeTokenUsageLoader: { _, _, _, _ in
                rangeLoadStarted.fulfill()
                return .empty
            }
        )

        store.setTimeRangeFromFilter(.last7)

        XCTAssertEqual(store.timeRange, .last7)
        XCTAssertNil(store.activityDetailRange)
        XCTAssertNil(store.selectedActivityDate)
        XCTAssertFalse(store.isActivityDetailPresented)
        wait(for: [rangeLoadStarted], timeout: 0.2)
    }

    func testStaleRangeLoadCannotOverwriteNewAppFilter() {
        let oldLoadStarted = expectation(description: "old range load starts")
        let releaseOldLoad = DispatchSemaphore(value: 0)
        let oldSeries = ActivityRangeTokenSeries(
            aggregation: .day,
            usage: [ActivityRangeTokenUsage(
                periodStart: date(year: 2026, month: 7, day: 1),
                requestCount: 1,
                inputTokens: 100,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheCreationTokens: 0
            )]
        )
        let currentSeries = ActivityRangeTokenSeries(
            aggregation: .day,
            usage: [ActivityRangeTokenUsage(
                periodStart: date(year: 2026, month: 7, day: 2),
                requestCount: 1,
                inputTokens: 200,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheCreationTokens: 0
            )]
        )
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            observeRefreshIntervalChanges: false,
            activityRangeTokenUsageLoader: { _, app, _, _ in
                if app == .all {
                    oldLoadStarted.fulfill()
                    _ = releaseOldLoad.wait(timeout: .now() + 1)
                    return oldSeries
                }
                return currentSeries
            }
        )
        store.selectActivityDate("2026-07-08")
        store.setTimeRangeFromFilter(.last7)
        wait(for: [oldLoadStarted], timeout: 1)

        store.appFilter = .cursor
        store.reload()

        let currentLoadFinished = expectation(description: "current range load finishes")
        waitUntil(attemptsRemaining: 50) {
            store.activityRangeTokenSeries == currentSeries && !store.isActivityRangeTokenUsageLoading
        } completion: {
            currentLoadFinished.fulfill()
        }
        wait(for: [currentLoadFinished], timeout: 1)

        releaseOldLoad.signal()
        let staleLoadFinished = expectation(description: "stale range load finishes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertEqual(store.activityRangeTokenSeries, currentSeries)
            XCTAssertFalse(store.isActivityRangeTokenUsageLoading)
            staleLoadFinished.fulfill()
        }
        wait(for: [staleLoadFinished], timeout: 1)
    }

    func testSelectActivityDateFromDateUsesCanonicalCalendarDay() {
        let now = date(year: 2026, month: 7, day: 9, hour: 10)
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            observeRefreshIntervalChanges: false,
            currentDateProvider: { now }
        )

        store.selectActivityDate(
            date(year: 2026, month: 7, day: 8, hour: 18),
            calendar: .current
        )

        XCTAssertEqual(
            store.timeRange,
            .custom(
                start: date(year: 2026, month: 7, day: 8),
                end: date(year: 2026, month: 7, day: 8)
            )
        )
        XCTAssertEqual(store.selectedActivityDate, "2026-07-08")
    }

    func testSelectZeroActivityDateKeepsSelectionAndLoadsZeroHourlyUsage() {
        let now = date(year: 2026, month: 7, day: 9, hour: 10)
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            observeRefreshIntervalChanges: false,
            currentDateProvider: { now }
        )

        store.selectActivityDate("2026-07-08")

        XCTAssertTrue(store.isHourlyTokenUsageLoading)
        XCTAssertTrue(store.hourlyTokenUsage.isEmpty)

        let loaded = expectation(description: "zero hourly usage loads")
        waitUntil(attemptsRemaining: 50) {
            store.hourlyTokenUsage.count == 24
        } completion: {
            XCTAssertEqual(store.selectedActivityDate, "2026-07-08")
            XCTAssertFalse(store.isHourlyTokenUsageLoading)
            XCTAssertTrue(store.hourlyTokenUsage.allSatisfy { !$0.hasTokenUsage && $0.requestCount == 0 })
            loaded.fulfill()
        }

        wait(for: [loaded], timeout: 1)
    }

    func testStaleHourlyLoadCannotOverwriteNewAppFilter() {
        let oldLoadStarted = expectation(description: "old hourly load starts")
        let releaseOldLoad = DispatchSemaphore(value: 0)
        let oldUsage = [hourlyUsage(hour: 1, inputTokens: 100)]
        let currentUsage = [hourlyUsage(hour: 2, inputTokens: 200)]
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            observeRefreshIntervalChanges: false,
            hourlyTokenUsageLoader: { _, app, _, _ in
                if app == .all {
                    oldLoadStarted.fulfill()
                    _ = releaseOldLoad.wait(timeout: .now() + 1)
                    return oldUsage
                }
                return currentUsage
            }
        )

        store.selectActivityDate("2026-07-08")
        wait(for: [oldLoadStarted], timeout: 1)

        store.appFilter = .cursor
        store.reload()

        let currentLoadFinished = expectation(description: "current hourly load finishes")
        waitUntil(attemptsRemaining: 50) {
            store.hourlyTokenUsage == currentUsage && !store.isHourlyTokenUsageLoading
        } completion: {
            currentLoadFinished.fulfill()
        }
        wait(for: [currentLoadFinished], timeout: 1)

        releaseOldLoad.signal()
        let staleLoadFinished = expectation(description: "stale hourly load finishes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertEqual(store.hourlyTokenUsage, currentUsage)
            XCTAssertFalse(store.isHourlyTokenUsageLoading)
            staleLoadFinished.fulfill()
        }
        wait(for: [staleLoadFinished], timeout: 1)
    }

    func testMonitoringChangeReloadsExpandedActivityWithNewAgentScope() {
        let suiteName = "AppStoreTodayRolloverTests.expandedActivityMonitoringChange"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let monitoringSettings = AgentMonitoringSettings(defaults: defaults)
        let allAgentUsage = [hourlyUsage(hour: 1, inputTokens: 100)]
        let enabledAgentUsage = [hourlyUsage(hour: 2, inputTokens: 200)]
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            monitoringSettings: monitoringSettings,
            observeRefreshIntervalChanges: false,
            hourlyTokenUsageLoader: { _, _, enabledAgents, _ in
                enabledAgents.contains(.cursor) ? allAgentUsage : enabledAgentUsage
            }
        )
        store.selectActivityDate("2026-07-08")
        let initialLoadFinished = expectation(description: "initial hourly load finishes")
        waitUntil(attemptsRemaining: 50) {
            store.hourlyTokenUsage == allAgentUsage && !store.isHourlyTokenUsageLoading
        } completion: {
            initialLoadFinished.fulfill()
        }
        wait(for: [initialLoadFinished], timeout: 1)

        monitoringSettings.enabledAgents = [.claude, .codex]

        let updatedLoadFinished = expectation(description: "updated hourly load finishes")
        waitUntil(attemptsRemaining: 50) {
            store.hourlyTokenUsage == enabledAgentUsage && !store.isHourlyTokenUsageLoading
        } completion: {
            XCTAssertEqual(store.selectedActivityDate, "2026-07-08")
            updatedLoadFinished.fulfill()
        }
        wait(for: [updatedLoadFinished], timeout: 1)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testReloadAfterDayRolloverKeepsHourlyActivityPresentedForNewToday() {
        var now = date(year: 2026, month: 7, day: 9, hour: 23)
        let oldLoadStarted = expectation(description: "old hourly load starts")
        let releaseOldLoad = DispatchSemaphore(value: 0)
        let oldUsage = [hourlyUsage(hour: 23, inputTokens: 100)]
        let newUsage = [hourlyUsage(hour: 0, inputTokens: 200)]
        let loadedDatesLock = NSLock()
        var loadedDates: [String] = []
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            observeRefreshIntervalChanges: false,
            currentDateProvider: { now },
            hourlyTokenUsageLoader: { _, _, _, date in
                loadedDatesLock.lock()
                loadedDates.append(date)
                loadedDatesLock.unlock()
                if date == "2026-07-08" {
                    oldLoadStarted.fulfill()
                    _ = releaseOldLoad.wait(timeout: .now() + 1)
                    return oldUsage
                }
                return newUsage
            }
        )
        store.selectActivityDate("2026-07-08")
        wait(for: [oldLoadStarted], timeout: 1)

        now = date(year: 2026, month: 7, day: 10, hour: 0)
        store.reload()

        let newTodayLoaded = expectation(description: "new Today hourly usage loads")
        waitUntil(attemptsRemaining: 50) {
            store.activityDetailState == .hourly(
                date: "2026-07-10",
                usage: newUsage,
                isLoading: false
            )
        } completion: {
            XCTAssertEqual(store.timeRange, .today)
            XCTAssertTrue(store.isActivityDetailPresented)
            newTodayLoaded.fulfill()
        }
        wait(for: [newTodayLoaded], timeout: 1)

        releaseOldLoad.signal()
        let staleLoadFinished = expectation(description: "stale pre-rollover load finishes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            loadedDatesLock.lock()
            let newTodayLoadCount = loadedDates.filter { $0 == "2026-07-10" }.count
            loadedDatesLock.unlock()
            XCTAssertEqual(newTodayLoadCount, 1)
            XCTAssertEqual(
                store.activityDetailState,
                .hourly(date: "2026-07-10", usage: newUsage, isLoading: false)
            )
            staleLoadFinished.fulfill()
        }
        wait(for: [staleLoadFinished], timeout: 1)
    }

    func testReloadAfterDayRolloverConvertsOpenRangeActivityToNewToday() {
        var now = date(year: 2026, month: 7, day: 9, hour: 23)
        let rangeUsage = ActivityRangeTokenSeries(
            aggregation: .day,
            usage: [ActivityRangeTokenUsage(
                periodStart: date(year: 2026, month: 7, day: 9),
                requestCount: 1,
                inputTokens: 100,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheCreationTokens: 0
            )]
        )
        let newUsage = [hourlyUsage(hour: 0, inputTokens: 200)]
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            observeRefreshIntervalChanges: false,
            currentDateProvider: { now },
            hourlyTokenUsageLoader: { _, _, _, _ in newUsage },
            activityRangeTokenUsageLoader: { _, _, _, _ in rangeUsage }
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        store.setTimeRangeFromFilter(.last7)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        store.toggleActivityDetail()

        let rangeLoaded = expectation(description: "range Activity usage loads")
        waitUntil(attemptsRemaining: 50) {
            store.activityDetailState == .range(
                range: .last7,
                series: rangeUsage,
                isLoading: false
            )
        } completion: {
            rangeLoaded.fulfill()
        }
        wait(for: [rangeLoaded], timeout: 1)

        now = date(year: 2026, month: 7, day: 10, hour: 0)
        store.reload()

        let newTodayLoaded = expectation(description: "range converts to new Today")
        waitUntil(attemptsRemaining: 50) {
            store.activityDetailState == .hourly(
                date: "2026-07-10",
                usage: newUsage,
                isLoading: false
            )
        } completion: {
            XCTAssertEqual(store.timeRange, .today)
            XCTAssertTrue(store.isActivityDetailPresented)
            newTodayLoaded.fulfill()
        }
        wait(for: [newTodayLoaded], timeout: 1)
    }

    func testReloadAfterDayRolloverKeepsClosedActivityClosed() {
        var now = date(year: 2026, month: 7, day: 9, hour: 23)
        let activityLoadStarted = expectation(description: "closed Activity should not load")
        activityLoadStarted.isInverted = true
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            observeRefreshIntervalChanges: false,
            currentDateProvider: { now },
            hourlyTokenUsageLoader: { _, _, _, _ in
                activityLoadStarted.fulfill()
                return []
            },
            activityRangeTokenUsageLoader: { _, _, _, _ in
                activityLoadStarted.fulfill()
                return .empty
            }
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        store.setTimeRangeFromFilter(.last30)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        now = date(year: 2026, month: 7, day: 10, hour: 0)
        store.reload()

        let resetFinished = expectation(description: "closed Activity resets to Today")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(store.timeRange, .today)
            XCTAssertEqual(store.activityDetailState, .closed)
            XCTAssertFalse(store.isActivityDetailPresented)
            resetFinished.fulfill()
        }

        wait(for: [resetFinished, activityLoadStarted], timeout: 1)
    }

    func testReloadClearsUnavailableYearsAndResetsYearMode() {
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            observeRefreshIntervalChanges: false
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

    /// Enables both quota providers by giving each a future expiration date,
    /// since enablement now derives from a set expiration date.
    private func enableAllProviders(_ settings: QuotaSettings) {
        let future = Date(timeIntervalSinceNow: 30 * 24 * 60 * 60)
        settings.claudeExpirationDate = future
        settings.codexExpirationDate = future
    }

    private func date(year: Int, month: Int, day: Int, hour: Int = 0) -> Date {
        let calendar = Calendar.current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func hourlyUsage(hour: Int, inputTokens: Int64) -> HourlyTokenUsage {
        HourlyTokenUsage(
            hour: hour,
            requestCount: 1,
            inputTokens: inputTokens,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0
        )
    }
}

private final class RecordingQuotaService: QuotaRefreshing {
    private(set) var providers: [QuotaProviderID] = []

    func refresh(
        provider: QuotaProviderID,
        now: Date,
        completion: @escaping (QuotaRefreshResult) -> Void
    ) {
        providers.append(provider)
        completion(QuotaRefreshResult(
            snapshot: .failure(provider: provider, status: .notInstalled, at: now),
            identityDigest: nil
        ))
    }
}

private final class BlockingQuotaService: QuotaRefreshing {
    let started = XCTestExpectation(description: "Quota refresh started")
    private var completion: ((QuotaRefreshResult) -> Void)?

    func refresh(
        provider: QuotaProviderID,
        now: Date,
        completion: @escaping (QuotaRefreshResult) -> Void
    ) {
        self.completion = completion
        started.fulfill()
    }

    func finish() {
        completion?(QuotaRefreshResult(
            snapshot: .failure(provider: .claude, status: .notInstalled, at: Date()),
            identityDigest: nil
        ))
        completion = nil
    }
}

private final class CancellableCursorUsageSyncerProbe: CancellableCursorUsageSyncing {
    let started = XCTestExpectation(description: "Cursor routine sync started")
    let cancelled = XCTestExpectation(description: "Cursor routine sync cancelled")

    func sync() throws -> SessionSyncResult {
        XCTFail("Routine Cursor sync should receive a cancellation token")
        return SessionSyncResult()
    }

    func sync(cancellation: AgentSyncCancellation?) throws -> SessionSyncResult {
        started.fulfill()
        guard let cancellation else {
            XCTFail("Routine Cursor sync should receive a cancellation token")
            return SessionSyncResult()
        }
        while cancellation.isEnabled(.cursor) {
            Thread.sleep(forTimeInterval: 0.001)
        }
        cancelled.fulfill()
        return SessionSyncResult()
    }
}
