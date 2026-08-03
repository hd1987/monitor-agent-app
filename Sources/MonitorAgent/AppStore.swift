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

final class AppStore: ObservableObject {
    @Published var appFilter: AppFilter = .all
    @Published var timeRange: TimeRange = .today
    @Published var heatmapMode: HeatmapMode = .trailing

    @Published var stats = UsageStats()
    @Published var heatmap: [DayActivity] = []
    @Published private(set) var activityDetailState: ActivityDetailState = .closed
    @Published var modelDistribution: [ModelShare] = []
    @Published var availableYears: [Int] = []
    @Published var isRebuildingUsageData = false
    @Published var usageDataRebuildProgress: SessionSyncProgress?
    @Published var usageDataRebuildSummary: UsageDataRebuildSummary?
    @Published var usageDataRebuildErrorMessage: String?
    @Published var usageDataRebuildWasCancelled = false
    @Published var quotaSnapshots: [QuotaProviderID: QuotaSnapshot] = [:]
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
    private let refreshCoordinator: PanelRefreshCoordinator
    private let hourlyTokenUsageLoader: HourlyTokenUsageLoader
    private let activityRangeTokenUsageLoader: ActivityRangeTokenUsageLoader
    private var activeDay: Date
    private var cancellables = Set<AnyCancellable>()
    private var usageDataRebuildCancellation: UsageDataRebuildCancellation?
    private var activeAgentSyncCancellation: AgentSyncCancellation?
    private var activeQuotaParticipants: [QuotaProviderID: RefreshCycleParticipant] = [:]
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
        self.refreshCoordinator = refreshCoordinator
        self.hourlyTokenUsageLoader = hourlyTokenUsageLoader
        self.activityRangeTokenUsageLoader = activityRangeTokenUsageLoader
        self.activeDay = Calendar.current.startOfDay(for: currentDateProvider())
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

    }

    var availableAppFilters: [AppFilter] { AppFilter.available(for: enabledAgents) }
    var hasEnabledAgents: Bool { !enabledAgents.isEmpty }
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

        let group = DispatchGroup()
        let syncCancellation = AgentSyncCancellation(enabledAgents: enabledAgents)
        activeAgentSyncCancellation = syncCancellation

        group.enter()
        syncManager.syncOnce(
            enabledAgents: enabledAgents,
            cancellation: syncCancellation,
            onLocalComplete: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.isPanelVisible else { return }
                    self.reload()
                }
            },
            onCursorComplete: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.isPanelVisible else { return }
                    self.reload()
                }
            },
            completion: {
                group.leave()
            }
        )

        for provider in QuotaProviderID.allCases
            where quotaSettings.isEnabled(provider) && isAgentEnabled(for: provider, in: enabledAgents) {
            group.enter()
            let participant = RefreshCycleParticipant {
                group.leave()
            }
            activeQuotaParticipants[provider] = participant
            quotaService.refresh(
                provider: provider,
                now: Date()
            ) { [weak self] snapshot in
                DispatchQueue.main.async {
                    if let self,
                       self.activeQuotaParticipants[provider] === participant {
                        self.activeQuotaParticipants.removeValue(forKey: provider)
                        if self.quotaSettings.isEnabled(provider),
                           self.isAgentEnabled(for: provider, in: self.enabledAgents) {
                            self.quotaSnapshots[provider] = snapshot
                        }
                    }
                    participant.finish()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            if self?.activeAgentSyncCancellation === syncCancellation {
                self?.activeAgentSyncCancellation = nil
            }
            completion()
        }
    }

    /// Start one unified visible-panel refresh lifecycle.
    func panelDidOpen() {
        isPanelVisible = true
        applyRefreshInterval(refreshSettings.interval, throttleInitialRefresh: true)
    }

    /// Stop periodic refreshing when the panel is hidden.
    func panelDidClose() {
        isPanelVisible = false
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
    }

    var visibleQuotaProviders: [QuotaProviderID] {
        let filtered: [QuotaProviderID]
        switch appFilter {
        case .all: filtered = QuotaProviderID.allCases
        case .claude: filtered = [.claude]
        case .codex: filtered = [.codex]
        case .cursor: filtered = []
        }
        return filtered.filter { isAgentEnabled(for: $0, in: enabledAgents) }
    }

    func cycleAppFilter(reverse: Bool = false) {
        appFilter = appFilter.cycled(in: availableAppFilters, reverse: reverse)
    }

    private func monitoringSettingsDidChange(_ enabledAgents: Set<AgentID>) {
        self.enabledAgents = enabledAgents
        activeAgentSyncCancellation?.disableAgents(notIn: enabledAgents)
        cancelQuotaParticipants(disabledBy: enabledAgents)
        let filters = AppFilter.available(for: enabledAgents)
        if enabledAgents.isEmpty {
            clearSelectedActivityDate()
            reload(enabledAgents: enabledAgents)
        } else if !filters.contains(appFilter) {
            clearSelectedActivityDate()
            appFilter = .all
        } else {
            reload(enabledAgents: enabledAgents)
        }
        quotaSnapshots = quotaSnapshots.filter {
            isAgentEnabled(for: $0.key, in: enabledAgents)
        }
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

        isRebuildingUsageData = true
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
                        cursorUsageServiceFactory: { CursorUsageService(database: $0) }
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

        resetToTodayAfterDayRolloverIfNeeded()
        reloadGeneration += 1
        activityLoadGeneration += 1

        let appFilter = appFilter
        let enabledAgents = requestedEnabledAgents ?? self.enabledAgents
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
                enabledAgents: enabledAgents
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
                    enabledAgents: enabledAgents
                )
            case .year(let year):
                let start = cal.date(from: DateComponents(year: year, month: 1, day: 1))!
                let end = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1))!
                h = db.fetchHeatmap(
                    app: appFilter,
                    from: start,
                    to: end,
                    enabledAgents: enabledAgents
                )
            }
            let hourly: [HourlyTokenUsage]
            let ranged: ActivityRangeTokenSeries
            switch activityDetailRequest {
            case .hourly(let date):
                hourly = hourlyTokenUsageLoader(db, appFilter, enabledAgents, date)
                ranged = .empty
            case .range(let range):
                hourly = []
                ranged = activityRangeTokenUsageLoader(db, appFilter, enabledAgents, range)
            case nil:
                hourly = []
                ranged = .empty
            }
            let m = db.fetchModelDistribution(
                app: appFilter,
                range: timeRange,
                enabledAgents: enabledAgents
            )
            let years = db.availableYears(enabledAgents: enabledAgents)

            DispatchQueue.main.async {
                guard
                    self.appFilter == appFilter,
                    self.enabledAgents == enabledAgents,
                    self.timeRange == timeRange,
                    self.heatmapMode == heatmapMode,
                    self.activityDetailRequest == activityDetailRequest,
                    self.reloadGeneration == reloadGeneration,
                    self.activityLoadGeneration == activityLoadGeneration
                else {
                    return
                }

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
                if case .year(let selectedYear) = self.heatmapMode,
                   !years.contains(selectedYear) {
                    self.heatmapMode = .trailing
                }
            }
        }
    }

    func selectActivityDate(_ date: String) {
        guard let range = TimeRange.activityDay(date, now: currentDateProvider()) else { return }

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
            clearSelectedActivityDate()
            return
        }

        let selectedDate = activityDateString(for: timeRange)
        if let selectedDate {
            activityDetailState = .hourly(date: selectedDate, usage: [], isLoading: true)
            loadHourlyTokenUsage(for: selectedDate)
        } else {
            activityDetailState = .range(range: timeRange, series: .empty, isLoading: true)
            loadActivityRangeTokenUsage(for: timeRange)
        }
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

    func clearSelectedActivityDate() {
        activityLoadGeneration += 1
        activityDetailState = .closed
    }

    private func loadHourlyTokenUsage(for date: String) {
        let app = appFilter
        let enabledAgents = enabledAgents
        activityLoadGeneration += 1
        let generation = activityLoadGeneration
        let loader = hourlyTokenUsageLoader
        DispatchQueue.global(qos: .userInitiated).async { [db] in
            let usage = loader(db, app, enabledAgents, date)
            DispatchQueue.main.async { [weak self] in
                guard
                    let self,
                    self.selectedActivityDate == date,
                    self.appFilter == app,
                    self.enabledAgents == enabledAgents,
                    self.activityLoadGeneration == generation
                else {
                    return
                }
                self.activityDetailState = .hourly(
                    date: date,
                    usage: usage,
                    isLoading: false
                )
            }
        }
    }

    private func loadActivityRangeTokenUsage(for range: TimeRange) {
        let app = appFilter
        let enabledAgents = enabledAgents
        activityLoadGeneration += 1
        let generation = activityLoadGeneration
        let loader = activityRangeTokenUsageLoader
        DispatchQueue.global(qos: .userInitiated).async { [db] in
            let series = loader(db, app, enabledAgents, range)
            DispatchQueue.main.async { [weak self] in
                guard
                    let self,
                    self.activityDetailRequest == .range(range),
                    self.appFilter == app,
                    self.enabledAgents == enabledAgents,
                    self.activityLoadGeneration == generation
                else {
                    return
                }
                self.activityDetailState = .range(
                    range: range,
                    series: series,
                    isLoading: false
                )
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

    private func resetToTodayAfterDayRolloverIfNeeded() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: currentDateProvider())
        guard !calendar.isDate(activeDay, inSameDayAs: today) else { return }

        activeDay = today
        timeRange = .today
        clearSelectedActivityDate()
    }
}
