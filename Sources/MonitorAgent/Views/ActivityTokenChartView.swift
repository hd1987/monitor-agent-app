import Charts
import SwiftUI

struct ActivityTokenChartView: View {
    @EnvironmentObject var theme: ThemeManager
    let date: String
    let usage: [HourlyTokenUsage]
    @State private var hoveredHour: Int?

    private var points: [TokenSeriesPoint] {
        usage.flatMap { item in
            [
                TokenSeriesPoint(metric: "Input Tokens", hour: item.hour, value: Double(item.inputTokens)),
                TokenSeriesPoint(metric: "Output Tokens", hour: item.hour, value: Double(item.outputTokens)),
                TokenSeriesPoint(metric: "Cache Read", hour: item.hour, value: Double(item.cacheReadTokens)),
            ]
        }
    }

    private var maxValue: Double {
        max(points.map(\.value).max() ?? 0, 1)
    }

    private var totalTokens: Int64 {
        usage.reduce(Int64(0)) { total, item in
            total + item.inputTokens + item.outputTokens + item.cacheReadTokens
        }
    }

    private var hoveredUsage: HourlyTokenUsage? {
        guard let hoveredHour else { return nil }
        return usage.first { $0.hour == hoveredHour }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(chartTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                Text(formatTokens(totalTokens))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
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
            .chartLegend(position: .bottom, alignment: .leading)
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
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(theme.tooltipBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
    }

    private func requestRow(value: Int) -> some View {
        HStack(spacing: 5) {
            Text("Requests")
                .foregroundStyle(theme.tooltipForeground.opacity(0.85))
            Spacer(minLength: 6)
            Text(formatCount(value))
                .fontWeight(.medium)
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
