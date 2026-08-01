import Charts
import SwiftUI

enum ActivityTokenPalette {
    static let input: Color = .blue
    static let output: Color = .green
    static let cacheRead: Color = .orange
    static let cacheCreation: Color = .purple
}

struct ActivityTokenChartView: View {
    @EnvironmentObject var theme: ThemeManager
    let date: String
    let usage: [HourlyTokenUsage]
    let isLoading: Bool
    @State private var hoveredHour: Int?
    @State private var hiddenMetrics: Set<String> = []

    private var metricStyles: [TokenMetricStyle] {
        [
            TokenMetricStyle(name: "Input Tokens", color: ActivityTokenPalette.input),
            TokenMetricStyle(name: "Output Tokens", color: ActivityTokenPalette.output),
            TokenMetricStyle(name: "Cache Read", color: ActivityTokenPalette.cacheRead),
            TokenMetricStyle(name: "Cache Creation", color: ActivityTokenPalette.cacheCreation),
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

    private var hoveredPoints: [TokenSeriesPoint] {
        guard let item = hoveredUsage else { return [] }
        return [
            TokenSeriesPoint(metric: "Input Tokens", hour: item.hour, value: Double(item.inputTokens)),
            TokenSeriesPoint(metric: "Output Tokens", hour: item.hour, value: Double(item.outputTokens)),
            TokenSeriesPoint(metric: "Cache Read", hour: item.hour, value: Double(item.cacheReadTokens)),
            TokenSeriesPoint(metric: "Cache Creation", hour: item.hour, value: Double(item.cacheCreationTokens)),
        ].filter { !hiddenMetrics.contains($0.metric) }
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
                AreaMark(
                    x: .value("Hour", point.hour),
                    yStart: .value("Baseline", 0),
                    yEnd: .value("Tokens", point.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(by: .value("Metric", point.metric))
                .opacity(0.12)

                LineMark(
                    x: .value("Hour", point.hour),
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
            .chartXScale(domain: 0...23)
            .chartYScale(domain: 0...maxValue)
            .chartXAxis {
                AxisMarks(values: ActivityTokenChartLayout.hourAxisMarks) { value in
                    AxisValueLabel(anchor: .top) {
                        if let hour = value.as(Int.self) {
                            Text(ActivityTokenChartLayout.hourAxisLabel(for: hour))
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

                                verticalGuide(
                                    from: plotAreaFrame.minY,
                                    to: plotAreaFrame.maxY,
                                    x: nowX,
                                    color: Color.secondary.opacity(0.45)
                                )
                                    .allowsHitTesting(false)

                                Text("Now")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(.primary.opacity(0.82))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.14))
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                    .position(
                                        x: min(max(nowX, plotAreaFrame.minX + 18), plotAreaFrame.maxX - 18),
                                        y: plotAreaFrame.minY + 7
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

                                ForEach(hoveredPoints) { point in
                                    if let plotY = proxy.position(forY: point.value) {
                                        chartIntersectionMarker(color: metricColor(for: point.metric))
                                            .position(
                                                x: anchorX,
                                                y: plotAreaFrame.minY + plotY
                                            )
                                            .allowsHitTesting(false)
                                    }
                                }

                                chartTooltip(for: hoveredUsage)
                                    .frame(width: ActivityTokenChartLayout.chartTooltipWidth, alignment: .leading)
                                    .position(
                                        x: tooltipOffset + ActivityTokenChartLayout.chartTooltipWidth / 2,
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

            Text("Hourly breakdown")
                .font(.system(size: 9))
                .foregroundStyle(theme.tooltipForeground.opacity(0.62))

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

    private func verticalGuide(from minY: CGFloat, to maxY: CGFloat, x: CGFloat, color: Color) -> some View {
        Path { path in
            path.move(to: CGPoint(x: x, y: minY))
            path.addLine(to: CGPoint(x: x, y: maxY))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
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
