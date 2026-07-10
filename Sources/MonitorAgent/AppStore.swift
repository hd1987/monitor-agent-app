import Foundation
import SwiftUI
import Combine

final class AppStore: ObservableObject {
    @Published var appFilter: AppFilter = .all
    @Published var timeRange: TimeRange = .today
    @Published var heatmapMode: HeatmapMode = .trailing

    @Published var stats = UsageStats()
    @Published var heatmap: [DayActivity] = []
    @Published var selectedActivityDate: String?
    @Published var hourlyTokenUsage: [HourlyTokenUsage] = []
    @Published var modelDistribution: [ModelShare] = []
    @Published var availableYears: [Int] = []
    @Published var isRebuildingUsageData = false
    @Published var usageDataRebuildProgress: SessionSyncProgress?
    @Published var usageDataRebuildSummary: UsageDataRebuildSummary?
    @Published var usageDataRebuildErrorMessage: String?

    private let db: DatabaseManager
    private let syncManager: SessionSyncManager
    private let syncSettings: SyncSettings
    private let currentDateProvider: () -> Date
    private var activeDay: Date
    private var cancellables = Set<AnyCancellable>()

    init(
        database: DatabaseManager = .shared,
        syncManager: SessionSyncManager? = nil,
        syncSettings: SyncSettings = .shared,
        autoStartSync: Bool = true,
        currentDateProvider: @escaping () -> Date = Date.init
    ) {
        self.db = database
        self.syncManager = syncManager ?? SessionSyncManager(database: database)
        self.syncSettings = syncSettings
        self.currentDateProvider = currentDateProvider
        self.activeDay = Calendar.current.startOfDay(for: currentDateProvider())

        DatabaseManager.cleanUpTemporaryRebuildDatabase()

        // React to filter changes
        Publishers.CombineLatest3($appFilter, $timeRange, $heatmapMode)
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _, _ in
                self?.reload()
            }
            .store(in: &cancellables)

        if autoStartSync {
            // React to sync interval changes
            syncSettings.$interval
                .sink { [weak self] interval in
                    self?.applySyncInterval(interval)
                }
                .store(in: &cancellables)
        }
    }

    /// Apply sync interval: start/restart timer or stop if "never".
    private func applySyncInterval(_ interval: SyncInterval) {
        if interval == .never {
            syncManager.stop()
        } else {
            syncManager.restart(interval: TimeInterval(interval.rawValue)) { [weak self] in
                self?.reload()
            }
        }
    }

    /// Trigger a one-shot sync + reload (called when panel opens).
    func sync() {
        guard !isRebuildingUsageData else { return }
        syncManager.syncOnce { [weak self] in
            self?.reload()
        }
    }

    func rebuildLocalUsageData() {
        guard !isRebuildingUsageData else { return }

        isRebuildingUsageData = true
        usageDataRebuildProgress = nil
        usageDataRebuildSummary = nil
        usageDataRebuildErrorMessage = nil
        syncManager.stop()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            do {
                let summary = try syncManager.performExclusive {
                    try UsageDataRebuilder(activeDatabase: self.db).rebuild { [weak self] progress in
                        DispatchQueue.main.async {
                            self?.usageDataRebuildProgress = progress
                        }
                    }
                }
                DispatchQueue.main.async {
                    self.usageDataRebuildSummary = summary
                    self.isRebuildingUsageData = false
                    self.applySyncInterval(self.syncSettings.interval)
                    self.reload()
                }
            } catch {
                DispatchQueue.main.async {
                    self.usageDataRebuildErrorMessage = error.localizedDescription
                    self.isRebuildingUsageData = false
                    self.applySyncInterval(self.syncSettings.interval)
                }
            }
        }
    }

    func prepareUsageDataRebuild() {
        guard !isRebuildingUsageData else { return }
        usageDataRebuildProgress = nil
        usageDataRebuildSummary = nil
        usageDataRebuildErrorMessage = nil
    }

    func reload() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.reload()
            }
            return
        }

        resetToTodayAfterDayRolloverIfNeeded()

        let appFilter = appFilter
        let timeRange = timeRange
        let heatmapMode = heatmapMode
        let selectedActivityDate = selectedActivityDate
        let db = db

        DispatchQueue.global(qos: .userInitiated).async {
            let s = db.fetchStats(app: appFilter, range: timeRange)
            let cal = Calendar.current
            let h: [DayActivity]
            switch heatmapMode {
            case .trailing:
                let today = cal.startOfDay(for: Date())
                let start = cal.date(byAdding: .day, value: -364, to: today)!
                let end = cal.date(byAdding: .day, value: 1, to: today)!
                h = db.fetchHeatmap(app: appFilter, from: start, to: end)
            case .year(let year):
                let start = cal.date(from: DateComponents(year: year, month: 1, day: 1))!
                let end = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1))!
                h = db.fetchHeatmap(app: appFilter, from: start, to: end)
            }
            let hourly = selectedActivityDate.map {
                db.fetchHourlyTokenUsage(app: appFilter, date: $0)
            } ?? []
            let m = db.fetchModelDistribution(app: appFilter, range: timeRange)
            let years = db.availableYears()

            DispatchQueue.main.async {
                guard
                    self.appFilter == appFilter,
                    self.timeRange == timeRange,
                    self.heatmapMode == heatmapMode,
                    self.selectedActivityDate == selectedActivityDate
                else {
                    return
                }

                self.stats = s
                self.heatmap = h
                self.hourlyTokenUsage = hourly
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

        selectedActivityDate = date
        timeRange = range
        loadHourlyTokenUsage(for: date)
    }

    func setTimeRangeFromFilter(_ range: TimeRange) {
        clearSelectedActivityDate()
        timeRange = range
    }

    func clearSelectedActivityDate() {
        selectedActivityDate = nil
        hourlyTokenUsage = []
    }

    private func loadHourlyTokenUsage(for date: String) {
        let app = appFilter
        DispatchQueue.global(qos: .userInitiated).async { [db] in
            let usage = db.fetchHourlyTokenUsage(app: app, date: date)
            DispatchQueue.main.async { [weak self] in
                guard self?.selectedActivityDate == date else { return }
                if usage.contains(where: \.hasTokenUsage) {
                    self?.hourlyTokenUsage = usage
                } else {
                    self?.clearSelectedActivityDate()
                }
            }
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
