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
    let data: ActivityChartData
    let isLoading: Bool
    let chartStyle: ActivityChartStyle
    let onToggleChartStyle: () -> Void
    @State private var hoveredIndex: Int?
    @State private var hiddenMetrics: Set<String> = []

    private var metricStyles: [TokenMetricStyle] {
        [
            TokenMetricStyle(name: "Input Tokens", color: ActivityTokenPalette.input),
            TokenMetricStyle(name: "Output Tokens", color: ActivityTokenPalette.output),
            TokenMetricStyle(name: "Cache Read", color: ActivityTokenPalette.cacheRead),
            TokenMetricStyle(name: "Cache Creation", color: ActivityTokenPalette.cacheCreation),
        ]
    }

    private var points: [TokenSeriesPoint] {
        data.usage.flatMap { item in
            [
                TokenSeriesPoint(metric: "Input Tokens", index: item.index, value: Double(item.inputTokens)),
                TokenSeriesPoint(metric: "Output Tokens", index: item.index, value: Double(item.outputTokens)),
                TokenSeriesPoint(metric: "Cache Read", index: item.index, value: Double(item.cacheReadTokens)),
                TokenSeriesPoint(metric: "Cache Creation", index: item.index, value: Double(item.cacheCreationTokens)),
            ]
        }.filter { !hiddenMetrics.contains($0.metric) }
    }

    private var maxValue: Double {
        let maximum = switch chartStyle {
        case .line:
            points.map(\.value).max() ?? 0
        case .bar:
            barSegments.map(\.yEnd).max() ?? 0
        }
        return max(maximum, 1)
    }

    private var barSegments: [TokenBarSegment] {
        let barMetricNames = [
            "Cache Creation",
            "Output Tokens",
            "Input Tokens",
            "Cache Read",
        ]
        return data.usage.flatMap { item in
            var yStart = 0.0
            return barMetricNames.compactMap { metricName -> TokenBarSegment? in
                let value = metricValue(metricName, for: item)
                guard value > 0 else { return nil }

                let segment = TokenBarSegment(
                    metric: metricName,
                    index: item.index,
                    xStart: max(0, Double(item.index) - 0.36),
                    xEnd: min(Double(data.chartDomainEnd), Double(item.index) + 0.36),
                    yStart: yStart,
                    yEnd: yStart + value
                )
                yStart += value
                return segment
            }
        }
    }

    private var hoveredUsage: ActivityChartUsage? {
        guard let hoveredIndex else { return nil }
        return data.usage.first { $0.index == hoveredIndex }
    }

    private var hoveredPoints: [TokenSeriesPoint] {
        guard let item = hoveredUsage else { return [] }
        return [
            TokenSeriesPoint(metric: "Input Tokens", index: item.index, value: Double(item.inputTokens)),
            TokenSeriesPoint(metric: "Output Tokens", index: item.index, value: Double(item.outputTokens)),
            TokenSeriesPoint(metric: "Cache Read", index: item.index, value: Double(item.cacheReadTokens)),
            TokenSeriesPoint(metric: "Cache Creation", index: item.index, value: Double(item.cacheCreationTokens)),
        ].filter { !hiddenMetrics.contains($0.metric) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ActivityTokenChartLayout.chartSectionSpacing) {
            HStack {
                Text(data.chartTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                if let granularityLabel = data.granularityLabel(isLoading: isLoading) {
                    Text(granularityLabel)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.panelTertiaryForeground)
                }
                Spacer()
            }
            .padding(.trailing, MainPanelDesign.headerControlItemHeight)
            .frame(height: ActivityTokenChartLayout.chartHeaderHeight)

            Chart {
                if chartStyle == .line {
                    ForEach(points) { point in
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
                } else {
                    ForEach(barSegments) { segment in
                        barMark(for: segment)
                            .foregroundStyle(metricColor(for: segment.metric))
                    }
                }
            }
            .chartForegroundStyleScale([
                "Input Tokens": ActivityTokenPalette.input,
                "Output Tokens": ActivityTokenPalette.output,
                "Cache Read": ActivityTokenPalette.cacheRead,
                "Cache Creation": ActivityTokenPalette.cacheCreation,
            ])
            .chartXScale(domain: 0...data.chartDomainEnd)
            .chartYScale(domain: 0...maxValue)
            .chartXAxis {
                AxisMarks(values: data.xAxisMarks) { value in
                    if let index = value.as(Int.self) {
                        AxisValueLabel(
                            anchor: index == data.xAxisMarks.first ? .topLeading : .top,
                            collisionResolution: .disabled,
                            horizontalSpacing: index == data.xAxisMarks.first ? 0 : nil
                        ) {
                            if let label = data.axisLabel(for: index) {
                                Text(label)
                                    .foregroundStyle(theme.panelSecondaryForeground)
                            }
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
                            if let nowPosition = data.nowPosition,
                               let plotX = proxy.position(forX: nowPosition) {
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
                                        x: nowX + 38 <= plotAreaFrame.maxX
                                            ? nowX + 20
                                            : nowX - 20,
                                        y: plotAreaFrame.minY + 10
                                    )
                                    .allowsHitTesting(false)
                            }

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

                            if let hoveredUsage,
                               let plotX = proxy.position(forX: hoveredUsage.index) {
                                let anchorX = plotAreaFrame.minX + plotX
                                let tooltipOffset = ActivityTokenChartLayout.tooltipXOffset(
                                    anchorX: anchorX,
                                    tooltipWidth: data.tooltipWidth,
                                    availableWidth: geometry.size.width
                                )

                                if chartStyle == .line {
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
                                }

                                chartTooltip(for: hoveredUsage)
                                    .frame(width: data.tooltipWidth, alignment: .leading)
                                    .position(
                                        x: tooltipOffset + data.tooltipWidth / 2,
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
            .frame(height: ActivityTokenChartLayout.chartLegendHeight)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, ActivityTokenChartLayout.chartVerticalPadding)
        .overlay(alignment: .topTrailing) {
            MainPanelChartStyleSwitchButton(
                currentStyle: chartStyle,
                action: onToggleChartStyle
            )
            .padding(.top, 5)
            .padding(.trailing, 10)
        }
        .frame(height: ActivityTokenChartLayout.drawerHeight)
        .mainPanelGroupedSurface()
        .accessibilityLabel(data.accessibilityLabel)
        .onChange(of: data) { _, _ in
            hoveredIndex = nil
        }
    }

    private func metricValue(_ metric: String, for item: ActivityChartUsage) -> Double {
        guard !hiddenMetrics.contains(metric) else { return 0 }
        return switch metric {
        case "Input Tokens": Double(item.inputTokens)
        case "Output Tokens": Double(item.outputTokens)
        case "Cache Read": Double(item.cacheReadTokens)
        default: Double(item.cacheCreationTokens)
        }
    }

    private func barMark(for segment: TokenBarSegment) -> RectangleMark {
        let xStart: PlottableValue<Double> = .value("Period Start", segment.xStart)
        let xEnd: PlottableValue<Double> = .value("Period End", segment.xEnd)
        let yStart: PlottableValue<Double> = .value("Token Start", segment.yStart)
        let yEnd: PlottableValue<Double> = .value("Token End", segment.yEnd)
        return RectangleMark(xStart: xStart, xEnd: xEnd, yStart: yStart, yEnd: yEnd)
    }

    private func toggleMetric(_ metric: String) {
        if hiddenMetrics.contains(metric) {
            hiddenMetrics.remove(metric)
        } else if hiddenMetrics.count < metricStyles.count - 1 {
            hiddenMetrics.insert(metric)
        }
    }

    private func updateHoveredIndex(
        at location: CGPoint,
        in plotAreaFrame: CGRect,
        proxy: ChartProxy
    ) {
        guard plotAreaFrame.contains(location), !data.usage.isEmpty else {
            hoveredIndex = nil
            return
        }

        let plotX = location.x - plotAreaFrame.minX
        guard let value = proxy.value(atX: plotX, as: Double.self) else { return }
        hoveredIndex = min(max(0, Int(value.rounded())), data.usage.count - 1)
    }

    private func chartTooltip(for item: ActivityChartUsage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(data.periodLabel(for: item))
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
    let index: Int
    let value: Double
    var id: String { "\(metric)-\(index)" }
}

private struct TokenBarSegment: Identifiable {
    let metric: String
    let index: Int
    let xStart: Double
    let xEnd: Double
    let yStart: Double
    let yEnd: Double
    var id: String { "\(metric)-\(index)" }
}

private struct TokenMetricStyle: Identifiable {
    let name: String
    let color: Color
    var id: String { name }
}
