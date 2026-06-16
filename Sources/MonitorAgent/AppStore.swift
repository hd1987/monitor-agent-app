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
    private var cancellables = Set<AnyCancellable>()

    init() {
        let years = DatabaseManager.shared.availableYears()
        self.availableYears = years
        self.selectedYear = years.first ?? Calendar.current.component(.year, from: Date())

        // React to filter changes
        Publishers.CombineLatest3($appFilter, $timeRange, $selectedYear)
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _, _ in
                self?.reload()
            }
            .store(in: &cancellables)

        reload()
    }

    func reload() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let s = db.fetchStats(app: appFilter, range: timeRange)
            let h = db.fetchHeatmap(app: appFilter, year: selectedYear)
            let m = db.fetchModelDistribution(app: appFilter, range: timeRange)

            DispatchQueue.main.async {
                self.stats = s
                self.heatmap = h
                self.modelDistribution = m
            }
        }
    }
}
