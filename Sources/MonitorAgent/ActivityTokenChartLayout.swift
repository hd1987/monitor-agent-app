import CoreGraphics
import Foundation

enum ActivityTokenChartLayout {
    static let drawerHeight: CGFloat = 190
    static let chartHeight: CGFloat = 128
    static let defaultTooltipWidth: CGFloat = 120
    static let chartTooltipWidth: CGFloat = 150
    static let monthLabelWidth: CGFloat = 24
    static let monthLabelHeight: CGFloat = 11
    static let hourAxisMarkInterval = 3
    static let lastHourAxisMark = 21
    static let lastChartHour = 23
    static let hourAxisMarks = Array(stride(from: 0, through: lastHourAxisMark, by: hourAxisMarkInterval))
    static let heatmapIntensities: [Double] = [0.20, 0.40, 0.60, 0.80, 1.0]

    static func hourAxisLabel(for hour: Int) -> String {
        "\(hour)h"
    }

    static func tokenAxisLabel(for value: Double) -> String {
        let roundedValue = max(0, value)
        if roundedValue >= 1_000_000_000 {
            return String(format: "%.0fB", roundedValue / 1_000_000_000)
        }
        if roundedValue >= 1_000_000 {
            return String(format: "%.0fM", roundedValue / 1_000_000)
        }
        if roundedValue >= 1_000 {
            return String(format: "%.0fK", roundedValue / 1_000)
        }
        return String(format: "%.0f", roundedValue)
    }

    static func hourRangeLabel(for hour: Int) -> String {
        let startHour = min(max(0, hour), lastChartHour)
        let endHour = (startHour + 1) % 24
        return String(format: "%02d:00-%02d:00", startHour, endHour)
    }

    static func tooltipXOffset(anchorX: CGFloat, tooltipWidth: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let proposedOffset = anchorX - tooltipWidth / 2
        let maxOffset = max(0, availableWidth - tooltipWidth)
        return min(max(0, proposedOffset), maxOffset)
    }

    static func monthLabelXOffset(
        column: Int,
        cellSize: CGFloat,
        cellSpacing: CGFloat,
        availableWidth: CGFloat
    ) -> CGFloat {
        let proposedOffset = CGFloat(column) * (cellSize + cellSpacing)
        let maxOffset = max(0, availableWidth - monthLabelWidth)
        return min(max(0, proposedOffset), maxOffset)
    }

    static func hoveredHour(forChartXValue value: Double) -> Int {
        min(max(0, Int(value.rounded())), lastChartHour)
    }

    static func currentHourPosition(
        for dateString: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Double? {
        let parts = dateString.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(
                year: parts[0],
                month: parts[1],
                day: parts[2]
              )),
              calendar.isDate(date, inSameDayAs: now) else {
            return nil
        }

        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        return min(Double(lastChartHour) + 0.99, Double(hour) + Double(minute) / 60)
    }

    static func heatmapThresholds(for counts: [Int]) -> [Int] {
        let sortedCounts = counts.filter { $0 > 0 }.sorted()
        guard !sortedCounts.isEmpty else { return [] }

        return [0.2, 0.4, 0.6, 0.8].map { quantile in
            let index = Int((Double(sortedCounts.count - 1) * quantile).rounded())
            return sortedCounts[index]
        }
    }

    static func heatmapIntensity(for count: Int, thresholds: [Int]) -> Double {
        guard count > 0 else { return 0 }
        let level = thresholds.reduce(0) { partialResult, threshold in
            partialResult + (count > threshold ? 1 : 0)
        }
        return heatmapIntensities[min(level, heatmapIntensities.count - 1)]
    }

    static func visibleUsage(
        _ usage: [HourlyTokenUsage],
        for dateString: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [HourlyTokenUsage] {
        let parts = dateString.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return usage }

        guard let date = calendar.date(from: DateComponents(
            year: parts[0],
            month: parts[1],
            day: parts[2]
        )) else {
            return usage
        }

        guard calendar.isDate(date, inSameDayAs: now) else { return usage }

        let currentHour = min(max(0, calendar.component(.hour, from: now)), lastChartHour)
        return usage.filter { $0.hour <= currentHour }
    }
}
