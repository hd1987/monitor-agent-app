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

    func testUnifiedRefreshRequestsCursorSpendOnAllAndSelectionChangesStayLocal() throws {
        let database = DatabaseManager(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_786_435_200)
        let account = cursorAuthenticatedAccount(userId: 1)
        try seedCursorCache(
            database: database,
            identity: account.account.syncIdentity,
            model: "cursor-model",
            inputTokens: 100
        )
        _ = try database.mergeCursorSpendSnapshot(
            accountIdentity: account.account.syncIdentity,
            range: CursorSpendRange(timeRange: .today, now: now),
            totalCents: 500,
            updatedAt: now
        )
        _ = try database.mergeCursorSpendSnapshot(
            accountIdentity: account.account.syncIdentity,
            range: CursorSpendRange(timeRange: .last7, now: now),
            totalCents: 700,
            updatedAt: now
        )
        let refresher = RecordingCursorSpendRefresher()
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: "/missing-claude-\(UUID().uuidString)",
            codexSessionsPath: "/missing-codex-\(UUID().uuidString)",
            codexArchivedSessionsPath: "/missing-archive-\(UUID().uuidString)"
        )
        let store = AppStore(
            database: database,
            syncManager: syncManager,
            cursorSpendRefresher: refresher,
            observeRefreshIntervalChanges: false,
            currentDateProvider: { now }
        )
        store.panelDidOpen()
        wait(for: [refresher.started], timeout: 1)
        XCTAssertEqual(refresher.refreshCount, 1)

        store.appFilter = .cursor
        let todayRestored = expectation(description: "Today spend snapshot is restored")
        waitUntil(attemptsRemaining: 100) {
            store.cursorSpendSnapshot?.totalCents == 500
        } completion: {
            todayRestored.fulfill()
        }
        wait(for: [todayRestored], timeout: 1)

        store.setTimeRangeFromFilter(.last7)
        let rangeRestored = expectation(description: "Last seven days spend snapshot is restored")
        waitUntil(attemptsRemaining: 100) {
            store.cursorSpendSnapshot?.totalCents == 700
        } completion: {
            rangeRestored.fulfill()
        }
        wait(for: [rangeRestored], timeout: 1)
        XCTAssertEqual(refresher.refreshCount, 1)
        store.panelDidClose()
    }

    func testUnifiedRefreshRunsCursorSpendOnceAndWaitsForItsCompletion() throws {
        let suiteName = "AppStoreTodayRolloverTests.cursorSpendRefreshParticipant"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let refreshSettings = RefreshSettings(defaults: defaults)
        refreshSettings.interval = .never
        let database = DatabaseManager(inMemory: true)
        let account = cursorAuthenticatedAccount(userId: 1)
        try seedCursorCache(
            database: database,
            identity: account.account.syncIdentity,
            model: "cursor-model",
            inputTokens: 100
        )
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: "/missing-claude-\(UUID().uuidString)",
            codexSessionsPath: "/missing-codex-\(UUID().uuidString)",
            codexArchivedSessionsPath: "/missing-archive-\(UUID().uuidString)",
            cursorUsageSyncer: CountingCursorUsageSyncerProbe()
        )
        let refresher = ControllableCursorSpendRefresher()
        let store = AppStore(
            database: database,
            syncManager: syncManager,
            refreshSettings: refreshSettings,
            cursorSpendRefresher: refresher,
            cursorAccountResolver: StaticCursorAccountResolver(result: .success(account)),
            observeRefreshIntervalChanges: false
        )
        store.appFilter = .cursor
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        store.panelDidOpen()
        wait(for: [refresher.started], timeout: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(refresher.refreshCount, 1)
        XCTAssertTrue(store.isRefreshInProgress)
        refresher.finishNext(outcome: .failure(nil, .request))

        let refreshFinished = expectation(description: "Unified refresh waits for Cursor spend")
        waitUntil(attemptsRemaining: 100) {
            !store.isRefreshInProgress
        } completion: {
            refreshFinished.fulfill()
        }
        wait(for: [refreshFinished], timeout: 1)
        XCTAssertEqual(store.cursorRefreshFailures[.spend]?.kind, .refreshFailed)
        XCTAssertTrue(store.cursorRefreshFailureHelp?.contains("Cursor spend refresh failed") == true)
        store.panelDidClose()
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testChangingTabDoesNotCancelUnifiedSpendRefresh() throws {
        let suiteName = "AppStoreTodayRolloverTests.cursorSpendUnifiedCancellation"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let refreshSettings = RefreshSettings(defaults: defaults)
        refreshSettings.interval = .never
        let monitoringSettings = AgentMonitoringSettings(defaults: defaults)
        let database = DatabaseManager(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_786_435_200)
        let account = cursorAuthenticatedAccount(userId: 1)
        try seedCursorCache(
            database: database,
            identity: account.account.syncIdentity,
            model: "cursor-model",
            inputTokens: 100
        )
        let refreshCoordinator = PanelRefreshCoordinator(currentDateProvider: { now })
        let refresher = ControllableCursorSpendRefresher()
        let store = AppStore(
            database: database,
            refreshSettings: refreshSettings,
            monitoringSettings: monitoringSettings,
            cursorSpendRefresher: refresher,
            cursorAccountResolver: StaticCursorAccountResolver(result: .success(account)),
            refreshCoordinator: refreshCoordinator,
            observeRefreshIntervalChanges: false,
            currentDateProvider: { now }
        )
        store.appFilter = .cursor
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        store.panelDidOpen()
        wait(for: [refresher.started], timeout: 1)
        let cancellation = try XCTUnwrap(refresher.cancellations.first ?? nil)
        XCTAssertTrue(cancellation.isEnabled(.cursor))

        store.appFilter = .claude

        XCTAssertTrue(cancellation.isEnabled(.cursor))
        refresher.finishNext()
        store.panelDidClose()
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testRangeChangeDuringSpendSyncReloadsCommittedLocalSelection() throws {
        let suiteName = "AppStoreTodayRolloverTests.cursorSpendRangeDuringSync"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let refreshSettings = RefreshSettings(defaults: defaults)
        refreshSettings.interval = .never
        let database = DatabaseManager(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_786_435_200)
        let account = cursorAuthenticatedAccount(userId: 1)
        try seedCursorCache(
            database: database,
            identity: account.account.syncIdentity,
            model: "cursor-model",
            inputTokens: 100
        )
        let todayRange = CursorSpendRange(timeRange: .today, now: now)
        let last7Range = CursorSpendRange(timeRange: .last7, now: now)
        _ = try database.mergeCursorSpendSnapshot(
            accountIdentity: account.account.syncIdentity,
            range: last7Range,
            totalCents: 700,
            updatedAt: now
        )
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: "/missing-claude-\(UUID().uuidString)",
            codexSessionsPath: "/missing-codex-\(UUID().uuidString)",
            codexArchivedSessionsPath: "/missing-archive-\(UUID().uuidString)",
            cursorUsageSyncer: CountingCursorUsageSyncerProbe()
        )
        let refresher = ControllableCursorSpendRefresher()
        let store = AppStore(
            database: database,
            syncManager: syncManager,
            refreshSettings: refreshSettings,
            cursorSpendRefresher: refresher,
            cursorAccountResolver: StaticCursorAccountResolver(result: .success(account)),
            observeRefreshIntervalChanges: false,
            currentDateProvider: { now }
        )
        store.appFilter = .cursor
        store.setTimeRangeFromFilter(.today)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        store.panelDidOpen()
        wait(for: [refresher.started], timeout: 1)
        XCTAssertEqual(refresher.ranges, [todayRange])
        store.setTimeRangeFromFilter(.last7)
        let initialSelectionRestored = expectation(description: "Initial local range is restored")
        waitUntil(attemptsRemaining: 100) {
            store.cursorSpendSnapshot?.totalCents == 700
        } completion: {
            initialSelectionRestored.fulfill()
        }
        wait(for: [initialSelectionRestored], timeout: 1)

        _ = try database.mergeCursorSpendSnapshot(
            accountIdentity: account.account.syncIdentity,
            range: last7Range,
            totalCents: 800,
            updatedAt: now.addingTimeInterval(1)
        )
        refresher.finishNext(outcome: .success(CursorSpendSnapshot(
            accountIdentity: account.account.syncIdentity,
            range: todayRange,
            totalCents: 900,
            totalUpdatedAt: now.addingTimeInterval(1)
        )))

        let localSelectionReloaded = expectation(description: "Committed local range is reloaded")
        waitUntil(attemptsRemaining: 100) {
            store.cursorSpendSnapshot?.totalCents == 800 && !store.isRefreshInProgress
        } completion: {
            localSelectionReloaded.fulfill()
        }
        wait(for: [localSelectionReloaded], timeout: 1)
        store.panelDidClose()
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testUnifiedRefreshWaitsForDeferredCursorSpendAfterAccountReplacement() {
        let suiteName = "AppStoreTodayRolloverTests.deferredCursorSpendParticipant"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let refreshSettings = RefreshSettings(defaults: defaults)
        refreshSettings.interval = .never
        let database = DatabaseManager(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_786_435_200)
        let account = cursorAuthenticatedAccount(userId: 2)
        let syncer = BlockingReplacementCursorUsageSyncer(
            database: database,
            account: account,
            inputTokens: 200
        )
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: "/missing-claude-\(UUID().uuidString)",
            codexSessionsPath: "/missing-codex-\(UUID().uuidString)",
            codexArchivedSessionsPath: "/missing-archive-\(UUID().uuidString)",
            cursorUsageSyncer: syncer
        )
        let refresher = ControllableCursorSpendRefresher()
        let store = AppStore(
            database: database,
            syncManager: syncManager,
            refreshSettings: refreshSettings,
            cursorSpendRefresher: refresher,
            cursorAccountResolver: StaticCursorAccountResolver(result: .success(account)),
            observeRefreshIntervalChanges: false,
            currentDateProvider: { now }
        )
        store.appFilter = .cursor
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        store.panelDidOpen()
        wait(for: [syncer.started], timeout: 1)
        store.setTimeRangeFromFilter(.last7)
        syncer.release.signal()
        wait(for: [refresher.started], timeout: 1)

        XCTAssertTrue(store.isRefreshInProgress)
        XCTAssertEqual(refresher.refreshCount, 1)
        XCTAssertEqual(
            refresher.ranges,
            [CursorSpendRange(timeRange: .last7, now: now)]
        )
        refresher.finishNext()

        let refreshFinished = expectation(description: "Deferred Cursor spend finishes cycle")
        waitUntil(attemptsRemaining: 100) {
            !store.isRefreshInProgress
        } completion: {
            refreshFinished.fulfill()
        }
        wait(for: [refreshFinished], timeout: 1)
        store.panelDidClose()
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testChangedCursorAccountHidesOldCacheUntilAtomicReplacementCompletes() throws {
        let database = DatabaseManager(inMemory: true)
        try seedCursorCache(
            database: database,
            identity: cursorAuthenticatedAccount(userId: 1).account.syncIdentity,
            model: "account-one",
            inputTokens: 100
        )
        let secondAccount = cursorAuthenticatedAccount(userId: 2)
        let syncer = BlockingReplacementCursorUsageSyncer(
            database: database,
            account: secondAccount,
            inputTokens: 200
        )
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: "/missing-claude-\(UUID().uuidString)",
            codexSessionsPath: "/missing-codex-\(UUID().uuidString)",
            codexArchivedSessionsPath: "/missing-archive-\(UUID().uuidString)",
            cursorUsageSyncer: syncer
        )
        let store = AppStore(
            database: database,
            syncManager: syncManager,
            cursorAccountResolver: StaticCursorAccountResolver(
                result: .success(secondAccount)
            ),
            observeRefreshIntervalChanges: false
        )
        store.appFilter = .cursor

        store.panelDidOpen()
        wait(for: [syncer.started], timeout: 1)

        let oldCacheHidden = expectation(description: "Old Cursor cache is hidden")
        waitUntil(attemptsRemaining: 100) {
            store.cursorAccountPresentationState == .verifying(secondAccount.account.syncIdentity)
                && store.stats.totalRequests == 0
        } completion: {
            oldCacheHidden.fulfill()
        }
        wait(for: [oldCacheHidden], timeout: 1)

        syncer.release.signal()
        let replacementVisible = expectation(description: "New Cursor cache becomes visible")
        waitUntil(attemptsRemaining: 100) {
            store.cursorAccountPresentationState == .verified(secondAccount.account.syncIdentity)
                && store.stats.inputTokens == 200
        } completion: {
            replacementVisible.fulfill()
        }
        wait(for: [replacementVisible], timeout: 1)
        XCTAssertEqual(
            database.fetchModelDistribution(app: .cursor, range: .allTime).map(\.model),
            ["account-two"]
        )
        store.panelDidClose()
    }

    func testCursorVerificationFailureKeepsCachedDataVisibleInAll() throws {
        let database = DatabaseManager(inMemory: true)
        let identity = cursorAuthenticatedAccount(userId: 1).account.syncIdentity
        try seedCursorCache(
            database: database,
            identity: identity,
            model: "account-one",
            inputTokens: 100
        )
        let store = AppStore(
            database: database,
            cursorAccountResolver: StaticCursorAccountResolver(
                result: .failure(CursorUsageError.authenticationRejected)
            ),
            observeRefreshIntervalChanges: false
        )
        store.panelDidOpen()

        let unavailable = expectation(description: "Cursor refresh becomes unavailable")
        waitUntil(attemptsRemaining: 100) {
            store.cursorAccountPresentationState == .unavailable
                && store.stats.totalRequests == 1
        } completion: {
            unavailable.fulfill()
        }
        wait(for: [unavailable], timeout: 1)
        XCTAssertEqual(database.fetchStats(app: .cursor, range: .allTime).totalRequests, 1)
        XCTAssertEqual(
            database.getSyncState(for: CursorUsageService.syncStateKey)?.sessionId,
            identity
        )
        XCTAssertTrue(store.isCursorDataPresentationAvailable)
        XCTAssertEqual(
            store.cursorRefreshFailures[.account]?.kind,
            .signInUnavailable
        )
        XCTAssertTrue(store.hasCursorRefreshFailure)
        XCTAssertTrue(store.cursorRefreshFailureHelp?.contains("Cursor sign-in unavailable") == true)
        store.panelDidClose()
    }

    func testCursorUsageRefreshFailureMarksTabWithoutHidingCachedData() throws {
        let database = DatabaseManager(inMemory: true)
        let account = cursorAuthenticatedAccount(userId: 1)
        try seedCursorCache(
            database: database,
            identity: account.account.syncIdentity,
            model: "cached-model",
            inputTokens: 100
        )
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: "/missing-claude-\(UUID().uuidString)",
            codexSessionsPath: "/missing-codex-\(UUID().uuidString)",
            codexArchivedSessionsPath: "/missing-archive-\(UUID().uuidString)",
            cursorUsageSyncer: FailingCursorUsageSyncerProbe()
        )
        let store = AppStore(
            database: database,
            syncManager: syncManager,
            cursorAccountResolver: StaticCursorAccountResolver(result: .success(account)),
            observeRefreshIntervalChanges: false
        )
        store.panelDidOpen()

        let failed = expectation(description: "Cursor usage failure is retained")
        waitUntil(attemptsRemaining: 100) {
            store.cursorRefreshFailures[.usage]?.kind == .signInUnavailable
                && store.stats.totalRequests == 1
        } completion: {
            failed.fulfill()
        }
        wait(for: [failed], timeout: 1)
        XCTAssertEqual(store.cursorAccountPresentationState, .verified(account.account.syncIdentity))
        XCTAssertTrue(store.isCursorDataPresentationAvailable)
        XCTAssertNil(store.cursorRefreshFailures[.account])
        store.panelDidClose()
    }

    func testCursorAuthenticationFailureTakesPrecedenceInMultiComponentHelp() throws {
        let database = DatabaseManager(inMemory: true)
        let account = cursorAuthenticatedAccount(userId: 1)
        try seedCursorCache(
            database: database,
            identity: account.account.syncIdentity,
            model: "cached-model",
            inputTokens: 100
        )
        let resolver = StaticCursorAccountResolver(result: .success(account))
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: "/missing-claude-\(UUID().uuidString)",
            codexSessionsPath: "/missing-codex-\(UUID().uuidString)",
            codexArchivedSessionsPath: "/missing-archive-\(UUID().uuidString)",
            cursorUsageSyncer: RequestFailingCursorUsageSyncerProbe()
        )
        let store = AppStore(
            database: database,
            syncManager: syncManager,
            cursorAccountResolver: resolver,
            observeRefreshIntervalChanges: false
        )
        store.panelDidOpen()
        let usageFailed = expectation(description: "Cursor usage request fails")
        waitUntil(attemptsRemaining: 100) {
            store.cursorRefreshFailures[.usage]?.kind == .refreshFailed
        } completion: {
            usageFailed.fulfill()
        }
        wait(for: [usageFailed], timeout: 1)
        store.panelDidClose()

        resolver.setResult(.failure(CursorUsageError.authenticationRejected))
        store.panelDidOpen()
        let authenticationFailed = expectation(description: "Cursor authentication fails")
        waitUntil(attemptsRemaining: 100) {
            store.cursorRefreshFailures[.account]?.kind == .signInUnavailable
                && store.cursorRefreshFailures[.usage]?.kind == .refreshFailed
        } completion: {
            authenticationFailed.fulfill()
        }
        wait(for: [authenticationFailed], timeout: 1)
        XCTAssertTrue(store.cursorRefreshFailureHelp?.hasPrefix("Cursor sign-in unavailable · ") == true)
        store.panelDidClose()
    }

    func testCursorMultiComponentRequestHelpUsesLastFailureLabel() throws {
        let database = DatabaseManager(inMemory: true)
        let account = cursorAuthenticatedAccount(userId: 1)
        let now = Date(timeIntervalSince1970: 1_786_435_200)
        try seedCursorCache(
            database: database,
            identity: account.account.syncIdentity,
            model: "cached-model",
            inputTokens: 100
        )
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: "/missing-claude-\(UUID().uuidString)",
            codexSessionsPath: "/missing-codex-\(UUID().uuidString)",
            codexArchivedSessionsPath: "/missing-archive-\(UUID().uuidString)",
            cursorUsageSyncer: RequestFailingCursorUsageSyncerProbe()
        )
        let refresher = ControllableCursorSpendRefresher()
        let store = AppStore(
            database: database,
            syncManager: syncManager,
            cursorSpendRefresher: refresher,
            cursorAccountResolver: StaticCursorAccountResolver(result: .success(account)),
            observeRefreshIntervalChanges: false,
            currentDateProvider: { now }
        )
        store.appFilter = .cursor
        store.panelDidOpen()
        wait(for: [refresher.started], timeout: 1)
        refresher.finishNext(outcome: .failure(nil, .request))

        let failed = expectation(description: "Cursor usage and spend fail")
        waitUntil(attemptsRemaining: 100) {
            store.cursorRefreshFailures[.usage]?.kind == .refreshFailed
                && store.cursorRefreshFailures[.spend]?.kind == .refreshFailed
        } completion: {
            failed.fulfill()
        }
        wait(for: [failed], timeout: 1)
        XCTAssertTrue(
            store.cursorRefreshFailureHelp?.contains(
                "Cursor usage and spend refresh failed · Last failure "
            ) == true
        )
        store.panelDidClose()
    }

    func testCursorAccountReplacementClearsPreviousAccountFailures() throws {
        let database = DatabaseManager(inMemory: true)
        let firstAccount = cursorAuthenticatedAccount(userId: 1)
        let secondAccount = cursorAuthenticatedAccount(userId: 2)
        try seedCursorCache(
            database: database,
            identity: firstAccount.account.syncIdentity,
            model: "account-one",
            inputTokens: 100
        )
        let resolver = StaticCursorAccountResolver(result: .success(firstAccount))
        let syncer = FailingThenBlockingReplacementCursorUsageSyncer(
            database: database,
            replacementAccount: secondAccount
        )
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: "/missing-claude-\(UUID().uuidString)",
            codexSessionsPath: "/missing-codex-\(UUID().uuidString)",
            codexArchivedSessionsPath: "/missing-archive-\(UUID().uuidString)",
            cursorUsageSyncer: syncer
        )
        let store = AppStore(
            database: database,
            syncManager: syncManager,
            cursorAccountResolver: resolver,
            observeRefreshIntervalChanges: false
        )
        store.panelDidOpen()
        let firstFailure = expectation(description: "First account failure is recorded")
        waitUntil(attemptsRemaining: 100) {
            store.cursorRefreshFailures[.usage]?.kind == .refreshFailed
        } completion: {
            firstFailure.fulfill()
        }
        wait(for: [firstFailure], timeout: 1)
        store.panelDidClose()

        resolver.setResult(.success(secondAccount))
        store.panelDidOpen()
        wait(for: [syncer.replacementStarted], timeout: 1)
        XCTAssertEqual(
            store.cursorAccountPresentationState,
            .verifying(secondAccount.account.syncIdentity)
        )
        XCTAssertTrue(store.cursorRefreshFailures.isEmpty)

        syncer.releaseReplacement.signal()
        let replaced = expectation(description: "Replacement account becomes visible")
        waitUntil(attemptsRemaining: 100) {
            store.cursorAccountPresentationState == .verified(secondAccount.account.syncIdentity)
        } completion: {
            replaced.fulfill()
        }
        wait(for: [replaced], timeout: 1)
        XCTAssertTrue(store.cursorRefreshFailures.isEmpty)
        store.panelDidClose()
    }

    func testCursorActivityLoadRejectsAccountReplacementBeforePublication() throws {
        let database = DatabaseManager(inMemory: true)
        let firstAccount = cursorAuthenticatedAccount(userId: 1)
        let secondAccount = cursorAuthenticatedAccount(userId: 2)
        try seedCursorCache(
            database: database,
            identity: firstAccount.account.syncIdentity,
            model: "account-one",
            inputTokens: 100
        )
        let loaderStarted = DispatchSemaphore(value: 0)
        let releaseLoader = DispatchSemaphore(value: 0)
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: "/missing-claude-\(UUID().uuidString)",
            codexSessionsPath: "/missing-codex-\(UUID().uuidString)",
            codexArchivedSessionsPath: "/missing-archive-\(UUID().uuidString)",
            cursorUsageSyncer: CountingCursorUsageSyncerProbe()
        )
        let store = AppStore(
            database: database,
            syncManager: syncManager,
            cursorAccountResolver: StaticCursorAccountResolver(result: .success(firstAccount)),
            observeRefreshIntervalChanges: false,
            hourlyTokenUsageLoader: { _, _, enabledAgents, _ in
                guard enabledAgents.contains(.cursor) else { return [] }
                loaderStarted.signal()
                _ = releaseLoader.wait(timeout: .now() + 2)
                return [HourlyTokenUsage(
                    hour: 12,
                    requestCount: 1,
                    inputTokens: 200,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheCreationTokens: 0
                )]
            }
        )
        store.appFilter = .cursor
        store.panelDidOpen()

        let verified = expectation(description: "Initial Cursor account is verified")
        waitUntil(attemptsRemaining: 100) {
            store.cursorAccountPresentationState == .verified(firstAccount.account.syncIdentity)
        } completion: {
            verified.fulfill()
        }
        wait(for: [verified], timeout: 1)
        store.panelDidClose()

        store.selectActivityDate("2026-08-11")
        XCTAssertEqual(loaderStarted.wait(timeout: .now() + 1), .success)
        try seedCursorCache(
            database: database,
            identity: secondAccount.account.syncIdentity,
            model: "account-two",
            inputTokens: 200
        )
        releaseLoader.signal()

        let staleLoadRejected = expectation(description: "Replaced account load is rejected")
        waitUntil(attemptsRemaining: 100) {
            !store.isHourlyTokenUsageLoading && store.hourlyTokenUsage.isEmpty
        } completion: {
            staleLoadRejected.fulfill()
        }
        wait(for: [staleLoadRejected], timeout: 1)
        XCTAssertFalse(store.isCursorDataPresentationAvailable)
    }

    func testCursorVerificationFailureRetainsCachedPresentationAndSpend() throws {
        let database = DatabaseManager(inMemory: true)
        let account = cursorAuthenticatedAccount(userId: 1)
        let now = Date()
        try seedCursorCache(
            database: database,
            identity: account.account.syncIdentity,
            model: "account-one",
            inputTokens: 100
        )
        let spendRange = CursorSpendRange(timeRange: .today, now: now)
        _ = try database.mergeCursorSpendSnapshot(
            accountIdentity: account.account.syncIdentity,
            range: spendRange,
            totalCents: 500,
            updatedAt: now
        )
        let resolver = StaticCursorAccountResolver(result: .success(account))
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: "/missing-claude-\(UUID().uuidString)",
            codexSessionsPath: "/missing-codex-\(UUID().uuidString)",
            codexArchivedSessionsPath: "/missing-archive-\(UUID().uuidString)",
            cursorUsageSyncer: CountingCursorUsageSyncerProbe()
        )
        let store = AppStore(
            database: database,
            syncManager: syncManager,
            cursorAccountResolver: resolver,
            observeRefreshIntervalChanges: false,
            currentDateProvider: { now }
        )
        let selectedYear = Calendar.current.component(.year, from: now)
        store.appFilter = .cursor
        store.heatmapMode = .year(selectedYear)
        store.panelDidOpen()

        let verified = expectation(description: "Cached Cursor presentation becomes verified")
        waitUntil(attemptsRemaining: 100) {
            store.cursorAccountPresentationState == .verified(account.account.syncIdentity)
                && store.stats.totalRequests == 1
                && !store.heatmap.isEmpty
                && !store.modelDistribution.isEmpty
                && store.cursorSpendSnapshot?.totalCents == 500
        } completion: {
            verified.fulfill()
        }
        wait(for: [verified], timeout: 1)
        store.panelDidClose()

        resolver.setResult(.failure(CursorUsageError.authenticationRejected))
        store.panelDidOpen()

        XCTAssertEqual(store.cursorAccountPresentationState, .verifying(nil))
        XCTAssertEqual(store.stats.totalRequests, 1)
        XCTAssertEqual(store.stats.totalSessions, 1)
        XCTAssertEqual(store.stats.totalTokens, 100)
        XCTAssertFalse(store.heatmap.isEmpty)
        XCTAssertFalse(store.modelDistribution.isEmpty)
        XCTAssertFalse(store.availableYears.isEmpty)
        XCTAssertEqual(store.cursorSpendSnapshot?.totalCents, 500)

        let unavailable = expectation(description: "Cursor verification failure settles")
        waitUntil(attemptsRemaining: 100) {
            store.cursorAccountPresentationState == .unavailable
        } completion: {
            unavailable.fulfill()
        }
        wait(for: [unavailable], timeout: 1)
        XCTAssertEqual(store.heatmapMode, .year(selectedYear))
        XCTAssertTrue(store.isCursorDataPresentationAvailable)
        XCTAssertEqual(store.stats.totalRequests, 1)
        XCTAssertEqual(store.cursorSpendSnapshot?.totalCents, 500)

        XCTAssertEqual(
            store.cursorRefreshFailures[.account]?.kind,
            .signInUnavailable
        )
        resolver.setResult(.success(account))
        store.panelDidClose()
        store.panelDidOpen()
        let recovered = expectation(description: "Cursor account failure clears after recovery")
        waitUntil(attemptsRemaining: 100) {
            store.cursorAccountPresentationState == .verified(account.account.syncIdentity)
                && store.cursorRefreshFailures[.account] == nil
        } completion: {
            recovered.fulfill()
        }
        wait(for: [recovered], timeout: 1)
        store.panelDidClose()
    }

    func testPanelOpenVerifiesCursorEvenWhenUnifiedRefreshIsThrottled() {
        let suiteName = "AppStoreTodayRolloverTests.cursorVerificationThrottle"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(RefreshInterval.fiveMinutes.rawValue, forKey: "refreshInterval")
        let resolver = StaticCursorAccountResolver(
            result: .success(cursorAuthenticatedAccount(userId: 1))
        )
        let database = DatabaseManager(inMemory: true)
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: "/missing-claude-\(UUID().uuidString)",
            codexSessionsPath: "/missing-codex-\(UUID().uuidString)",
            codexArchivedSessionsPath: "/missing-archive-\(UUID().uuidString)"
        )
        let store = AppStore(
            database: database,
            syncManager: syncManager,
            refreshSettings: RefreshSettings(defaults: defaults),
            cursorAccountResolver: resolver,
            observeRefreshIntervalChanges: false
        )

        store.panelDidOpen()
        let firstVerification = expectation(description: "First Cursor verification finishes")
        waitUntil(attemptsRemaining: 100) {
            resolver.callCount > 0
        } completion: {
            firstVerification.fulfill()
        }
        wait(for: [firstVerification], timeout: 1)
        store.panelDidClose()
        let firstCallCount = resolver.callCount

        store.panelDidOpen()
        let throttledVerification = expectation(description: "Throttled open still verifies Cursor")
        waitUntil(attemptsRemaining: 100) {
            resolver.callCount > firstCallCount
        } completion: {
            throttledVerification.fulfill()
        }
        wait(for: [throttledVerification], timeout: 1)
        store.panelDidClose()
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDisablingCursorCancelsAccountReplacementBeforeCommit() throws {
        let suiteName = "AppStoreTodayRolloverTests.cancelCursorAccountReplacement"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let monitoringSettings = AgentMonitoringSettings(defaults: defaults)
        let database = DatabaseManager(inMemory: true)
        let firstIdentity = cursorAuthenticatedAccount(userId: 1).account.syncIdentity
        try seedCursorCache(
            database: database,
            identity: firstIdentity,
            model: "account-one",
            inputTokens: 100
        )
        let secondAccount = cursorAuthenticatedAccount(userId: 2)
        let syncer = BlockingReplacementCursorUsageSyncer(
            database: database,
            account: secondAccount,
            inputTokens: 200
        )
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: "/missing-claude-\(UUID().uuidString)",
            codexSessionsPath: "/missing-codex-\(UUID().uuidString)",
            codexArchivedSessionsPath: "/missing-archive-\(UUID().uuidString)",
            cursorUsageSyncer: syncer
        )
        let store = AppStore(
            database: database,
            syncManager: syncManager,
            monitoringSettings: monitoringSettings,
            cursorAccountResolver: StaticCursorAccountResolver(
                result: .success(secondAccount)
            ),
            observeRefreshIntervalChanges: false
        )

        store.panelDidOpen()
        wait(for: [syncer.started], timeout: 1)
        monitoringSettings.enabledAgents = [.claude, .codex]
        syncer.release.signal()

        let cancellationFinished = expectation(description: "Cursor replacement cancellation finishes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            cancellationFinished.fulfill()
        }
        wait(for: [cancellationFinished], timeout: 1)
        XCTAssertEqual(
            database.getSyncState(for: CursorUsageService.syncStateKey)?.sessionId,
            firstIdentity
        )
        XCTAssertEqual(store.cursorAccountPresentationState, .unverified)
        store.panelDidClose()
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testCancelledSameAccountSyncCannotInvalidateNewerGeneration() throws {
        let suiteName = "AppStoreTodayRolloverTests.sameAccountSyncGeneration"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(RefreshInterval.fiveMinutes.rawValue, forKey: "refreshInterval")
        let database = DatabaseManager(inMemory: true)
        let oldAccount = cursorAuthenticatedAccount(userId: 1)
        let currentAccount = cursorAuthenticatedAccount(userId: 2)
        try seedCursorCache(
            database: database,
            identity: oldAccount.account.syncIdentity,
            model: "old-account",
            inputTokens: 100
        )
        let syncer = BlockingThenSuccessfulCursorUsageSyncer(
            database: database,
            account: currentAccount
        )
        let secondRequestSubmitted = expectation(description: "Second same-account sync is submitted")
        let submissionLock = NSLock()
        var submissionCount = 0
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: "/missing-claude-\(UUID().uuidString)",
            codexSessionsPath: "/missing-codex-\(UUID().uuidString)",
            codexArchivedSessionsPath: "/missing-archive-\(UUID().uuidString)",
            cursorUsageSyncer: syncer,
            beforeCursorDrainSubmission: {
                submissionLock.lock()
                submissionCount += 1
                let isSecondSubmission = submissionCount == 2
                submissionLock.unlock()
                if isSecondSubmission {
                    secondRequestSubmitted.fulfill()
                }
            }
        )
        let refreshCoordinator = PanelRefreshCoordinator()
        let refreshCoordinatorSettled = expectation(description: "Refresh throttle is primed")
        refreshCoordinator.start(interval: .fiveMinutes) { completion in
            completion()
            DispatchQueue.main.async {
                refreshCoordinatorSettled.fulfill()
            }
        }
        wait(for: [refreshCoordinatorSettled], timeout: 1)
        let store = AppStore(
            database: database,
            syncManager: syncManager,
            refreshSettings: RefreshSettings(defaults: defaults),
            cursorAccountResolver: StaticCursorAccountResolver(result: .success(currentAccount)),
            refreshCoordinator: refreshCoordinator,
            observeRefreshIntervalChanges: false
        )
        store.appFilter = .cursor
        store.panelDidOpen()

        wait(for: [syncer.firstStarted], timeout: 1)

        store.appFilter = .all
        wait(for: [secondRequestSubmitted], timeout: 1)
        syncer.releaseFirst.signal()

        let verified = expectation(description: "Newer same-account sync remains authoritative")
        waitUntil(attemptsRemaining: 100) {
            store.cursorAccountPresentationState == .verified(currentAccount.account.syncIdentity)
                && database.getSyncState(
                    for: CursorUsageService.syncStateKey
                )?.sessionId == currentAccount.account.syncIdentity
        } completion: {
            verified.fulfill()
        }
        wait(for: [verified], timeout: 1)
        store.panelDidClose()
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDisablingCursorWhileAccountResolutionIsPendingDoesNotStartSync() {
        let suiteName = "AppStoreTodayRolloverTests.cancelPendingCursorResolution"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let monitoringSettings = AgentMonitoringSettings(defaults: defaults)
        let resolver = BlockingCursorAccountResolver(
            account: cursorAuthenticatedAccount(userId: 2)
        )
        let syncer = CountingCursorUsageSyncerProbe()
        let database = DatabaseManager(inMemory: true)
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: "/missing-claude-\(UUID().uuidString)",
            codexSessionsPath: "/missing-codex-\(UUID().uuidString)",
            codexArchivedSessionsPath: "/missing-archive-\(UUID().uuidString)",
            cursorUsageSyncer: syncer
        )
        let store = AppStore(
            database: database,
            syncManager: syncManager,
            monitoringSettings: monitoringSettings,
            cursorAccountResolver: resolver,
            observeRefreshIntervalChanges: false
        )

        store.panelDidOpen()
        let resolutionStarted = expectation(description: "Cursor resolution starts")
        waitUntil(attemptsRemaining: 100) {
            resolver.callCount > 0
        } completion: {
            resolutionStarted.fulfill()
        }
        wait(for: [resolutionStarted], timeout: 1)

        monitoringSettings.enabledAgents = [.claude, .codex]
        resolver.releasePendingCalls()

        let callbacksSettled = expectation(description: "Rejected resolutions settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            callbacksSettled.fulfill()
        }
        wait(for: [callbacksSettled], timeout: 1)
        XCTAssertEqual(syncer.syncCount, 0)
        XCTAssertEqual(store.cursorAccountPresentationState, .unverified)
        store.panelDidClose()
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testAccountResolutionFinishingDuringRebuildDoesNotStartSync() {
        let resolver = BlockingCursorAccountResolver(
            account: cursorAuthenticatedAccount(userId: 2)
        )
        let syncer = CountingCursorUsageSyncerProbe()
        let database = DatabaseManager(inMemory: true)
        let syncManager = SessionSyncManager(
            database: database,
            claudeProjectsPath: "/missing-claude-\(UUID().uuidString)",
            codexSessionsPath: "/missing-codex-\(UUID().uuidString)",
            codexArchivedSessionsPath: "/missing-archive-\(UUID().uuidString)",
            cursorUsageSyncer: syncer
        )
        let store = AppStore(
            database: database,
            syncManager: syncManager,
            cursorAccountResolver: resolver,
            observeRefreshIntervalChanges: false
        )

        store.panelDidOpen()
        let resolutionStarted = expectation(description: "Cursor resolution starts")
        waitUntil(attemptsRemaining: 100) {
            resolver.callCount > 0
        } completion: {
            resolutionStarted.fulfill()
        }
        wait(for: [resolutionStarted], timeout: 1)

        store.isRebuildingUsageData = true
        resolver.releasePendingCalls()
        let callbackSettled = expectation(description: "Rebuild rejects Cursor resolution")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            callbackSettled.fulfill()
        }
        wait(for: [callbackSettled], timeout: 1)
        XCTAssertEqual(syncer.syncCount, 0)
        XCTAssertEqual(store.cursorAccountPresentationState, .verifying(nil))
        store.isRebuildingUsageData = false
        store.panelDidClose()
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

    private func cursorAuthenticatedAccount(userId: Int) -> CursorAuthenticatedAccount {
        let account = try! JSONDecoder().decode(
            CursorAccount.self,
            from: Data(#"{"userId":\#(userId),"teamId":7}"#.utf8)
        )
        return CursorAuthenticatedAccount(token: "token-\(userId)", account: account)
    }

    private func seedCursorCache(
        database: DatabaseManager,
        identity: String,
        model: String,
        inputTokens: Int
    ) throws {
        let record = ParsedRecord(
            requestId: "cursor:\(model)",
            appType: AgentID.cursor.appType,
            model: model,
            inputTokens: inputTokens,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            sessionId: model,
            createdAt: Int(Date().timeIntervalSince1970)
        )
        let state = SyncState(
            filePath: CursorUsageService.syncStateKey,
            byteOffset: 1,
            recordCount: 1,
            sessionId: identity,
            model: nil,
            lastModified: 1,
            lastSyncedAt: 1
        )
        try database.replaceAppRecords(
            appType: AgentID.cursor.appType,
            records: [record],
            state: state
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

private final class RecordingCursorSpendRefresher: CursorSpendRefreshing {
    let started = XCTestExpectation(description: "Cursor spend refresh started")
    private(set) var refreshCount = 0

    func refresh(
        range: CursorSpendRange,
        expectedAccountIdentity: String?,
        force: Bool,
        cancellation: AgentSyncCancellation?,
        completion: @escaping (CursorSpendRefreshOutcome) -> Void
    ) {
        refreshCount += 1
        started.fulfill()
        completion(.cancelled)
    }
}

private final class ControllableCursorSpendRefresher: CursorSpendRefreshing {
    let started = XCTestExpectation(description: "Cursor spend refresh started")
    private let lock = NSLock()
    private var completions: [(CursorSpendRefreshOutcome) -> Void] = []
    private var storedRanges: [CursorSpendRange] = []
    private var storedCancellations: [AgentSyncCancellation?] = []

    var refreshCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedRanges.count
    }

    var ranges: [CursorSpendRange] {
        lock.lock()
        defer { lock.unlock() }
        return storedRanges
    }

    var cancellations: [AgentSyncCancellation?] {
        lock.lock()
        defer { lock.unlock() }
        return storedCancellations
    }

    func refresh(
        range: CursorSpendRange,
        expectedAccountIdentity: String?,
        force: Bool,
        cancellation: AgentSyncCancellation?,
        completion: @escaping (CursorSpendRefreshOutcome) -> Void
    ) {
        lock.lock()
        storedRanges.append(range)
        storedCancellations.append(cancellation)
        completions.append(completion)
        lock.unlock()
        started.fulfill()
    }

    func finishNext(outcome: CursorSpendRefreshOutcome = .cancelled) {
        lock.lock()
        let completion = completions.isEmpty ? nil : completions.removeFirst()
        lock.unlock()
        completion?(outcome)
    }
}

private final class StaticCursorAccountResolver: CursorAccountResolving {
    private let lock = NSLock()
    private var result: Result<CursorAuthenticatedAccount, Error>
    private var storedCallCount = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCallCount
    }

    init(result: Result<CursorAuthenticatedAccount, Error>) {
        self.result = result
    }

    func resolve(
        force: Bool,
        cancellation: AgentSyncCancellation?
    ) throws -> CursorAuthenticatedAccount {
        lock.lock()
        storedCallCount += 1
        let result = result
        lock.unlock()
        return try result.get()
    }

    func setResult(_ result: Result<CursorAuthenticatedAccount, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }
}

private final class BlockingCursorAccountResolver: CursorAccountResolving {
    private let account: CursorAuthenticatedAccount
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedCallCount = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCallCount
    }

    init(account: CursorAuthenticatedAccount) {
        self.account = account
    }

    func resolve(
        force: Bool,
        cancellation: AgentSyncCancellation?
    ) throws -> CursorAuthenticatedAccount {
        lock.lock()
        storedCallCount += 1
        lock.unlock()
        _ = release.wait(timeout: .now() + 2)
        return account
    }

    func releasePendingCalls() {
        for _ in 0..<4 {
            release.signal()
        }
    }
}

private final class CountingCursorUsageSyncerProbe: CursorUsageSyncing {
    private let lock = NSLock()
    private var storedSyncCount = 0

    var syncCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedSyncCount
    }

    func sync() throws -> SessionSyncResult {
        lock.lock()
        storedSyncCount += 1
        lock.unlock()
        return SessionSyncResult(filesSynced: 1, recordsSynced: 0)
    }
}

private struct FailingCursorUsageSyncerProbe: CursorUsageSyncing {
    func sync() throws -> SessionSyncResult {
        throw CursorUsageError.authenticationRejected
    }
}

private struct RequestFailingCursorUsageSyncerProbe: CursorUsageSyncing {
    func sync() throws -> SessionSyncResult {
        throw CursorUsageError.requestFailed
    }
}

private final class FailingThenBlockingReplacementCursorUsageSyncer: CancellableCursorUsageSyncing {
    let replacementStarted = XCTestExpectation(description: "Replacement Cursor sync starts")
    let releaseReplacement = DispatchSemaphore(value: 0)
    private let database: DatabaseManager
    private let replacementAccount: CursorAuthenticatedAccount
    private let lock = NSLock()
    private var syncCount = 0

    init(database: DatabaseManager, replacementAccount: CursorAuthenticatedAccount) {
        self.database = database
        self.replacementAccount = replacementAccount
    }

    func sync() throws -> SessionSyncResult {
        try sync(cancellation: nil)
    }

    func sync(cancellation: AgentSyncCancellation?) throws -> SessionSyncResult {
        lock.lock()
        let currentSync = syncCount
        syncCount += 1
        lock.unlock()
        if currentSync == 0 {
            throw CursorUsageError.requestFailed
        }
        if currentSync == 1 {
            replacementStarted.fulfill()
            _ = releaseReplacement.wait(timeout: .now() + 2)
        }
        guard cancellation?.isEnabled(.cursor) != false else {
            throw CursorUsageError.cancelled
        }
        let identity = replacementAccount.account.syncIdentity
        let state = SyncState(
            filePath: CursorUsageService.syncStateKey,
            byteOffset: Int64(currentSync + 1),
            recordCount: 0,
            sessionId: identity,
            model: nil,
            lastModified: currentSync + 1,
            lastSyncedAt: currentSync + 1
        )
        try database.replaceAppRecords(
            appType: AgentID.cursor.appType,
            records: [],
            state: state
        )
        return SessionSyncResult(filesSynced: 1, recordsSynced: 0)
    }
}

private final class BlockingReplacementCursorUsageSyncer: CancellableCursorUsageSyncing {
    let started = XCTestExpectation(description: "Cursor account replacement starts")
    let release = DispatchSemaphore(value: 0)
    private let database: DatabaseManager
    private let account: CursorAuthenticatedAccount
    private let inputTokens: Int

    init(
        database: DatabaseManager,
        account: CursorAuthenticatedAccount,
        inputTokens: Int
    ) {
        self.database = database
        self.account = account
        self.inputTokens = inputTokens
    }

    func sync() throws -> SessionSyncResult {
        try sync(cancellation: nil)
    }

    func sync(cancellation: AgentSyncCancellation?) throws -> SessionSyncResult {
        started.fulfill()
        _ = release.wait(timeout: .now() + 2)
        guard cancellation?.isEnabled(.cursor) != false else {
            throw CursorUsageError.cancelled
        }
        let record = ParsedRecord(
            requestId: "cursor:account-two",
            appType: AgentID.cursor.appType,
            model: "account-two",
            inputTokens: inputTokens,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            sessionId: "account-two",
            createdAt: Int(Date().timeIntervalSince1970)
        )
        let state = SyncState(
            filePath: CursorUsageService.syncStateKey,
            byteOffset: 2,
            recordCount: 1,
            sessionId: account.account.syncIdentity,
            model: nil,
            lastModified: 2,
            lastSyncedAt: 2
        )
        try database.replaceAppRecords(
            appType: AgentID.cursor.appType,
            records: [record],
            state: state
        )
        return SessionSyncResult(filesSynced: 1, recordsSynced: 1)
    }
}

private final class BlockingThenSuccessfulCursorUsageSyncer: CancellableCursorUsageSyncing {
    let firstStarted = XCTestExpectation(description: "First same-account sync starts")
    let releaseFirst = DispatchSemaphore(value: 0)
    private let database: DatabaseManager
    private let account: CursorAuthenticatedAccount
    private let lock = NSLock()
    private var syncCount = 0

    init(database: DatabaseManager, account: CursorAuthenticatedAccount) {
        self.database = database
        self.account = account
    }

    func sync() throws -> SessionSyncResult {
        try sync(cancellation: nil)
    }

    func sync(cancellation: AgentSyncCancellation?) throws -> SessionSyncResult {
        lock.lock()
        let index = syncCount
        syncCount += 1
        lock.unlock()
        if index == 0 {
            firstStarted.fulfill()
            _ = releaseFirst.wait(timeout: .now() + 2)
            guard cancellation?.isEnabled(.cursor) != false else {
                throw CursorUsageError.cancelled
            }
        }
        let state = SyncState(
            filePath: CursorUsageService.syncStateKey,
            byteOffset: Int64(index + 1),
            recordCount: 0,
            sessionId: account.account.syncIdentity,
            model: nil,
            lastModified: index + 1,
            lastSyncedAt: index + 1
        )
        try database.replaceAppRecords(
            appType: AgentID.cursor.appType,
            records: [],
            state: state
        )
        return SessionSyncResult(filesSynced: 1, recordsSynced: 0)
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
