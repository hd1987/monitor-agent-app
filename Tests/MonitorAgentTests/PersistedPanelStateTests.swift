import XCTest
@testable import MonitorAgent

final class PersistedPanelStateTests: XCTestCase {
    func testActivityPresentationIntentRestoresOneCurrentRangeLoad() {
        let suiteName = "PersistedPanelStateTests.activity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = ActivityPresentationSettings(
            defaults: defaults,
            environment: .production
        )
        settings.isPresented = true
        let now = Date(timeIntervalSince1970: 1_784_122_400)
        let expectedUsage = [HourlyTokenUsage(
            hour: 10,
            requestCount: 1,
            inputTokens: 100,
            outputTokens: 20,
            cacheReadTokens: 10,
            cacheCreationTokens: 5
        )]
        let loadLock = NSLock()
        var loadCount = 0
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            activityPresentationSettings: settings,
            observeRefreshIntervalChanges: false,
            currentDateProvider: { now },
            hourlyTokenUsageLoader: { _, _, _, _ in
                loadLock.lock()
                loadCount += 1
                loadLock.unlock()
                return expectedUsage
            }
        )

        XCTAssertTrue(store.isActivityDetailPresented)
        let restored = expectation(description: "Activity intent restores")
        poll {
            guard store.hourlyTokenUsage == expectedUsage,
                  !store.isHourlyTokenUsageLoading else { return false }
            loadLock.lock()
            let count = loadCount
            loadLock.unlock()
            XCTAssertEqual(count, 1)
            restored.fulfill()
            return true
        }
        wait(for: [restored], timeout: 1)
    }

    func testActivityClosePersistsAndEnvironmentKeysRemainIsolated() {
        let suiteName = "PersistedPanelStateTests.activityIsolation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let production = ActivityPresentationSettings(defaults: defaults, environment: .production)
        let development = ActivityPresentationSettings(defaults: defaults, environment: .development)
        production.isPresented = true

        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            activityPresentationSettings: production,
            observeRefreshIntervalChanges: false
        )
        store.closeActivityDetail()

        XCTAssertFalse(production.isPresented)
        XCTAssertFalse(development.isPresented)
        development.isPresented = true
        XCTAssertFalse(production.isPresented)
        XCTAssertTrue(development.isPresented)
    }

    func testMonitoringClosurePersistsActivityIntentAcrossStoreRestart() {
        let suiteName = "PersistedPanelStateTests.activityMonitoring.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let monitoringSettings = AgentMonitoringSettings(defaults: defaults)
        let presentationSettings = ActivityPresentationSettings(
            defaults: defaults,
            environment: .production
        )
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            monitoringSettings: monitoringSettings,
            activityPresentationSettings: presentationSettings,
            observeRefreshIntervalChanges: false
        )
        store.appFilter = .codex
        store.selectActivityDate("2026-07-09")

        monitoringSettings.enabledAgents = [.claude, .cursor]

        XCTAssertFalse(presentationSettings.isPresented)
        XCTAssertFalse(store.isActivityDetailPresented)
        let restartedStore = AppStore(
            database: DatabaseManager(inMemory: true),
            monitoringSettings: monitoringSettings,
            activityPresentationSettings: presentationSettings,
            observeRefreshIntervalChanges: false
        )
        XCTAssertFalse(restartedStore.isActivityDetailPresented)
    }

    func testNoMonitoredAgentsClearsPersistedActivityIntentAtStartup() {
        let suiteName = "PersistedPanelStateTests.activityNoAgents.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let monitoringSettings = AgentMonitoringSettings(defaults: defaults)
        monitoringSettings.enabledAgents = []
        let presentationSettings = ActivityPresentationSettings(
            defaults: defaults,
            environment: .production
        )
        presentationSettings.isPresented = true

        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            monitoringSettings: monitoringSettings,
            activityPresentationSettings: presentationSettings,
            observeRefreshIntervalChanges: false
        )

        XCTAssertFalse(store.isActivityDetailPresented)
        XCTAssertFalse(presentationSettings.isPresented)
    }

    func testQuotaCacheRestoresOnlyMatchingIdentityAndPrunesExpiredWindow() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-cache-\(UUID().uuidString).json").path
        let cache = QuotaSnapshotCache(path: path)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = quotaSnapshot(
            fetchedAt: now.addingTimeInterval(-6 * 60 * 60),
            fiveHourReset: now.addingTimeInterval(-1),
            weeklyReset: now.addingTimeInterval(24 * 60 * 60)
        )
        cache.store(snapshot, identityDigest: "account-a")

        let matching = expectation(description: "Matching cache loads")
        cache.load(provider: .codex, identityDigest: "account-a", now: now) { restored in
            XCTAssertNil(restored?.fiveHour)
            XCTAssertEqual(restored?.weekly, snapshot.weekly)
            matching.fulfill()
        }
        wait(for: [matching], timeout: 1)

        let mismatching = expectation(description: "Mismatching cache is rejected")
        cache.load(provider: .codex, identityDigest: "account-b", now: now) { restored in
            XCTAssertNil(restored)
            mismatching.fulfill()
        }
        wait(for: [mismatching], timeout: 1)
    }

    func testQuotaCacheSerializesProviderWritesAndIgnoresCorruption() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-cache-\(UUID().uuidString)")
        let path = directory.appendingPathComponent("quota-snapshots.json").path
        let cache = QuotaSnapshotCache(path: path)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let claude = quotaSnapshot(provider: .claude)
        let codex = quotaSnapshot(provider: .codex)
        cache.store(claude, identityDigest: "claude-account")
        cache.store(codex, identityDigest: "codex-account")

        let bothProviders = expectation(description: "Both provider writes survive")
        bothProviders.expectedFulfillmentCount = 2
        cache.load(provider: .claude, identityDigest: "claude-account", now: now) { snapshot in
            XCTAssertEqual(snapshot, claude)
            bothProviders.fulfill()
        }
        cache.load(provider: .codex, identityDigest: "codex-account", now: now) { snapshot in
            XCTAssertEqual(snapshot, codex)
            bothProviders.fulfill()
        }
        wait(for: [bothProviders], timeout: 1)

        let corruptPath = directory.appendingPathComponent("corrupt.json")
        try Data("not-json".utf8).write(to: corruptPath)
        let corruptCache = QuotaSnapshotCache(path: corruptPath.path)
        let ignored = expectation(description: "Corrupt cache is ignored")
        corruptCache.load(provider: .codex, identityDigest: "codex-account", now: now) { snapshot in
            XCTAssertNil(snapshot)
            ignored.fulfill()
        }
        wait(for: [ignored], timeout: 1)
    }

    func testQuotaCachePathsSeparateProductionAndDevelopment() {
        let production = QuotaCachePaths.make(
            homeDirectory: "/Users/test",
            environment: .production
        )
        let development = QuotaCachePaths.make(
            homeDirectory: "/Users/test",
            environment: .development
        )

        XCTAssertEqual(production.file, "/Users/test/.monitor-agent/quota-snapshots.json")
        XCTAssertEqual(
            development.file,
            "/Users/test/.monitor-agent/development/quota-snapshots.json"
        )
    }

    func testQuotaRefreshFailureRetainsMatchingCachedSuccess() {
        let suiteName = "PersistedPanelStateTests.quotaFailure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let monitoringSettings = AgentMonitoringSettings(defaults: defaults)
        monitoringSettings.enabledAgents = [.claude]
        let quotaSettings = QuotaSettings(defaults: defaults)
        quotaSettings.claudeExpirationDate = Date(timeIntervalSinceNow: 30 * 24 * 60 * 60)
        let cached = quotaSnapshot(provider: .claude)
        let cache = MemoryQuotaCache(
            records: [.claude: MemoryQuotaRecord(identityDigest: "account-a", snapshot: cached)]
        )
        let quotaService = ControlledQuotaService(identityDigest: "account-a")
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
            quotaCache: cache,
            observeRefreshIntervalChanges: false
        )
        XCTAssertEqual(store.quotaSnapshots[.claude], cached)

        store.panelDidOpen()
        wait(for: [quotaService.started], timeout: 1)
        quotaService.finish(
            snapshot: .failure(
                provider: .claude,
                status: .unavailable("Quota service unavailable")
            )
        )

        let retained = expectation(description: "Cached success remains after failure")
        DispatchQueue.main.async {
            XCTAssertEqual(store.quotaSnapshots[.claude], cached)
            guard case .failed(.unavailable, _) = store.quotaRefreshPhase(for: .claude) else {
                XCTFail("Expected a failed refresh phase")
                retained.fulfill()
                return
            }
            XCTAssertEqual(QuotaCardLayout.cardHeight, 34)
            retained.fulfill()
        }
        wait(for: [retained], timeout: 1)
        store.panelDidClose()
    }

    func testImmediatePanelOpenDoesNotCancelDelayedQuotaCacheRestore() {
        let suiteName = "PersistedPanelStateTests.quotaRestoreRace.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let monitoringSettings = AgentMonitoringSettings(defaults: defaults)
        monitoringSettings.enabledAgents = [.claude]
        let quotaSettings = QuotaSettings(defaults: defaults)
        quotaSettings.claudeExpirationDate = Date(timeIntervalSinceNow: 30 * 24 * 60 * 60)
        let cached = quotaSnapshot(provider: .claude)
        let cache = MemoryQuotaCache(
            records: [.claude: MemoryQuotaRecord(identityDigest: "account-a", snapshot: cached)]
        )
        let quotaService = DelayedIdentityQuotaService(identityDigest: "account-a")
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
            quotaCache: cache,
            observeRefreshIntervalChanges: false
        )

        store.panelDidOpen()
        wait(for: [quotaService.started], timeout: 1)
        XCTAssertNil(store.quotaSnapshots[.claude])
        quotaService.releaseNextIdentityResolution()
        quotaService.releaseNextIdentityResolution()

        XCTAssertEqual(store.quotaSnapshots[.claude], cached)
        XCTAssertEqual(store.quotaRefreshPhase(for: .claude), .refreshing)
        quotaService.finish(
            snapshot: .failure(
                provider: .claude,
                status: .unavailable("Quota service unavailable")
            )
        )
        let retained = expectation(description: "Delayed restored cache survives failure")
        DispatchQueue.main.async {
            XCTAssertEqual(store.quotaSnapshots[.claude], cached)
            retained.fulfill()
        }
        wait(for: [retained], timeout: 1)
        store.panelDidClose()
    }

    private func quotaSnapshot(
        provider: QuotaProviderID = .codex,
        fetchedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        fiveHourReset: Date = Date(timeIntervalSince1970: 1_800_003_600),
        weeklyReset: Date = Date(timeIntervalSince1970: 1_800_086_400)
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: provider,
            plan: "PRO",
            fiveHour: QuotaWindow(
                remainingPercent: 80,
                resetsAt: fiveHourReset,
                durationSeconds: 18_000
            ),
            weekly: QuotaWindow(
                remainingPercent: 60,
                resetsAt: weeklyReset,
                durationSeconds: 604_800
            ),
            opusWeekly: nil,
            resetCredits: nil,
            resetCreditExpirations: [],
            status: .available,
            fetchedAt: fetchedAt
        )
    }

    private func poll(attempts: Int = 50, condition: @escaping () -> Bool) {
        guard attempts > 0, !condition() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            self.poll(attempts: attempts - 1, condition: condition)
        }
    }
}

private final class MemoryQuotaCache: QuotaSnapshotCaching {
    private var records: [QuotaProviderID: MemoryQuotaRecord]

    init(records: [QuotaProviderID: MemoryQuotaRecord] = [:]) {
        self.records = records
    }

    func load(
        provider: QuotaProviderID,
        identityDigest: String,
        now _: Date,
        completion: @escaping (QuotaSnapshot?) -> Void
    ) {
        let record = records[provider]
        completion(record?.identityDigest == identityDigest ? record?.snapshot : nil)
    }

    func store(_ snapshot: QuotaSnapshot, identityDigest: String) {
        records[snapshot.provider] = MemoryQuotaRecord(
            identityDigest: identityDigest,
            snapshot: snapshot
        )
    }
}

private struct MemoryQuotaRecord: Equatable {
    let identityDigest: String
    let snapshot: QuotaSnapshot
}

private final class ControlledQuotaService: QuotaRefreshing {
    let started = XCTestExpectation(description: "Quota refresh starts")
    private let identityDigest: String
    private var completion: ((QuotaRefreshResult) -> Void)?

    init(identityDigest: String) {
        self.identityDigest = identityDigest
    }

    func resolveIdentityDigest(
        provider _: QuotaProviderID,
        completion: @escaping (String?) -> Void
    ) {
        completion(identityDigest)
    }

    func refresh(
        provider _: QuotaProviderID,
        now _: Date,
        completion: @escaping (QuotaRefreshResult) -> Void
    ) {
        self.completion = completion
        started.fulfill()
    }

    func finish(snapshot: QuotaSnapshot) {
        completion?(QuotaRefreshResult(
            snapshot: snapshot,
            identityDigest: identityDigest
        ))
        completion = nil
    }
}

private final class DelayedIdentityQuotaService: QuotaRefreshing {
    let started = XCTestExpectation(description: "Quota refresh starts before cache identity resolves")
    private let identityDigest: String
    private var identityCompletions: [(String?) -> Void] = []
    private var refreshCompletion: ((QuotaRefreshResult) -> Void)?

    init(identityDigest: String) {
        self.identityDigest = identityDigest
    }

    func resolveIdentityDigest(
        provider _: QuotaProviderID,
        completion: @escaping (String?) -> Void
    ) {
        identityCompletions.append(completion)
    }

    func refresh(
        provider _: QuotaProviderID,
        now _: Date,
        completion: @escaping (QuotaRefreshResult) -> Void
    ) {
        refreshCompletion = completion
        started.fulfill()
    }

    func releaseNextIdentityResolution() {
        guard !identityCompletions.isEmpty else {
            XCTFail("Expected a pending identity resolution")
            return
        }
        identityCompletions.removeFirst()(identityDigest)
    }

    func finish(snapshot: QuotaSnapshot) {
        refreshCompletion?(QuotaRefreshResult(
            snapshot: snapshot,
            identityDigest: identityDigest
        ))
        refreshCompletion = nil
    }
}
