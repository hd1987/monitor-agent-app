import Foundation
import SwiftUI
import Combine

typealias HourlyTokenUsageLoader = (
    DatabaseManager,
    AppFilter,
    Set<AgentID>,
    String
) -> [HourlyTokenUsage]

typealias ActivityRangeTokenUsageLoader = (
    DatabaseManager,
    AppFilter,
    Set<AgentID>,
    TimeRange
) -> ActivityRangeTokenSeries

private enum ActivityDetailRequest: Equatable {
    case hourly(date: String)
    case range(TimeRange)
}

enum CursorAccountPresentationState: Equatable {
    case unverified
    case verifying(String?)
    case verified(String)
    case mismatched(String)
    case unavailable
}

enum CursorRefreshComponent: Int, CaseIterable, Hashable {
    case account
    case usage
    case spend

    var displayName: String {
        switch self {
        case .account: return "account"
        case .usage: return "usage"
        case .spend: return "spend"
        }
    }
}

enum CursorRefreshFailureKind: Equatable {
    case signInUnavailable
    case refreshFailed
}

struct CursorRefreshFailure: Equatable {
    let component: CursorRefreshComponent
    let kind: CursorRefreshFailureKind
    let attemptedAt: Date
}

private final class RefreshCycleParticipant {
    private let lock = NSLock()
    private var isFinished = false
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        lock.unlock()
        onFinish()
    }
}

private final class DeferredRefreshCycleParticipant {
    private let lock = NSLock()
    private let participant: RefreshCycleParticipant
    private var sourceDidSucceed = false

    init(participant: RefreshCycleParticipant) {
        self.participant = participant
    }

    func markSourceSucceeded() {
        lock.lock()
        sourceDidSucceed = true
        lock.unlock()
    }

    func finishIfSourceFailed() {
        lock.lock()
        let shouldFinish = !sourceDidSucceed
        lock.unlock()
        if shouldFinish {
            participant.finish()
        }
    }

    func finish() {
        participant.finish()
    }
}

final class AppStore: ObservableObject {
    @Published var appFilter: AppFilter = .all
    @Published var timeRange: TimeRange = .today
    @Published var heatmapMode: HeatmapMode = .trailing

    @Published var stats = UsageStats()
    @Published var heatmap: [DayActivity] = []
    @Published private(set) var activityDetailState: ActivityDetailState = .closed
    @Published private(set) var activityChartStyle: ActivityChartStyle
    @Published var modelDistribution: [ModelShare] = []
    @Published var availableYears: [Int] = []
    @Published var isRebuildingUsageData = false
    @Published var usageDataRebuildProgress: SessionSyncProgress?
    @Published var usageDataRebuildSummary: UsageDataRebuildSummary?
    @Published var usageDataRebuildErrorMessage: String?
    @Published var usageDataRebuildWasCancelled = false
    @Published var quotaSnapshots: [QuotaProviderID: QuotaSnapshot] = [:]
    @Published private(set) var quotaRefreshPhases: [QuotaProviderID: QuotaRefreshPhase] = [:]
    @Published private(set) var cursorSpendSnapshot: CursorSpendSnapshot?
    @Published private(set) var cursorAccountPresentationState: CursorAccountPresentationState = .unverified
    @Published private(set) var cursorRefreshFailures: [CursorRefreshComponent: CursorRefreshFailure] = [:]
    @Published private(set) var manualRefreshAvailableAt: Date?
    @Published private(set) var isRefreshInProgress = false
    @Published private(set) var isManualRefreshInProgress = false
    @Published private(set) var enabledAgents: Set<AgentID>

    private let db: DatabaseManager
    private let syncManager: SessionSyncManager
    private let refreshSettings: RefreshSettings
    private let monitoringSettings: AgentMonitoringSettings
    private let currentDateProvider: () -> Date
    private let quotaService: QuotaRefreshing
    private let quotaSettings: QuotaSettings
    private let quotaCache: QuotaSnapshotCaching?
    private let cursorSpendRefresher: CursorSpendRefreshing?
    private let cursorAccountResolver: CursorAccountResolving?
    private let activityPresentationSettings: ActivityPresentationPersisting?
    private let refreshCoordinator: PanelRefreshCoordinator
    private let hourlyTokenUsageLoader: HourlyTokenUsageLoader
    private let activityRangeTokenUsageLoader: ActivityRangeTokenUsageLoader
    private var activeDay: Date
    private var cancellables = Set<AnyCancellable>()
    private var usageDataRebuildCancellation: UsageDataRebuildCancellation?
    private var activeAgentSyncCancellation: AgentSyncCancellation?
    private var cursorAccountSyncCancellation: AgentSyncCancellation?
    private var activeQuotaParticipants: [QuotaProviderID: RefreshCycleParticipant] = [:]
    private var quotaSnapshotIdentities: [QuotaProviderID: String] = [:]
    private var quotaRefreshGenerations: [QuotaProviderID: Int] = [:]
    private var quotaRestoreGenerations: [QuotaProviderID: Int] = [:]
    private var cursorSpendSnapshotRestoreGeneration = 0
    private var cursorSpendRefreshGeneration = 0
    private var cursorUsageRefreshGeneration = 0
    private var cursorAccountVerificationGeneration = 0
    private var reloadGeneration = 0
    private var activityLoadGeneration = 0
    private(set) var isPanelVisible = false
    var isPeriodicRefreshActive: Bool { refreshCoordinator.isRunning }

    init(
        database: DatabaseManager = .shared,
        syncManager: SessionSyncManager? = nil,
        refreshSettings: RefreshSettings = .shared,
        monitoringSettings: AgentMonitoringSettings = .shared,
        quotaService: QuotaRefreshing = QuotaService.shared,
        quotaSettings: QuotaSettings = .shared,
        quotaCache: QuotaSnapshotCaching? = nil,
        cursorSpendRefresher: CursorSpendRefreshing? = nil,
        cursorAccountResolver: CursorAccountResolving? = nil,
        activityPresentationSettings: ActivityPresentationPersisting? = nil,
        refreshCoordinator: PanelRefreshCoordinator = PanelRefreshCoordinator(),
        observeRefreshIntervalChanges: Bool = true,
        currentDateProvider: @escaping () -> Date = Date.init,
        hourlyTokenUsageLoader: @escaping HourlyTokenUsageLoader = { database, app, agents, date in
            database.fetchHourlyTokenUsage(app: app, date: date, enabledAgents: agents)
        },
        activityRangeTokenUsageLoader: @escaping ActivityRangeTokenUsageLoader = { database, app, agents, range in
            database.fetchActivityRangeTokenUsage(app: app, range: range, enabledAgents: agents)
        }
    ) {
        self.db = database
        self.syncManager = syncManager ?? SessionSyncManager(
            database: database,
            cursorUsageSyncer: CursorUsageService(database: database)
        )
        self.refreshSettings = refreshSettings
        self.monitoringSettings = monitoringSettings
        self.enabledAgents = monitoringSettings.enabledAgents
        self.currentDateProvider = currentDateProvider
        self.quotaService = quotaService
        self.quotaSettings = quotaSettings
        self.quotaCache = quotaCache
        self.cursorSpendRefresher = cursorSpendRefresher
        self.cursorAccountResolver = cursorAccountResolver
        self.activityPresentationSettings = activityPresentationSettings
        self.activityChartStyle = activityPresentationSettings?.chartStyle ?? .line
        self.refreshCoordinator = refreshCoordinator
        self.hourlyTokenUsageLoader = hourlyTokenUsageLoader
        self.activityRangeTokenUsageLoader = activityRangeTokenUsageLoader
        self.activeDay = Calendar.current.startOfDay(for: currentDateProvider())
        if activityPresentationSettings?.isPresented == true, !enabledAgents.isEmpty {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            activityDetailState = .hourly(
                date: formatter.string(from: currentDateProvider()),
                usage: [],
                isLoading: true
            )
        } else if enabledAgents.isEmpty {
            activityPresentationSettings?.isPresented = false
        }
        refreshCoordinator.setRefreshStateHandler { [weak self] isRefreshing, isManual in
            self?.isRefreshInProgress = isRefreshing
            self?.isManualRefreshInProgress = isManual
        }

        // React to filter changes
        Publishers.CombineLatest3($appFilter, $timeRange, $heatmapMode)
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _, _ in
                self?.reload()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest($appFilter, $timeRange)
            .removeDuplicates { lhs, rhs in
                lhs.0 == rhs.0 && lhs.1 == rhs.1
            }
            .sink { [weak self] _ in
                self?.invalidateCursorSpendSnapshotRestore()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest($appFilter, $timeRange)
            .removeDuplicates { lhs, rhs in
                lhs.0 == rhs.0 && lhs.1 == rhs.1
            }
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.restoreCursorSpendSnapshotForSelection()
            }
            .store(in: &cancellables)

        $appFilter
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] filter in
                guard filter == .all || filter == .cursor else { return }
                self?.verifyCursorAccountForPresentation(force: true)
            }
            .store(in: &cancellables)

        if observeRefreshIntervalChanges {
            refreshSettings.$interval
                .sink { [weak self] interval in
                    self?.applyRefreshInterval(interval)
                }
                .store(in: &cancellables)
        }

        monitoringSettings.$enabledAgents
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabledAgents in
                self?.monitoringSettingsDidChange(enabledAgents)
            }
            .store(in: &cancellables)

        restoreCachedQuotaSnapshots()
    }

    var availableAppFilters: [AppFilter] { AppFilter.available(for: enabledAgents) }
    var hasEnabledAgents: Bool { !enabledAgents.isEmpty }
    var hasCursorRefreshFailure: Bool { !cursorRefreshFailures.isEmpty }
    var cursorRefreshFailureHelp: String? {
        let failures = CursorRefreshComponent.allCases.compactMap { cursorRefreshFailures[$0] }
        guard !failures.isEmpty else { return nil }
        let authenticationFailures = failures.filter { $0.kind == .signInUnavailable }
        if let latestAuthenticationFailure = authenticationFailures.max(
            by: { $0.attemptedAt < $1.attemptedAt }
        ) {
            return "Cursor sign-in unavailable · \(QuotaDateFormat.updateDateTime(latestAuthenticationFailure.attemptedAt))"
        }
        let latestAttempt = failures.map(\.attemptedAt).max() ?? currentDateProvider()
        if failures.count == 1, let failure = failures.first {
            return "Cursor \(failure.component.displayName) refresh failed · \(QuotaDateFormat.updateDateTime(latestAttempt))"
        }
        let components = cursorFailureComponentList(
            failures.map { $0.component.displayName }
        )
        return "Cursor \(components) refresh failed · Last failure \(QuotaDateFormat.updateDateTime(latestAttempt))"
    }
    var isCursorDataPresentationAvailable: Bool {
        guard cursorAccountResolver != nil else { return true }
        return cursorPresentationIdentity != nil
    }
    private var isCursorRefreshAvailable: Bool {
        guard cursorAccountResolver != nil else { return true }
        guard case .verified(let identity) = cursorAccountPresentationState else { return false }
        return cachedCursorIdentity == identity
    }
    private var cachedCursorIdentity: String? {
        db.getSyncState(for: CursorUsageService.syncStateKey)?.sessionId
    }
    private var cursorPresentationIdentity: String? {
        guard !isRebuildingUsageData, let cachedIdentity = cachedCursorIdentity else { return nil }
        switch cursorAccountPresentationState {
        case .verified(let identity):
            return identity == cachedIdentity ? cachedIdentity : nil
        case .verifying(let identity):
            return identity == nil || identity == cachedIdentity ? cachedIdentity : nil
        case .mismatched:
            return nil
        case .unverified, .unavailable:
            return cachedIdentity
        }
    }
    var isActivityDetailPresented: Bool {
        if case .closed = activityDetailState { return false }
        return true
    }

    var selectedActivityDate: String? {
        guard case .hourly(let date, _, _) = activityDetailState else { return nil }
        return date
    }

    var hourlyTokenUsage: [HourlyTokenUsage] {
        guard case .hourly(_, let usage, _) = activityDetailState else { return [] }
        return usage
    }

    var isHourlyTokenUsageLoading: Bool {
        guard case .hourly(_, _, let isLoading) = activityDetailState else { return false }
        return isLoading
    }

    var activityDetailRange: TimeRange? {
        switch activityDetailState {
        case .closed:
            return nil
        case .hourly(let date, _, _):
            return TimeRange.activityDay(date, now: currentDateProvider())
        case .range(let range, _, _):
            return range
        }
    }

    var activityRangeTokenSeries: ActivityRangeTokenSeries {
        guard case .range(_, let series, _) = activityDetailState else { return .empty }
        return series
    }

    var isActivityRangeTokenUsageLoading: Bool {
        guard case .range(_, _, let isLoading) = activityDetailState else { return false }
        return isLoading
    }

    var activityChartData: ActivityChartData? {
        switch activityDetailState {
        case .closed:
            return nil
        case .hourly(let date, let usage, _):
            return .hourly(date: date, usage: usage)
        case .range(let range, let series, _):
            return .range(range: range, series: series)
        }
    }

    var isActivityChartLoading: Bool {
        switch activityDetailState {
        case .closed:
            return false
        case .hourly(_, _, let isLoading), .range(_, _, let isLoading):
            return isLoading
        }
    }

    func updateEnabledAgents(_ enabledAgents: Set<AgentID>) {
        monitoringSettings.enabledAgents = enabledAgents
    }

    private func applyRefreshInterval(
        _ interval: RefreshInterval,
        throttleInitialRefresh: Bool = false,
        enabledAgents requestedEnabledAgents: Set<AgentID>? = nil
    ) {
        let enabledAgents = requestedEnabledAgents ?? self.enabledAgents
        guard isPanelVisible, !isRebuildingUsageData, !enabledAgents.isEmpty else {
            refreshCoordinator.stop()
            return
        }

        refreshCoordinator.start(
            interval: interval,
            initialRefreshMinimumInterval: throttleInitialRefresh
                ? interval.effectiveInterval
                : nil
        ) { [weak self] completion in
            guard let self else {
                completion()
                return
            }
            self.manualRefreshAvailableAt = self.refreshCoordinator.manualRefreshAvailableAt
            self.performRefreshCycle(
                enabledAgents: enabledAgents,
                completion: completion
            )
        }
    }

    private func performRefreshCycle(
        enabledAgents: Set<AgentID>,
        completion: @escaping () -> Void
    ) {
        guard !isRebuildingUsageData else {
            completion()
            return
        }

        guard !enabledAgents.isEmpty else {
            completion()
            return
        }

        guard cursorAccountResolver != nil,
              enabledAgents.contains(.cursor) else {
            performRefreshCycleAfterCursorVerification(
                enabledAgents: enabledAgents,
                expectedCursorIdentity: nil,
                cursorVerificationGeneration: nil,
                completion: completion
            )
            return
        }

        resolveCursorAccount(force: true) { [weak self] identity, isAccepted, verificationGeneration in
            guard let self else {
                completion()
                return
            }
            guard isAccepted, self.isPanelVisible else {
                completion()
                return
            }
            let currentEnabledAgents = enabledAgents.intersection(self.enabledAgents)
            let refreshAgents = identity == nil
                ? currentEnabledAgents.subtracting([.cursor])
                : currentEnabledAgents
            self.performRefreshCycleAfterCursorVerification(
                enabledAgents: refreshAgents,
                expectedCursorIdentity: identity,
                cursorVerificationGeneration: verificationGeneration,
                completion: completion
            )
        }
    }

    private func performRefreshCycleAfterCursorVerification(
        enabledAgents: Set<AgentID>,
        expectedCursorIdentity: String?,
        cursorVerificationGeneration: Int?,
        completion: @escaping () -> Void
    ) {
        guard !enabledAgents.isEmpty else {
            completion()
            return
        }

        let group = DispatchGroup()
        let syncCancellation = AgentSyncCancellation(enabledAgents: enabledAgents)
        activeAgentSyncCancellation = syncCancellation
        let shouldRefreshCursorSpend = enabledAgents.contains(.cursor)
        let cursorSpendRange = CursorSpendRange(
            timeRange: timeRange,
            now: currentDateProvider()
        )
        let forceCursorSpendRefresh = isManualRefreshInProgress
        let cursorSpendParticipant: RefreshCycleParticipant?
        let deferredCursorSpendParticipant: DeferredRefreshCycleParticipant?
        if shouldRefreshCursorSpend {
            group.enter()
            let participant = RefreshCycleParticipant {
                group.leave()
            }
            cursorSpendParticipant = participant
            deferredCursorSpendParticipant = isCursorRefreshAvailable
                ? nil
                : DeferredRefreshCycleParticipant(participant: participant)
        } else {
            cursorSpendParticipant = nil
            deferredCursorSpendParticipant = nil
        }

        let cursorUsageGeneration: Int?
        if enabledAgents.contains(.cursor) {
            cursorUsageRefreshGeneration += 1
            cursorUsageGeneration = cursorUsageRefreshGeneration
        } else {
            cursorUsageGeneration = nil
        }

        group.enter()
        syncManager.syncOnce(
            enabledAgents: enabledAgents,
            cancellation: syncCancellation,
            expectedCursorIdentity: expectedCursorIdentity,
            onLocalComplete: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.isPanelVisible else { return }
                    self.reload()
                }
            },
            onCursorComplete: { [weak self] in
                deferredCursorSpendParticipant?.markSourceSucceeded()
                DispatchQueue.main.async {
                    guard let self, self.isPanelVisible else {
                        deferredCursorSpendParticipant?.finish()
                        return
                    }
                    if let cursorVerificationGeneration,
                       self.cursorAccountVerificationGeneration != cursorVerificationGeneration {
                        deferredCursorSpendParticipant?.finish()
                        return
                    }
                    let currentIdentity = self.db.getSyncState(
                        for: CursorUsageService.syncStateKey
                    )?.sessionId
                    guard expectedCursorIdentity == nil
                            || currentIdentity == expectedCursorIdentity else {
                        deferredCursorSpendParticipant?.finish()
                        return
                    }
                    if let expectedCursorIdentity {
                        guard self.cursorAccountPresentationState == .verifying(expectedCursorIdentity)
                                || self.cursorAccountPresentationState == .verified(expectedCursorIdentity) else {
                            deferredCursorSpendParticipant?.finish()
                            return
                        }
                    }
                    if let currentIdentity {
                        self.cursorAccountPresentationState = .verified(currentIdentity)
                    }
                    self.reload()
                    if deferredCursorSpendParticipant != nil {
                        if self.cursorSpendSnapshot?.accountIdentity != currentIdentity {
                            self.cursorSpendSnapshot = nil
                        }
                        let currentCursorSpendRange = CursorSpendRange(
                            timeRange: self.timeRange,
                            now: self.currentDateProvider()
                        )
                        self.refreshCursorSpend(
                            range: currentCursorSpendRange,
                            force: forceCursorSpendRefresh,
                            cancellation: syncCancellation,
                            completion: {
                                cursorSpendParticipant?.finish()
                            }
                        )
                    }
                }
            },
            onCursorOutcome: { [weak self] outcome in
                DispatchQueue.main.async {
                    guard let self,
                          let cursorUsageGeneration,
                          self.cursorUsageRefreshGeneration == cursorUsageGeneration,
                          self.isPanelVisible,
                          self.enabledAgents.contains(.cursor),
                          syncCancellation.isEnabled(.cursor) else {
                        return
                    }
                    self.applyCursorUsageSyncOutcome(outcome)
                }
            },
            completion: {
                group.leave()
                deferredCursorSpendParticipant?.finishIfSourceFailed()
            }
        )

        if let cursorSpendParticipant,
           deferredCursorSpendParticipant == nil {
            refreshCursorSpend(
                range: cursorSpendRange,
                force: forceCursorSpendRefresh,
                cancellation: syncCancellation
            ) {
                cursorSpendParticipant.finish()
            }
        }

        for provider in QuotaProviderID.allCases
            where quotaSettings.isEnabled(provider) && isAgentEnabled(for: provider, in: enabledAgents) {
            group.enter()
            let quotaGeneration = (quotaRefreshGenerations[provider] ?? 0) + 1
            quotaRefreshGenerations[provider] = quotaGeneration
            quotaRefreshPhases[provider] = .refreshing
            let participant = RefreshCycleParticipant {
                group.leave()
            }
            activeQuotaParticipants[provider] = participant
            quotaService.refresh(
                provider: provider,
                now: Date()
            ) { [weak self] result in
                DispatchQueue.main.async {
                    if let self,
                       self.activeQuotaParticipants[provider] === participant,
                       self.quotaRefreshGenerations[provider] == quotaGeneration {
                        self.activeQuotaParticipants.removeValue(forKey: provider)
                        if self.quotaSettings.isEnabled(provider),
                           self.isAgentEnabled(for: provider, in: self.enabledAgents) {
                            self.applyQuotaRefreshResult(result, provider: provider)
                        }
                    }
                    participant.finish()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            if let self {
                if self.activeAgentSyncCancellation === syncCancellation {
                    self.activeAgentSyncCancellation = nil
                }
                let isCurrentVerification = cursorVerificationGeneration.map {
                    self.cursorAccountVerificationGeneration == $0
                } ?? true
                if isCurrentVerification,
                   let expectedCursorIdentity {
                    let currentIdentity = self.db.getSyncState(
                        for: CursorUsageService.syncStateKey
                    )?.sessionId
                    let isPendingIdentity: Bool
                    if case .verifying(let pendingIdentity) = self.cursorAccountPresentationState {
                        isPendingIdentity = pendingIdentity == expectedCursorIdentity
                    } else {
                        isPendingIdentity = false
                    }
                    if currentIdentity != expectedCursorIdentity || isPendingIdentity {
                        self.cursorAccountPresentationState = .unavailable
                        self.cursorSpendSnapshot = nil
                        self.clearCursorDependentPresentation()
                        self.reload()
                    }
                }
            }
            completion()
        }
    }

    /// Start one unified visible-panel refresh lifecycle.
    func panelDidOpen() {
        isPanelVisible = true
        normalizeCodexResetCredits(at: currentDateProvider())
        verifyCursorAccountForPresentation(force: true)
        restoreCursorSpendSnapshotForSelection()
        applyRefreshInterval(refreshSettings.interval, throttleInitialRefresh: true)
    }

    /// Stop periodic refreshing when the panel is hidden.
    func panelDidClose() {
        isPanelVisible = false
        cursorAccountVerificationGeneration += 1
        invalidateCursorSpendSnapshotRestore()
        cursorSpendRefreshGeneration += 1
        refreshCoordinator.stop()
    }

    /// Start a unified manual refresh and reset the next automatic interval.
    func refreshNow() {
        guard isPanelVisible, !isRebuildingUsageData, hasEnabledAgents else { return }
        refreshCoordinator.refreshNow()
    }

    func manualRefreshCooldownRemaining(at date: Date) -> Int {
        guard let manualRefreshAvailableAt else { return 0 }
        return max(0, Int(ceil(manualRefreshAvailableAt.timeIntervalSince(date))))
    }

    func quotaProviderSettingsDidChange() {
        for provider in Array(activeQuotaParticipants.keys)
            where !quotaSettings.isEnabled(provider)
                || !isAgentEnabled(for: provider, in: enabledAgents) {
            activeQuotaParticipants.removeValue(forKey: provider)?.finish()
        }
        quotaSnapshots = quotaSnapshots.filter {
            quotaSettings.isEnabled($0.key) && isAgentEnabled(for: $0.key, in: enabledAgents)
        }
        retainQuotaPresentationState {
            quotaSettings.isEnabled($0) && isAgentEnabled(for: $0, in: enabledAgents)
        }
        restoreCachedQuotaSnapshots()
    }

    var visibleQuotaProviders: [QuotaProviderID] {
        let filtered: [QuotaProviderID]
        switch appFilter {
        case .all: filtered = QuotaProviderID.allCases
        case .claude: filtered = [.claude]
        case .codex: filtered = [.codex]
        case .cursor: filtered = []
        }
        return filtered.filter {
            isAgentEnabled(for: $0, in: enabledAgents) && quotaSettings.isEnabled($0)
        }
    }

    func quotaExpirationDate(for provider: QuotaProviderID) -> Date? {
        quotaSettings.expirationDate(for: provider)
    }

    func cycleAppFilter(reverse: Bool = false) {
        appFilter = appFilter.cycled(in: availableAppFilters, reverse: reverse)
    }

    private func monitoringSettingsDidChange(_ enabledAgents: Set<AgentID>) {
        self.enabledAgents = enabledAgents
        activeAgentSyncCancellation?.disableAgents(notIn: enabledAgents)
        cursorAccountSyncCancellation?.disableAgents(notIn: enabledAgents)
        cancelQuotaParticipants(disabledBy: enabledAgents)
        let filters = AppFilter.available(for: enabledAgents)
        if enabledAgents.isEmpty {
            closeActivityDetail()
            cursorSpendSnapshot = nil
            reload(enabledAgents: enabledAgents)
        } else if !filters.contains(appFilter) {
            closeActivityDetail()
            appFilter = .all
        } else {
            reload(enabledAgents: enabledAgents)
        }
        if !enabledAgents.contains(.cursor) {
            cursorAccountVerificationGeneration += 1
            cursorUsageRefreshGeneration += 1
            cursorAccountPresentationState = .unverified
            invalidateCursorSpendSnapshotRestore()
            cursorSpendRefreshGeneration += 1
            cursorSpendSnapshot = nil
            cursorRefreshFailures = [:]
        }
        quotaSnapshots = quotaSnapshots.filter {
            isAgentEnabled(for: $0.key, in: enabledAgents)
        }
        retainQuotaPresentationState { isAgentEnabled(for: $0, in: enabledAgents) }
        restoreCachedQuotaSnapshots()
        applyRefreshInterval(
            refreshSettings.interval,
            enabledAgents: enabledAgents
        )
    }

    private func cancelQuotaParticipants(disabledBy enabledAgents: Set<AgentID>) {
        for provider in Array(activeQuotaParticipants.keys)
            where !isAgentEnabled(for: provider, in: enabledAgents) {
            activeQuotaParticipants.removeValue(forKey: provider)?.finish()
        }
    }

    private func isAgentEnabled(
        for provider: QuotaProviderID,
        in enabledAgents: Set<AgentID>
    ) -> Bool {
        switch provider {
        case .claude: return enabledAgents.contains(.claude)
        case .codex: return enabledAgents.contains(.codex)
        }
    }

    func rebuildLocalUsageData() {
        guard !isRebuildingUsageData else { return }

        cancelActiveSyncForRebuild()
        isRebuildingUsageData = true
        cursorAccountVerificationGeneration += 1
        cursorAccountPresentationState = .unverified
        invalidateCursorSpendSnapshotRestore()
        cursorSpendRefreshGeneration += 1
        cursorSpendSnapshot = nil
        clearCursorDependentPresentation()
        reload()
        usageDataRebuildProgress = nil
        usageDataRebuildSummary = nil
        usageDataRebuildErrorMessage = nil
        usageDataRebuildWasCancelled = false
        let cancellation = UsageDataRebuildCancellation()
        usageDataRebuildCancellation = cancellation
        refreshCoordinator.stop()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            do {
                let summary = try syncManager.performExclusive {
                    try UsageDataRebuilder(
                        activeDatabase: self.db,
                        cursorUsageServiceFactory: { CursorUsageService(database: $0) },
                        cursorSpendServiceFactory: { CursorSpendService(database: $0) }
                    ).rebuild(
                        cancellation: cancellation
                    ) { [weak self] progress in
                        DispatchQueue.main.async {
                            self?.usageDataRebuildProgress = progress
                        }
                    }
                }
                DispatchQueue.main.async {
                    self.usageDataRebuildSummary = summary
                    self.isRebuildingUsageData = false
                    self.usageDataRebuildCancellation = nil
                    self.reload()
                    self.verifyCursorAccountForPresentation(force: true)
                    self.applyRefreshInterval(self.refreshSettings.interval)
                }
            } catch {
                DispatchQueue.main.async {
                    if (error as? StrictSessionSyncError) == .cancelled {
                        self.usageDataRebuildWasCancelled = true
                    } else {
                        self.usageDataRebuildErrorMessage = error.localizedDescription
                    }
                    self.isRebuildingUsageData = false
                    self.usageDataRebuildCancellation = nil
                    self.applyRefreshInterval(self.refreshSettings.interval)
                }
            }
        }
    }

    func cancelActiveSyncForRebuild() {
        activeAgentSyncCancellation?.disableAgents(notIn: [])
        cursorAccountSyncCancellation?.disableAgents(notIn: [])
    }

    func cancelUsageDataRebuild() {
        guard usageDataRebuildProgress?.phase?.isCancellable != false else { return }
        usageDataRebuildCancellation?.cancel()
    }

    func prepareUsageDataRebuild() {
        guard !isRebuildingUsageData else { return }
        usageDataRebuildProgress = nil
        usageDataRebuildSummary = nil
        usageDataRebuildErrorMessage = nil
        usageDataRebuildWasCancelled = false
    }

    func reload(enabledAgents requestedEnabledAgents: Set<AgentID>? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.reload(enabledAgents: requestedEnabledAgents)
            }
            return
        }

        guard !resetToTodayAfterDayRolloverIfNeeded() else { return }
        reloadGeneration += 1
        activityLoadGeneration += 1

        let appFilter = appFilter
        let enabledAgents = requestedEnabledAgents ?? self.enabledAgents
        let cursorQueryContext = cursorBoundQueryContext(from: enabledAgents)
        let queryEnabledAgents = cursorQueryContext.enabledAgents
        let cursorDataPresentationToken = cursorQueryContext.token
        let isCursorTemporarilyExcluded = enabledAgents.contains(.cursor)
            && !queryEnabledAgents.contains(.cursor)
        let cursorAccountPresentationState = cursorAccountPresentationState
        let timeRange = timeRange
        let heatmapMode = heatmapMode
        let activityDetailRequest = activityDetailRequest
        let reloadGeneration = reloadGeneration
        let activityLoadGeneration = activityLoadGeneration
        let db = db
        let hourlyTokenUsageLoader = hourlyTokenUsageLoader
        let activityRangeTokenUsageLoader = activityRangeTokenUsageLoader
        markActivityDetailLoading()

        DispatchQueue.global(qos: .userInitiated).async {
            let s = db.fetchStats(
                app: appFilter,
                range: timeRange,
                enabledAgents: queryEnabledAgents
            )
            let cal = Calendar.current
            let h: [DayActivity]
            switch heatmapMode {
            case .trailing:
                let today = cal.startOfDay(for: Date())
                let start = cal.date(byAdding: .day, value: -364, to: today)!
                let end = cal.date(byAdding: .day, value: 1, to: today)!
                h = db.fetchHeatmap(
                    app: appFilter,
                    from: start,
                    to: end,
                    enabledAgents: queryEnabledAgents
                )
            case .year(let year):
                let start = cal.date(from: DateComponents(year: year, month: 1, day: 1))!
                let end = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1))!
                h = db.fetchHeatmap(
                    app: appFilter,
                    from: start,
                    to: end,
                    enabledAgents: queryEnabledAgents
                )
            }
            let hourly: [HourlyTokenUsage]
            let ranged: ActivityRangeTokenSeries
            switch activityDetailRequest {
            case .hourly(let date):
                hourly = hourlyTokenUsageLoader(db, appFilter, queryEnabledAgents, date)
                ranged = .empty
            case .range(let range):
                hourly = []
                ranged = activityRangeTokenUsageLoader(db, appFilter, queryEnabledAgents, range)
            case nil:
                hourly = []
                ranged = .empty
            }
            let m = db.fetchModelDistribution(
                app: appFilter,
                range: timeRange,
                enabledAgents: queryEnabledAgents
            )
            let years = db.availableYears(enabledAgents: queryEnabledAgents)
            let isCursorDataPresentationTokenCurrent = cursorDataPresentationToken.map {
                db.isCursorDataPresentationTokenCurrent($0)
            } ?? true

            DispatchQueue.main.async {
                guard
                    self.appFilter == appFilter,
                    self.enabledAgents == enabledAgents,
                    self.cursorAccountPresentationState == cursorAccountPresentationState,
                    self.timeRange == timeRange,
                    self.heatmapMode == heatmapMode,
                    self.activityDetailRequest == activityDetailRequest,
                    self.reloadGeneration == reloadGeneration,
                    self.activityLoadGeneration == activityLoadGeneration,
                    isCursorDataPresentationTokenCurrent
                else {
                    return
                }

                self.performCursorBoundPublication(
                    token: cursorDataPresentationToken
                ) {
                    self.stats = s
                    self.heatmap = h
                    switch activityDetailRequest {
                    case .hourly(let date):
                        self.activityDetailState = .hourly(
                            date: date,
                            usage: hourly,
                            isLoading: false
                        )
                    case .range(let range):
                        self.activityDetailState = .range(
                            range: range,
                            series: ranged,
                            isLoading: false
                        )
                    case nil:
                        break
                    }
                    self.modelDistribution = m
                    self.availableYears = years
                    if !isCursorTemporarilyExcluded,
                       case .year(let selectedYear) = self.heatmapMode,
                       !years.contains(selectedYear) {
                        self.heatmapMode = .trailing
                    }
                }
            }
        }
    }

    private func cursorQueryEnabledAgents(from enabledAgents: Set<AgentID>) -> Set<AgentID> {
        guard cursorAccountResolver != nil,
              !isCursorDataPresentationAvailable else {
            return enabledAgents
        }
        return enabledAgents.subtracting([.cursor])
    }

    private func cursorBoundQueryContext(
        from enabledAgents: Set<AgentID>
    ) -> (enabledAgents: Set<AgentID>, token: CursorDataPresentationToken?) {
        var queryEnabledAgents = cursorQueryEnabledAgents(from: enabledAgents)
        guard cursorAccountResolver != nil,
              queryEnabledAgents.contains(.cursor),
              let identity = cursorPresentationIdentity,
              let token = db.cursorDataPresentationToken(matching: identity) else {
            if cursorAccountResolver != nil {
                queryEnabledAgents.remove(.cursor)
            }
            return (queryEnabledAgents, nil)
        }
        return (queryEnabledAgents, token)
    }

    private func performCursorBoundPublication(
        token: CursorDataPresentationToken?,
        operation: () -> Void
    ) {
        guard let token else {
            operation()
            return
        }
        db.performIfCursorDataPresentationTokenCurrent(token, operation: operation)
    }

    private func verifyCursorAccountForPresentation(force: Bool) {
        guard cursorAccountResolver != nil,
              isPanelVisible,
              enabledAgents.contains(.cursor) else {
            return
        }
        invalidateCursorSpendSnapshotRestore()
        cursorAccountPresentationState = .verifying(nil)
        reload()
        resolveCursorAccount(force: force) { [weak self] identity, isAccepted, verificationGeneration in
            guard let self, isAccepted, let identity else { return }
            if self.cursorAccountPresentationState == .verified(identity) {
                self.restoreCursorSpendSnapshotForSelection()
                return
            }
            guard self.cursorAccountPresentationState == .verifying(identity) else { return }
            self.syncCursorForVerifiedAccount(
                identity,
                verificationGeneration: verificationGeneration
            )
        }
    }

    private func resolveCursorAccount(
        force: Bool,
        completion: @escaping (String?, Bool, Int) -> Void
    ) {
        guard let cursorAccountResolver else {
            completion(nil, false, cursorAccountVerificationGeneration)
            return
        }
        cursorAccountVerificationGeneration += 1
        let generation = cursorAccountVerificationGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try cursorAccountResolver.resolve(force: force, cancellation: nil)
            }
            DispatchQueue.main.async {
                guard let self else {
                    completion(nil, false, generation)
                    return
                }
                let identity = try? result.get().account.syncIdentity
                let isAccepted = self.cursorAccountVerificationGeneration == generation
                    && self.enabledAgents.contains(.cursor)
                    && self.isPanelVisible
                    && !self.isRebuildingUsageData
                if isAccepted {
                    if let identity {
                        self.clearCursorRefreshFailure(.account)
                        let cachedIdentity = self.db.getSyncState(
                            for: CursorUsageService.syncStateKey
                        )?.sessionId
                        self.cursorAccountPresentationState = cachedIdentity == identity
                            ? .verified(identity)
                            : .verifying(identity)
                        if cachedIdentity != identity {
                            self.cursorRefreshFailures = [:]
                            self.invalidateCursorSpendSnapshotRestore()
                            self.cursorSpendRefreshGeneration += 1
                            self.cursorSpendSnapshot = nil
                            self.clearCursorDependentPresentation()
                        }
                    } else {
                        self.cursorAccountPresentationState = .unavailable
                        if case .failure(let error) = result,
                           (error as? CursorUsageError) != .cancelled {
                            let kind: CursorRefreshFailureKind
                            switch error as? CursorUsageError {
                            case .authenticationUnavailable, .authenticationRejected:
                                kind = .signInUnavailable
                            default:
                                kind = .refreshFailed
                            }
                            self.recordCursorRefreshFailure(.account, kind: kind)
                        }
                    }
                    self.reload()
                }
                completion(isAccepted ? identity : nil, isAccepted, generation)
            }
        }
    }

    private func syncCursorForVerifiedAccount(
        _ identity: String,
        verificationGeneration: Int
    ) {
        cursorAccountSyncCancellation?.disableAgents(notIn: [])
        let cancellation = AgentSyncCancellation(enabledAgents: [.cursor])
        cursorAccountSyncCancellation = cancellation
        cursorUsageRefreshGeneration += 1
        let usageGeneration = cursorUsageRefreshGeneration
        syncManager.syncCursorOnce(
            expectedIdentity: identity,
            cancellation: cancellation,
            onSuccess: { [weak self] in
                DispatchQueue.main.async {
                    guard let self,
                          self.cursorAccountSyncCancellation === cancellation,
                          self.cursorAccountVerificationGeneration == verificationGeneration,
                          self.cursorAccountPresentationState == .verifying(identity),
                          self.db.getSyncState(
                            for: CursorUsageService.syncStateKey
                          )?.sessionId == identity else {
                        return
                    }
                    self.cursorAccountSyncCancellation = nil
                    self.cursorAccountPresentationState = .verified(identity)
                    self.reload()
                    self.restoreCursorSpendSnapshotForSelection()
                }
            },
            onOutcome: { [weak self] outcome in
                DispatchQueue.main.async {
                    guard let self,
                          self.cursorUsageRefreshGeneration == usageGeneration,
                          self.cursorAccountVerificationGeneration == verificationGeneration,
                          self.isPanelVisible,
                          self.enabledAgents.contains(.cursor),
                          cancellation.isEnabled(.cursor) else {
                        return
                    }
                    self.applyCursorUsageSyncOutcome(outcome)
                }
            },
            completion: { [weak self] in
                DispatchQueue.main.async {
                    guard let self,
                          self.cursorAccountSyncCancellation === cancellation,
                          self.cursorAccountVerificationGeneration == verificationGeneration,
                          self.cursorAccountPresentationState == .verifying(identity) else {
                        return
                    }
                    self.cursorAccountSyncCancellation = nil
                    self.cursorAccountPresentationState = .mismatched(identity)
                    self.cursorSpendSnapshot = nil
                    self.clearCursorDependentPresentation()
                    self.reload()
                }
            }
        )
    }

    private func clearCursorDependentPresentation() {
        availableYears = []
        guard appFilter == .all || appFilter == .cursor else { return }
        stats = UsageStats()
        heatmap = []
        modelDistribution = []
        switch activityDetailState {
        case .closed:
            break
        case .hourly(let date, _, _):
            activityDetailState = .hourly(date: date, usage: [], isLoading: true)
        case .range(let range, _, _):
            activityDetailState = .range(range: range, series: .empty, isLoading: true)
        }
    }

    private func restoreCursorSpendSnapshotForSelection() {
        invalidateCursorSpendSnapshotRestore()
        let generation = cursorSpendSnapshotRestoreGeneration
        guard appFilter == .cursor,
              enabledAgents.contains(.cursor),
              isCursorDataPresentationAvailable else {
            cursorSpendSnapshot = nil
            return
        }
        let accountIdentity = cursorPresentationIdentity ?? cachedCursorIdentity

        let range = CursorSpendRange(
            timeRange: timeRange,
            now: currentDateProvider()
        )
        let db = db
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let cached = accountIdentity.flatMap {
                db.fetchCursorSpendSnapshot(accountIdentity: $0, range: range)
            }
            DispatchQueue.main.async {
                guard let self,
                      self.cursorSpendSnapshotRestoreGeneration == generation,
                      self.appFilter == .cursor,
                      self.isCursorDataPresentationAvailable,
                      (self.cursorPresentationIdentity ?? self.cachedCursorIdentity) == accountIdentity,
                      CursorSpendRange(
                          timeRange: self.timeRange,
                          now: self.currentDateProvider()
                      ) == range else {
                    return
                }
                self.cursorSpendSnapshot = cached
            }
        }
    }

    private func invalidateCursorSpendSnapshotRestore() {
        cursorSpendSnapshotRestoreGeneration += 1
    }

    private func refreshCursorSpend(
        range: CursorSpendRange,
        force: Bool,
        cancellation: AgentSyncCancellation?,
        completion: @escaping () -> Void = {}
    ) {
        guard let cursorSpendRefresher,
              enabledAgents.contains(.cursor),
              isPanelVisible,
              isCursorRefreshAvailable else {
            completion()
            return
        }
        cursorSpendRefreshGeneration += 1
        let generation = cursorSpendRefreshGeneration
        if cursorSpendSnapshot?.range != range {
            cursorSpendSnapshot = nil
        }
        let expectedAccountIdentity = cachedCursorIdentity
        cursorSpendRefresher.refresh(
            range: range,
            expectedAccountIdentity: expectedAccountIdentity,
            force: force,
            cancellation: cancellation
        ) { [weak self] outcome in
            defer { completion() }
            guard let self,
                  self.cursorSpendRefreshGeneration == generation,
                  self.isPanelVisible,
                  self.enabledAgents.contains(.cursor),
                  self.isCursorRefreshAvailable else {
                return
            }
            let currentRange = CursorSpendRange(
                timeRange: self.timeRange,
                now: self.currentDateProvider()
            )
            if let snapshot = outcome.snapshot, currentRange == range {
                if case .verified(let identity) = self.cursorAccountPresentationState {
                    guard snapshot.accountIdentity == identity else { return }
                }
                self.cursorSpendSnapshot = snapshot
            } else if currentRange != range {
                self.restoreCursorSpendSnapshotForSelection()
            }
            self.applyCursorSpendRefreshOutcome(outcome)
        }
    }

    private func applyCursorUsageSyncOutcome(_ outcome: CursorUsageSyncOutcome) {
        switch outcome {
        case .success:
            clearCursorRefreshFailure(.usage)
        case .failure(let reason):
            recordCursorRefreshFailure(.usage, kind: failureKind(for: reason))
        case .cancelled, .skipped:
            break
        }
    }

    private func applyCursorSpendRefreshOutcome(_ outcome: CursorSpendRefreshOutcome) {
        switch outcome {
        case .success:
            clearCursorRefreshFailure(.spend)
        case .failure(_, let reason):
            recordCursorRefreshFailure(.spend, kind: failureKind(for: reason))
        case .cancelled, .superseded:
            break
        }
    }

    private func recordCursorRefreshFailure(
        _ component: CursorRefreshComponent,
        kind: CursorRefreshFailureKind
    ) {
        cursorRefreshFailures[component] = CursorRefreshFailure(
            component: component,
            kind: kind,
            attemptedAt: currentDateProvider()
        )
    }

    private func clearCursorRefreshFailure(_ component: CursorRefreshComponent) {
        cursorRefreshFailures.removeValue(forKey: component)
    }

    private func failureKind(
        for reason: CursorRefreshFailureReason
    ) -> CursorRefreshFailureKind {
        reason == .authentication ? .signInUnavailable : .refreshFailed
    }

    private func cursorFailureComponentList(_ components: [String]) -> String {
        guard let last = components.last else { return "" }
        guard components.count > 1 else { return last }
        if components.count == 2 {
            return components.joined(separator: " and ")
        }
        return "\(components.dropLast().joined(separator: ", ")), and \(last)"
    }

    func selectActivityDate(_ date: String) {
        guard let range = TimeRange.activityDay(date, now: currentDateProvider()) else { return }

        activityPresentationSettings?.isPresented = true
        activityDetailState = .hourly(date: date, usage: [], isLoading: true)
        timeRange = range
        loadHourlyTokenUsage(for: date)
    }

    func selectActivityDate(_ date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else { return }

        selectActivityDate(String(format: "%04d-%02d-%02d", year, month, day))
    }

    func setTimeRangeFromFilter(_ range: TimeRange) {
        let keepsActivityDetailPresented = isActivityDetailPresented
        let selectedDate = activityDateString(for: range)
        activityLoadGeneration += 1
        if keepsActivityDetailPresented, let selectedDate {
            activityDetailState = .hourly(date: selectedDate, usage: [], isLoading: true)
        } else if keepsActivityDetailPresented {
            activityDetailState = .range(range: range, series: .empty, isLoading: true)
        } else {
            activityDetailState = .closed
        }
        timeRange = range
    }

    func toggleActivityDetail() {
        guard hasEnabledAgents else { return }
        if isActivityDetailPresented {
            closeActivityDetail()
            return
        }

        activityPresentationSettings?.isPresented = true
        let selectedDate = activityDateString(for: timeRange)
        if let selectedDate {
            activityDetailState = .hourly(date: selectedDate, usage: [], isLoading: true)
            loadHourlyTokenUsage(for: selectedDate)
        } else {
            activityDetailState = .range(range: timeRange, series: .empty, isLoading: true)
            loadActivityRangeTokenUsage(for: timeRange)
        }
    }

    func toggleActivityChartStyle() {
        activityChartStyle = activityChartStyle.toggled
        activityPresentationSettings?.chartStyle = activityChartStyle
    }

    private func activityDateString(for range: TimeRange) -> String? {
        let date: Date
        switch range {
        case .today:
            date = currentDateProvider()
        case .custom(let start, let end):
            guard Calendar.current.isDate(start, inSameDayAs: end) else { return nil }
            date = start
        case .last7, .last30, .allTime:
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func closeActivityDetail() {
        activityLoadGeneration += 1
        activityPresentationSettings?.isPresented = false
        activityDetailState = .closed
    }

    func quotaRefreshPhase(for provider: QuotaProviderID) -> QuotaRefreshPhase {
        quotaRefreshPhases[provider] ?? .idle
    }

    private func restoreCachedQuotaSnapshots() {
        guard let quotaCache else { return }
        for provider in QuotaProviderID.allCases
            where quotaSettings.isEnabled(provider)
                && isAgentEnabled(for: provider, in: enabledAgents)
                && quotaSnapshots[provider]?.status != .available {
            let generation = quotaRestoreGenerations[provider] ?? 0
            quotaService.resolveIdentityDigest(provider: provider) { [weak self] identityDigest in
                guard let self, let identityDigest,
                      (self.quotaRestoreGenerations[provider] ?? 0) == generation else { return }
                quotaCache.load(
                    provider: provider,
                    identityDigest: identityDigest,
                    now: self.currentDateProvider()
                ) { [weak self] snapshot in
                    guard let self, let snapshot else { return }
                    self.quotaService.resolveIdentityDigest(provider: provider) { [weak self] currentIdentity in
                        guard let self,
                              currentIdentity == identityDigest,
                              (self.quotaRestoreGenerations[provider] ?? 0) == generation,
                              self.quotaSettings.isEnabled(provider),
                              self.isAgentEnabled(for: provider, in: self.enabledAgents) else { return }
                        if let current = self.quotaSnapshots[provider], current.status == .available {
                            guard provider == .codex,
                                  current.resetCredits == nil,
                                  self.quotaSnapshotIdentities[provider] == identityDigest,
                                  let state = ResetCreditsState.restored(
                                    count: snapshot.resetCredits,
                                    expirations: snapshot.resetCreditExpirations,
                                    now: self.currentDateProvider()
                                  ) else { return }
                            let merged = current.replacingResetCredits(with: state)
                            self.quotaSnapshots[provider] = merged
                            self.quotaCache?.store(merged, identityDigest: identityDigest)
                        } else {
                            self.quotaSnapshots[provider] = snapshot
                            self.quotaSnapshotIdentities[provider] = identityDigest
                        }
                    }
                }
            }
        }
    }

    private func applyQuotaRefreshResult(
        _ result: QuotaRefreshResult,
        provider: QuotaProviderID
    ) {
        var snapshot = result.snapshot
        if snapshot.status == .available, let identityDigest = result.identityDigest {
            var shouldStoreSnapshot = true
            if provider == .codex {
                let resetCreditsState: ResetCreditsState?
                switch result.resetCreditsUpdate {
                case .authoritative(let state):
                    resetCreditsState = state
                case .notUpdated:
                    if quotaSnapshotIdentities[provider] == identityDigest,
                       let current = quotaSnapshots[provider] {
                        resetCreditsState = ResetCreditsState.restored(
                            count: current.resetCredits,
                            expirations: current.resetCreditExpirations,
                            now: currentDateProvider()
                        )
                    } else {
                        resetCreditsState = nil
                    }
                    shouldStoreSnapshot = resetCreditsState != nil
                case .notApplicable:
                    resetCreditsState = nil
                }
                snapshot = snapshot.replacingResetCredits(with: resetCreditsState)
            }
            quotaSnapshots[provider] = snapshot
            quotaSnapshotIdentities[provider] = identityDigest
            quotaRefreshPhases[provider] = .idle
            if shouldStoreSnapshot {
                quotaCache?.store(snapshot, identityDigest: identityDigest)
            }
            return
        }

        let canRetainSuccess = result.identityDigest != nil
            && quotaSnapshotIdentities[provider] == result.identityDigest
            && quotaSnapshots[provider]?.status == .available
            && shouldRetainSuccessfulQuota(for: snapshot.status)
        if !canRetainSuccess {
            quotaSnapshots[provider] = snapshot
            quotaSnapshotIdentities.removeValue(forKey: provider)
        }
        quotaRefreshPhases[provider] = .failed(
            status: snapshot.status,
            attemptedAt: snapshot.fetchedAt
        )
    }

    private func normalizeCodexResetCredits(at date: Date) {
        guard let snapshot = quotaSnapshots[.codex], snapshot.status == .available else { return }
        let state = ResetCreditsState.restored(
            count: snapshot.resetCredits,
            expirations: snapshot.resetCreditExpirations,
            now: date
        )
        let normalized = snapshot.replacingResetCredits(with: state)
        if normalized != snapshot {
            quotaSnapshots[.codex] = normalized
        }
    }

    private func shouldRetainSuccessfulQuota(for status: QuotaSnapshotStatus) -> Bool {
        switch status {
        case .authenticationExpired, .unavailable:
            return true
        case .available, .notInstalled, .thirdPartyConfigured, .signedOut:
            return false
        }
    }

    private func retainQuotaPresentationState(
        where shouldRetain: (QuotaProviderID) -> Bool
    ) {
        quotaRefreshPhases = quotaRefreshPhases.filter { shouldRetain($0.key) }
        quotaSnapshotIdentities = quotaSnapshotIdentities.filter { shouldRetain($0.key) }
        for provider in QuotaProviderID.allCases where !shouldRetain(provider) {
            quotaRefreshGenerations[provider, default: 0] += 1
            quotaRestoreGenerations[provider, default: 0] += 1
        }
    }

    private func loadHourlyTokenUsage(for date: String) {
        let app = appFilter
        let enabledAgents = enabledAgents
        let cursorQueryContext = cursorBoundQueryContext(from: enabledAgents)
        let queryEnabledAgents = cursorQueryContext.enabledAgents
        let cursorDataPresentationToken = cursorQueryContext.token
        let cursorAccountPresentationState = cursorAccountPresentationState
        activityLoadGeneration += 1
        let generation = activityLoadGeneration
        let loader = hourlyTokenUsageLoader
        DispatchQueue.global(qos: .userInitiated).async { [db] in
            let usage = loader(db, app, queryEnabledAgents, date)
            let isCursorDataPresentationTokenCurrent = cursorDataPresentationToken.map {
                db.isCursorDataPresentationTokenCurrent($0)
            } ?? true
            DispatchQueue.main.async { [weak self] in
                guard
                    let self,
                    self.selectedActivityDate == date,
                    self.appFilter == app,
                    self.enabledAgents == enabledAgents,
                    self.cursorAccountPresentationState == cursorAccountPresentationState,
                    self.activityLoadGeneration == generation,
                    isCursorDataPresentationTokenCurrent
                else {
                    return
                }
                self.performCursorBoundPublication(
                    token: cursorDataPresentationToken
                ) {
                    self.activityDetailState = .hourly(
                        date: date,
                        usage: usage,
                        isLoading: false
                    )
                }
            }
        }
    }

    private func loadActivityRangeTokenUsage(for range: TimeRange) {
        let app = appFilter
        let enabledAgents = enabledAgents
        let cursorQueryContext = cursorBoundQueryContext(from: enabledAgents)
        let queryEnabledAgents = cursorQueryContext.enabledAgents
        let cursorDataPresentationToken = cursorQueryContext.token
        let cursorAccountPresentationState = cursorAccountPresentationState
        activityLoadGeneration += 1
        let generation = activityLoadGeneration
        let loader = activityRangeTokenUsageLoader
        DispatchQueue.global(qos: .userInitiated).async { [db] in
            let series = loader(db, app, queryEnabledAgents, range)
            let isCursorDataPresentationTokenCurrent = cursorDataPresentationToken.map {
                db.isCursorDataPresentationTokenCurrent($0)
            } ?? true
            DispatchQueue.main.async { [weak self] in
                guard
                    let self,
                    self.activityDetailRequest == .range(range),
                    self.appFilter == app,
                    self.enabledAgents == enabledAgents,
                    self.cursorAccountPresentationState == cursorAccountPresentationState,
                    self.activityLoadGeneration == generation,
                    isCursorDataPresentationTokenCurrent
                else {
                    return
                }
                self.performCursorBoundPublication(
                    token: cursorDataPresentationToken
                ) {
                    self.activityDetailState = .range(
                        range: range,
                        series: series,
                        isLoading: false
                    )
                }
            }
        }
    }

    private var activityDetailRequest: ActivityDetailRequest? {
        switch activityDetailState {
        case .closed:
            return nil
        case .hourly(let date, _, _):
            return .hourly(date: date)
        case .range(let range, _, _):
            return .range(range)
        }
    }

    private func markActivityDetailLoading() {
        switch activityDetailState {
        case .closed:
            break
        case .hourly(let date, let usage, _):
            activityDetailState = .hourly(date: date, usage: usage, isLoading: true)
        case .range(let range, let series, _):
            activityDetailState = .range(range: range, series: series, isLoading: true)
        }
    }

    private func resetToTodayAfterDayRolloverIfNeeded() -> Bool {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: currentDateProvider())
        guard !calendar.isDate(activeDay, inSameDayAs: today) else { return false }

        activeDay = today
        setTimeRangeFromFilter(.today)
        return true
    }
}
