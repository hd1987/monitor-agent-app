import Foundation
import SwiftUI
import Combine

final class AppStore: ObservableObject {
    @Published var appFilter: AppFilter = .all
    @Published var timeRange: TimeRange = .today
    @Published var selectedYear: Int

    @Published var stats = UsageStats()
    @Published var heatmap: [DayActivity] = []
    @Published var modelDistribution: [ModelShare] = []
    @Published var availableYears: [Int] = []

    private let db = DatabaseManager.shared
    private let syncManager = SessionSyncManager()
    private let syncSettings = SyncSettings.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        self.selectedYear = Calendar.current.component(.year, from: Date())

        // React to filter changes
        Publishers.CombineLatest3($appFilter, $timeRange, $selectedYear)
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
            let h = db.fetchHeatmap(app: appFilter, year: selectedYear)
            let m = db.fetchModelDistribution(app: appFilter, range: timeRange)
            let years = db.availableYears()

            DispatchQueue.main.async {
                self.stats = s
                self.heatmap = h
                self.modelDistribution = m
                if !years.isEmpty {
                    self.availableYears = years
                    // Keep selectedYear if valid, else use latest
                    if !years.contains(self.selectedYear) {
                        self.selectedYear = years.first!
                    }
                }
            }
        }
    }
}
