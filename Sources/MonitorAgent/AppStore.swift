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

    private let db = DatabaseManager.shared
    private let syncManager = SessionSyncManager()
    private let syncSettings = SyncSettings.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        // React to filter changes
        Publishers.CombineLatest3($appFilter, $timeRange, $heatmapMode)
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _, _ in
                self?.reload()
            }
            .store(in: &cancellables)

        // React to sync interval changes
        syncSettings.$interval
            .sink { [weak self] interval in
                self?.applySyncInterval(interval)
            }
            .store(in: &cancellables)
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
        syncManager.syncOnce { [weak self] in
            self?.reload()
        }
    }

    func reload() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
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
                self.stats = s
                self.heatmap = h
                self.hourlyTokenUsage = hourly
                self.modelDistribution = m
                if !years.isEmpty {
                    self.availableYears = years
                }
            }
        }
    }

    func selectActivityDate(_ date: String) {
        guard let range = TimeRange.activityDay(date) else { return }

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
}
