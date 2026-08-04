import CoreGraphics
import Foundation

enum ActivityTokenChartLayout {
    static let drawerHeight: CGFloat = 190
    static let chartHeight: CGFloat = 128
    static let chartHeaderHeight: CGFloat = 14
    static let chartLegendHeight: CGFloat = 12
    static let chartSectionSpacing: CGFloat = 8
    static let chartVerticalPadding: CGFloat = 10
    static let defaultTooltipWidth: CGFloat = 120
    static let chartTooltipWidth: CGFloat = 150
    static let rangeChartTooltipWidth: CGFloat = 170
    static let chartTooltipGap: CGFloat = 8
    static let monthLabelWidth: CGFloat = 24
    static let monthLabelHeight: CGFloat = 11
    static let hourAxisMarkInterval = 3
    static let lastHourAxisMark = 21
    static let lastChartHour = 23
    static let hourAxisMarks = Array(
        stride(from: 0, through: lastHourAxisMark, by: hourAxisMarkInterval)
    ) + [lastChartHour]
    static let heatmapIntensities: [Double] = [0.20, 0.40, 0.60, 0.80, 1.0]

    static var requiredDrawerHeight: CGFloat {
        chartHeaderHeight
            + chartHeight
            + chartLegendHeight
            + chartSectionSpacing * 2
            + chartVerticalPadding * 2
    }

    static func hourAxisLabel(for hour: Int) -> String {
        "\(hour)h"
    }

    static func rangeHourAxisLabel(for date: Date, calendar: Calendar = .current) -> String {
        "\(calendar.component(.hour, from: date))h"
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

    static func rangeHourLabel(for start: Date, calendar: Calendar = .current) -> String {
        let end = calendar.date(byAdding: .hour, value: 1, to: start)!
        let startFormatter = DateFormatter()
        startFormatter.locale = Locale(identifier: "en_US_POSIX")
        startFormatter.calendar = calendar
        startFormatter.dateFormat = "MMM d, yyyy HH:mm"
        let endFormatter = DateFormatter()
        endFormatter.locale = Locale(identifier: "en_US_POSIX")
        endFormatter.calendar = calendar
        endFormatter.dateFormat = "HH:mm"
        return "\(startFormatter.string(from: start)) - \(endFormatter.string(from: end))"
    }

    static func weekLabelBounds(
        for periodStart: Date,
        range: TimeRange,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        let periodEnd = calendar.date(byAdding: .day, value: 6, to: periodStart)!
        let bounds = range.bounds(now: now, calendar: calendar)
        let rangeStart = bounds.start.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let rangeEnd = bounds.end.flatMap {
            calendar.date(
                byAdding: .day,
                value: -1,
                to: Date(timeIntervalSince1970: TimeInterval($0))
            )
        }
        return (
            start: rangeStart.map { max(periodStart, $0) } ?? periodStart,
            end: rangeEnd.map { min(periodEnd, $0) } ?? periodEnd
        )
    }

    static func tooltipXOffset(
        anchorX: CGFloat,
        tooltipWidth: CGFloat,
        availableWidth: CGFloat,
        gap: CGFloat = chartTooltipGap
    ) -> CGFloat {
        let rightOffset = anchorX + gap
        let leftOffset = anchorX - gap - tooltipWidth
        let proposedOffset = leftOffset >= 0
            ? leftOffset
            : rightOffset
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

    static func rangeAxisMarks(count: Int, maximumMarkCount: Int = 9) -> [Int] {
        guard count > 1 else { return count == 1 ? [0] : [] }
        let markCount = min(count, max(2, maximumMarkCount))
        return (0..<markCount).map { index in
            Int(
                (Double(index) * Double(count - 1) / Double(markCount - 1))
                    .rounded()
            )
        }
    }

    static func rangeHourAxisMarks(
        bucketCount: Int,
        dayCount: Int,
        includesEndBoundary: Bool
    ) -> [Int] {
        guard bucketCount > 0 else { return [] }
        let interval: Int
        switch dayCount {
        case 2: interval = 6
        case 3: interval = 8
        default: interval = hourAxisMarkInterval
        }
        let domainEnd = includesEndBoundary ? bucketCount : bucketCount - 1
        var marks = Array(stride(from: 0, through: domainEnd, by: interval))
        if let lastMark = marks.last, lastMark != domainEnd {
            if domainEnd - lastMark < interval / 2 {
                marks[marks.count - 1] = domainEnd
            } else {
                marks.append(domainEnd)
            }
        }
        return marks
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
        return Double(min(max(0, hour), lastChartHour))
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
