import Charts
import SwiftUI

struct ActivityRangeTokenChartView: View {
    @EnvironmentObject var theme: ThemeManager
    let range: TimeRange
    let series: ActivityRangeTokenSeries
    let isLoading: Bool
    @State private var hoveredIndex: Int?
    @State private var hiddenMetrics: Set<String> = []

    private var metricStyles: [ActivityRangeMetricStyle] {
        [
            ActivityRangeMetricStyle(name: "Input Tokens", color: ActivityTokenPalette.input),
            ActivityRangeMetricStyle(name: "Output Tokens", color: ActivityTokenPalette.output),
            ActivityRangeMetricStyle(name: "Cache Read", color: ActivityTokenPalette.cacheRead),
            ActivityRangeMetricStyle(name: "Cache Creation", color: ActivityTokenPalette.cacheCreation),
        ]
    }

    private var points: [ActivityRangeSeriesPoint] {
        series.usage.enumerated().flatMap { index, item in
            [
                ActivityRangeSeriesPoint(metric: "Input Tokens", index: index, value: Double(item.inputTokens)),
                ActivityRangeSeriesPoint(metric: "Output Tokens", index: index, value: Double(item.outputTokens)),
                ActivityRangeSeriesPoint(metric: "Cache Read", index: index, value: Double(item.cacheReadTokens)),
                ActivityRangeSeriesPoint(metric: "Cache Creation", index: index, value: Double(item.cacheCreationTokens)),
            ]
        }.filter { !hiddenMetrics.contains($0.metric) }
    }

    private var hoveredUsage: ActivityRangeTokenUsage? {
        guard let hoveredIndex, series.usage.indices.contains(hoveredIndex) else { return nil }
        return series.usage[hoveredIndex]
    }

    private var hoveredPoints: [ActivityRangeSeriesPoint] {
        guard let hoveredIndex, let item = hoveredUsage else { return [] }
        return [
            ActivityRangeSeriesPoint(metric: "Input Tokens", index: hoveredIndex, value: Double(item.inputTokens)),
            ActivityRangeSeriesPoint(metric: "Output Tokens", index: hoveredIndex, value: Double(item.outputTokens)),
            ActivityRangeSeriesPoint(metric: "Cache Read", index: hoveredIndex, value: Double(item.cacheReadTokens)),
            ActivityRangeSeriesPoint(metric: "Cache Creation", index: hoveredIndex, value: Double(item.cacheCreationTokens)),
        ].filter { !hiddenMetrics.contains($0.metric) }
    }

    private var maxValue: Double {
        max(points.map(\.value).max() ?? 0, 1)
    }

    private var chartDomainEnd: Int {
        if series.aggregation == .hour, includesHourEndBoundary {
            return max(1, series.usage.count)
        }
        return max(1, series.usage.count - 1)
    }

    private var xAxisMarks: [Int] {
        if series.aggregation == .hour {
            return ActivityTokenChartLayout.rangeHourAxisMarks(
                bucketCount: series.usage.count,
                dayCount: selectedDayCount,
                includesEndBoundary: includesHourEndBoundary
            )
        }
        return ActivityTokenChartLayout.rangeAxisMarks(count: series.usage.count)
    }

    private var selectedDayCount: Int {
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
        guard series.aggregation == .hour, !series.usage.isEmpty else { return false }
        let now = Date()
        let bounds = range.bounds()
        if let end = bounds.end {
            return Date(timeIntervalSince1970: TimeInterval(end)) <= now
        }
        guard let last = series.usage.last else { return false }
        return Calendar.current.date(byAdding: .hour, value: 1, to: last.periodStart)! <= now
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(chartTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                if !isLoading {
                    Text(series.aggregation.rawValue.capitalized)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.panelTertiaryForeground)
                }
                Spacer()
            }

            Chart(points) { point in
                AreaMark(
                    x: .value("Period", point.index),
                    yStart: .value("Baseline", 0),
                    yEnd: .value("Tokens", point.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(by: .value("Metric", point.metric))
                .opacity(0.12)

                LineMark(
                    x: .value("Period", point.index),
                    y: .value("Tokens", point.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(by: .value("Metric", point.metric))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartForegroundStyleScale([
                "Input Tokens": ActivityTokenPalette.input,
                "Output Tokens": ActivityTokenPalette.output,
                "Cache Read": ActivityTokenPalette.cacheRead,
                "Cache Creation": ActivityTokenPalette.cacheCreation,
            ])
            .chartXScale(domain: 0...chartDomainEnd)
            .chartYScale(domain: 0...maxValue)
            .chartXAxis {
                AxisMarks(values: xAxisMarks) { value in
                    AxisValueLabel(anchor: .top) {
                        if let index = value.as(Int.self), let date = axisDate(for: index) {
                            Text(axisLabel(for: date))
                                .foregroundStyle(theme.panelSecondaryForeground)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let tokenValue = value.as(Double.self) {
                            Text(ActivityTokenChartLayout.tokenAxisLabel(for: tokenValue))
                                .foregroundStyle(theme.panelSecondaryForeground)
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let plotFrame = proxy.plotFrame {
                        let plotAreaFrame = geometry[plotFrame]

                        ZStack(alignment: .topLeading) {
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location):
                                        updateHoveredIndex(at: location, in: plotAreaFrame, proxy: proxy)
                                    case .ended:
                                        hoveredIndex = nil
                                    }
                                }

                            if let hoveredIndex,
                               let hoveredUsage,
                               let plotX = proxy.position(forX: hoveredIndex) {
                                let anchorX = plotAreaFrame.minX + plotX
                                let tooltipOffset = ActivityTokenChartLayout.tooltipXOffset(
                                    anchorX: anchorX,
                                    tooltipWidth: ActivityTokenChartLayout.rangeChartTooltipWidth,
                                    availableWidth: geometry.size.width
                                )

                                ForEach(hoveredPoints) { point in
                                    if let plotY = proxy.position(forY: point.value) {
                                        chartIntersectionMarker(color: metricColor(for: point.metric))
                                            .position(x: anchorX, y: plotAreaFrame.minY + plotY)
                                            .allowsHitTesting(false)
                                    }
                                }

                                chartTooltip(for: hoveredUsage)
                                    .frame(width: ActivityTokenChartLayout.rangeChartTooltipWidth, alignment: .leading)
                                    .position(
                                        x: tooltipOffset + ActivityTokenChartLayout.rangeChartTooltipWidth / 2,
                                        y: plotAreaFrame.minY + 47
                                    )
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
            }
            .frame(height: ActivityTokenChartLayout.chartHeight)
            .overlay {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 16) {
                ForEach(metricStyles) { metric in
                    Button {
                        toggleMetric(metric.name)
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(metric.color)
                                .frame(width: 6, height: 6)
                            Text(metric.name)
                        }
                        .opacity(hiddenMetrics.contains(metric.name) ? 0.35 : 1)
                    }
                    .buttonStyle(.plain)
                    .help(hiddenMetrics.contains(metric.name) ? "Show \(metric.name)" : "Hide \(metric.name)")
                    .accessibilityLabel(hiddenMetrics.contains(metric.name) ? "Show \(metric.name)" : "Hide \(metric.name)")
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(theme.panelSecondaryForeground)
        }
        .padding(10)
        .frame(height: ActivityTokenChartLayout.drawerHeight)
        .mainPanelGroupedSurface()
        .accessibilityLabel("Token usage for \(chartTitle)")
    }

    private var chartTitle: String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
        return range.displayTitle(formatter: formatter)
    }

    private func toggleMetric(_ metric: String) {
        if hiddenMetrics.contains(metric) {
            hiddenMetrics.remove(metric)
        } else if hiddenMetrics.count < metricStyles.count - 1 {
            hiddenMetrics.insert(metric)
        }
    }

    private func updateHoveredIndex(at location: CGPoint, in plotAreaFrame: CGRect, proxy: ChartProxy) {
        guard plotAreaFrame.contains(location), !series.usage.isEmpty else {
            hoveredIndex = nil
            return
        }

        let plotX = location.x - plotAreaFrame.minX
        guard let value = proxy.value(atX: plotX, as: Double.self) else { return }
        hoveredIndex = min(max(0, Int(value.rounded())), series.usage.count - 1)
    }

    private func axisDate(for index: Int) -> Date? {
        if series.usage.indices.contains(index) {
            return series.usage[index].periodStart
        }
        if index == series.usage.count, let last = series.usage.last {
            return Calendar.current.date(byAdding: .hour, value: 1, to: last.periodStart)
        }
        return nil
    }

    private func axisLabel(for date: Date) -> String {
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

    private func periodLabel(for item: ActivityRangeTokenUsage) -> String {
        let start = item.periodStart
        let formatter = DateFormatter()
        switch series.aggregation {
        case .hour:
            return ActivityTokenChartLayout.rangeHourLabel(for: start)
        case .day:
            formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
            return formatter.string(from: start)
        case .week:
            let bounds = ActivityTokenChartLayout.weekLabelBounds(for: start, range: range)
            formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
            return "\(formatter.string(from: bounds.start)) - \(formatter.string(from: bounds.end))"
        case .month:
            formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
            return formatter.string(from: start)
        }
    }

    private func chartTooltip(for item: ActivityRangeTokenUsage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(periodLabel(for: item))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.tooltipForeground)
                .lineLimit(1)

            Divider()
                .overlay(theme.tooltipForeground.opacity(0.14))
                .padding(.vertical, 1)

            requestRow(value: item.requestCount)
            tokenRow(label: "Input", color: ActivityTokenPalette.input, value: item.inputTokens)
            tokenRow(label: "Output", color: ActivityTokenPalette.output, value: item.outputTokens)
            tokenRow(label: "Cache", color: ActivityTokenPalette.cacheRead, value: item.cacheReadTokens)
            tokenRow(label: "Created", color: ActivityTokenPalette.cacheCreation, value: item.cacheCreationTokens)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .mainPanelTooltipSurface()
    }

    private func chartIntersectionMarker(color: Color) -> some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.16))
                .frame(width: 16, height: 16)
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.95), lineWidth: 1.25)
                }
        }
    }

    private func metricColor(for metric: String) -> Color {
        switch metric {
        case "Input Tokens": ActivityTokenPalette.input
        case "Output Tokens": ActivityTokenPalette.output
        case "Cache Read": ActivityTokenPalette.cacheRead
        default: ActivityTokenPalette.cacheCreation
        }
    }

    private func requestRow(value: Int) -> some View {
        HStack(spacing: 5) {
            Text("Requests")
                .foregroundStyle(theme.tooltipForeground.opacity(0.85))
            Spacer(minLength: 6)
            Text(formatCount(value))
                .fontWeight(.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(theme.tooltipForeground)
        }
        .font(.system(size: 9))
    }

    private func tokenRow(label: String, color: Color, value: Int64) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .foregroundStyle(theme.tooltipForeground.opacity(0.85))
            Spacer(minLength: 6)
            Text(formatTokens(value))
                .fontWeight(.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(theme.tooltipForeground)
        }
        .font(.system(size: 9))
    }
}

private struct ActivityRangeSeriesPoint: Identifiable {
    let metric: String
    let index: Int
    let value: Double
    var id: String { "\(metric)-\(index)" }
}

private struct ActivityRangeMetricStyle: Identifiable {
    let name: String
    let color: Color
    var id: String { name }
}
