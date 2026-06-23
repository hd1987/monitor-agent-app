import Charts
import SwiftUI

struct ActivityTokenChartView: View {
    @EnvironmentObject var theme: ThemeManager
    let date: String
    let usage: [HourlyTokenUsage]

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
}

private struct TokenSeriesPoint: Identifiable {
    let metric: String
    let hour: Int
    let value: Double
    var id: String { "\(metric)-\(hour)" }
}
