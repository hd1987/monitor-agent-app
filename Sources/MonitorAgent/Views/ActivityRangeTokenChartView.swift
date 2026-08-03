import CoreGraphics
import Foundation

struct ActivityChartUsage: Identifiable, Equatable {
    let index: Int
    let periodStart: Date?
    let hour: Int?
    let requestCount: Int
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64
    let cacheCreationTokens: Int64

    var id: Int { index }
}

enum ActivityChartData: Equatable {
    case hourly(date: String, usage: [HourlyTokenUsage])
    case range(range: TimeRange, series: ActivityRangeTokenSeries)

    var usage: [ActivityChartUsage] {
        switch self {
        case .hourly(let date, let usage):
            return ActivityTokenChartLayout.visibleUsage(usage, for: date).map { item in
                ActivityChartUsage(
                    index: item.hour,
                    periodStart: nil,
                    hour: item.hour,
                    requestCount: item.requestCount,
                    inputTokens: item.inputTokens,
                    outputTokens: item.outputTokens,
                    cacheReadTokens: item.cacheReadTokens,
                    cacheCreationTokens: item.cacheCreationTokens
                )
            }
        case .range(_, let series):
            return series.usage.enumerated().map { index, item in
                ActivityChartUsage(
                    index: index,
                    periodStart: item.periodStart,
                    hour: nil,
                    requestCount: item.requestCount,
                    inputTokens: item.inputTokens,
                    outputTokens: item.outputTokens,
                    cacheReadTokens: item.cacheReadTokens,
                    cacheCreationTokens: item.cacheCreationTokens
                )
            }
        }
    }

    var chartTitle: String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")

        switch self {
        case .hourly(let date, _):
            let input = DateFormatter()
            input.locale = Locale(identifier: "en_US_POSIX")
            input.dateFormat = "yyyy-MM-dd"
            return input.date(from: date).map(formatter.string(from:)) ?? date
        case .range(let range, _):
            return range.displayTitle(formatter: formatter)
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .hourly(let date, _):
            return "Hourly token usage for \(date)"
        case .range:
            return "Token usage for \(chartTitle)"
        }
    }

    var chartDomainEnd: Int {
        switch self {
        case .hourly:
            return ActivityTokenChartLayout.lastChartHour
        case .range(_, let series):
            if series.aggregation == .hour, includesHourEndBoundary {
                return max(1, series.usage.count)
            }
            return max(1, series.usage.count - 1)
        }
    }

    var xAxisMarks: [Int] {
        switch self {
        case .hourly:
            return ActivityTokenChartLayout.hourAxisMarks
        case .range(_, let series):
            if series.aggregation == .hour {
                return ActivityTokenChartLayout.rangeHourAxisMarks(
                    bucketCount: series.usage.count,
                    dayCount: selectedDayCount,
                    includesEndBoundary: includesHourEndBoundary
                )
            }
            return ActivityTokenChartLayout.rangeAxisMarks(count: series.usage.count)
        }
    }

    var nowPosition: Double? {
        guard case .hourly(let date, _) = self else { return nil }
        return ActivityTokenChartLayout.currentHourPosition(for: date)
    }

    var tooltipWidth: CGFloat {
        switch self {
        case .hourly: ActivityTokenChartLayout.chartTooltipWidth
        case .range: ActivityTokenChartLayout.rangeChartTooltipWidth
        }
    }

    func granularityLabel(isLoading: Bool) -> String? {
        switch self {
        case .hourly:
            return "Hour"
        case .range(_, let series):
            return isLoading ? nil : series.aggregation.rawValue.capitalized
        }
    }

    func axisLabel(for index: Int) -> String? {
        switch self {
        case .hourly:
            return ActivityTokenChartLayout.hourAxisLabel(for: index)
        case .range(_, let series):
            guard let date = axisDate(for: index) else { return nil }
            let formatter = DateFormatter()
            switch series.aggregation {
            case .hour:
                return ActivityTokenChartLayout.rangeHourAxisLabel(for: date)
            case .day:
                formatter.setLocalizedDateFormatFromTemplate("M/d")
            case .week:
                formatter.setLocalizedDateFormatFromTemplate("MMM d")
            case .month:
                formatter.setLocalizedDateFormatFromTemplate("MMM yy")
            }
            return formatter.string(from: date)
        }
    }

    func periodLabel(for item: ActivityChartUsage) -> String {
        switch self {
        case .hourly:
            return ActivityTokenChartLayout.hourRangeLabel(for: item.hour ?? item.index)
        case .range(let range, let series):
            guard let start = item.periodStart else { return "" }
            let formatter = DateFormatter()
            switch series.aggregation {
            case .hour:
                return ActivityTokenChartLayout.rangeHourLabel(for: start)
            case .day:
                formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
                return formatter.string(from: start)
            case .week:
                let bounds = ActivityTokenChartLayout.weekLabelBounds(
                    for: start,
                    range: range
                )
                formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
                return "\(formatter.string(from: bounds.start)) - \(formatter.string(from: bounds.end))"
            case .month:
                formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
                return formatter.string(from: start)
            }
        }
    }

    private var selectedDayCount: Int {
        guard case .range(let range, let series) = self else { return 1 }
        let calendar = Calendar.current
        let bounds = range.bounds(calendar: calendar)
        if let start = bounds.start, let end = bounds.end {
            return max(1, calendar.dateComponents(
                [.day],
                from: Date(timeIntervalSince1970: TimeInterval(start)),
                to: Date(timeIntervalSince1970: TimeInterval(end))
            ).day ?? 1)
        }
        return max(1, Int(ceil(Double(series.usage.count) / 24)))
    }

    private var includesHourEndBoundary: Bool {
        guard case .range(let range, let series) = self,
              series.aggregation == .hour,
              !series.usage.isEmpty else {
            return false
        }

        let now = Date()
        let bounds = range.bounds()
        if let end = bounds.end {
            return Date(timeIntervalSince1970: TimeInterval(end)) <= now
        }
        guard let last = series.usage.last else { return false }
        return Calendar.current.date(byAdding: .hour, value: 1, to: last.periodStart)! <= now
    }

    private func axisDate(for index: Int) -> Date? {
        guard case .range(_, let series) = self else { return nil }
        if series.usage.indices.contains(index) {
            return series.usage[index].periodStart
        }
        if index == series.usage.count, let last = series.usage.last {
            return Calendar.current.date(byAdding: .hour, value: 1, to: last.periodStart)
        }
        return nil
    }
}
