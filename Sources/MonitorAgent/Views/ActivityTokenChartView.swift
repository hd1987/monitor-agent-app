import Charts
import SwiftUI

struct ActivityTokenChartView: View {
    @EnvironmentObject var theme: ThemeManager
    let date: String
    let usage: [HourlyTokenUsage]
    let isLoading: Bool
    @State private var hoveredHour: Int?
    @State private var hiddenMetrics: Set<String> = []

    private var metricStyles: [TokenMetricStyle] {
        [
            TokenMetricStyle(name: "Input Tokens", color: .blue),
            TokenMetricStyle(name: "Output Tokens", color: .green),
            TokenMetricStyle(name: "Cache Read", color: .orange),
            TokenMetricStyle(name: "Cache Creation", color: .purple),
        ]
    }

    private var visibleUsage: [HourlyTokenUsage] {
        ActivityTokenChartLayout.visibleUsage(usage, for: date)
    }

    private var points: [TokenSeriesPoint] {
        visibleUsage.flatMap { item in
            [
                TokenSeriesPoint(metric: "Input Tokens", hour: item.hour, value: Double(item.inputTokens)),
                TokenSeriesPoint(metric: "Output Tokens", hour: item.hour, value: Double(item.outputTokens)),
                TokenSeriesPoint(metric: "Cache Read", hour: item.hour, value: Double(item.cacheReadTokens)),
                TokenSeriesPoint(metric: "Cache Creation", hour: item.hour, value: Double(item.cacheCreationTokens)),
            ]
        }.filter { !hiddenMetrics.contains($0.metric) }
    }

    private var maxValue: Double {
        max(points.map(\.value).max() ?? 0, 1)
    }

    private var hoveredUsage: HourlyTokenUsage? {
        guard let hoveredHour else { return nil }
        return visibleUsage.first { $0.hour == hoveredHour }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(chartTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
            }

            Chart(points) { point in
                LineMark(
                    x: .value("Hour", point.hour),
                    y: .value("Tokens", point.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(by: .value("Metric", point.metric))
            }
            .chartForegroundStyleScale([
                "Input Tokens": Color.blue,
                "Output Tokens": Color.green,
                "Cache Read": Color.orange,
                "Cache Creation": Color.purple,
            ])
            .chartXScale(domain: 0...23)
            .chartYScale(domain: 0...maxValue)
            .chartXAxis {
                AxisMarks(values: ActivityTokenChartLayout.hourAxisMarks) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let hour = value.as(Int.self) {
                            Text(ActivityTokenChartLayout.hourAxisLabel(for: hour))
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
                            if let nowHour = ActivityTokenChartLayout.currentHourPosition(for: date),
                               let plotX = proxy.position(forX: nowHour) {
                                let nowX = plotAreaFrame.minX + plotX
                                let futureWidth = max(0, plotAreaFrame.maxX - nowX)

                                Rectangle()
                                    .fill(Color.secondary.opacity(0.06))
                                    .frame(width: futureWidth, height: plotAreaFrame.height)
                                    .position(
                                        x: nowX + futureWidth / 2,
                                        y: plotAreaFrame.midY
                                    )
                                    .allowsHitTesting(false)

                                Rectangle()
                                    .fill(Color.secondary.opacity(0.45))
                                    .frame(width: 1, height: plotAreaFrame.height)
                                    .position(x: nowX, y: plotAreaFrame.midY)
                                    .allowsHitTesting(false)

                                Text("Now")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .position(
                                        x: min(nowX + 14, plotAreaFrame.maxX - 14),
                                        y: plotAreaFrame.minY + 6
                                    )
                                    .allowsHitTesting(false)
                            }

                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location):
                                        updateHoveredHour(at: location, in: plotAreaFrame, proxy: proxy)
                                    case .ended:
                                        hoveredHour = nil
                                    }
                                }

                            if let hoveredUsage, let plotX = proxy.position(forX: hoveredUsage.hour) {
                                let anchorX = plotAreaFrame.minX + plotX
                                let tooltipOffset = ActivityTokenChartLayout.tooltipXOffset(
                                    anchorX: anchorX,
                                    tooltipWidth: ActivityTokenChartLayout.chartTooltipWidth,
                                    availableWidth: geometry.size.width
                                )

                                Rectangle()
                                    .fill(Color.secondary.opacity(0.35))
                                    .frame(width: 1, height: plotAreaFrame.height)
                                    .position(x: anchorX, y: plotAreaFrame.midY)
                                    .allowsHitTesting(false)

                                chartTooltip(for: hoveredUsage)
                                    .frame(width: ActivityTokenChartLayout.chartTooltipWidth, alignment: .leading)
                                    .position(
                                        x: tooltipOffset + ActivityTokenChartLayout.chartTooltipWidth / 2,
                                        y: plotAreaFrame.minY + 34
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
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(height: ActivityTokenChartLayout.drawerHeight)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.cardBorder, lineWidth: 0.5)
        )
        .accessibilityLabel("Hourly token usage for \(date)")
    }

    private func toggleMetric(_ metric: String) {
        if hiddenMetrics.contains(metric) {
            hiddenMetrics.remove(metric)
        } else if hiddenMetrics.count < metricStyles.count - 1 {
            hiddenMetrics.insert(metric)
        }
    }

    private var chartTitle: String {
        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX")
        input.dateFormat = "yyyy-MM-dd"

        let output = DateFormatter()
        output.setLocalizedDateFormatFromTemplate("MMM d, yyyy")

        guard let parsedDate = input.date(from: date) else { return date }
        return output.string(from: parsedDate)
    }

    private func updateHoveredHour(at location: CGPoint, in plotAreaFrame: CGRect, proxy: ChartProxy) {
        guard plotAreaFrame.contains(location) else {
            hoveredHour = nil
            return
        }

        let plotX = location.x - plotAreaFrame.minX
        guard let value = proxy.value(atX: plotX, as: Double.self) else { return }
        hoveredHour = ActivityTokenChartLayout.hoveredHour(forChartXValue: value)
    }

    private func chartTooltip(for item: HourlyTokenUsage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(ActivityTokenChartLayout.hourRangeLabel(for: item.hour))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.tooltipForeground)
            requestRow(value: item.requestCount)
            tokenRow(label: "Input", color: .blue, value: item.inputTokens)
            tokenRow(label: "Output", color: .green, value: item.outputTokens)
            tokenRow(label: "Cache", color: .orange, value: item.cacheReadTokens)
            tokenRow(label: "Created", color: .purple, value: item.cacheCreationTokens)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(theme.tooltipBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.10), radius: 5, x: 0, y: 2)
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

private struct TokenSeriesPoint: Identifiable {
    let metric: String
    let hour: Int
    let value: Double
    var id: String { "\(metric)-\(hour)" }
}

private struct TokenMetricStyle: Identifiable {
    let name: String
    let color: Color
    var id: String { name }
}
